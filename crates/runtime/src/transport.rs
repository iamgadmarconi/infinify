// SPDX-License-Identifier: GPL-3.0-or-later
use crate::{Identity, Readback, valid_matrix, valid_rect};
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};
#[cfg(target_os = "macos")]
use std::os::fd::AsRawFd;
use std::{
    fs,
    io::{Read, Write},
    net::Shutdown,
    os::unix::{
        fs::{FileTypeExt, MetadataExt},
        net::UnixStream,
    },
    path::Path,
    time::{Duration, Instant},
};

// Wire contract: native/privileged/protocol2.h. Decode little-endian fields
// explicitly: neither Rust struct padding nor a host ABI enters the protocol.
const MAX_BODY: usize = 131_072;
const HELLO: u16 = 1;
const FRAME: u16 = 2;
const HEARTBEAT: u16 = 3;
const RESTORE_ALL: u16 = 4;
const PROBE: u16 = 5;
const INSPECT: u16 = 7;
const REQUIRED_CAPS: u32 = 2 | 4 | 16;
const DEADLINE: Duration = Duration::from_secs(1);

struct Fields<'a>(&'a [u8]);
impl Fields<'_> {
    fn take<const N: usize>(&mut self) -> Result<[u8; N]> {
        let head = self.0.get(..N).context("truncated helper response")?;
        let value = head.try_into().context("invalid helper field")?;
        self.0 = &self.0[N..];
        Ok(value)
    }
    fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_le_bytes(self.take()?))
    }
    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take()?))
    }
    fn i32(&mut self) -> Result<i32> {
        Ok(i32::from_le_bytes(self.take()?))
    }
    fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.take()?))
    }
    fn doubles<const N: usize>(&mut self) -> Result<[f64; N]> {
        let mut values = [0.0; N];
        for value in &mut values {
            *value = f64::from_le_bytes(self.take()?);
        }
        Ok(values)
    }
    fn identity(&mut self) -> Result<Identity> {
        let pid = self.i32()?;
        let wid = self.u32()?;
        let birth_sec = self.u64()?;
        let birth_usec = self.u64()?;
        ensure!(
            pid > 0 && wid > 0 && birth_sec > 0 && birth_usec < 1_000_000,
            "invalid helper identity"
        );
        Ok(Identity {
            pid,
            wid,
            birth_sec,
            birth_usec: birth_usec as u32,
            owner: 0,
        })
    }
    fn finish(self) -> Result<()> {
        ensure!(self.0.is_empty(), "extra helper response bytes");
        Ok(())
    }
}
fn identity_bytes(who: &Identity) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(24);
    bytes.extend(who.pid.to_le_bytes());
    bytes.extend(who.wid.to_le_bytes());
    bytes.extend(who.birth_sec.to_le_bytes());
    bytes.extend(u64::from(who.birth_usec).to_le_bytes());
    bytes
}

// Deliberately no Debug implementation: the HELLO secret must never enter logs.
pub(crate) struct Client {
    stream: UnixStream,
    seq: u64,
    server_pid: i32,
    scope: u32,
    caps: u32,
    queue: u32,
    lease_ms: u32,
}
impl Client {
    pub(crate) fn connect(directory: &Path, nonce: String) -> Result<Self> {
        ensure!(
            nonce.len() == 64
                && nonce
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)),
            "nonce must be 64 lowercase hexadecimal characters"
        );
        // SAFETY: getuid has no pointer arguments or preconditions.
        let uid = unsafe { libc::getuid() };
        let dir = fs::symlink_metadata(directory)
            .context("private helper directory unavailable; explicitly start the helper first")?;
        ensure!(
            dir.is_dir() && dir.uid() == uid && dir.mode() & 0o777 == 0o700,
            "helper directory must be a same-UID, non-symlink 0700 directory"
        );
        let path = directory.join("v2.sock");
        let socket = fs::symlink_metadata(&path)
            .context("helper socket unavailable; privileged helper is not running")?;
        ensure!(
            socket.file_type().is_socket() && socket.uid() == uid && socket.mode() & 0o777 == 0o600,
            "helper socket must be a same-UID 0600 socket"
        );
        let stream =
            UnixStream::connect(path).context("cannot connect to explicitly selected helper")?;
        let peer_pid = authenticate_peer(&stream, uid)?;
        let mut client = Self {
            stream,
            seq: 0,
            server_pid: peer_pid,
            scope: 0,
            caps: 0,
            queue: 0,
            lease_ms: 0,
        };
        let mut hello = Vec::with_capacity(88);
        hello.extend(b"DWv2");
        hello.extend(2_u16.to_le_bytes());
        hello.extend(1_u16.to_le_bytes());
        hello.extend(nonce.as_bytes());
        hello.extend([0_u8; 16]);
        let bytes = client.exchange(HELLO, &hello)?;
        let mut fields = Fields(&bytes);
        let status = fields.u32()?;
        ensure!(
            status == 0,
            "helper refused protocol v2 session (status {status})"
        );
        client.lease_ms = fields.u32()?;
        let records = fields.u32()?;
        let max_body = fields.u32()?;
        client.caps = fields.u32()?;
        client.scope = fields.u32()?;
        client.queue = fields.u32()?;
        ensure!(
            fields.i32()? == peer_pid,
            "helper response does not match kernel peer PID"
        );
        let token = fields.take::<16>()?;
        fields.finish()?;
        ensure!(
            (1..=1024).contains(&records)
                && max_body as usize <= MAX_BODY
                && max_body >= 8 + 80 * records
                && client.lease_ms == 2000
                && (1..=3).contains(&client.scope)
                && client.queue <= 1
                && token.iter().any(|b| *b != 0),
            "invalid helper v2 negotiation"
        );
        ensure!(
            client.caps & REQUIRED_CAPS == REQUIRED_CAPS,
            "helper lacks required restoration, scope audit or native inspection capability; rebuild it"
        );
        Ok(client)
    }
    fn exchange(&mut self, kind: u16, body: &[u8]) -> Result<Vec<u8>> {
        ensure!(
            body.len() <= MAX_BODY,
            "helper request exceeds protocol limit"
        );
        self.seq = self
            .seq
            .checked_add(1)
            .context("helper sequence exhausted")?;
        let mut packet = Vec::with_capacity(16 + body.len());
        packet.extend((body.len() as u32).to_le_bytes());
        packet.extend(kind.to_le_bytes());
        packet.extend(0_u16.to_le_bytes());
        packet.extend(self.seq.to_le_bytes());
        packet.extend(body);
        let deadline = Instant::now() + DEADLINE;
        let result = (|| {
            let mut remaining = packet.as_slice();
            while !remaining.is_empty() {
                self.stream.set_write_timeout(Some(time_left(deadline)?))?;
                let sent = self.stream.write(remaining)?;
                ensure!(sent > 0, "helper disconnected during request");
                remaining = &remaining[sent..];
            }
            let mut header = [0_u8; 16];
            read_until(&mut self.stream, &mut header, deadline)?;
            let mut fields = Fields(&header);
            let length = fields.u32()? as usize;
            ensure!(
                length <= MAX_BODY
                    && fields.u16()? == kind | 0x8000
                    && fields.u16()? == 0
                    && fields.u64()? == self.seq,
                "invalid helper reply header"
            );
            let mut reply = vec![0; length];
            read_until(&mut self.stream, &mut reply, deadline)?;
            Ok(reply)
        })();
        if result.is_err() {
            self.disconnect();
        }
        result
    }
    fn inspect_native(&mut self, wanted: &Identity) -> Result<(Identity, Readback)> {
        let bytes = self.exchange(INSPECT, &identity_bytes(wanted))?;
        ensure!(bytes.len() == 144, "invalid native inspection size");
        let mut fields = Fields(&bytes);
        let mut who = fields.identity()?;
        ensure!(
            who.pid == wanted.pid
                && who.wid == wanted.wid
                && who.birth_sec == wanted.birth_sec
                && who.birth_usec == wanted.birth_usec,
            "native inspection identity mismatch"
        );
        let status = fields.u32()?;
        ensure!(
            status == 0,
            "helper refused native inspection (status {status})"
        );
        who.owner = fields.i32()?;
        let state = Readback {
            readback_ok: true,
            matrix: fields.doubles()?,
            bounds: fields.doubles()?,
            screen_rect: fields.doubles()?,
        };
        fields.finish()?;
        valid_matrix(state.matrix)?;
        valid_rect(state.bounds)?;
        valid_rect(state.screen_rect)?;
        Ok((who, state))
    }
    pub(crate) fn inspect(&mut self, wanted: &Identity) -> Result<Readback> {
        let (who, state) = self.inspect_native(wanted)?;
        ensure!(&who == wanted, "native window owner changed");
        Ok(state)
    }
    pub(crate) fn apply(&mut self, who: &Identity, matrix: [f64; 6]) -> Result<Readback> {
        // Session verifies the expected native state and owner immediately
        // before this frame; the server independently revalidates its identity.
        let mut body = Vec::with_capacity(88);
        body.extend(1_u32.to_le_bytes());
        body.extend(0_u32.to_le_bytes());
        body.extend(identity_bytes(who));
        for value in matrix {
            body.extend(value.to_le_bytes());
        }
        body.extend(0_f32.to_le_bytes());
        body.extend(0_u32.to_le_bytes());
        let bytes = self.exchange(FRAME, &body)?;
        let mut fields = Fields(&bytes);
        ensure!(
            fields.u32()? == 0 && fields.u32()? == 1 && fields.u32()? == 0 && fields.u32()? == 0,
            "native frame was dropped or malformed"
        );
        fields.u64()?;
        let [status] = fields.take::<1>()?;
        fields.finish()?;
        ensure!(
            status == 0,
            "native frame was not applied (status {status})"
        );
        self.inspect(who)
    }
    pub(crate) fn heartbeat(&mut self) -> Result<()> {
        let bytes = self.exchange(HEARTBEAT, &[])?;
        let mut fields = Fields(&bytes);
        ensure!(
            fields.u32()? == 0 && fields.u32()? == self.lease_ms,
            "helper lease was lost"
        );
        fields.u32()?;
        ensure!(
            fields.u32()? == 0,
            "helper began restoration during session"
        );
        fields.finish()
    }
    pub(crate) fn restore(&mut self, who: &Identity) -> Result<Readback> {
        let bytes = self.exchange(RESTORE_ALL, &[])?;
        let mut fields = Fields(&bytes);
        let count = fields.u32()?;
        ensure!(
            count <= 1 && fields.u32()? == 0 && fields.u32()? == 1 && fields.u32()? == 0,
            "native restoration or its journal is pending"
        );
        for _ in 0..count {
            let actual = fields.identity()?;
            ensure!(
                identity_bytes(&actual) == identity_bytes(who)
                    && fields.u32()? == 0
                    && fields.i32()? == 0,
                "selected native window did not restore"
            );
        }
        fields.finish()?;
        self.inspect(who)
    }
    pub(crate) fn probe(&mut self) -> Result<Value> {
        let bytes = self.exchange(PROBE, &[])?;
        let mut fields = Fields(&bytes);
        ensure!(
            fields.u32()? == self.scope
                && fields.u32()? == self.caps
                && fields.u32()? == self.queue
                && fields.u32()? == self.lease_ms
                && fields.i32()? == self.server_pid,
            "helper probe contradicts negotiation"
        );
        let held = fields.u32()?;
        let restoring = fields.u32()?;
        ensure!(
            fields.u32()? == 0,
            "helper restoration journal is still pending"
        );
        let received = fields.u64()?;
        let applied = fields.u64()?;
        let superseded = fields.u64()?;
        let journal_writes = fields.u64()?;
        let count = fields.u32()?;
        let fixtures = fields.u32()?;
        ensure!(
            count <= 1024 && fixtures <= 16 && held.checked_add(restoring) == Some(count),
            "invalid helper probe counts"
        );
        // A new client never adopts a prior session's restoration table.
        ensure!(
            count == 0,
            "helper still has native restoration obligations"
        );
        let mut identities = Vec::with_capacity(fixtures as usize);
        for _ in 0..fixtures {
            identities.push(fields.identity()?);
        }
        fields.finish()?;
        let mut windows = Vec::with_capacity(identities.len());
        for who in identities {
            let (identity, readback) = self.inspect_native(&who)?;
            windows.push(json!({"identity":identity,"readback":readback}));
        }
        Ok(
            json!({"v":2,"ok":true,"scope":self.scope,"server_pid":self.server_pid,"caps":self.caps,"held":held,"restoring":restoring,"frames_received":received,"frames_applied":applied,"frames_superseded":superseded,"journal_writes":journal_writes,"windows":windows}),
        )
    }
    pub(crate) fn disconnect(&self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}
fn time_left(deadline: Instant) -> Result<Duration> {
    let left = deadline
        .checked_duration_since(Instant::now())
        .context("helper response deadline exceeded")?;
    ensure!(!left.is_zero(), "helper response deadline exceeded");
    Ok(left)
}
fn read_until(stream: &mut UnixStream, mut bytes: &mut [u8], deadline: Instant) -> Result<()> {
    while !bytes.is_empty() {
        stream.set_read_timeout(Some(time_left(deadline)?))?;
        let count = stream
            .read(bytes)
            .context("helper disconnected or timed out; native state is unacknowledged")?;
        ensure!(
            count > 0,
            "helper disconnected; native state is unacknowledged"
        );
        bytes = &mut bytes[count..];
    }
    Ok(())
}
#[cfg(target_os = "macos")]
fn authenticate_peer(stream: &UnixStream, uid: u32) -> Result<i32> {
    let (mut peer_uid, mut peer_gid, mut peer_pid) = (0, 0, 0_i32);
    let mut length = std::mem::size_of_val(&peer_pid) as libc::socklen_t;
    // SAFETY: live socket and valid output buffers with matching lengths. The
    // kernel authenticates peer UID and PID independently of HELLO claims.
    let status = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut peer_uid, &mut peer_gid) };
    ensure!(
        status == 0 && peer_uid == uid,
        "helper peer UID authentication failed"
    );
    // SAFETY: as above; LOCAL_PEERPID returns one pid_t.
    let status = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            0,
            2,
            (&mut peer_pid as *mut i32).cast(),
            &mut length,
        )
    };
    ensure!(
        status == 0 && length as usize == std::mem::size_of_val(&peer_pid) && peer_pid > 1,
        "helper peer PID authentication failed"
    );
    Ok(peer_pid)
}
#[cfg(not(target_os = "macos"))]
fn authenticate_peer(_stream: &UnixStream, _uid: u32) -> Result<i32> {
    anyhow::bail!("helper peer authentication requires macOS")
}
