// SPDX-License-Identifier: MIT AND GPL-3.0-or-later
// Pause semantics translated from Sunlight Sources/Canvas/RealWindows/AdditionReloader.swift
// lines 50-56 at afeea74b18e70ca49bf462d6fe462cf65deb2b32, https://github.com/spacefarm-digital/sunlight
// (MIT, Copyright (c) 2026 spacefarm; native/app/Resources/SUNLIGHT-NOTICE.txt).
// Loader admission extracted from DWLoader.m (MIT), adapted from yabai src/osax/loader.m
// at dd845723416f5fe92af49fad5ebab00369e07edd (Copyright (c) 2019 Åsmund Vikane).
// The original copyright and MIT permission text remain in Loader/DWLoader.m.
// Lifecycle rules extracted without policy changes from DWLoader.m, DWLoaddRequest.m,
// DWDockReloader.m and native-desktop-launcher.sh. Injection remains in the MIT loader.
#import "DWHelperLifecycle.h"
#import "DWHelperMacEnvironment.h"
#import "DWJournalFields.h"
#import "DWOwnerFile.h"
#include <CommonCrypto/CommonDigest.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>
#include <limits.h>
#include <unistd.h>

BOOL DWHelperBootSessionUUID(char output[37]) {
    char value[37]={0};size_t size=sizeof(value);
    if(sysctlbyname("kern.bootsessionuuid",value,&size,NULL,0) || size!=sizeof(value) || value[36]!='\0')return NO;
    for(NSUInteger i=0;i<36;i++) {
        char c=value[i];
        if(i==8 || i==13 || i==18 || i==23) { if(c!='-')return NO; }
        else if(!((c>='0'&&c<='9')||(c>='A'&&c<='F')))return NO;
    }
    memcpy(output,value,sizeof(value));return YES;
}
static BOOL json_integer(id value,uint64_t minimum,uint64_t maximum) {
    return [value isKindOfClass:NSNumber.class]
        && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()
        && !CFNumberIsFloatType((__bridge CFNumberRef)value)
        && [value compare:@(minimum)]!=NSOrderedAscending
        && [value compare:@(maximum)]!=NSOrderedDescending;
}
const char *DWHelperRuntimeSuffix(const char *path) {
    static const char varPrefix[]="/var/tmp/if-native.",tmpPrefix[]="/tmp/if-native.";
    const char *suffix=NULL;
    if(path && !strncmp(path,varPrefix,sizeof(varPrefix)-1))suffix=path+sizeof(varPrefix)-1;
    else if(path && !strncmp(path,tmpPrefix,sizeof(tmpPrefix)-1))suffix=path+sizeof(tmpPrefix)-1;
    if(!suffix || strlen(suffix)!=6)return NULL;
    for(const char *p=suffix;*p;p++)if(!((*p>='a'&&*p<='z')||(*p>='A'&&*p<='Z')||(*p>='0'&&*p<='9')))return NULL;
    return suffix;
}
static BOOL private_runtime_path(const char *path) { return DWHelperRuntimeSuffix(path)!=NULL; }
static NSString *sha256_hex(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if(!CC_SHA256(data.bytes,(CC_LONG)data.length,digest))return nil;
    NSMutableString *hex=[NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for(unsigned i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];
    return hex;
}
static BOOL valid_nonce(const char *nonce) {
    if(strlen(nonce)!=64)return NO;
    for(const char *p=nonce;*p;p++)if(!((*p>='0' && *p<='9') || (*p>='a' && *p<='f')))return NO;
    return YES;
}
// The production launcher never places credentials in argv. O_NONBLOCK also
// avoids waiting on a substituted FIFO before fstat rejects its file type.
BOOL DWHelperReadNonceFile(const char *path,uid_t uid,char nonce[65]) {
    if(path[0]!='/')return NO;
    int fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0)return NO;
    struct stat st;
    BOOL ok=fstat(fd,&st)==0 && S_ISREG(st.st_mode) && st.st_uid==uid
        && (st.st_mode&07777)==0600 && (st.st_size==64 || st.st_size==65);
    char bytes[66];size_t used=0;
    while(ok && used<sizeof(bytes)) {
        ssize_t n=read(fd,bytes+used,sizeof(bytes)-used);
        if(n<0 && errno==EINTR)continue;
        if(n<0){ok=NO;break;}
        if(!n)break;
        used+=(size_t)n;
    }
    close(fd);
    if(!ok || (used!=64 && !(used==65 && bytes[64]=='\n')))return NO;
    memcpy(nonce,bytes,64);nonce[64]=0;
    return valid_nonce(nonce);
}

static NSString *const kPauseFile=@"auto-reload-paused.plist";
static NSString *const kEndpointPrefix=@"INFINIFY-NATIVE-ENDPOINT ";
NSString *DWDockReloadStateDirectory(void) { return [DWSupportDirectory() stringByAppendingPathComponent:@"native-desktop"]; }
BOOL DWDockReloadPaused(NSString *directory,NSString *payloadSHA256) {
    NSString *path=[directory stringByAppendingPathComponent:kPauseFile];
    struct stat st;
    if(lstat(path.fileSystemRepresentation,&st))return NO;
    // Present but not a pause this user made: it cannot be told from one, so it holds loading back until the owner loads by hand.
    NSDictionary *record=DWOwnerFileReadPlist(path);
    if(!record||![record[@"version"] isEqual:@1]||![record[@"payload_sha256"] isKindOfClass:NSString.class])return YES;
    return [record[@"payload_sha256"] isEqualToString:payloadSHA256];
}
BOOL DWDockReloadPause(NSString *directory,NSString *payloadSHA256,NSString *reason) {
    if(payloadSHA256.length!=64)return NO;
    return DWOwnerFileWritePlist([directory stringByAppendingPathComponent:kPauseFile],
        @{@"version":@1,@"payload_sha256":payloadSHA256,@"paused_at":[NSDate date],@"reason":reason?:@""});
}
BOOL DWDockReloadResume(NSString *directory) { return DWOwnerFileRemove([directory stringByAppendingPathComponent:kPauseFile]); }

BOOL DWDockReloadParseEndpoint(NSString *output,NSString *__autoreleasing *runtime,NSString *__autoreleasing *nonceFile) {
    NSString *line=nil;
    for(NSString *candidate in [output componentsSeparatedByString:@"\n"])if([candidate hasPrefix:kEndpointPrefix])line=candidate;
    if(!line)return NO;
    NSArray<NSString *> *parts=[[line substringFromIndex:kEndpointPrefix.length] componentsSeparatedByString:@" "];
    if(parts.count!=2)return NO;
    NSString *path=parts[0],*nonce=parts[1];
    const char *bytes=path.UTF8String;
    if(!bytes || strlen(bytes)!=path.length || !DWHelperRuntimeSuffix(bytes))return NO;
    if(![nonce isEqualToString:[path stringByAppendingString:@"/nonce"]])return NO;
    if(runtime)*runtime=path;
    if(nonceFile)*nonceFile=nonce;
    return YES;
}


@implementation DWHelperLifecycle {
    id<DWHelperLifecycleEnvironment> _environment;
}
+ (instancetype)systemLifecycle { return [[self alloc] initWithEnvironment:[DWHelperMacEnvironment new]]; }
- (instancetype)initWithEnvironment:(id<DWHelperLifecycleEnvironment>)environment {
    if((self=[super init]))_environment=environment;
    return self;
}
- (BOOL)retiredProcess:(pid_t)pid birthSec:(uint64_t)birthSec birthUsec:(uint64_t)birthUsec {
    struct proc_bsdinfo current={0};
    errno=0;
    int length=[_environment processInfo:pid result:&current];
    if(length==(int)sizeof(current)) {
        if(current.pbi_pid!=(uint32_t)pid || !current.pbi_start_tvsec || current.pbi_start_tvusec>=1000000)return NO;
        return current.pbi_start_tvsec!=birthSec || current.pbi_start_tvusec!=birthUsec;
    }
    if(length!=0 && errno==ESRCH)return YES;
    if(length!=0)return NO;
    if(errno==ESRCH)return YES;
    if([_environment probeProcess:pid]==-1 && errno==ESRCH)return YES;
    return NO;
}
- (BOOL)recoveryJournal:(const char *)sourcePath runtime:(const char *)runtime dock:(const struct proc_bsdinfo *)dock
           expectedPID:(pid_t)expectedPID expectedSec:(uint64_t)expectedSec expectedUsec:(uint64_t)expectedUsec
           sourceBytes:(NSData *__autoreleasing *)sourceBytes recoveryFields:(NSDictionary *__autoreleasing *)recoveryFields {
    if(!sourcePath || sourcePath[0]!='/' || strlen(sourcePath)>=PATH_MAX || !private_runtime_path(runtime))return NO;
    const char *lastSlash=strrchr(sourcePath,'/');
    if(!lastSlash || strcmp(lastSlash+1,"v2-journal.json"))return NO;
    size_t directoryLength=(size_t)(lastSlash-sourcePath);
    if(!directoryLength || directoryLength>=PATH_MAX)return NO;
    char sourceDirectory[PATH_MAX];memcpy(sourceDirectory,sourcePath,directoryLength);sourceDirectory[directoryLength]=0;
    const char *runtimeSuffix=DWHelperRuntimeSuffix(runtime),*sourceSuffix=DWHelperRuntimeSuffix(sourceDirectory);
    if(!runtimeSuffix || !sourceSuffix || !strcmp(sourceSuffix,runtimeSuffix))return NO;
    int sourceFD=open([_environment fileSystemPath:@(sourceDirectory)].fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(sourceFD<0)return NO;
    struct stat directoryStat={0},stageStat={0};
    BOOL ok=fstat(sourceFD,&directoryStat)==0 && S_ISDIR(directoryStat.st_mode)
        && directoryStat.st_uid==dock->pbi_uid && (directoryStat.st_mode&07777)==0700;
    if(ok) {
        if(fstatat(sourceFD,"v2-journal.next",&stageStat,AT_SYMLINK_NOFOLLOW)==0 || errno!=ENOENT)ok=NO;
    }
    int journalFD=ok ? openat(sourceFD,"v2-journal.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK) : -1;
    if(journalFD<0)ok=NO;
    struct stat fileStat={0};
    if(ok)ok=fstat(journalFD,&fileStat)==0 && S_ISREG(fileStat.st_mode) && fileStat.st_uid==dock->pbi_uid
        && (fileStat.st_mode&07777)==0600 && fileStat.st_size>0 && fileStat.st_size<=4*1024*1024;
    NSMutableData *data=ok ? [NSMutableData dataWithLength:(NSUInteger)fileStat.st_size] : nil;
    if(ok) {
        uint8_t *cursor=data.mutableBytes;size_t remaining=(size_t)fileStat.st_size;
        while(remaining) {
            ssize_t count=read(journalFD,cursor,remaining);
            if(count<0 && errno==EINTR)continue;
            if(count<=0){ok=NO;break;}
            cursor+=(size_t)count;remaining-=(size_t)count;
        }
        char extra;
        if(ok) {
            ssize_t count;
            do { count=read(journalFD,&extra,1); } while(count<0 && errno==EINTR);
            if(count!=0)ok=NO;
        }
    }
    if(journalFD>=0)close(journalFD);
    if(sourceFD>=0)close(sourceFD);
    if(!ok)return NO;

    NSDictionary *journal=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if(![journal isKindOfClass:NSDictionary.class])return NO;
    NSArray *keys=@[@"v",@"server_pid",@"server_birth_sec",@"server_birth_usec",@"server_uid",@"boot_uuid",
        @"generation",@"state",@"windows",@"released_windows",@"last_restore"];
    NSArray *windows=journal[@"windows"],*released=journal[@"released_windows"];
    char bootUUID[37];
    if(![_environment bootSessionUUID:bootUUID] || !dw_exact_keys(journal,keys)
        || !json_integer(journal[@"v"],4,4) || !json_integer(journal[@"server_pid"],2,INT_MAX)
        || !json_integer(journal[@"server_birth_sec"],1,UINT64_MAX) || !json_integer(journal[@"server_birth_usec"],0,999999)
        || !json_integer(journal[@"server_uid"],1,UINT32_MAX) || !dw_boot_uuid_valid(journal[@"boot_uuid"])
        || !json_integer(journal[@"generation"],0,UINT64_MAX-1)
        || ![@[@"empty",@"holding",@"restoring"] containsObject:journal[@"state"]]
        || ![windows isKindOfClass:NSArray.class] || ![released isKindOfClass:NSArray.class]
        || windows.count>1024 || released.count>1024 || windows.count+released.count>1024
        || (journal[@"last_restore"]!=NSNull.null && ![journal[@"last_restore"] isKindOfClass:NSDictionary.class]))return NO;
    if([journal[@"server_pid"]intValue]!=expectedPID || [journal[@"server_birth_sec"]unsignedLongLongValue]!=expectedSec
        || [journal[@"server_birth_usec"]unsignedLongLongValue]!=expectedUsec
        || [journal[@"server_uid"]unsignedIntValue]!=dock->pbi_uid
        || ![journal[@"boot_uuid"]isEqual:[NSString stringWithUTF8String:bootUUID]]
        || ![self retiredProcess:expectedPID birthSec:expectedSec birthUsec:expectedUsec])return NO;
    NSString *digest=sha256_hex(data);
    if(!digest)return NO;
    *sourceBytes=data;
    *recoveryFields=@{@"recovery_source_sha256":digest,@"recovery_server_pid":journal[@"server_pid"],
        @"recovery_server_birth_sec":journal[@"server_birth_sec"],@"recovery_server_birth_usec":journal[@"server_birth_usec"],
        @"recovery_server_uid":journal[@"server_uid"],@"recovery_boot_uuid":journal[@"boot_uuid"]};
    return YES;
}
@end
