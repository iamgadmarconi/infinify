// SPDX-License-Identifier: GPL-3.0-or-later
// Where the Dock opens its payload from when the launch daemon loaded it, and the rule for that place.
//
// The daemon (Daemon.m) copies the bundled payload to ROOT/infinify-payload.XXXXXX/payload-arm64e.dylib, a directory it
// makes, owned by root, mode 0755, holding one 0644 root-owned file, below a chain of directories only root writes. The
// loader (DWLoader.m) then injects that path and the Dock dlopens it, so no file the login user can write or replace is on
// that path. DWLoader.m enforces the rule here just before injecting; DWLoaddRequest.m creates the place and inspects it.
// Header-only and plain C, like DWPreflight.h, so the loader's own bytes (which the daemon pins by digest) need no new
// translation unit.
//
// The payload's adjacent sidecar (payload-arm64e.dylib.json) is the one login-user-owned file in that directory: the
// payload must read it as the Dock's user (mode 0600, the user's), and it carries the runtime path, the nonce and the
// recovery import facts. It is configuration the payload validates, not code: it cannot be renamed, replaced or linked (the
// directory is root's), and rewriting its bytes only changes how the user's own helper is configured, which the loader's
// authenticated readiness audit (scope, capabilities, journal state) then fails to see as the one it asked for.
#ifndef DW_STAGED_PAYLOAD_H
#define DW_STAGED_PAYLOAD_H
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// /var is a symbolic link to private/var, and nothing on the path may be a link, so the real name is used.
#define DW_STAGED_ROOT "/private/var/run"
#define DW_STAGED_PREFIX "infinify-payload."
#define DW_STAGED_NAME "payload-arm64e.dylib"
#define DW_STAGED_SUFFIX_LENGTH 6

static int dw_staged_alnum(char c) { return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }

// Does `path` have the form ROOT/infinify-payload.XXXXXX/payload-arm64e.dylib (six letters or digits)? On success the
// directory part (ROOT/infinify-payload.XXXXXX) is copied to `directory`.
static int dw_staged_path_form(const char *path, const char *root, char *directory, size_t capacity) {
    size_t rootLength = strlen(root), prefixLength = strlen(DW_STAGED_PREFIX);
    if (!path || path[0] != '/' || strncmp(path, root, rootLength) || path[rootLength] != '/') return 0;
    const char *name = path + rootLength + 1;
    if (strncmp(name, DW_STAGED_PREFIX, prefixLength)) return 0;
    for (size_t i = 0; i < DW_STAGED_SUFFIX_LENGTH; i++) if (!dw_staged_alnum(name[prefixLength + i])) return 0;
    const char *tail = name + prefixLength + DW_STAGED_SUFFIX_LENGTH;
    if (tail[0] != '/' || strcmp(tail + 1, DW_STAGED_NAME)) return 0;
    size_t directoryLength = rootLength + 1 + prefixLength + DW_STAGED_SUFFIX_LENGTH;
    if (directoryLength >= capacity) return 0;
    memcpy(directory, path, directoryLength);
    directory[directoryLength] = 0;
    return 1;
}

// Is `gid` one of the groups of the login user `uid`? A directory that group may write is the login user's to change then.
static int dw_staged_user_in_group(uid_t uid, gid_t gid) {
    struct passwd *pw = getpwuid(uid);
    if (!pw) return 1;   // an unknown user cannot be cleared: treat as a member
    int groups[64];
    int count = 64;
    if (getgrouplist(pw->pw_name, (int)pw->pw_gid, groups, &count) < 0) return 1;
    for (int i = 0; i < count; i++) if ((gid_t)groups[i] == gid) return 1;
    return (gid_t)pw->pw_gid == gid;
}

// A directory on the chain: root's (or `trusted`, the test's own user in the regression, root in production), not writable
// by everyone, and writable by a group only if that group does not contain the login user. `strict` (the staged directory
// itself) allows no group or other write at all.
static const char *dw_staged_directory_refusal(const struct stat *st, uid_t trusted, uid_t login, int strict) {
    if (!S_ISDIR(st->st_mode)) return "is not a directory";
    if (st->st_uid != 0 && st->st_uid != trusted) return "belongs to neither root nor the trusted owner";
    if (st->st_mode & S_IWOTH) return "is writable by everyone";
    if (st->st_mode & S_IWGRP) {
        if (strict) return "is group-writable";
        if (dw_staged_user_in_group(login, st->st_gid)) return "is writable by a group the login user is in";
    }
    return NULL;
}

// NULL when `path` is a payload staged by the daemon and nothing the login user can write is on the way to it, else the
// reason. `root` is DW_STAGED_ROOT (the regression passes a directory of its own), `trusted` the owner of the staged
// directory and the payload (0 in production), `login` the login user whose groups must not be able to write the chain.
//   - the path has the exact form above and every component is opened without following a link;
//   - every directory above the staged directory is owned by root (or `trusted`), not other-writable, and group-writable
//     only by a group the login user is not in (/private/var/run is root:daemon 0775);
//   - the staged directory and the payload are owned by `trusted`, writable by no group or other (and no setid bits), and
//     the payload is a regular file with one link.
static const char *dw_staged_payload_refusal(const char *path, const char *root, uid_t trusted, uid_t login) {
    char directory[PATH_MAX];
    if (!dw_staged_path_form(path, root, directory, sizeof(directory))) return "the payload is not at a staged-payload path";
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return "cannot open /";
    const char *failure = NULL;
    size_t directoryLength = strlen(directory), cursor = 1;
    while (!failure && cursor <= directoryLength) {
        size_t end = cursor;
        while (end < directoryLength && directory[end] != '/') end++;
        char component[NAME_MAX + 1];
        if (end == cursor || end - cursor > NAME_MAX) { failure = "the path has an empty or long component"; break; }
        memcpy(component, directory + cursor, end - cursor);
        component[end - cursor] = 0;
        int next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd);
        fd = next;
        if (fd < 0) { failure = "a component of the path is missing, a link or not a directory"; break; }
        struct stat st;
        if (fstat(fd, &st)) { failure = "a component of the path cannot be inspected"; break; }
        int last = end >= directoryLength;
        if (dw_staged_directory_refusal(&st, trusted, login, last)) { failure = last ? "the staged directory is not a non-writable directory of the trusted owner" : "a directory above the staged payload can be changed by the login user"; break; }
        if (last && (st.st_uid != trusted || (st.st_mode & 07022))) { failure = "the staged directory is not a non-writable directory of the trusted owner"; break; }
        cursor = end + 1;
    }
    if (failure) { close(fd); return failure; }
    int file = openat(fd, DW_STAGED_NAME, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    close(fd);
    if (file < 0) return "the staged payload cannot be opened (missing, or a link)";
    struct stat st;
    int bad = fstat(file, &st);
    close(file);
    if (bad || !S_ISREG(st.st_mode)) return "the staged payload is not a regular file";
    if (st.st_uid != trusted) return "the staged payload belongs to someone other than the trusted owner";
    if (st.st_mode & 07022) return "the staged payload can be written by someone besides its owner";
    if (st.st_nlink != 1) return "the staged payload has another link";
    if (st.st_size <= 0) return "the staged payload is empty";
    return NULL;
}
#endif
