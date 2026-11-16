// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include <libproc.h>
#include <sys/types.h>

// Logical runtime names are wire/disk identities, never canonicalized through realpath.
// Both current /var/tmp and legacy /tmp forms have exactly six ASCII alphanumerics.
const char *DWHelperRuntimeSuffix(const char *path);
BOOL DWHelperBootSessionUUID(char output[37]);
BOOL DWHelperReadNonceFile(const char *path,uid_t uid,char nonce[65]);

// Filesystem-and-process seam. The macOS adapter uses the original paths and kernel
// process queries; a temporary-directory adapter can map logical paths and provide a
// fake Dock (including failed/uncertain queries). errno is part of the query contract.
@protocol DWHelperLifecycleEnvironment <NSObject>
- (NSString *)fileSystemPath:(NSString *)logicalPath;
- (int)processInfo:(pid_t)pid result:(struct proc_bsdinfo *)result;
- (int)probeProcess:(pid_t)pid;
- (BOOL)bootSessionUUID:(char [37])output;
@end

// Owns private credentials and retired-journal admission. Failure returns NO without
// modifying the source, and never implies that a failed process query proves retirement.
// Callers preserve their layered checks and error wording before entering this module.
@interface DWHelperLifecycle : NSObject
+ (instancetype)systemLifecycle;
- (instancetype)initWithEnvironment:(id<DWHelperLifecycleEnvironment>)environment;
- (BOOL)recoveryJournal:(const char *)sourcePath runtime:(const char *)runtime
                  dock:(const struct proc_bsdinfo *)dock expectedPID:(pid_t)expectedPID
           expectedSec:(uint64_t)expectedSec expectedUsec:(uint64_t)expectedUsec
           sourceBytes:(NSData *__autoreleasing *)sourceBytes
        recoveryFields:(NSDictionary *__autoreleasing *)recoveryFields;
@end

// Kept as the established app entry points; their implementation is now lifecycle-owned.
NSString *DWDockReloadStateDirectory(void);
BOOL DWDockReloadPaused(NSString *directory,NSString *payloadSHA256);
BOOL DWDockReloadPause(NSString *directory,NSString *payloadSHA256,NSString *reason);
BOOL DWDockReloadResume(NSString *directory);
BOOL DWDockReloadParseEndpoint(NSString *output,NSString *__autoreleasing *runtime,NSString *__autoreleasing *nonceFile);
