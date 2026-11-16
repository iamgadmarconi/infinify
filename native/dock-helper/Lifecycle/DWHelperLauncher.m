// SPDX-License-Identifier: GPL-3.0-or-later
// Compiled port of scripts/native-desktop-launcher.sh (post-preflight lifecycle, launch records,
// pause policy, same-Dock code-identity reuse, single Dock restart and retired-journal recovery).
#import "DWHelperLauncher.h"
#import "DWHelperMacEnvironment.h"
#import "DWJournalFields.h"
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>

static NSString *const kLauncherUsage = @"usage: Infinify.app/Contents/Resources/NativeDesktop/launch.sh [--check]";
static const uint64_t kJournalSchema = 4;
static const uint64_t kMaxJournalSize = 4194304;

static char gActiveLockPath[PATH_MAX];
static volatile sig_atomic_t gActiveLockHeld;
static struct sigaction gSavedINT, gSavedHUP, gSavedTERM;
static BOOL gSignalsInstalled;

static void dwLauncherSignalHandler(int sig) {
    if (gActiveLockHeld && gActiveLockPath[0]) {
        rmdir(gActiveLockPath);
        gActiveLockHeld = 0;
    }
    int status = (sig == SIGINT) ? 130 : (sig == SIGHUP) ? 129 : 143;
    _exit(status);
}

static void dwInstallLockSignals(const char *fsLockPath) {
    if (!fsLockPath || strlen(fsLockPath) >= sizeof(gActiveLockPath)) return;
    memcpy(gActiveLockPath, fsLockPath, strlen(fsLockPath) + 1);
    gActiveLockHeld = 1;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = dwLauncherSignalHandler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, &gSavedINT);
    sigaction(SIGHUP, &sa, &gSavedHUP);
    sigaction(SIGTERM, &sa, &gSavedTERM);
    gSignalsInstalled = YES;
}

static void dwRestoreLockSignals(void) {
    gActiveLockHeld = 0;
    gActiveLockPath[0] = '\0';
    if (gSignalsInstalled) {
        sigaction(SIGINT, &gSavedINT, NULL);
        sigaction(SIGHUP, &gSavedHUP, NULL);
        sigaction(SIGTERM, &gSavedTERM, NULL);
        gSignalsInstalled = NO;
    }
}

static BOOL dwWriteAllFD(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = (const uint8_t *)bytes;
    while (length > 0) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        cursor += (size_t)written;
        length -= (size_t)written;
    }
    return YES;
}

static NSString *dwStripTrailingNewlines(NSString *text) {
    if (!text.length) return @"";
    NSUInteger end = text.length;
    while (end > 0 && [text characterAtIndex:end - 1] == '\n') end--;
    return [text substringToIndex:end];
}

static BOOL dwValidHexLower(NSString *value, NSUInteger expectedLength) {
    if (![value isKindOfClass:NSString.class] || value.length != expectedLength) return NO;
    for (NSUInteger i = 0; i < expectedLength; i++) {
        unichar c = [value characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return NO;
    }
    return YES;
}

static BOOL dwIsBool(id value) {
    return value != nil && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

static BOOL dwExtractInteger(id value, uint64_t *unsignedOut, BOOL *negativeOut) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    if (CFNumberIsFloatType((__bridge CFNumberRef)value)) return NO;
    const char *objCType = [value objCType];
    if (objCType && objCType[0] == 'Q') {
        if (negativeOut) *negativeOut = NO;
        if (unsignedOut) *unsignedOut = [value unsignedLongLongValue];
        return YES;
    }
    long long signedVal = [value longLongValue];
    if (signedVal < 0) {
        if (negativeOut) *negativeOut = YES;
        if (unsignedOut) *unsignedOut = 0ULL - (uint64_t)signedVal;
        return YES;
    }
    if (negativeOut) *negativeOut = NO;
    if (unsignedOut) *unsignedOut = (uint64_t)signedVal;
    return YES;
}

static NSString *dwCanonicalIntegerString(id value) {
    uint64_t mag = 0;
    BOOL neg = NO;
    if (!dwExtractInteger(value, &mag, &neg)) return nil;
    if (neg) return [NSString stringWithFormat:@"-%llu", (unsigned long long)mag];
    return [NSString stringWithFormat:@"%llu", (unsigned long long)mag];
}

static BOOL dwPIDValid(uint64_t value, BOOL negative) {
    return !negative && value >= 1 && value <= 2147483647ULL;
}

static void dwCollectPlistKeysRecursively(id obj, NSMutableArray<NSString *> *keys) {
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)obj;
        for (id key in dict) {
            if ([key isKindOfClass:NSString.class]) [keys addObject:(NSString *)key];
            dwCollectPlistKeysRecursively(dict[key], keys);
        }
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id item in (NSArray *)obj) {
            dwCollectPlistKeysRecursively(item, keys);
        }
    }
}

static BOOL dwReadRegularFileNoFollow(NSString *fsPath, size_t maxBytes, NSData *__autoreleasing *outData) {
    if (!fsPath.length) return NO;
    int fd = open(fsPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return NO;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0 || (uint64_t)st.st_size > (uint64_t)maxBytes) {
        close(fd);
        return NO;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    uint8_t *cursor = (uint8_t *)data.mutableBytes;
    size_t remaining = (size_t)st.st_size;
    BOOL ok = YES;
    while (remaining > 0) {
        ssize_t got = read(fd, cursor, remaining);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) { ok = NO; break; }
        cursor += (size_t)got;
        remaining -= (size_t)got;
    }
    if (ok) {
        char extra = 0;
        ssize_t more = 0;
        do { more = read(fd, &extra, 1); } while (more < 0 && errno == EINTR);
        if (more != 0) ok = NO;
    }
    close(fd);
    if (!ok) return NO;
    if (outData) *outData = data;
    return YES;
}

static NSString *dwSHA256HexOfRegularFile(NSString *fsPath) {
    if (!fsPath.length) return nil;
    int fd = open(fsPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size < 0) {
        close(fd);
        return nil;
    }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    uint8_t buf[65536];
    BOOL ok = YES;
    for (;;) {
        ssize_t got = read(fd, buf, sizeof(buf));
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) { ok = NO; break; }
        if (got == 0) break;
        CC_SHA256_Update(&ctx, buf, (CC_LONG)got);
    }
    close(fd);
    if (!ok) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (unsigned i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static id dwParsePlistFile(NSString *fsPath) {
    NSData *data = nil;
    if (!dwReadRegularFileNoFollow(fsPath, SIZE_MAX, &data) || !data.length) return nil;
    return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
}

// Structured documents read through plutil in the shell launcher (JSON from doctor/loader/journal/sidecar,
// or property list if rewritten with plutil). JSON is tried first so NSNull (`last_restore: null`) is preserved.
static id dwParseStructuredData(NSData *data) {
    if (!data.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (obj) return obj;
    return [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
}

static id dwParseStructuredFile(NSString *fsPath, size_t maxBytes) {
    NSData *data = nil;
    if (!dwReadRegularFileNoFollow(fsPath, maxBytes, &data)) return nil;
    return dwParseStructuredData(data);
}

// MARK: - Production macOS adapter

@interface DWHelperMacLauncherEnvironment : DWHelperMacEnvironment <DWHelperLauncherEnvironment>
@end

@implementation DWHelperMacLauncherEnvironment

- (NSString *)bundlePath {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    if (size == 0) return NSBundle.mainBundle.bundlePath ?: @"";
    NSMutableData *buf = [NSMutableData dataWithLength:size + 1];
    if (_NSGetExecutablePath(buf.mutableBytes, &size) != 0) return NSBundle.mainBundle.bundlePath ?: @"";
    char resolvedExec[PATH_MAX];
    if (!realpath((const char *)buf.bytes, resolvedExec)) return NSBundle.mainBundle.bundlePath ?: @"";
    NSString *macosDir = [@(resolvedExec) stringByDeletingLastPathComponent];
    NSString *contentsDir = [macosDir stringByDeletingLastPathComponent];
    return [contentsDir stringByDeletingLastPathComponent];
}

- (NSString *)stateDirectory {
    const char *homeEnv = getenv("HOME");
    if (!homeEnv) return nil;
    return [NSString stringWithFormat:@"%s/Library/Application Support/Infinify/native-desktop", homeEnv];
}

- (uid_t)effectiveUID { return geteuid(); }
- (pid_t)currentPID { return getpid(); }
- (pid_t)parentPID { return getppid(); }

- (BOOL)isAppleSiliconDarwin {
    struct utsname uts;
    if (uname(&uts) != 0) return NO;
    return strcmp(uts.sysname, "Darwin") == 0 && strcmp(uts.machine, "arm64") == 0;
}

- (int)readMacOSProductVersion:(NSString *__autoreleasing *)version {
    NSString *raw = nil;
    int status = [self runTask:@"/usr/bin/sw_vers" arguments:@[@"-productVersion"]
                 captureStdout:YES discardStdout:NO discardStderr:NO output:&raw launched:NULL];
    if (version) *version = dwStripTrailingNewlines(raw);
    return status;
}

- (BOOL)stdinIsTerminal { return isatty(STDIN_FILENO) != 0; }
- (time_t)currentEpochSeconds { return time(NULL); }
- (void)sleepSeconds:(unsigned int)seconds { sleep(seconds); }

- (BOOL)randomBytes:(void *)buffer length:(size_t)length {
    return SecRandomCopyBytes(kSecRandomDefault, length, buffer) == errSecSuccess;
}

- (int)runTask:(NSString *)executablePath arguments:(NSArray<NSString *> *)arguments
 captureStdout:(BOOL)captureStdout discardStdout:(BOOL)discardStdout discardStderr:(BOOL)discardStderr
        output:(NSString *__autoreleasing *)output launched:(BOOL *)launched {
    if (launched) *launched = NO;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executablePath];
    task.arguments = arguments ?: @[];
    NSPipe *stdoutPipe = nil;
    if (captureStdout) {
        stdoutPipe = [NSPipe pipe];
        task.standardOutput = stdoutPipe;
    } else if (discardStdout) {
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    }
    if (discardStderr) {
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
    }
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        if (output) *output = @"";
        return -1;
    }
    if (launched) *launched = YES;
    NSData *stdoutData = stdoutPipe ? [stdoutPipe.fileHandleForReading readDataToEndOfFile] : nil;
    [task waitUntilExit];
    if (output) {
        *output = stdoutData ? ([[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"") : @"";
    }
    if (task.terminationReason != NSTaskTerminationReasonExit) return -1;
    return task.terminationStatus;
}

- (NSArray<NSNumber *> *)runningInfinifyPIDsForUID:(uid_t)uid includeAncestors:(BOOL)includeAncestors failed:(BOOL *)failed {
    if (failed) *failed = NO;
    NSString *uidText = [NSString stringWithFormat:@"%u", (unsigned)uid];
    NSArray<NSString *> *args = includeAncestors ? @[@"-a", @"-u", uidText, @"-x", @"Infinify"] : @[@"-u", uidText, @"-x", @"Infinify"];
    NSString *raw = nil;
    BOOL launched = NO;
    int status = [self runTask:@"/usr/bin/pgrep" arguments:args captureStdout:YES discardStdout:NO discardStderr:YES output:&raw launched:&launched];
    if (!launched || (status != 0 && status != 1)) {
        if (failed) *failed = YES;
        return @[];
    }
    if (status == 1 || !raw.length) return @[];
    pid_t selfPID = [self currentPID];
    NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
    for (NSString *line in [raw componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        char *end = NULL;
        errno = 0;
        long val = strtol(line.UTF8String, &end, 10);
        if (errno != 0 || !end || *end != '\0' || val <= 0 || val > INT_MAX) continue;
        if ((pid_t)val == selfPID) continue;
        [pids addObject:@((int)val)];
    }
    return pids;
}

- (BOOL)verifyCodeSignatureAtPath:(NSString *)logicalPath deep:(BOOL)deep {
    NSString *fsPath = [self fileSystemPath:logicalPath];
    NSArray<NSString *> *args = deep ? @[@"--verify", @"--deep", @"--strict", fsPath] : @[@"--verify", @"--strict", fsPath];
    return [self runTask:@"/usr/bin/codesign" arguments:args captureStdout:NO discardStdout:NO discardStderr:NO output:NULL launched:NULL] == 0;
}

- (int)runDoctorAtPath:(NSString *)logicalDoctorPath output:(NSString *__autoreleasing *)output {
    return [self runTask:[self fileSystemPath:logicalDoctorPath] arguments:@[] captureStdout:YES discardStdout:NO discardStderr:NO output:output launched:NULL];
}

- (int)runLoaderDockIdentityAtPath:(NSString *)logicalLoaderPath output:(NSString *__autoreleasing *)output {
    return [self runTask:[self fileSystemPath:logicalLoaderPath] arguments:@[@"--dock-identity"] captureStdout:YES discardStdout:NO discardStderr:YES output:output launched:NULL];
}

- (int)runLoaderPayloadIdentity:(NSString *)logicalPayloadPath loaderPath:(NSString *)logicalLoaderPath output:(NSString *__autoreleasing *)output {
    NSArray<NSString *> *args = @[@"--payload-identity", [self fileSystemPath:logicalPayloadPath]];
    return [self runTask:[self fileSystemPath:logicalLoaderPath] arguments:args captureStdout:YES discardStdout:NO discardStderr:YES output:output launched:NULL];
}

- (int)runLoaderRestartDockPID:(pid_t)pid birthSec:(uint64_t)sec birthUsec:(uint64_t)usec loaderPath:(NSString *)logicalLoaderPath {
    NSArray<NSString *> *args = @[
        @"--restart-dock",
        [NSString stringWithFormat:@"%d", (int)pid],
        [NSString stringWithFormat:@"%llu", (unsigned long long)sec],
        [NSString stringWithFormat:@"%llu", (unsigned long long)usec],
    ];
    return [self runTask:[self fileSystemPath:logicalLoaderPath] arguments:args captureStdout:NO discardStdout:YES discardStderr:NO output:NULL launched:NULL];
}

- (BOOL)daemonEnabledWithStatusText:(NSString *__autoreleasing *)statusText appPath:(NSString *)logicalAppPath {
    NSString *raw = nil;
    int status = [self runTask:[self fileSystemPath:logicalAppPath] arguments:@[@"native-desktop", @"daemon", @"status"]
                 captureStdout:YES discardStdout:NO discardStderr:YES output:&raw launched:NULL];
    if (statusText) *statusText = dwStripTrailingNewlines(raw);
    return status == 0;
}

- (BOOL)pingDaemonWithAppPath:(NSString *)logicalAppPath {
    return [self runTask:[self fileSystemPath:logicalAppPath] arguments:@[@"native-desktop", @"daemon", @"ping"]
           captureStdout:NO discardStdout:YES discardStderr:YES output:NULL launched:NULL] == 0;
}

- (BOOL)stagedPayloadForRuntime:(NSString *)runtime appPath:(NSString *)logicalAppPath
                      directory:(NSString *__autoreleasing *)directory sha256:(NSString *__autoreleasing *)sha256 {
    NSString *raw = nil;
    int status = [self runTask:[self fileSystemPath:logicalAppPath] arguments:@[@"native-desktop", @"daemon", @"staged", runtime]
                 captureStdout:YES discardStdout:NO discardStderr:YES output:&raw launched:NULL];
    if (status != 0) return NO;
    NSString *trimmed = dwStripTrailingNewlines(raw);
    NSRange lastSpace = [trimmed rangeOfString:@" " options:NSBackwardsSearch];
    if (lastSpace.location == NSNotFound || lastSpace.location == 0 || lastSpace.location + 1 >= trimmed.length) return NO;
    NSString *dir = [trimmed substringToIndex:lastSpace.location];
    NSString *hash = [trimmed substringFromIndex:lastSpace.location + 1];
    if (directory) *directory = dir;
    if (sha256) *sha256 = hash;
    return YES;
}

- (int)runDaemonLoadWithArguments:(NSArray<NSString *> *)arguments appPath:(NSString *)logicalAppPath {
    NSMutableArray<NSString *> *full = [NSMutableArray arrayWithObjects:@"native-desktop", @"daemon", @"load", nil];
    [full addObjectsFromArray:arguments];
    return [self runTask:[self fileSystemPath:logicalAppPath] arguments:full captureStdout:NO discardStdout:NO discardStderr:NO output:NULL launched:NULL];
}

- (BOOL)authorizeSudo {
    return [self runTask:@"/usr/bin/sudo" arguments:@[@"/usr/bin/true"] captureStdout:NO discardStdout:NO discardStderr:NO output:NULL launched:NULL] == 0;
}

- (int)runSudoLoaderAtPath:(NSString *)logicalLoaderPath payloadPath:(NSString *)logicalPayloadPath arguments:(NSArray<NSString *> *)arguments {
    NSMutableArray<NSString *> *full = [NSMutableArray arrayWithObjects:[self fileSystemPath:logicalLoaderPath], @"--inject-dock", [self fileSystemPath:logicalPayloadPath], nil];
    [full addObjectsFromArray:arguments];
    return [self runTask:@"/usr/bin/sudo" arguments:full captureStdout:NO discardStdout:NO discardStderr:NO output:NULL launched:NULL];
}

- (void)writeStdout:(NSString *)text {
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes.length) (void)dwWriteAllFD(STDOUT_FILENO, bytes.bytes, bytes.length);
}

- (void)writeStderr:(NSString *)text {
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes.length) (void)dwWriteAllFD(STDERR_FILENO, bytes.bytes, bytes.length);
}

- (BOOL)writeReloadEndpoint:(NSString *)line {
    NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes.length) return NO;
    return dwWriteAllFD(3, bytes.bytes, bytes.length);
}

static int dwExecProgram(NSString *fsAppPath, NSString *logicalAppPath, NSArray<NSString *> *arguments, int fallbackStatus) {
    fflush(stdout);
    fflush(stderr);
    size_t count = arguments.count + 1;
    char **argv = (char **)calloc(count + 1, sizeof(char *));
    if (!argv) {
        int err = errno ? errno : ENOMEM;
        fprintf(stderr, "Infinify native desktop: execv %s: %s\n", (logicalAppPath ?: fsAppPath).UTF8String, strerror(err));
        return fallbackStatus;
    }
    argv[0] = strdup(fsAppPath.fileSystemRepresentation);
    BOOL ok = argv[0] != NULL;
    for (NSUInteger i = 0; i < arguments.count && ok; i++) {
        argv[i + 1] = strdup(arguments[i].UTF8String ?: "");
        if (!argv[i + 1]) ok = NO;
    }
    if (ok) execv(argv[0], argv);
    int err = errno ? errno : EIO;
    fprintf(stderr, "Infinify native desktop: execv %s: %s\n", (logicalAppPath ?: fsAppPath).UTF8String, strerror(err));
    for (size_t i = 0; i < count; i++) free(argv[i]);
    free(argv);
    return fallbackStatus;
}

- (int)execSetupRefused:(NSString *)reason appPath:(NSString *)logicalAppPath fallbackStatus:(int)fallbackStatus {
    return dwExecProgram([self fileSystemPath:logicalAppPath], logicalAppPath, @[@"setup", @"--refused", reason ?: @""], fallbackStatus);
}

- (int)execDesktopAppAtPath:(NSString *)logicalAppPath runtime:(NSString *)runtime nonceFile:(NSString *)nonceFile
              daemonEnabled:(BOOL)daemonEnabled payloadSHA256:(NSString *)payloadSHA256 loadedAt:(uint64_t)loadedAt {
    if (daemonEnabled) {
        setenv("INFINIFY_DOCK_RELOAD", "1", 1);
        setenv("INFINIFY_NATIVE_PAYLOAD_SHA256", payloadSHA256.UTF8String ?: "", 1);
        NSString *loadedText = [NSString stringWithFormat:@"%llu", (unsigned long long)loadedAt];
        setenv("INFINIFY_NATIVE_LOADED_AT", loadedText.UTF8String, 1);
    }
    return dwExecProgram([self fileSystemPath:logicalAppPath], logicalAppPath, @[@"--native-desktop-helper", runtime, nonceFile], 1);
}

@end

static BOOL dwMkdirP0700(const char *path) {
    if (!path || !path[0]) { errno = ENOENT; return NO; }
    struct stat st;
    if (stat(path, &st) == 0) {
        if (S_ISDIR(st.st_mode)) return YES;
        errno = EEXIST;
        return NO;
    }
    size_t len = strlen(path);
    char *buf = (char *)malloc(len + 1);
    if (!buf) { errno = ENOMEM; return NO; }
    memcpy(buf, path, len + 1);
    while (len > 1 && buf[len - 1] == '/') buf[--len] = '\0';
    for (char *p = buf + (buf[0] == '/' ? 1 : 0); *p; p++) {
        if (*p != '/') continue;
        *p = '\0';
        if (stat(buf, &st) != 0) {
            if (mkdir(buf, 0700) != 0 && errno != EEXIST) {
                int saved = errno;
                free(buf);
                errno = saved;
                return NO;
            }
        } else if (!S_ISDIR(st.st_mode)) {
            free(buf);
            errno = ENOTDIR;
            return NO;
        }
        *p = '/';
    }
    if (mkdir(buf, 0700) != 0) {
        int saved = errno;
        if (saved == EEXIST && stat(buf, &st) == 0 && S_ISDIR(st.st_mode)) {
            free(buf);
            return YES;
        }
        free(buf);
        errno = saved;
        return NO;
    }
    free(buf);
    return YES;
}

// MARK: - Launcher state machine

typedef NS_ENUM(NSInteger, DWJournalRefusalKind) {
    DWJournalRefusalNone,
    DWJournalRefusalAbsent,
    DWJournalRefusalSchema,
};

typedef NS_ENUM(NSInteger, DWPriorDockState) {
    DWPriorDockGone = 0,
    DWPriorDockPresent = 1,
    DWPriorDockUncertain = 2,
};

@implementation DWHelperLauncher {
    id<DWHelperLauncherEnvironment> _environment;
    BOOL _managesSignals;

    BOOL _isCheck;
    BOOL _isLogin;
    BOOL _isReload;
    BOOL _isLaunch;
    int _failStatus;
    BOOL _setupFeedback;
    BOOL _appVerified;
    BOOL _lockHeld;

    NSString *_stateDir;
    NSString *_recordPath;
    NSString *_pendingRecordPath;
    NSString *_lockPath;
    NSString *_pausePath;

    NSString *_bundlePath;
    NSString *_nativeDir;
    NSString *_doctorPath;
    NSString *_loaderPath;
    NSString *_payloadPath;
    NSString *_appPath;
    NSString *_payloadSHA256;

    uid_t _uid;
    NSString *_lastDockReport;
    pid_t _dockPID;
    uint64_t _dockSec;
    uint64_t _dockUsec;
    NSString *_bootUUID;

    NSString *_recordBootUUID;
    pid_t _oldDockPID;
    uint64_t _oldDockSec;
    uint64_t _oldDockUsec;
    NSString *_recordPayloadSHA256;
    NSString *_runtime;
    NSString *_nonceFile;
    NSString *_runtimeSuffix;
    BOOL _runtimeInTmp;
    NSString *_loadedDir;

    NSString *_archiveDir;
    NSString *_archivedRecordSHA256;
    DWJournalRefusalKind _journalRefused;
    uint64_t _journalVersion;
    NSString *_recoverySource;
    BOOL _dockRestarted;
}

+ (instancetype)systemLauncher {
    DWHelperMacLauncherEnvironment *env = [DWHelperMacLauncherEnvironment new];
    DWHelperLauncher *launcher = [[self alloc] initWithEnvironment:env];
    launcher->_managesSignals = YES;
    return launcher;
}

- (instancetype)initWithEnvironment:(id<DWHelperLauncherEnvironment>)environment {
    if ((self = [super init])) {
        _environment = environment;
    }
    return self;
}

- (NSString *)fs:(NSString *)logicalPath {
    return [_environment fileSystemPath:logicalPath];
}

- (void)emitLine:(NSString *)line {
    NSString *withNewline = [line stringByAppendingString:@"\n"];
    if (_isReload) {
        [_environment writeStderr:withNewline];
    } else {
        [_environment writeStdout:withNewline];
    }
}

- (void)releaseLock {
    if (!_lockHeld) return;
    if (_lockPath.length) {
        (void)rmdir([self fs:_lockPath].fileSystemRepresentation);
    }
    _lockHeld = NO;
    if (_managesSignals) {
        dwRestoreLockSignals();
    }
}

- (int)fail:(NSString *)reason exitOut:(int *)exitOut {
    [_environment writeStderr:[NSString stringWithFormat:@"Infinify native desktop: %@\n", reason]];
    if (_setupFeedback && _appVerified) {
        [self releaseLock];
        int status = [_environment execSetupRefused:reason appPath:_appPath fallbackStatus:_failStatus];
        if (exitOut) *exitOut = status;
        return status;
    }
    [self releaseLock];
    if (exitOut) *exitOut = _failStatus;
    return _failStatus;
}

- (int)failNativeOperation:(NSString *)operation path:(NSString *)logicalPath errorNumber:(int)err exitOut:(int *)exitOut {
    const char *detail = err ? strerror(err) : "failed";
    [_environment writeStderr:[NSString stringWithFormat:@"Infinify native desktop: %@ %@: %s\n",
                               operation, logicalPath ?: @"", detail]];
    [self releaseLock];
    if (exitOut) *exitOut = 1;
    return 1;
}

- (BOOL)pathExistsOrSymlink:(NSString *)logicalPath {
    struct stat st;
    return lstat([self fs:logicalPath].fileSystemRepresentation, &st) == 0;
}

- (BOOL)isRegularNonSymlink:(NSString *)logicalPath {
    struct stat st;
    return lstat([self fs:logicalPath].fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode);
}

- (BOOL)isPrivateFile:(NSString *)logicalPath {
    struct stat st;
    if (lstat([self fs:logicalPath].fileSystemRepresentation, &st) != 0) return NO;
    return S_ISREG(st.st_mode) && st.st_uid == _uid && (st.st_mode & 07777) == 0600;
}

- (BOOL)isPrivateDirectory:(NSString *)logicalPath {
    struct stat st;
    if (lstat([self fs:logicalPath].fileSystemRepresentation, &st) != 0) return NO;
    return S_ISDIR(st.st_mode) && st.st_uid == _uid && (st.st_mode & 07777) == 0700;
}

// Preserves shell `native_paused` exactly (checks private 0600 ownership and `payload_sha256`
// without requiring `version == 1`, treating any unreadable or malformed pause file as paused).
- (BOOL)isLauncherPaused {
    if (![self pathExistsOrSymlink:_pausePath]) return NO;
    if (![self isPrivateFile:_pausePath]) return YES;
    id plist = dwParsePlistFile([self fs:_pausePath]);
    if (![plist isKindOfClass:NSDictionary.class]) return YES;
    id sha = ((NSDictionary *)plist)[@"payload_sha256"];
    if (![sha isKindOfClass:NSString.class]) return YES;
    return [(NSString *)sha isEqualToString:_payloadSHA256];
}

- (BOOL)verifyOwnBundleWithExit:(int *)exitOut {
    _bundlePath = [_environment bundlePath];
    if (!_bundlePath.length) {
        [self fail:@"could not resolve the containing app bundle." exitOut:exitOut];
        return NO;
    }
    NSString *fsBundle = [self fs:_bundlePath];
    struct stat bundleStat;
    if (stat(fsBundle.fileSystemRepresentation, &bundleStat) != 0 || !S_ISDIR(bundleStat.st_mode)) {
        [self fail:@"could not resolve the containing app bundle." exitOut:exitOut];
        return NO;
    }
    if (![[_bundlePath lastPathComponent] isEqualToString:@"Infinify.app"]) {
        [self fail:@"the bundled launcher must run from Infinify.app." exitOut:exitOut];
        return NO;
    }
    for (NSString *rel in @[@"Contents", @"Contents/Resources", @"Contents/Resources/NativeDesktop", @"Contents/MacOS"]) {
        NSString *logicalComp = [_bundlePath stringByAppendingPathComponent:rel];
        struct stat st;
        if (lstat([self fs:logicalComp].fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode)) {
            [self fail:[NSString stringWithFormat:@"app bundle path component is a symlink: %@", logicalComp] exitOut:exitOut];
            return NO;
        }
    }
    _nativeDir = [_bundlePath stringByAppendingPathComponent:@"Contents/Resources/NativeDesktop"];
    NSString *manifestPath = [_nativeDir stringByAppendingPathComponent:@"manifest.plist"];
    NSString *launcherScript = [_nativeDir stringByAppendingPathComponent:@"launch.sh"];
    _doctorPath = [_nativeDir stringByAppendingPathComponent:@"doctor"];
    _loaderPath = [_nativeDir stringByAppendingPathComponent:@"loader-arm64e"];
    NSString *daemonPath = [_nativeDir stringByAppendingPathComponent:@"loadd"];
    _payloadPath = [_nativeDir stringByAppendingPathComponent:@"payload-arm64e.dylib"];
    _appPath = [_bundlePath stringByAppendingPathComponent:@"Contents/MacOS/Infinify"];
    NSString *infoPath = [_bundlePath stringByAppendingPathComponent:@"Contents/Info.plist"];

    if (![self isRegularNonSymlink:launcherScript]) { [self fail:@"bundled launcher is missing or is a symlink." exitOut:exitOut]; return NO; }
    if (![self isRegularNonSymlink:manifestPath]) { [self fail:@"native helper manifest is missing or is a symlink." exitOut:exitOut]; return NO; }
    if (![self isRegularNonSymlink:_doctorPath]) { [self fail:@"bundled doctor is missing or is a symlink." exitOut:exitOut]; return NO; }
    if (![self isRegularNonSymlink:_loaderPath]) { [self fail:@"bundled loader is missing or is a symlink." exitOut:exitOut]; return NO; }
    if (![self isRegularNonSymlink:daemonPath]) { [self fail:@"bundled launch daemon is missing or is a symlink." exitOut:exitOut]; return NO; }
    if (![self isRegularNonSymlink:_payloadPath]) { [self fail:@"bundled payload is missing or is a symlink." exitOut:exitOut]; return NO; }
    if (![self isRegularNonSymlink:_appPath]) { [self fail:@"standard app executable is missing or is a symlink." exitOut:exitOut]; return NO; }
    if (![self isRegularNonSymlink:infoPath]) { [self fail:@"app Info.plist is missing or is a symlink." exitOut:exitOut]; return NO; }

    id manifestObj = dwParsePlistFile([self fs:manifestPath]);
    if (!manifestObj) { [self fail:@"native helper manifest is invalid." exitOut:exitOut]; return NO; }
    if (![manifestObj isKindOfClass:NSDictionary.class]) { [self fail:@"unsupported native helper manifest schema." exitOut:exitOut]; return NO; }
    NSDictionary *manifest = (NSDictionary *)manifestObj;
    uint64_t schemaVer = 0; BOOL schemaNeg = NO;
    if (!dwExtractInteger(manifest[@"schema_version"], &schemaVer, &schemaNeg) || schemaNeg || schemaVer != 1) {
        [self fail:@"unsupported native helper manifest schema." exitOut:exitOut];
        return NO;
    }
    id sourceFP = manifest[@"source_fingerprint_sha256"];
    if (![sourceFP isKindOfClass:NSString.class]) { [self fail:@"native helper manifest has no source fingerprint." exitOut:exitOut]; return NO; }
    if (!dwValidHexLower((NSString *)sourceFP, 64)) { [self fail:@"native helper manifest has an invalid source fingerprint." exitOut:exitOut]; return NO; }
    id gitCommit = manifest[@"git_commit"];
    if (![gitCommit isKindOfClass:NSString.class] || ![(NSString *)gitCommit length]) {
        [self fail:@"native helper manifest has no source commit." exitOut:exitOut];
        return NO;
    }

    id infoObj = dwParsePlistFile([self fs:infoPath]);
    NSDictionary *info = [infoObj isKindOfClass:NSDictionary.class] ? (NSDictionary *)infoObj : nil;
    if (![info[@"CFBundleIdentifier"] isKindOfClass:NSString.class] || ![info[@"CFBundleIdentifier"] isEqualToString:@"com.marengox.infinify"]) {
        [self fail:@"unexpected app bundle identifier." exitOut:exitOut];
        return NO;
    }
    if (![info[@"CFBundleExecutable"] isKindOfClass:NSString.class] || ![info[@"CFBundleExecutable"] isEqualToString:@"Infinify"]) {
        [self fail:@"unexpected app bundle executable." exitOut:exitOut];
        return NO;
    }

    NSDictionary *artifacts = [manifest[@"artifacts"] isKindOfClass:NSDictionary.class] ? manifest[@"artifacts"] : nil;
    NSDictionary *payloadEntry = [artifacts[@"payload"] isKindOfClass:NSDictionary.class] ? artifacts[@"payload"] : nil;
    if (![payloadEntry[@"path"] isKindOfClass:NSString.class] || ![payloadEntry[@"path"] isEqualToString:@"Contents/Resources/NativeDesktop/payload-arm64e.dylib"]) {
        [self fail:@"native helper manifest has an unexpected payload path." exitOut:exitOut];
        return NO;
    }
    id expectedPayloadSHA = payloadEntry[@"sha256"];
    if (![expectedPayloadSHA isKindOfClass:NSString.class]) {
        [self fail:@"native helper manifest has no payload digest." exitOut:exitOut];
        return NO;
    }
    if (!dwValidHexLower((NSString *)expectedPayloadSHA, 64)) {
        [self fail:@"native helper manifest has an invalid payload digest." exitOut:exitOut];
        return NO;
    }
    if (access([self fs:_payloadPath].fileSystemRepresentation, X_OK) != 0) {
        [self fail:@"bundled payload is not executable." exitOut:exitOut];
        return NO;
    }
    NSString *actualPayloadSHA = dwSHA256HexOfRegularFile([self fs:_payloadPath]);
    if (!actualPayloadSHA || ![actualPayloadSHA isEqualToString:(NSString *)expectedPayloadSHA]) {
        [self fail:@"bundled payload bytes differ from the signed manifest." exitOut:exitOut];
        return NO;
    }
    _payloadSHA256 = (NSString *)expectedPayloadSHA;
    _appVerified = YES;
    return YES;
}

- (BOOL)readDockWithAttempts:(int)attempts confirmSeconds:(unsigned int)confirm {
    _lastDockReport = @"";
    BOOL stable = NO;
    int attempt = 0;
    for (;;) {
        attempt++;
        NSString *raw = nil;
        if ([_environment runLoaderDockIdentityAtPath:_loaderPath output:&raw] == 0) {
            _lastDockReport = dwStripTrailingNewlines(raw);
            if (confirm == 0) {
                stable = YES;
                break;
            }
            [_environment sleepSeconds:confirm];
            NSString *againRaw = nil;
            NSString *again = ([_environment runLoaderDockIdentityAtPath:_loaderPath output:&againRaw] == 0) ? dwStripTrailingNewlines(againRaw) : @"";
            if ([_lastDockReport isEqualToString:again]) {
                stable = YES;
                break;
            }
        } else {
            _lastDockReport = @"";
        }
        if (attempt >= attempts) break;
        if (confirm != 0) [_environment sleepSeconds:2];
    }
    return _lastDockReport.length > 0 && stable;
}

- (BOOL)takeDockWithExit:(int *)exitOut {
    NSData *data = [_lastDockReport dataUsingEncoding:NSUTF8StringEncoding];
    id obj = dwParseStructuredData(data);
    NSDictionary *dict = [obj isKindOfClass:NSDictionary.class] ? (NSDictionary *)obj : nil;
    uint64_t pidVal = 0, secVal = 0, usecVal = 0, uidVal = 0;
    BOOL pidNeg = NO, secNeg = NO, usecNeg = NO, uidNeg = NO;
    if (!dwExtractInteger(dict[@"pid"], &pidVal, &pidNeg) || pidNeg || pidVal > INT_MAX) {
        [self fail:@"invalid Dock PID report." exitOut:exitOut];
        return NO;
    }
    if (!dwExtractInteger(dict[@"birth_sec"], &secVal, &secNeg) || secNeg) {
        [self fail:@"invalid Dock birth report." exitOut:exitOut];
        return NO;
    }
    if (!dwExtractInteger(dict[@"birth_usec"], &usecVal, &usecNeg) || usecNeg) {
        [self fail:@"invalid Dock birth report." exitOut:exitOut];
        return NO;
    }
    if (!dwExtractInteger(dict[@"uid"], &uidVal, &uidNeg)) {
        [self fail:@"invalid Dock user report." exitOut:exitOut];
        return NO;
    }
    id bootObj = dict[@"boot_uuid"];
    if (![bootObj isKindOfClass:NSString.class]) {
        [self fail:@"invalid boot identity report." exitOut:exitOut];
        return NO;
    }
    if (!dw_boot_uuid_valid(bootObj)) {
        [self fail:@"invalid boot session UUID report." exitOut:exitOut];
        return NO;
    }
    if (uidNeg || uidVal != (uint64_t)_uid) {
        [self fail:@"Dock belongs to another login user." exitOut:exitOut];
        return NO;
    }
    _dockPID = (pid_t)pidVal;
    _dockSec = secVal;
    _dockUsec = usecVal;
    _bootUUID = (NSString *)bootObj;
    return YES;
}

- (DWPriorDockState)priorDockState {
    if (_oldDockPID == _dockPID) {
        return (_oldDockSec != _dockSec || _oldDockUsec != _dockUsec) ? DWPriorDockGone : DWPriorDockPresent;
    }
    errno = 0;
    int probe = [_environment probeProcess:_oldDockPID];
    if (probe == 0) return DWPriorDockPresent;
    if (probe == -1 && errno == ESRCH) return DWPriorDockGone;
    return DWPriorDockUncertain;
}

- (BOOL)copyPrivateFileFrom:(NSString *)logicalSrc to:(NSString *)logicalDst
                  copyError:(NSString *)copyError chmodError:(NSString *)chmodError exitOut:(int *)exitOut {
    NSString *fsSrc = [self fs:logicalSrc];
    int srcFD = open(fsSrc.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (srcFD < 0) {
        [self fail:copyError exitOut:exitOut];
        return NO;
    }
    struct stat srcStat;
    if (fstat(srcFD, &srcStat) != 0 || !S_ISREG(srcStat.st_mode) || srcStat.st_size < 0) {
        close(srcFD);
        [self fail:copyError exitOut:exitOut];
        return NO;
    }
    NSString *fsDst = [self fs:logicalDst];
    int dstFD = open(fsDst.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (dstFD < 0) {
        close(srcFD);
        [self fail:copyError exitOut:exitOut];
        return NO;
    }
    uint8_t buf[65536];
    BOOL copied = YES;
    for (;;) {
        ssize_t got = read(srcFD, buf, sizeof(buf));
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) { copied = NO; break; }
        if (got == 0) break;
        if (!dwWriteAllFD(dstFD, buf, (size_t)got)) { copied = NO; break; }
    }
    close(srcFD);
    if (!copied) {
        close(dstFD);
        [self fail:copyError exitOut:exitOut];
        return NO;
    }
    if (fchmod(dstFD, 0600) != 0) {
        close(dstFD);
        [self fail:chmodError exitOut:exitOut];
        return NO;
    }
    (void)fsync(dstFD);
    if (close(dstFD) != 0) {
        [self fail:copyError exitOut:exitOut];
        return NO;
    }
    return YES;
}

- (BOOL)archiveRetiredRecordWithExit:(int *)exitOut {
    NSString *fsState = [self fs:_stateDir];
    NSString *tmplStr = [fsState stringByAppendingPathComponent:@"retired-launch.XXXXXX"];
    NSMutableData *tmpl = [[tmplStr dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [tmpl increaseLengthBy:1];
    if (!mkdtemp((char *)tmpl.mutableBytes)) {
        [self fail:@"could not create a private archive for the retired launch record." exitOut:exitOut];
        return NO;
    }
    NSString *createdName = [@((const char *)tmpl.bytes) lastPathComponent];
    _archiveDir = [_stateDir stringByAppendingPathComponent:createdName];
    if (![self isPrivateDirectory:_archiveDir]) {
        [self fail:@"retired launch-record archive is not private." exitOut:exitOut];
        return NO;
    }
    _archivedRecordSHA256 = dwSHA256HexOfRegularFile([self fs:_recordPath]);
    if (!_archivedRecordSHA256) {
        [self fail:@"could not hash the retired launch record." exitOut:exitOut];
        return NO;
    }
    NSString *archivedPlist = [_archiveDir stringByAppendingPathComponent:@"launch.plist"];
    if (![self copyPrivateFileFrom:_recordPath to:archivedPlist
                         copyError:@"could not preserve the retired launch record."
                        chmodError:@"could not secure the archived launch record."
                           exitOut:exitOut]) {
        return NO;
    }
    if (![self isPrivateFile:archivedPlist]) {
        [self fail:@"archived launch record is not a private regular file." exitOut:exitOut];
        return NO;
    }
    NSString *copiedSHA = dwSHA256HexOfRegularFile([self fs:archivedPlist]);
    if (!copiedSHA || ![copiedSHA isEqualToString:_archivedRecordSHA256]) {
        [self fail:@"archived launch record bytes changed; preserve the archive and inspect it." exitOut:exitOut];
        return NO;
    }
    [self emitLine:[NSString stringWithFormat:@"Archived the retired Dock launch record at %@; no runtime or recovery journal was changed.", archivedPlist]];
    return YES;
}

- (BOOL)archiveAndRemovePriorBootRecordWithExit:(int *)exitOut {
    if (![self archiveRetiredRecordWithExit:exitOut]) return NO;
    NSString *nowSHA = dwSHA256HexOfRegularFile([self fs:_recordPath]);
    if (!nowSHA || ![nowSHA isEqualToString:_archivedRecordSHA256]) {
        [self fail:@"the launch record changed while archiving; preserve both copies and inspect them." exitOut:exitOut];
        return NO;
    }
    if (unlink([self fs:_recordPath].fileSystemRepresentation) != 0) {
        [self fail:@"the prior-boot record was archived but could not be removed from the active launch path." exitOut:exitOut];
        return NO;
    }
    return YES;
}

- (BOOL)refuseUnrecoverableJournalWithExit:(int *)exitOut {
    if (![self archiveRetiredRecordWithExit:exitOut]) return NO;
    if (_journalRefused == DWJournalRefusalAbsent) {
        NSString *nowSHA = dwSHA256HexOfRegularFile([self fs:_recordPath]);
        if (!nowSHA || ![nowSHA isEqualToString:_archivedRecordSHA256]) {
            [self fail:@"the launch record changed while archiving; preserve both copies and inspect them." exitOut:exitOut];
            return NO;
        }
        if (unlink([self fs:_recordPath].fileSystemRepresentation) != 0) {
            [self fail:@"the retired launch record was archived but could not be removed from the active launch path." exitOut:exitOut];
            return NO;
        }
        [self emitLine:[NSString stringWithFormat:@"The retired helper runtime holds no journal and no recovery source. The helper writes its journal before it changes any window, so it changed none; nothing needs recovering. The launch record was archived under %@, the retired runtime was left untouched, and startup will be fresh.", _archiveDir]];
        return YES;
    }
    NSString *journalPath = [_runtime stringByAppendingPathComponent:@"v2-journal.json"];
    NSString *archivedJournal = [_archiveDir stringByAppendingPathComponent:@"v2-journal.json"];
    if (![self copyPrivateFileFrom:journalPath to:archivedJournal
                         copyError:@"could not preserve the retired helper journal."
                        chmodError:@"could not secure the archived helper journal."
                           exitOut:exitOut]) {
        return NO;
    }
    if (![self isPrivateFile:archivedJournal]) {
        [self fail:@"archived helper journal is not a private regular file." exitOut:exitOut];
        return NO;
    }
    NSString *archivedJournalSHA = dwSHA256HexOfRegularFile([self fs:archivedJournal]);
    NSString *origJournalSHA = dwSHA256HexOfRegularFile([self fs:journalPath]);
    if (!archivedJournalSHA || !origJournalSHA || ![archivedJournalSHA isEqualToString:origJournalSHA]) {
        [self fail:@"archived helper journal bytes changed; preserve the archive and inspect it." exitOut:exitOut];
        return NO;
    }
    NSString *nowRecordSHA = dwSHA256HexOfRegularFile([self fs:_recordPath]);
    if (!nowRecordSHA || ![nowRecordSHA isEqualToString:_archivedRecordSHA256]) {
        [self fail:@"the launch record changed while archiving; preserve both copies and inspect them." exitOut:exitOut];
        return NO;
    }
    if (unlink([self fs:_recordPath].fileSystemRepresentation) != 0) {
        [self fail:@"the retired launch record was archived but could not be removed from the active launch path." exitOut:exitOut];
        return NO;
    }
    [self emitLine:[NSString stringWithFormat:@"The retired helper journal is schema %llu and this build recovers schema %llu only (older journals are not migrated), so nothing was recovered from it. The launch record and the journal were archived under %@, the retired runtime was left untouched, and startup will be fresh without journal replay.",
                    (unsigned long long)_journalVersion, (unsigned long long)kJournalSchema, _archiveDir]];
    return YES;
}

- (BOOL)validateRetiredJournalWithExit:(int *)exitOut {
    _journalRefused = DWJournalRefusalNone;
    NSString *journalPath = [_runtime stringByAppendingPathComponent:@"v2-journal.json"];
    BOOL journalAbsent = YES;
    for (NSString *artifact in @[@"v2-journal.json", @"v2-journal.next", @"recovery-source.json", @"recovery.json", @"recovery.next"]) {
        if ([self pathExistsOrSymlink:[_runtime stringByAppendingPathComponent:artifact]]) {
            journalAbsent = NO;
        }
    }
    if (journalAbsent) {
        _journalRefused = DWJournalRefusalAbsent;
        return YES;
    }
    if (![self isPrivateFile:journalPath]) {
        [self fail:@"the retired helper has no private committed v2 journal; preserve its state and inspect it. Restart your Mac to start fresh without replaying it." exitOut:exitOut];
        return NO;
    }
    struct stat journalStat;
    if (lstat([self fs:journalPath].fileSystemRepresentation, &journalStat) != 0) {
        [self fail:@"could not inspect the retired helper journal. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (journalStat.st_size < 1 || (uint64_t)journalStat.st_size > kMaxJournalSize) {
        [self fail:@"the retired helper journal size is invalid; preserve it and inspect it. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    id journalObj = dwParseStructuredFile([self fs:journalPath], (size_t)kMaxJournalSize);
    NSDictionary *journal = [journalObj isKindOfClass:NSDictionary.class] ? (NSDictionary *)journalObj : nil;
    uint64_t ver = 0; BOOL verNeg = NO;
    if (!dwExtractInteger(journal[@"v"], &ver, &verNeg)) {
        [self fail:@"the retired helper journal has no integer schema number; preserve it and inspect it. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (verNeg) {
        [self fail:@"the retired helper journal has an invalid schema number; preserve it and inspect it. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    _journalVersion = ver;
    if (ver != kJournalSchema) {
        _journalRefused = DWJournalRefusalSchema;
        return YES;
    }
    uint64_t jPID = 0; BOOL jPIDNeg = NO;
    if (!dwExtractInteger(journal[@"server_pid"], &jPID, &jPIDNeg)) {
        [self fail:@"the retired helper journal has no exact integer server PID. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (!dwPIDValid(jPID, jPIDNeg) || (pid_t)jPID != _oldDockPID) {
        [self fail:@"the retired helper journal does not identify its recorded Dock process. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    uint64_t jSec = 0, jUsec = 0, jUID = 0;
    BOOL jSecNeg = NO, jUsecNeg = NO, jUIDNeg = NO;
    if (!dwExtractInteger(journal[@"server_birth_sec"], &jSec, &jSecNeg)) {
        [self fail:@"the retired helper journal has no exact server birth time. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (!dwExtractInteger(journal[@"server_birth_usec"], &jUsec, &jUsecNeg)) {
        [self fail:@"the retired helper journal has no exact server birth time. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (!dwExtractInteger(journal[@"server_uid"], &jUID, &jUIDNeg)) {
        [self fail:@"the retired helper journal has no exact server UID. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (jSecNeg || jSec != _oldDockSec) {
        [self fail:@"the retired helper journal birth time differs from the launch record. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (jUsecNeg || jUsec != _oldDockUsec) {
        [self fail:@"the retired helper journal birth time differs from the launch record. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (jUIDNeg || jUID != (uint64_t)_uid) {
        [self fail:@"the retired helper journal belongs to another login user. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    id jBoot = journal[@"boot_uuid"];
    if (![jBoot isKindOfClass:NSString.class]) {
        [self fail:@"the retired helper journal has no exact boot session UUID. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (!dw_boot_uuid_valid(jBoot) || ![(NSString *)jBoot isEqualToString:_bootUUID]) {
        [self fail:@"the retired helper journal belongs to a different boot session; preserve it and inspect it. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    uint64_t jGen = 0; BOOL jGenNeg = NO;
    if (!dwExtractInteger(journal[@"generation"], &jGen, &jGenNeg)) {
        [self fail:@"the retired helper journal has no exact integer generation. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (jGenNeg) {
        [self fail:@"the retired helper journal generation is invalid. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    id jState = journal[@"state"];
    if (![jState isKindOfClass:NSString.class]) {
        [self fail:@"the retired helper journal has no valid state. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (![@[@"empty", @"holding", @"restoring"] containsObject:jState]) {
        [self fail:@"the retired helper journal has an unknown state; preserve it and inspect it. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (![journal[@"windows"] isKindOfClass:NSArray.class]) {
        [self fail:@"the retired helper journal has no valid active window table. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (![journal[@"released_windows"] isKindOfClass:NSArray.class]) {
        [self fail:@"the retired helper journal has no valid retained-original table. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    id lastRestore = journal[@"last_restore"];
    if (!lastRestore) {
        [self fail:@"the retired helper journal has no valid restoration receipt. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }
    if (lastRestore != NSNull.null && ![lastRestore isKindOfClass:NSDictionary.class]) {
        [self fail:@"the retired helper journal has an unknown restoration receipt; preserve it and inspect it. Restart your Mac to start fresh." exitOut:exitOut];
        return NO;
    }

    NSString *importSource = [_runtime stringByAppendingPathComponent:@"recovery-source.json"];
    if (_loadedDir.length > 0) {
        NSString *sidecarPath = [_loadedDir stringByAppendingPathComponent:@"payload-arm64e.dylib.json"];
        if (![self isPrivateFile:sidecarPath]) {
            [self fail:@"the retired helper sidecar is missing or not private; preserve the runtime and inspect it. Restart your Mac to start fresh." exitOut:exitOut];
            return NO;
        }
        id sidecarObj = dwParseStructuredFile([self fs:sidecarPath], SIZE_MAX);
        NSDictionary *sidecar = [sidecarObj isKindOfClass:NSDictionary.class] ? (NSDictionary *)sidecarObj : nil;
        if ([self pathExistsOrSymlink:importSource]) {
            if (![self isPrivateFile:importSource]) {
                [self fail:@"the retained historical recovery source is not private; preserve it and inspect it. Restart your Mac to start fresh." exitOut:exitOut];
                return NO;
            }
            struct stat importStat;
            if (lstat([self fs:importSource].fileSystemRepresentation, &importStat) != 0) {
                [self fail:@"could not inspect the historical recovery source. Restart your Mac to start fresh." exitOut:exitOut];
                return NO;
            }
            if (importStat.st_size < 1 || (uint64_t)importStat.st_size > kMaxJournalSize) {
                [self fail:@"the historical recovery source size is invalid; preserve it and inspect it. Restart your Mac to start fresh." exitOut:exitOut];
                return NO;
            }
            id importHashObj = sidecar[@"recovery_source_sha256"];
            if (![importHashObj isKindOfClass:NSString.class]) {
                [self fail:@"the retained recovery sidecar has no source digest. Restart your Mac to start fresh." exitOut:exitOut];
                return NO;
            }
            if (!dwValidHexLower((NSString *)importHashObj, 64)) {
                [self fail:@"the retained recovery sidecar has an invalid source digest. Restart your Mac to start fresh." exitOut:exitOut];
                return NO;
            }
            NSString *actualImportHash = dwSHA256HexOfRegularFile([self fs:importSource]);
            if (!actualImportHash || ![actualImportHash isEqualToString:(NSString *)importHashObj]) {
                [self fail:@"the retained historical recovery source differs from its sidecar digest. Restart your Mac to start fresh." exitOut:exitOut];
                return NO;
            }
            id importObj = dwParseStructuredFile([self fs:importSource], (size_t)kMaxJournalSize);
            NSDictionary *importDict = [importObj isKindOfClass:NSDictionary.class] ? (NSDictionary *)importObj : nil;
            uint64_t importVer = 0; BOOL importVerNeg = NO;
            if (!dwExtractInteger(importDict[@"v"], &importVer, &importVerNeg) || importVerNeg || importVer != kJournalSchema) {
                [self fail:[NSString stringWithFormat:@"the retained historical recovery source is not schema %llu. Restart your Mac to start fresh.", (unsigned long long)kJournalSchema] exitOut:exitOut];
                return NO;
            }
            NSArray<NSArray<NSString *> *> *pairs = @[
                @[@"server_pid", @"recovery_server_pid"],
                @[@"server_birth_sec", @"recovery_server_birth_sec"],
                @[@"server_birth_usec", @"recovery_server_birth_usec"],
                @[@"server_uid", @"recovery_server_uid"],
            ];
            for (NSArray<NSString *> *pair in pairs) {
                NSString *srcVal = dwCanonicalIntegerString(importDict[pair[0]]);
                if (!srcVal) {
                    [self fail:@"the retained historical recovery source is missing writer identity. Restart your Mac to start fresh." exitOut:exitOut];
                    return NO;
                }
                NSString *sideVal = dwCanonicalIntegerString(sidecar[pair[1]]);
                if (!sideVal) {
                    [self fail:@"the retained recovery sidecar is missing writer identity. Restart your Mac to start fresh." exitOut:exitOut];
                    return NO;
                }
                if (![srcVal isEqualToString:sideVal]) {
                    [self fail:@"the retained historical source identity differs from its sidecar. Restart your Mac to start fresh." exitOut:exitOut];
                    return NO;
                }
            }
            id srcBoot = importDict[@"boot_uuid"];
            if (![srcBoot isKindOfClass:NSString.class]) {
                [self fail:@"the retained historical source has no boot session UUID. Restart your Mac to start fresh." exitOut:exitOut];
                return NO;
            }
            id sideBoot = sidecar[@"recovery_boot_uuid"];
            if (![sideBoot isKindOfClass:NSString.class]) {
                [self fail:@"the retained recovery sidecar has no boot session UUID. Restart your Mac to start fresh." exitOut:exitOut];
                return NO;
            }
            if (!dw_boot_uuid_valid(srcBoot) || ![(NSString *)srcBoot isEqualToString:(NSString *)sideBoot]) {
                [self fail:@"the retained historical source boot identity differs from its sidecar. Restart your Mac to start fresh." exitOut:exitOut];
                return NO;
            }
        } else if (!_runtimeInTmp) {
            if ([sidecar[@"recovery_source_sha256"] isKindOfClass:NSString.class]) {
                [self fail:@"the recovery sidecar names a historical source that is missing; preserve the runtime and inspect it. Restart your Mac to start fresh." exitOut:exitOut];
                return NO;
            }
        }
    } else {
        if ([self pathExistsOrSymlink:importSource]) {
            if (![self isPrivateFile:importSource]) {
                [self fail:@"the retained historical recovery source is not private; preserve it and inspect it. Restart your Mac to start fresh." exitOut:exitOut];
                return NO;
            }
            id importObj = dwParseStructuredFile([self fs:importSource], SIZE_MAX);
            NSDictionary *importDict = [importObj isKindOfClass:NSDictionary.class] ? (NSDictionary *)importObj : nil;
            uint64_t importVer = 0; BOOL importVerNeg = NO;
            if (!dwExtractInteger(importDict[@"v"], &importVer, &importVerNeg) || importVerNeg || importVer != kJournalSchema) {
                [self fail:[NSString stringWithFormat:@"the retained historical recovery source is not schema %llu. Restart your Mac to start fresh.", (unsigned long long)kJournalSchema] exitOut:exitOut];
                return NO;
            }
        }
    }

    for (NSString *artifact in @[@"v2-journal.next", @"recovery.json", @"recovery.next", @"helper.sock"]) {
        if ([self pathExistsOrSymlink:[_runtime stringByAppendingPathComponent:artifact]]) {
            [self fail:[NSString stringWithFormat:@"the retired helper runtime contains %@; preserve it and inspect it. Restart your Mac to start fresh.", artifact] exitOut:exitOut];
            return NO;
        }
    }
    _recoverySource = journalPath;
    return YES;
}

- (BOOL)pingDaemonWithExit:(int *)exitOut {
    int attempts = 0;
    while (![_environment pingDaemonWithAppPath:_appPath]) {
        attempts++;
        if (_isLogin && attempts < 6) {
            [_environment sleepSeconds:5];
            continue;
        }
        [self fail:@"the launch daemon does not answer this app; nothing was loaded." exitOut:exitOut];
        return NO;
    }
    return YES;
}

- (BOOL)parsePayloadIdentityAtPath:(NSString *)logicalPath signer:(NSString *__autoreleasing *)signer cdhash:(NSString *__autoreleasing *)cdhash {
    NSString *raw = nil;
    if ([_environment runLoaderPayloadIdentity:logicalPath loaderPath:_loaderPath output:&raw] != 0) return NO;
    NSString *trimmed = dwStripTrailingNewlines(raw);
    if (!trimmed.length) return NO;
    NSArray<NSString *> *lines = [trimmed componentsSeparatedByString:@"\n"];
    if (lines.count < 3) return NO;
    if (![lines[0] hasPrefix:@"identifier="] || lines[0].length <= @"identifier=".length) return NO;
    if (![lines[1] hasPrefix:@"team="]) return NO;
    NSMutableArray<NSString *> *signerLines = [NSMutableArray arrayWithCapacity:lines.count];
    NSString *foundCDHash = nil;
    NSUInteger cdhashCount = 0;
    for (NSString *line in lines) {
        if ([line hasPrefix:@"cdhash="]) {
            cdhashCount++;
            foundCDHash = [line substringFromIndex:@"cdhash=".length];
        } else {
            [signerLines addObject:line];
        }
    }
    if (cdhashCount != 1 || !dwValidHexLower(foundCDHash, 40)) return NO;
    if (signer) *signer = [signerLines componentsJoinedByString:@"\n"];
    if (cdhash) *cdhash = foundCDHash;
    return YES;
}

- (BOOL)canLoadAfterRestart {
    if ([_environment daemonEnabledWithStatusText:NULL appPath:_appPath]) return YES;
    return _isLaunch && !_setupFeedback && [_environment stdinIsTerminal];
}

- (BOOL)restartRecordedDockForReason:(NSString *)why exitOut:(int *)exitOut {
    BOOL isRuntimeReason = [why isEqualToString:@"runtime"];
    if (_dockRestarted) {
        [self fail:@"the Dock was already restarted once in this start; nothing more was done. Start Infinify again." exitOut:exitOut];
        return NO;
    }
    if (!_isLogin && !_isLaunch) {
        if (isRuntimeReason) {
            [self fail:@"the recorded helper runtime lost its credentials while the Dock lived; a reload does not restart the Dock. Quit Infinify and start it again." exitOut:exitOut];
        } else {
            [self fail:@"the running Dock holds the helper of another Infinify build; a reload does not restart the Dock. Quit Infinify and start it again." exitOut:exitOut];
        }
        return NO;
    }
    if ([_environment daemonEnabledWithStatusText:NULL appPath:_appPath]) {
        if (![self pingDaemonWithExit:exitOut]) return NO;
    } else if (_isLaunch && !_setupFeedback && [_environment stdinIsTerminal]) {
        if (![_environment authorizeSudo]) {
            [self fail:@"sudo authorization failed; the Dock was not restarted and nothing was loaded." exitOut:exitOut];
            return NO;
        }
    } else if (isRuntimeReason) {
        [self fail:@"the recorded helper runtime lost its nonce while the Dock was still running, and without the launch daemon a new helper cannot be loaded without a password. Run Infinify native-desktop enable in Terminal once, or restart the Dock (killall Dock) and run Infinify native-desktop in Terminal; the windows are restored from the journal." exitOut:exitOut];
        return NO;
    } else {
        [self fail:@"the running Dock holds the helper of an earlier Infinify build, and without the launch daemon a new one cannot be loaded without a password. Run Infinify native-desktop enable in Terminal once, or restart the Dock (killall Dock) and run Infinify native-desktop in Terminal; the windows are restored from the journal." exitOut:exitOut];
        return NO;
    }

    if (![self validateRetiredJournalWithExit:exitOut]) return NO;
    _dockRestarted = YES;
    if ([_environment runLoaderRestartDockPID:_oldDockPID birthSec:_oldDockSec birthUsec:_oldDockUsec loaderPath:_loaderPath] != 0) {
        [self fail:@"the Dock is no longer the one the launch record names, so it was not restarted and nothing was loaded. Start Infinify again." exitOut:exitOut];
        return NO;
    }
    if (isRuntimeReason) {
        [self emitLine:@"Infinify restarted the Dock once: the recorded runtime lost its nonce or /tmp payload while that Dock lived; the new Dock gets a fresh /var/tmp runtime and the windows are restored from the journal."];
    } else if ([why isEqualToString:@"migrate"]) {
        [self emitLine:@"Infinify restarted the Dock once: the recorded runtime was under /tmp from an earlier build; the new Dock gets a /var/tmp runtime that survives nightly /tmp cleanup and the windows are restored from the journal."];
    } else {
        [self emitLine:@"Infinify restarted the Dock once: it held the helper of an earlier Infinify build, and this build's helper is other code; the new Dock gets this build's helper and the windows are restored from the journal."];
    }

    int restartWait = 0;
    for (;;) {
        restartWait++;
        [_environment sleepSeconds:2];
        if ([self readDockWithAttempts:1 confirmSeconds:3]) {
            if (![self takeDockWithExit:exitOut]) return NO;
            if (_dockPID != _oldDockPID || _dockSec != _oldDockSec || _dockUsec != _oldDockUsec) {
                if (![_bootUUID isEqualToString:_recordBootUUID]) {
                    [self fail:@"the boot session changed while the Dock restarted; preserve the launch record and inspect it. Restart your Mac, then open Infinify again." exitOut:exitOut];
                    return NO;
                }
                return YES;
            }
        }
        if (restartWait >= 36) {
            [self fail:@"the Dock was restarted to load this build's helper, but no new Dock settled; nothing was loaded. Once the Dock is back, start Infinify again: the windows are restored from the journal." exitOut:exitOut];
            return NO;
        }
    }
}

- (BOOL)loadedPayloadForRuntime:(NSString *)runtime directory:(NSString *__autoreleasing *)directory sha256:(NSString *__autoreleasing *)sha256 {
    NSString *runtimePayload = [runtime stringByAppendingPathComponent:@"payload-arm64e.dylib"];
    if ([self pathExistsOrSymlink:runtimePayload]) {
        if (![self isPrivateFile:runtimePayload]) return NO;
        NSString *digest = dwSHA256HexOfRegularFile([self fs:runtimePayload]);
        if (!digest) return NO;
        if (directory) *directory = runtime;
        if (sha256) *sha256 = digest;
        return YES;
    }
    return [_environment stagedPayloadForRuntime:runtime appPath:_appPath directory:directory sha256:sha256];
}

- (BOOL)copyPayloadToRuntime:(NSString *)runtimePayload exitOut:(int *)exitOut {
    NSString *fsSrc = [self fs:_payloadPath];
    int srcFD = open(fsSrc.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (srcFD < 0) {
        [self failNativeOperation:@"open" path:_payloadPath errorNumber:errno ? errno : EIO exitOut:exitOut];
        return NO;
    }
    struct stat srcStat;
    if (fstat(srcFD, &srcStat) != 0 || !S_ISREG(srcStat.st_mode) || srcStat.st_size < 0) {
        int err = errno ? errno : EINVAL;
        close(srcFD);
        [self failNativeOperation:@"stat" path:_payloadPath errorNumber:err exitOut:exitOut];
        return NO;
    }
    NSString *fsDst = [self fs:runtimePayload];
    int dstFD = open(fsDst.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (dstFD < 0) {
        int err = errno ? errno : EIO;
        close(srcFD);
        [self failNativeOperation:@"open" path:runtimePayload errorNumber:err exitOut:exitOut];
        return NO;
    }
    uint8_t buf[65536];
    for (;;) {
        ssize_t got = read(srcFD, buf, sizeof(buf));
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) {
            int err = errno ? errno : EIO;
            close(srcFD);
            close(dstFD);
            [self failNativeOperation:@"read" path:_payloadPath errorNumber:err exitOut:exitOut];
            return NO;
        }
        if (got == 0) break;
        if (!dwWriteAllFD(dstFD, buf, (size_t)got)) {
            int err = errno ? errno : EIO;
            close(srcFD);
            close(dstFD);
            [self failNativeOperation:@"write" path:runtimePayload errorNumber:err exitOut:exitOut];
            return NO;
        }
    }
    close(srcFD);
    if (fchmod(dstFD, 0600) != 0) {
        int err = errno ? errno : EIO;
        close(dstFD);
        [self failNativeOperation:@"chmod" path:runtimePayload errorNumber:err exitOut:exitOut];
        return NO;
    }
    (void)fsync(dstFD);
    if (close(dstFD) != 0) {
        int err = errno ? errno : EIO;
        [self failNativeOperation:@"close" path:runtimePayload errorNumber:err exitOut:exitOut];
        return NO;
    }
    return YES;
}

- (BOOL)writeLaunchRecordTo:(NSString *)logicalTarget outcome:(NSString *)outcome exitOut:(int *)exitOut {
    NSDictionary *record = @{
        @"version": @3,
        @"dock_pid": @(_dockPID),
        @"dock_birth_sec": @(_dockSec),
        @"dock_birth_usec": @(_dockUsec),
        @"boot_uuid": _bootUUID,
        @"runtime": _runtime,
        @"nonce_file": _nonceFile,
        @"payload_sha256": _payloadSHA256,
        @"outcome": outcome,
    };
    NSError *plistError = nil;
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListXMLFormat_v1_0 options:0 error:&plistError];
    if (!xml.length) {
        [self failNativeOperation:@"serialize" path:logicalTarget errorNumber:EINVAL exitOut:exitOut];
        return NO;
    }
    NSString *fsState = [self fs:_stateDir];
    NSString *logicalTmpTemplate = [_stateDir stringByAppendingPathComponent:@".launch.XXXXXX"];
    NSString *tmplStr = [fsState stringByAppendingPathComponent:@".launch.XXXXXX"];
    NSMutableData *tmpl = [[tmplStr dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [tmpl increaseLengthBy:1];
    int fd = mkstemp((char *)tmpl.mutableBytes);
    if (fd < 0) {
        [self failNativeOperation:@"mkstemp" path:logicalTmpTemplate errorNumber:errno ? errno : EIO exitOut:exitOut];
        return NO;
    }
    const char *tmpPath = (const char *)tmpl.bytes;
    if (!dwWriteAllFD(fd, xml.bytes, xml.length)) {
        int err = errno ? errno : EIO;
        close(fd);
        unlink(tmpPath);
        [self failNativeOperation:@"write" path:logicalTarget errorNumber:err exitOut:exitOut];
        return NO;
    }
    if (fchmod(fd, 0600) != 0) {
        int err = errno ? errno : EIO;
        close(fd);
        unlink(tmpPath);
        [self failNativeOperation:@"chmod" path:logicalTarget errorNumber:err exitOut:exitOut];
        return NO;
    }
    (void)fsync(fd);
    if (close(fd) != 0) {
        int err = errno ? errno : EIO;
        unlink(tmpPath);
        [self failNativeOperation:@"close" path:logicalTarget errorNumber:err exitOut:exitOut];
        return NO;
    }
    if (rename(tmpPath, [self fs:logicalTarget].fileSystemRepresentation) != 0) {
        int err = errno ? errno : EIO;
        unlink(tmpPath);
        [self failNativeOperation:@"rename" path:logicalTarget errorNumber:err exitOut:exitOut];
        return NO;
    }
    return YES;
}

- (int)runMode:(DWHelperLauncherMode)mode {
    _isCheck = (mode == DWHelperLauncherModeCheck);
    _isLogin = (mode == DWHelperLauncherModeLogin);
    _isReload = (mode == DWHelperLauncherModeReload);
    _isLaunch = (mode == DWHelperLauncherModeLaunch || mode == DWHelperLauncherModeLaunchSetup);
    _failStatus = _isLogin ? 0 : 1;
    _setupFeedback = (_isLogin || mode == DWHelperLauncherModeLaunchSetup);
    _appVerified = NO;
    _lockHeld = NO;
    _dockRestarted = NO;
    _runtimeInTmp = NO;
    _loadedDir = nil;
    _runtimeSuffix = nil;
    _recoverySource = nil;
    unsetenv("INFINIFY_LAUNCH_FROM_SETUP");

    int exitCode = _failStatus;
    if (![self verifyOwnBundleWithExit:&exitCode]) return exitCode;

    _uid = [_environment effectiveUID];
    if (_uid == 0) {
        return [self fail:@"run this launcher as the login user, never with sudo; only its explicit loader step uses sudo." exitOut:NULL];
    }
    if (![_environment isAppleSiliconDarwin]) {
        return [self fail:@"Apple Silicon macOS 26 or later is required." exitOut:NULL];
    }
    NSString *productVersion = nil;
    int swVersStatus = [_environment readMacOSProductVersion:&productVersion];
    if (swVersStatus != 0) {
        return swVersStatus > 0 ? swVersStatus : 1;
    }
    NSString *majorText = [(productVersion ?: @"") componentsSeparatedByString:@"."].firstObject ?: @"";
    if (!majorText.length) {
        return [self fail:@"could not identify the macOS version." exitOut:NULL];
    }
    for (NSUInteger i = 0; i < majorText.length; i++) {
        unichar c = [majorText characterAtIndex:i];
        if (c < '0' || c > '9') return [self fail:@"could not identify the macOS version." exitOut:NULL];
    }
    if (majorText.integerValue < 26) {
        return [self fail:@"macOS 26 or later is required." exitOut:NULL];
    }

    NSString *doctorRaw = nil;
    if ([_environment runDoctorAtPath:_doctorPath output:&doctorRaw] != 0) {
        return [self fail:@"doctor failed; no helper was loaded." exitOut:NULL];
    }
    NSString *doctorReport = dwStripTrailingNewlines(doctorRaw);
    [self emitLine:doctorReport];
    id reportObj = dwParseStructuredData([doctorReport dataUsingEncoding:NSUTF8StringEncoding]);
    NSDictionary *reportDict = [reportObj isKindOfClass:NSDictionary.class] ? (NSDictionary *)reportObj : nil;
    id preflightVal = reportDict[@"injection_preflight_passed"];
    if (!dwIsBool(preflightVal)) {
        return [self fail:@"doctor returned an invalid policy report." exitOut:NULL];
    }
    if (![preflightVal boolValue]) {
        return [self fail:@"current SIP/arm64e boot policy does not pass preflight; nothing was loaded and no settings were changed." exitOut:NULL];
    }

    if (_isCheck) {
        NSString *daemonText = nil;
        (void)[_environment daemonEnabledWithStatusText:&daemonText appPath:_appPath];
        [self emitLine:[NSString stringWithFormat:@"launch daemon: %@", daemonText ?: @""]];
        return 0;
    }

    if (_isReload) {
        BOOL lookupFailed = NO;
        NSArray<NSNumber *> *instances = [_environment runningInfinifyPIDsForUID:_uid includeAncestors:YES failed:&lookupFailed];
        if (lookupFailed || instances.count == 0) {
            return [self fail:@"a reload is for the running Infinify, and none is running." exitOut:NULL];
        }
        pid_t ppid = [_environment parentPID];
        if (instances.count != 1 || [instances[0] intValue] != (int)ppid) {
            return [self fail:@"a reload is for the one running Infinify to ask, as its child." exitOut:NULL];
        }
    } else {
        BOOL lookupFailed = NO;
        NSArray<NSNumber *> *instances = [_environment runningInfinifyPIDsForUID:_uid includeAncestors:NO failed:&lookupFailed];
        if (!lookupFailed && instances.count > 0) {
            if (_isLogin) {
                [self emitLine:@"Infinify is already running; nothing to start."];
                return 0;
            }
            return [self fail:@"an Infinify instance is already running; quit it normally before starting native desktop mode." exitOut:NULL];
        }
        if (lookupFailed) {
            return [self fail:@"could not determine whether Infinify is already running." exitOut:NULL];
        }
    }

    int dockWait = _isLogin ? 60 : (_isReload ? 15 : 1);
    unsigned int dockConfirm = _isLogin ? 3 : (_isReload ? 1 : 0);
    if (![self readDockWithAttempts:dockWait confirmSeconds:dockConfirm]) {
        if (!_lastDockReport.length) {
            return [self fail:@"could not resolve the current Dock process identity." exitOut:NULL];
        }
        return [self fail:@"the Dock process identity did not settle." exitOut:NULL];
    }
    if (![self takeDockWithExit:&exitCode]) return exitCode;

    _stateDir = [_environment stateDirectory];
    if (!_stateDir.length) {
        return [self fail:@"launch-state directory must be owned by this login user with mode 0700." exitOut:NULL];
    }
    _recordPath = [_stateDir stringByAppendingPathComponent:@"launch.plist"];
    _pendingRecordPath = [_stateDir stringByAppendingPathComponent:@"launch.pending.plist"];
    _lockPath = [_stateDir stringByAppendingPathComponent:@"launch.lock"];
    _pausePath = [_stateDir stringByAppendingPathComponent:@"auto-reload-paused.plist"];

    struct stat stateLStat;
    NSString *fsStateDir = [self fs:_stateDir];
    if (lstat(fsStateDir.fileSystemRepresentation, &stateLStat) == 0 && S_ISLNK(stateLStat.st_mode)) {
        return [self fail:@"the launch-state directory must not be a symlink." exitOut:NULL];
    }
    if (!dwMkdirP0700(fsStateDir.fileSystemRepresentation)) {
        return [self failNativeOperation:@"mkdir" path:_stateDir errorNumber:errno ? errno : EIO exitOut:NULL];
    }
    if (![self isPrivateDirectory:_stateDir]) {
        return [self fail:@"launch-state directory must be owned by this login user with mode 0700." exitOut:NULL];
    }
    NSString *fsLockPath = [self fs:_lockPath];
    if (mkdir(fsLockPath.fileSystemRepresentation, 0700) != 0) {
        return [self fail:@"another launch or interrupted launch lock exists; inspect it before retrying. Wait a moment and try again, or remove ~/Library/Application Support/Infinify/native-desktop/launch.lock once no Infinify launcher is running." exitOut:NULL];
    }
    _lockHeld = YES;
    if (_managesSignals) {
        dwInstallLockSignals(fsLockPath.fileSystemRepresentation);
    }

    if (_isLaunch) {
        if ([self pathExistsOrSymlink:_pausePath]) {
            if (unlink([self fs:_pausePath].fileSystemRepresentation) == 0 || errno == ENOENT) {
                [self emitLine:@"Automatic loading had been paused after Dock restarts around loads; this start by hand lifts the pause."];
            } else {
                // Original rm -f was the left side of &&: report its error but
                // continue, with the pause file retained and this lock still held.
                int err = errno ? errno : EIO;
                [_environment writeStderr:[NSString stringWithFormat:@"Infinify native desktop: unlink %@: %s\n", _pausePath, strerror(err)]];
            }
        }
    } else if ([self isLauncherPaused]) {
        if (_isLogin) {
            return [self fail:@"automatic loading is paused after three Dock restarts in a row around loads; a start by hand lifts the pause." exitOut:NULL];
        }
        return [self fail:@"automatic loading is paused for this payload; run Infinify native-desktop by hand to lift the pause." exitOut:NULL];
    }

    if ([self pathExistsOrSymlink:_pendingRecordPath]) {
        if (![self isPrivateFile:_pendingRecordPath]) {
            return [self fail:@"an interrupted launch or recovery marker is not private; preserve it and inspect before retrying. Once no load is running, restart your Mac, remove ~/Library/Application Support/Infinify/native-desktop/launch.pending.plist, and open Infinify again." exitOut:NULL];
        }
        return [self fail:@"an interrupted launch or recovery remains pending; preserve its runtime and inspect it before retrying. Once no load is running, restart your Mac (or run killall Dock in Terminal), remove ~/Library/Application Support/Infinify/native-desktop/launch.pending.plist, and open Infinify again." exitOut:NULL];
    }

    BOOL reuse = NO;
    BOOL recovery = NO;
    NSString *reuseSignature = nil;

    if ([self pathExistsOrSymlink:_recordPath]) {
        if (![self isPrivateFile:_recordPath]) {
            return [self fail:@"the existing launch record is not a private regular file; inspect it before retrying. Restart your Mac, remove ~/Library/Application Support/Infinify/native-desktop/launch.plist, and open Infinify again." exitOut:NULL];
        }
        id recordObj = dwParsePlistFile([self fs:_recordPath]);
        if (!recordObj) {
            return [self fail:@"the existing launch record is not a valid property list. Restart your Mac, remove ~/Library/Application Support/Infinify/native-desktop/launch.plist, and open Infinify again." exitOut:NULL];
        }
        NSArray<NSString *> *expectedRecordKeys = @[
            @"boot_uuid", @"dock_birth_sec", @"dock_birth_usec", @"dock_pid",
            @"nonce_file", @"outcome", @"payload_sha256", @"runtime", @"version",
        ];
        NSMutableArray<NSString *> *collectedKeys = [NSMutableArray array];
        dwCollectPlistKeysRecursively(recordObj, collectedKeys);
        NSArray<NSString *> *sortedKeys = [collectedKeys sortedArrayUsingSelector:@selector(compare:)];
        if (![sortedKeys isEqualToArray:expectedRecordKeys]) {
            return [self fail:@"unknown or incomplete launch-record shape; preserve it and inspect before retrying. Restart your Mac, remove ~/Library/Application Support/Infinify/native-desktop/launch.plist, and open Infinify again." exitOut:NULL];
        }
        NSDictionary *record = [recordObj isKindOfClass:NSDictionary.class] ? (NSDictionary *)recordObj : nil;
        uint64_t recVer = 0; BOOL recVerNeg = NO;
        if (!dwExtractInteger(record[@"version"], &recVer, &recVerNeg) || recVerNeg || recVer != 3) {
            return [self fail:@"unsupported launch-record format; preserve it and inspect before retrying. Restart your Mac, remove ~/Library/Application Support/Infinify/native-desktop/launch.plist, and open Infinify again." exitOut:NULL];
        }
        id outcomeObj = record[@"outcome"];
        if (![outcomeObj isKindOfClass:NSString.class]) {
            return [self fail:@"invalid launch-record outcome; inspect it before retrying. Restart your Mac, remove ~/Library/Application Support/Infinify/native-desktop/launch.plist, and open Infinify again." exitOut:NULL];
        }
        if (![(NSString *)outcomeObj isEqualToString:@"ready"]) {
            return [self fail:@"a prior injection outcome is pending or unknown; retain its runtime and inspect it, do not inject again. Once no load is running, restart your Mac (or run killall Dock in Terminal), remove ~/Library/Application Support/Infinify/native-desktop/launch.plist, and open Infinify again." exitOut:NULL];
        }
        id recBootObj = record[@"boot_uuid"];
        if (![recBootObj isKindOfClass:NSString.class]) {
            return [self fail:@"launch record has no exact boot-session UUID; preserve it and inspect it before retrying." exitOut:NULL];
        }
        if (!dw_boot_uuid_valid(recBootObj)) {
            return [self fail:@"launch record has an invalid boot-session UUID; preserve it and inspect it before retrying." exitOut:NULL];
        }
        _recordBootUUID = (NSString *)recBootObj;

        uint64_t rPID = 0, rSec = 0, rUsec = 0;
        BOOL rPIDNeg = NO, rSecNeg = NO, rUsecNeg = NO;
        if (!dwExtractInteger(record[@"dock_pid"], &rPID, &rPIDNeg)) {
            return [self fail:@"launch record has no exact integer Dock PID; inspect it before retrying." exitOut:NULL];
        }
        if (!dwExtractInteger(record[@"dock_birth_sec"], &rSec, &rSecNeg)) {
            return [self fail:@"launch record has no exact integer Dock birth time; inspect it before retrying." exitOut:NULL];
        }
        if (!dwExtractInteger(record[@"dock_birth_usec"], &rUsec, &rUsecNeg)) {
            return [self fail:@"launch record has no exact integer Dock birth time; inspect it before retrying." exitOut:NULL];
        }
        if (!dwPIDValid(rPID, rPIDNeg)) {
            return [self fail:@"launch record has an invalid Dock PID; inspect it before retrying." exitOut:NULL];
        }
        if (rSecNeg || rSec == 0) {
            return [self fail:@"launch record has an invalid Dock birth time; inspect it before retrying." exitOut:NULL];
        }
        if (rUsecNeg || rUsec > 999999) {
            return [self fail:@"launch record has an invalid Dock birth time; inspect it before retrying." exitOut:NULL];
        }
        _oldDockPID = (pid_t)rPID;
        _oldDockSec = rSec;
        _oldDockUsec = rUsec;

        id recPayloadObj = record[@"payload_sha256"];
        if (![recPayloadObj isKindOfClass:NSString.class]) {
            return [self fail:@"launch record has no payload digest; inspect it before retrying." exitOut:NULL];
        }
        if (!dwValidHexLower((NSString *)recPayloadObj, 64)) {
            return [self fail:@"launch record has an invalid payload digest; inspect it before retrying." exitOut:NULL];
        }
        _recordPayloadSHA256 = (NSString *)recPayloadObj;

        id recRuntimeObj = record[@"runtime"];
        if (![recRuntimeObj isKindOfClass:NSString.class]) {
            return [self fail:@"invalid recorded runtime path." exitOut:NULL];
        }
        id recNonceObj = record[@"nonce_file"];
        if (![recNonceObj isKindOfClass:NSString.class]) {
            return [self fail:@"invalid recorded nonce-file path." exitOut:NULL];
        }
        _runtime = (NSString *)recRuntimeObj;
        _nonceFile = (NSString *)recNonceObj;

        BOOL matchesVarTmpShape = [_runtime hasPrefix:@"/var/tmp/if-native."] && _runtime.length == (@"/var/tmp/if-native.".length + 6);
        BOOL matchesTmpShape = [_runtime hasPrefix:@"/tmp/if-native."] && _runtime.length == (@"/tmp/if-native.".length + 6);
        if (!matchesVarTmpShape && !matchesTmpShape) {
            return [self fail:@"invalid recorded private runtime path. Restart your Mac, remove ~/Library/Application Support/Infinify/native-desktop/launch.plist, and open Infinify again." exitOut:NULL];
        }
        _runtimeInTmp = matchesTmpShape;
        const char *suffixC = DWHelperRuntimeSuffix(_runtime.UTF8String);
        if (!suffixC) {
            return [self fail:@"invalid recorded private runtime path." exitOut:NULL];
        }
        _runtimeSuffix = @(suffixC);
        if (![_nonceFile isEqualToString:[_runtime stringByAppendingString:@"/nonce"]]) {
            return [self fail:@"recorded nonce file does not belong to its runtime." exitOut:NULL];
        }

        if (![_recordBootUUID isEqualToString:_bootUUID]) {
            if (![self archiveAndRemovePriorBootRecordWithExit:&exitCode]) return exitCode;
            [self emitLine:@"The ready record belongs to a previous boot session; its prior Dock cannot survive this boot. The record was archived, any remaining runtime was left untouched, and startup will be fresh without journal replay."];
        } else {
            if (![self isPrivateDirectory:_runtime]) {
                return [self fail:@"recorded runtime is missing or no longer private in this boot session; do not inject again. Restart your Mac, then open Infinify again." exitOut:NULL];
            }
            BOOL noncePresent = NO;
            if ([self pathExistsOrSymlink:_nonceFile]) {
                if (![self isPrivateFile:_nonceFile]) {
                    return [self fail:@"recorded nonce file is missing or no longer private; do not inject again. Restart your Mac, then open Infinify again." exitOut:NULL];
                }
                noncePresent = YES;
            }
            NSString *loadedDir = nil;
            NSString *loadedSHA = nil;
            if ([self loadedPayloadForRuntime:_runtime directory:&loadedDir sha256:&loadedSHA]) {
                _loadedDir = loadedDir;
                if (![loadedSHA isEqualToString:_recordPayloadSHA256]) {
                    return [self fail:@"recorded runtime payload bytes differ from the launch record; do not reuse the old helper. Restart your Mac, then open Infinify again." exitOut:NULL];
                }
                NSString *loadedPayloadPath = [_loadedDir stringByAppendingPathComponent:@"payload-arm64e.dylib"];
                if (![_environment verifyCodeSignatureAtPath:loadedPayloadPath deep:NO]) {
                    return [self fail:@"recorded runtime payload signature verification failed; do not reuse the old helper. Restart your Mac, then open Infinify again." exitOut:NULL];
                }
            } else if (_runtimeInTmp
                       && ![self pathExistsOrSymlink:[_runtime stringByAppendingPathComponent:@"payload-arm64e.dylib"]]
                       && ![self pathExistsOrSymlink:[_runtime stringByAppendingPathComponent:@"payload-arm64e.dylib.json"]]
                       && (!noncePresent || ![_environment daemonEnabledWithStatusText:NULL appPath:_appPath])) {
                _loadedDir = nil;
            } else {
                return [self fail:@"recorded runtime payload is missing, no longer private, or no longer the launch daemon's root-owned copy; do not inject again. Restart your Mac, then open Infinify again." exitOut:NULL];
            }

            if (_oldDockPID == _dockPID && _oldDockSec == _dockSec && _oldDockUsec == _dockUsec) {
                if (!noncePresent || !_loadedDir.length) {
                    if (![self restartRecordedDockForReason:@"runtime" exitOut:&exitCode]) return exitCode;
                } else if (_runtimeInTmp && [self canLoadAfterRestart]) {
                    if (![self restartRecordedDockForReason:@"migrate" exitOut:&exitCode]) return exitCode;
                } else if ([_recordPayloadSHA256 isEqualToString:_payloadSHA256]) {
                    reuse = YES;
                } else {
                    NSString *loadedSigner = nil, *loadedCDHash = nil;
                    NSString *loadedPayloadPath = [_loadedDir stringByAppendingPathComponent:@"payload-arm64e.dylib"];
                    if (![self parsePayloadIdentityAtPath:loadedPayloadPath signer:&loadedSigner cdhash:&loadedCDHash]) {
                        return [self fail:@"could not read the code identity of the helper payload in the running Dock; nothing was loaded. Restart the Dock (killall Dock) and start Infinify again; the windows are restored from the journal." exitOut:NULL];
                    }
                    NSString *bundleSigner = nil, *bundleCDHash = nil;
                    if (![self parsePayloadIdentityAtPath:_payloadPath signer:&bundleSigner cdhash:&bundleCDHash]) {
                        return [self fail:@"could not read the code identity of this bundle's payload; reinstall Infinify." exitOut:NULL];
                    }
                    if (![loadedSigner isEqualToString:bundleSigner]) {
                        return [self fail:@"the helper in the running Dock is signed by another developer or under another identifier than this bundle's, so it is not reused and the Dock is not restarted by itself. To switch to this build, restart the Dock (killall Dock) or log out and back in, then start Infinify again; the windows are restored from the journal." exitOut:NULL];
                    }
                    if ([loadedCDHash isEqualToString:bundleCDHash]) {
                        reuse = YES;
                        reuseSignature = bundleCDHash;
                    } else {
                        if (![self restartRecordedDockForReason:@"update" exitOut:&exitCode]) return exitCode;
                    }
                }
            }

            if (!reuse) {
                DWPriorDockState priorState = [self priorDockState];
                if (priorState == DWPriorDockPresent) {
                    return [self fail:@"the recorded Dock PID is still present; preserve its launch record and runtime. Restart the Dock (killall Dock) or restart your Mac, then open Infinify again." exitOut:NULL];
                }
                if (priorState != DWPriorDockGone) {
                    return [self fail:@"could not prove the recorded Dock process is gone; preserve its launch record and runtime. Restart your Mac, then open Infinify again." exitOut:NULL];
                }
                if (![self validateRetiredJournalWithExit:&exitCode]) return exitCode;
                if (_journalRefused != DWJournalRefusalNone) {
                    if (![self refuseUnrecoverableJournalWithExit:&exitCode]) return exitCode;
                } else {
                    recovery = YES;
                }
            }
        }
    }

    uint64_t loadedAt = 0;
    if (reuse && reuseSignature.length > 0) {
        [self emitLine:[NSString stringWithFormat:@"Reusing the recorded same-Dock desktop helper: this bundle's payload is the same code (CodeDirectory hash %@, same identifier, team and signing authorities) signed again; the app will authenticate its scope and restoration capabilities.", reuseSignature]];
    } else if (reuse) {
        [self emitLine:@"Reusing the recorded same-Dock desktop helper with the payload hash bound to this bundle; the app will authenticate its scope and restoration capabilities."];
    } else {
        if (!recovery) {
            if ([self pathExistsOrSymlink:_recordPath]) {
                return [self fail:@"launch record remains after the retired record check; preserve it and inspect it." exitOut:NULL];
            }
        }
        BOOL loadViaDaemon = [_environment daemonEnabledWithStatusText:NULL appPath:_appPath];
        if (_isLogin || _isReload) {
            if (!loadViaDaemon) {
                return [self fail:@"the launch daemon is not enabled, so nothing can be loaded without a password; run Infinify native-desktop enable in a terminal." exitOut:NULL];
            }
            if (![self pingDaemonWithExit:&exitCode]) return exitCode;
        } else {
            if (!loadViaDaemon && ![_environment stdinIsTerminal]) {
                return [self fail:@"start this owner-run launcher in a terminal for the explicit sudo loader step." exitOut:NULL];
            }
        }

        NSString *retiredSuffix = _runtimeSuffix ?: @"";
        NSString *fsVarTmp = [self fs:@"/var/tmp"];
        NSString *createdRuntime = nil;
        for (;;) {
            NSString *tmplStr = [fsVarTmp stringByAppendingPathComponent:@"if-native.XXXXXX"];
            NSMutableData *tmpl = [[tmplStr dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
            [tmpl increaseLengthBy:1];
            if (!mkdtemp((char *)tmpl.mutableBytes)) {
                return [self failNativeOperation:@"mkdtemp" path:@"/var/tmp/if-native.XXXXXX" errorNumber:errno ? errno : EIO exitOut:NULL];
            }
            const char *createdC = (const char *)tmpl.bytes;
            const char *dot = strrchr(createdC, '.');
            NSString *candSuffix = dot ? @(dot + 1) : @"";
            if (candSuffix.length == 6 && ![candSuffix isEqualToString:retiredSuffix]) {
                createdRuntime = [@"/var/tmp/if-native." stringByAppendingString:candSuffix];
                break;
            }
            if (rmdir(createdC) != 0) {
                NSString *collidedLogical = [@"/var/tmp/if-native." stringByAppendingString:candSuffix];
                return [self failNativeOperation:@"rmdir" path:collidedLogical errorNumber:errno ? errno : EIO exitOut:NULL];
            }
        }
        if (![self isPrivateDirectory:createdRuntime]) {
            return [self fail:@"could not create a private runtime directory." exitOut:NULL];
        }
        _runtime = createdRuntime;
        _nonceFile = [_runtime stringByAppendingString:@"/nonce"];

        // Shell redirection created the empty private file before openssl ran;
        // preserve that retained state even when the randomness adapter fails.
        int nonceFD = open([self fs:_nonceFile].fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (nonceFD < 0) {
            return [self failNativeOperation:@"open" path:_nonceFile errorNumber:errno ? errno : EIO exitOut:NULL];
        }
        uint8_t rawNonce[32];
        errno = 0;
        if (![_environment randomBytes:rawNonce length:sizeof(rawNonce)]) {
            int err = errno ? errno : EIO;
            close(nonceFD);
            return [self failNativeOperation:@"randomBytes" path:_nonceFile errorNumber:err exitOut:NULL];
        }
        char hexLine[65];
        static const char digits[] = "0123456789abcdef";
        for (size_t i = 0; i < sizeof(rawNonce); i++) {
            hexLine[i * 2] = digits[(rawNonce[i] >> 4) & 0x0f];
            hexLine[i * 2 + 1] = digits[rawNonce[i] & 0x0f];
        }
        hexLine[64] = '\n';
        if (!dwWriteAllFD(nonceFD, hexLine, sizeof(hexLine))) {
            int err = errno ? errno : EIO;
            close(nonceFD);
            return [self failNativeOperation:@"write" path:_nonceFile errorNumber:err exitOut:NULL];
        }
        (void)fsync(nonceFD);
        if (close(nonceFD) != 0) {
            return [self failNativeOperation:@"close" path:_nonceFile errorNumber:errno ? errno : EIO exitOut:NULL];
        }
        char checkedNonce[65];
        if (![self isPrivateFile:_nonceFile]
            || !DWHelperReadNonceFile([self fs:_nonceFile].fileSystemRepresentation, _uid, checkedNonce)) {
            return [self fail:@"could not create a private nonce file." exitOut:NULL];
        }

        if (!loadViaDaemon) {
            NSString *runtimePayload = [_runtime stringByAppendingPathComponent:@"payload-arm64e.dylib"];
            if (![self copyPayloadToRuntime:runtimePayload exitOut:&exitCode]) {
                return exitCode;
            }
            if (![self isPrivateFile:runtimePayload]) {
                return [self fail:@"could not create a private runtime payload." exitOut:NULL];
            }
            NSString *copiedPayloadSHA = dwSHA256HexOfRegularFile([self fs:runtimePayload]);
            if (!copiedPayloadSHA || ![copiedPayloadSHA isEqualToString:_payloadSHA256]) {
                return [self fail:@"copied runtime payload bytes differ from the bundle." exitOut:NULL];
            }
            if (![_environment verifyCodeSignatureAtPath:runtimePayload deep:NO]) {
                return [self fail:@"copied payload signature verification failed." exitOut:NULL];
            }
        }

        if (recovery) {
            if ([self pathExistsOrSymlink:_pendingRecordPath]) {
                return [self fail:@"an interrupted recovery marker already exists; preserve it and inspect it." exitOut:NULL];
            }
            if (![self writeLaunchRecordTo:_pendingRecordPath outcome:@"pending" exitOut:&exitCode]) {
                return exitCode;
            }
        } else {
            if (![self writeLaunchRecordTo:_recordPath outcome:@"pending" exitOut:&exitCode]) {
                return exitCode;
            }
        }

        if (loadViaDaemon) {
            [self emitLine:@"Starting the explicitly selected full-desktop SAME_USER helper, including newly opened applications. Only the loader runs as root, through the launch daemon."];
        } else {
            [self emitLine:@"Starting the explicitly selected full-desktop SAME_USER helper, including newly opened applications. Only the loader runs with sudo."];
        }

        time_t epochNow = [_environment currentEpochSeconds];
        loadedAt = epochNow > 0 ? (uint64_t)epochNow : 0;

        NSMutableArray<NSString *> *loaderArgs = [NSMutableArray arrayWithObjects:
            _runtime,
            @"--nonce-file", _nonceFile,
            @"--desktop",
            @"--expected-dock",
            [NSString stringWithFormat:@"%d", (int)_dockPID],
            [NSString stringWithFormat:@"%llu", (unsigned long long)_dockSec],
            [NSString stringWithFormat:@"%llu", (unsigned long long)_dockUsec],
            nil];
        if (recovery) {
            [loaderArgs addObjectsFromArray:@[
                @"--recover-journal", _recoverySource,
                @"--expected-retired-dock",
                [NSString stringWithFormat:@"%d", (int)_oldDockPID],
                [NSString stringWithFormat:@"%llu", (unsigned long long)_oldDockSec],
                [NSString stringWithFormat:@"%llu", (unsigned long long)_oldDockUsec],
            ]];
        }

        int loaderStatus = loadViaDaemon
            ? [_environment runDaemonLoadWithArguments:loaderArgs appPath:_appPath]
            : [_environment runSudoLoaderAtPath:_loaderPath payloadPath:[_runtime stringByAppendingPathComponent:@"payload-arm64e.dylib"] arguments:loaderArgs];

        if (recovery) {
            if (loaderStatus != 0) {
                return [self fail:[NSString stringWithFormat:@"recovery loader did not establish readiness; retained old ready record at %@, pending marker at %@ and runtime at %@. Inspect before any retry.",
                                   _recordPath, _pendingRecordPath, _runtime] exitOut:NULL];
            }
            if (![self archiveRetiredRecordWithExit:&exitCode]) return exitCode;
            if (![self writeLaunchRecordTo:_pendingRecordPath outcome:@"ready" exitOut:&exitCode]) {
                return exitCode;
            }
            if (rename([self fs:_pendingRecordPath].fileSystemRepresentation, [self fs:_recordPath].fileSystemRepresentation) != 0) {
                return [self fail:@"helper recovered, but the ready record could not be promoted; preserve the pending marker and inspect it." exitOut:NULL];
            }
        } else {
            if (loaderStatus != 0) {
                return [self fail:[NSString stringWithFormat:@"loader did not establish readiness; retained pending record at %@ and runtime at %@. Inspect before any retry.",
                                   _recordPath, _runtime] exitOut:NULL];
            }
            if (![self writeLaunchRecordTo:_recordPath outcome:@"ready" exitOut:&exitCode]) {
                return exitCode;
            }
        }
    }

    uid_t nowUID = [_environment effectiveUID];
    if (nowUID != _uid || _uid == 0) {
        return [self fail:@"refusing to run the app as root or another user." exitOut:NULL];
    }
    [self releaseLock];

    if (_isReload) {
        NSString *endpointLine = [NSString stringWithFormat:@"INFINIFY-NATIVE-ENDPOINT %@ %@\n", _runtime, _nonceFile];
        errno = 0;
        if (![_environment writeReloadEndpoint:endpointLine]) {
            return [self failNativeOperation:@"write" path:@"fd:3" errorNumber:errno ? errno : EIO exitOut:NULL];
        }
        return 0;
    }

    BOOL daemonOn = [_environment daemonEnabledWithStatusText:NULL appPath:_appPath];
    return [_environment execDesktopAppAtPath:_appPath runtime:_runtime nonceFile:_nonceFile
                                daemonEnabled:daemonOn payloadSHA256:_payloadSHA256 loadedAt:loadedAt];
}

@end

BOOL DWHelperLauncherParseMode(const char *argument, DWHelperLauncherMode *mode) {
    if (!argument || !mode) return NO;
    if (!strcmp(argument, "launch")) { *mode = DWHelperLauncherModeLaunch; return YES; }
    if (!strcmp(argument, "launch-setup")) { *mode = DWHelperLauncherModeLaunchSetup; return YES; }
    if (!strcmp(argument, "check")) { *mode = DWHelperLauncherModeCheck; return YES; }
    if (!strcmp(argument, "login")) { *mode = DWHelperLauncherModeLogin; return YES; }
    if (!strcmp(argument, "reload")) { *mode = DWHelperLauncherModeReload; return YES; }
    return NO;
}

int DWHelperLauncherMain(int argc, const char *argv[]) {
    @autoreleasepool {
        umask(0077);
        DWHelperLauncherMode mode = DWHelperLauncherModeLaunch;
        if (argc != 1 || !argv || !DWHelperLauncherParseMode(argv[0], &mode)) {
            fprintf(stderr, "%s\n", kLauncherUsage.UTF8String);
            return 64;
        }
        return [[DWHelperLauncher systemLauncher] runMode:mode];
    }
}
