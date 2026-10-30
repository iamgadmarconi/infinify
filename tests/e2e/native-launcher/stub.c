// SPDX-License-Identifier: GPL-3.0-or-later
// One signed stand-in for the bundle's doctor, loader, payload and app, for tests/e2e/native-launcher.sh. It does what the
// launcher can observe of them (the Dock identity query, the daemon's status/ping/load, the exec of the app) and writes what the
// real helper writes into a runtime (journal, sidecar) so the launcher's recovery checks have something to read. It loads nothing.
// Behaviour comes from the file name it is run as and from files in $STUB_DIR.
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static const char *dir(void) { const char *d = getenv("STUB_DIR"); if (!d) { fputs("stub: STUB_DIR unset\n", stderr); exit(99); } return d; }
static void path(char *out, size_t n, const char *name) { snprintf(out, n, "%s/%s", dir(), name); }
static int exists(const char *name) { char p[1024]; path(p, sizeof p, name); return access(p, F_OK) == 0; }
static int slurp(const char *file, char *buf, size_t n) {
    FILE *f = fopen(file, "r"); if (!f) return -1;
    size_t got = fread(buf, 1, n - 1, f); fclose(f); buf[got] = 0; return (int)got;
}
static void append(const char *name, const char *line) {
    char p[1024]; path(p, sizeof p, name);
    FILE *f = fopen(p, "a"); if (!f) return; fputs(line, f); fputc('\n', f); fclose(f);
}
static void bootuuid(char out[37]) {
    size_t size = 37; out[0] = 0;
    if (sysctlbyname("kern.bootsessionuuid", out, &size, NULL, 0)) { fputs("stub: no boot uuid\n", stderr); exit(98); }
}
static void sha256hex(const char *file, char out[65]) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; static char data[1 << 20];
    int n = slurp(file, data, sizeof data); if (n < 0) n = 0;
    CC_SHA256(data, (CC_LONG)n, digest);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) sprintf(out + 2 * i, "%02x", digest[i]);
}
static int dock(long *pid, long long *sec, long long *usec) {
    char p[1024], text[256]; path(p, sizeof p, "dock");
    int countdown = 0; char c[1024]; path(c, sizeof c, "dock-absent-queries");
    if (slurp(c, text, sizeof text) > 0) {
        countdown = atoi(text);
        if (countdown > 0) { snprintf(text, sizeof text, "%d", countdown - 1); FILE *f = fopen(c, "w"); if (f) { fputs(text, f); fclose(f); } return -1; }
    }
    if (slurp(p, text, sizeof text) < 0) return -1;
    return sscanf(text, "%ld %lld %lld", pid, sec, usec) == 3 ? 0 : -1;
}
// Where the daemon stages the payload for a runtime (the real one: /private/var/run/infinify-payload.SUFFIX, root's); here a directory of the throwaway state.
static void staged_dir(char *out, size_t n, const char *runtime) {
    const char *suffix = strrchr(runtime, '.'); char root[1024]; path(root, sizeof root, "staged");
    snprintf(out, n, "%s/infinify-payload.%s", root, suffix ? suffix + 1 : "");
}
// What the daemon and loader leave behind for a load: the payload copy and its sidecar in the staged directory, the journal in the runtime.
static int helper(char **a, int n) {
    // a: RUNTIME --nonce-file NONCE --desktop --expected-dock PID SEC USEC [--recover-journal J --expected-retired-dock P S U]
    // There is no payload argument any more: the daemon names the copy it stages, so a payload path among them is a failure.
    if (n != 8 && n != 14) { fprintf(stderr, "stub: %d load arguments\n", n); return 2; }
    if (exists("daemon-load-fails")) { fputs("stub: load refused by request\n", stderr); return 1; }
    const char *runtime = a[0]; char p[1100], boot[37], text[8192]; bootuuid(boot);
    int recovering = n == 14;
    char sourceHash[65] = "";
    if (recovering) {
        snprintf(p, sizeof p, "%s/recovery-source.json", runtime);
        int in = open(a[9], O_RDONLY), out = open(p, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (in < 0 || out < 0) { fputs("stub: cannot stage the recovery source\n", stderr); return 1; }
        char buf[65536]; ssize_t got = read(in, buf, sizeof buf);
        if (got <= 0 || write(out, buf, (size_t)got) != got) return 1;
        close(in); close(out); sha256hex(p, sourceHash);
    }
    // The staged copy of the bundle's payload (STUB_PAYLOAD), and the sidecar beside it.
    char dir[1100], staged[1200]; staged_dir(dir, sizeof dir, runtime);
    char root[1024]; path(root, sizeof root, "staged"); mkdir(root, 0700);
    if (mkdir(dir, 0700)) { fputs("stub: a payload is already staged for this runtime\n", stderr); return 1; }
    snprintf(staged, sizeof staged, "%s/payload-arm64e.dylib", dir);
    const char *bundled = getenv("STUB_PAYLOAD"); static char bytes[1 << 20]; int got = bundled ? slurp(bundled, bytes, sizeof bytes) : -1;
    if (got < 0) { fputs("stub: STUB_PAYLOAD unset\n", stderr); return 1; }
    int copy = open(staged, O_WRONLY | O_CREAT | O_EXCL, 0644); if (copy < 0 || write(copy, bytes, (size_t)got) != got) return 1; close(copy);
    snprintf(p, sizeof p, "%s.json", staged);
    int fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0600); if (fd < 0) { fputs("stub: sidecar exists\n", stderr); return 1; }
    if (recovering) snprintf(text, sizeof text, "{\"runtime\":\"%s\",\"nonce\":\"stub\",\"recovery_source_sha256\":\"%s\",\"recovery_server_pid\":%s,\"recovery_server_birth_sec\":%s,\"recovery_server_birth_usec\":%s,\"recovery_server_uid\":%u,\"recovery_boot_uuid\":\"%s\"}", runtime, sourceHash, a[11], a[12], a[13], getuid(), boot);
    else snprintf(text, sizeof text, "{\"runtime\":\"%s\",\"nonce\":\"stub\"}", runtime);
    if (write(fd, text, strlen(text)) < 0) return 1; close(fd);
    snprintf(p, sizeof p, "%s/v2-journal.json", runtime);
    fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0600); if (fd < 0) return 1;
    snprintf(text, sizeof text, "{\"v\":3,\"server_pid\":%s,\"server_birth_sec\":%s,\"server_birth_usec\":%s,\"server_uid\":%u,\"boot_uuid\":\"%s\",\"generation\":1,\"state\":\"empty\",\"windows\":[],\"released_windows\":[],\"last_restore\":{}}", a[5], a[6], a[7], getuid(), boot);
    if (write(fd, text, strlen(text)) < 0) return 1; close(fd);
    fputs("stub: authenticated v2 helper ready in Dock (stub)\n", stderr);
    return 0;
}
int main(int argc, char **argv) {
    char *self = basename(argv[0]);
    if (!strcmp(self, "doctor")) { puts("{\"injection_preflight_passed\":true}"); return 0; }
    if (!strcmp(self, "loader-arm64e")) {
        if (argc == 2 && !strcmp(argv[1], "--dock-identity")) {
            long pid; long long sec, usec; char boot[37];
            if (dock(&pid, &sec, &usec)) { fputs("could not locate stable Dock identity\n", stderr); return 1; }
            bootuuid(boot);
            printf("{\"pid\":%ld,\"birth_sec\":%lld,\"birth_usec\":%lld,\"uid\":%u,\"boot_uuid\":\"%s\"}\n", pid, sec, usec, getuid(), boot);
            return 0;
        }
        append("loader-calls", argc > 1 ? argv[1] : "");   // the sudo path: the tests never take it
        return 1;
    }
    if (!strcmp(self, "Infinify")) {
        if (argc >= 3 && !strcmp(argv[1], "native-desktop") && !strcmp(argv[2], "daemon")) {
            const char *verb = argc > 3 ? argv[3] : "";
            if (!strcmp(verb, "status")) { int on = exists("daemon-enabled"); puts(on ? "enabled" : "not-registered"); return on ? 0 : 1; }
            if (!strcmp(verb, "ping")) { append("daemon-pings", ""); return exists("daemon-ping-fails") ? 1 : 0; }
            if (!strcmp(verb, "staged") && argc == 5) {
                // The read-only report of the payload staged for a runtime: "DIRECTORY SHA256", or nothing.
                char dir[1100], file[1200], digest[65]; staged_dir(dir, sizeof dir, argv[4]);
                snprintf(file, sizeof file, "%s/payload-arm64e.dylib", dir);
                if (access(file, F_OK)) { fprintf(stderr, "no staged payload for %s\n", argv[4]); return 1; }
                sha256hex(file, digest); printf("%s %s\n", dir, digest); return 0;
            }
            if (!strcmp(verb, "load")) {
                char line[4096] = ""; for (int i = 4; i < argc; i++) { strcat(line, argv[i]); strcat(line, " "); }
                append("daemon-loads", line);
                return helper(argv + 4, argc - 4);
            }
            return 64;
        }
        if (argc == 2 && !strcmp(argv[1], "stub-reload-parent")) {
            // The running app asking for a reload: the launcher is its child, and its descriptor 1 is the app's pipe.
            const char *launcher = getenv("STUB_LAUNCHER"); int fds[2]; if (!launcher || pipe(fds)) return 97;
            pid_t child = fork();
            if (child == 0) { dup2(fds[1], 1); close(fds[0]); close(fds[1]); execl(launcher, launcher, "--reload", (char *)NULL); _exit(96); }
            close(fds[1]); char buf[65536]; size_t used = 0; ssize_t got;
            while ((got = read(fds[0], buf + used, sizeof buf - 1 - used)) > 0) used += (size_t)got;
            buf[used] = 0; int status = 0; waitpid(child, &status, 0);
            fputs(buf, stdout); return WIFEXITED(status) ? WEXITSTATUS(status) : 95;
        }
        if (argc == 2 && !strcmp(argv[1], "stub-sleep")) { sleep(30); return 0; }
        // The exec of the app at the end of a launch.
        char line[4096]; snprintf(line, sizeof line, "args:"); for (int i = 1; i < argc; i++) { strcat(line, " "); strcat(line, argv[i]); }
        append("app-launch", line);
        snprintf(line, sizeof line, "env: reload=%s sha=%s loaded_at=%s", getenv("INFINIFY_DOCK_RELOAD") ?: "-", getenv("INFINIFY_NATIVE_PAYLOAD_SHA256") ?: "-", getenv("INFINIFY_NATIVE_LOADED_AT") ?: "-");
        append("app-launch", line);
        return 0;
    }
    return 0; // payload-arm64e.dylib and loadd are only hashed and signature-checked by the launcher
}
