// SPDX-License-Identifier: GPL-3.0-or-later
// New implementation. The caller requirement has the form Sunlight uses for its launch daemon
// (https://github.com/spacefarm-digital/sunlight, commit afeea74b18e70ca49bf462d6fe462cf65deb2b32, LiveWindows/helper.m
// lines 462-478, `daemonMain`: anchor apple generic, the app's
// identifier, the team's certificate subject OU); the rest is Infinify's own: the argument shapes are the two
// native-desktop-launcher.sh builds for loader-arm64e --inject-dock (less the payload, which the daemon supplies), the
// hardened-runtime caller rules, the staging of the payload and the digests of the loader and payload the build embeds in
// the daemon (native/dock-helper/Daemon/Daemon.m).
#import "DWLoaddRequest.h"
#import "DWStagedPayload.h"
#import <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>

NSString *const DWLoadMachService=@"com.marengox.infinify.loader";
NSString *const DWLoadAppIdentifier=@"com.marengox.infinify";
NSString *const DWLoadDaemonPlist=@"com.marengox.infinify.loader.plist";

static BOOL alnum(unichar c) { return (c>='0'&&c<='9')||(c>='A'&&c<='Z')||(c>='a'&&c<='z'); }
NSString *DWLoadCallerRequirement(NSString *team) {
    // An Apple team identifier is ten characters, capital letters and digits. Nothing else is put in a requirement.
    if(![team isKindOfClass:NSString.class]||team.length!=10)return nil;
    for(NSUInteger i=0;i<10;i++){unichar c=[team characterAtIndex:i];if(!((c>='0'&&c<='9')||(c>='A'&&c<='Z')))return nil;}
    return [NSString stringWithFormat:@"anchor apple generic and identifier \"%@\" and certificate leaf[subject.OU] = \"%@\"",DWLoadAppIdentifier,team];
}

// /tmp/if-native.XXXXXX, the form DWLoader.m's private_runtime_path accepts.
static BOOL runtimePath(NSString *path) {
    static NSString *const prefix=@"/tmp/if-native.";
    if(![path isKindOfClass:NSString.class]||path.length!=prefix.length+6||![path hasPrefix:prefix])return NO;
    for(NSUInteger i=prefix.length;i<path.length;i++)if(!alnum([path characterAtIndex:i]))return NO;
    return YES;
}
// A canonical unsigned decimal in [minimum, maximum]: no sign, no space, no leading zero.
static BOOL canonicalDecimal(NSString *text,unsigned long long minimum,unsigned long long maximum) {
    if(![text isKindOfClass:NSString.class]||!text.length||text.length>20)return NO;
    if(text.length>1&&[text characterAtIndex:0]=='0')return NO;
    for(NSUInteger i=0;i<text.length;i++){unichar c=[text characterAtIndex:i];if(c<'0'||c>'9')return NO;}
    errno=0;unsigned long long value=strtoull(text.UTF8String,NULL,10);
    return errno!=ERANGE&&value>=minimum&&value<=maximum;
}
static BOOL identity(NSArray<NSString *> *arguments,NSUInteger at) {
    return canonicalDecimal(arguments[at],2,INT_MAX)&&canonicalDecimal(arguments[at+1],1,UINT64_MAX)&&canonicalDecimal(arguments[at+2],0,999999);
}

NSString *DWLoadArgumentsRefusal(NSArray<NSString *> *arguments) {
    if(![arguments isKindOfClass:NSArray.class])return @"the load request has no arguments";
    for(id argument in arguments)if(![argument isKindOfClass:NSString.class]||[argument length]>256)return @"a load argument is not a short string";
    if(arguments.count!=8&&arguments.count!=14)return @"the load request is not one of the launcher's two forms";
    NSString *runtime=arguments[0];
    if(!runtimePath(runtime))return @"the runtime is not a private /tmp/if-native.XXXXXX directory";
    if(![arguments[1] isEqualToString:@"--nonce-file"]||![arguments[2] isEqualToString:[runtime stringByAppendingString:@"/nonce"]])return @"the nonce file is not the runtime's nonce";
    if(![arguments[3] isEqualToString:@"--desktop"])return @"only the whole-desktop scope is loaded";
    if(![arguments[4] isEqualToString:@"--expected-dock"]||!identity(arguments,5))return @"the load does not pin an exact Dock process";
    if(arguments.count==8)return nil;
    if(![arguments[8] isEqualToString:@"--recover-journal"]||![arguments[10] isEqualToString:@"--expected-retired-dock"]||!identity(arguments,11))return @"the recovery arguments are not the launcher's";
    NSString *journal=arguments[9];
    if(![journal hasSuffix:@"/v2-journal.json"])return @"the recovery journal is not a v2-journal.json";
    NSString *old=[journal substringToIndex:journal.length-@"/v2-journal.json".length];
    if(!runtimePath(old)||[old isEqualToString:runtime])return @"the recovery journal is not that of a different private runtime";
    return nil;
}

NSString *DWLoadRefusal(NSString *command,NSArray<NSString *> *arguments) {
    if(![command isKindOfClass:NSString.class])return @"no command";
    if([command isEqualToString:@"ping"])return arguments.count?@"ping takes no arguments":nil;
    if([command isEqualToString:@"load"])return DWLoadArgumentsRefusal(arguments);
    return @"the daemon runs only ping and load";
}

NSString *DWLoadFileSHA256(NSString *path,NSUInteger limit,NSData *__autoreleasing *bytes) {
    if(![path isKindOfClass:NSString.class]||!path.length)return nil;
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0)return nil;
    struct stat st;
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_size<=0||(unsigned long long)st.st_size>limit){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];
    uint8_t *cursor=data.mutableBytes;size_t remaining=(size_t)st.st_size;BOOL ok=YES;
    while(remaining){
        ssize_t count=read(fd,cursor,remaining);
        if(count<0&&errno==EINTR)continue;
        if(count<=0){ok=NO;break;}
        cursor+=count;remaining-=(size_t)count;
    }
    char extra;ssize_t more;
    if(ok){do{more=read(fd,&extra,1);}while(more<0&&errno==EINTR);ok=more==0;}
    close(fd);
    if(!ok)return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for(unsigned i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];
    if(bytes)*bytes=data;
    return hex;
}

static BOOL hexDigest(NSString *value) {
    if(![value isKindOfClass:NSString.class]||value.length!=64)return NO;
    for(NSUInteger i=0;i<64;i++){unichar c=[value characterAtIndex:i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return NO;}
    return YES;
}

BOOL DWLoadVerifyArtifacts(NSString *nativeDirectory,NSString *loaderSHA256,NSString *payloadSHA256,NSData *__autoreleasing *loader,NSData *__autoreleasing *payload,NSString *__autoreleasing *why) {
    #define REFUSE(text) do{if(why)*why=(text);return NO;}while(0)
    if(!hexDigest(loaderSHA256)||!hexDigest(payloadSHA256))REFUSE(@"this daemon was built without the loader and payload digests");
    struct stat st;
    if(lstat(nativeDirectory.fileSystemRepresentation,&st)||!S_ISDIR(st.st_mode))REFUSE(@"the daemon's NativeDesktop directory is missing or a symbolic link");
    NSData *loaderBytes=nil,*payloadBytes=nil;
    NSString *loaderDigest=DWLoadFileSHA256([nativeDirectory stringByAppendingPathComponent:@"loader-arm64e"],16u<<20,&loaderBytes);
    if(!loaderDigest||![loaderDigest isEqualToString:loaderSHA256])REFUSE(@"the bundled loader is not the one this daemon was built with");
    // The bundle's payload, read once: these bytes are hashed here and these bytes are what gets staged, so a swap of the
    // bundle's file afterwards changes nothing. The runtime's copy of the payload (the user's) is never read.
    NSString *payloadDigest=DWLoadFileSHA256([nativeDirectory stringByAppendingPathComponent:@"payload-arm64e.dylib"],64u<<20,&payloadBytes);
    if(!payloadDigest||![payloadDigest isEqualToString:payloadSHA256])REFUSE(@"the bundled payload is not the one this daemon was built with");
    if(loader)*loader=loaderBytes;
    if(payload)*payload=payloadBytes;
    #undef REFUSE
    return YES;
}

// MARK: Caller signature

// The raw code-signing status bits (xnu's kern/cs_blobs.h) that the public kSecCodeStatus constants leave out.
enum { DWCodeSigningGetTaskAllow=0x00000004, DWCodeSigningRuntime=0x00010000 };

NSString *DWLoadCallerFlagsRefusal(uint32_t signatureFlags,uint32_t processStatus,NSDictionary *entitlements) {
    if(!(signatureFlags&kSecCodeSignatureRuntime))return @"the caller's signature does not carry the hardened-runtime flag";
    if(!(processStatus&DWCodeSigningRuntime))return @"the caller's process is not running with the hardened runtime";
    if(processStatus&DWCodeSigningGetTaskAllow)return @"the caller's process can be debugged and injected into (get-task-allow)";
    if(entitlements&&![entitlements isKindOfClass:NSDictionary.class])return @"the caller's entitlements are unreadable";
    for(NSString *key in @[@"com.apple.security.get-task-allow",@"com.apple.security.cs.allow-dyld-environment-variables",@"com.apple.security.cs.disable-library-validation"]){
        id value=entitlements[key];
        // Any value but an explicit false counts: an entitlement that weakens the hardened runtime is not to be argued with.
        if(value&&!([value isKindOfClass:NSNumber.class]&&![value boolValue]))return [NSString stringWithFormat:@"the caller holds %@, which lets other code run inside it",key];
    }
    return nil;
}

NSString *DWLoadCallerEnvironmentRefusal(NSArray<NSString *> *environment) {
    if(![environment isKindOfClass:NSArray.class])return @"the caller's environment could not be read";
    for(id entry in environment){
        if(![entry isKindOfClass:NSString.class])return @"the caller's environment could not be read";
        if([entry hasPrefix:@"DYLD_"]||[entry hasPrefix:@"__XPC_DYLD_"])return [NSString stringWithFormat:@"the caller was started with %@, which can load code into it",[entry componentsSeparatedByString:@"="].firstObject];
    }
    return nil;
}

// KERN_PROCARGS2: int argc, the executable path, padding NULs, argc argument strings, then the environment strings up to the first empty one.
NSArray<NSString *> *DWLoadProcessEnvironment(pid_t pid) {
    int mib[3]={CTL_KERN,KERN_PROCARGS2,pid};
    size_t size=0;
    if(pid<=1||sysctl(mib,3,NULL,&size,NULL,0)||size<sizeof(int)+2||size>4u<<20)return nil;
    NSMutableData *data=[NSMutableData dataWithLength:size];
    if(sysctl(mib,3,data.mutableBytes,&size,NULL,0)||size<sizeof(int)+2)return nil;
    const char *base=data.bytes,*end=base+size,*cursor=base+sizeof(int);
    int argc;memcpy(&argc,base,sizeof(argc));
    if(argc<0||argc>4096)return nil;
    while(cursor<end&&*cursor)cursor++;                    // the executable path
    while(cursor<end&&!*cursor)cursor++;                   // padding
    for(int i=0;i<argc;i++){while(cursor<end&&*cursor)cursor++;if(cursor>=end)return nil;cursor++;}
    NSMutableArray<NSString *> *environment=[NSMutableArray array];
    while(cursor<end&&*cursor){
        const char *start=cursor;
        while(cursor<end&&*cursor)cursor++;
        if(cursor>=end)return nil;
        NSString *entry=[[NSString alloc]initWithBytes:start length:(NSUInteger)(cursor-start) encoding:NSUTF8StringEncoding];
        [environment addObject:entry?:@"?"];
        cursor++;
    }
    return environment;
}

NSString *DWLoadCallerRefusal(audit_token_t token) {
    NSData *tokenData=[NSData dataWithBytes:&token length:sizeof(token)];
    SecCodeRef code=NULL;CFDictionaryRef info=NULL;NSString *refusal=nil;
    if(SecCodeCopyGuestWithAttributes(NULL,(__bridge CFDictionaryRef)@{(__bridge NSString *)kSecGuestAttributeAudit:tokenData},kSecCSDefaultFlags,&code)!=errSecSuccess||!code)refusal=@"the caller's code could not be identified";
    else if(SecCodeCopySigningInformation(code,kSecCSSigningInformation|kSecCSDynamicInformation,&info)!=errSecSuccess||!info)refusal=@"the caller's signature could not be read";
    else{
        NSDictionary *dictionary=(__bridge NSDictionary *)info;
        NSNumber *flags=dictionary[(__bridge NSString *)kSecCodeInfoFlags],*status=dictionary[(__bridge NSString *)kSecCodeInfoStatus];
        if(![flags isKindOfClass:NSNumber.class]||![status isKindOfClass:NSNumber.class])refusal=@"the caller's signature flags could not be read";
        else refusal=DWLoadCallerFlagsRefusal(flags.unsignedIntValue,status.unsignedIntValue,dictionary[(__bridge NSString *)kSecCodeInfoEntitlementsDict]);
        // The process's pid is val[5] of its audit token. Read by pid, so a pid reused between the token and the read could be
        // judged by another process's environment: the signature checks above are by the token itself.
        if(!refusal)refusal=DWLoadCallerEnvironmentRefusal(DWLoadProcessEnvironment((pid_t)token.val[5]));
    }
    if(info)CFRelease(info);
    if(code)CFRelease(code);
    return refusal;
}

// MARK: Staged payload

NSString *const DWLoadStagedRoot=@DW_STAGED_ROOT;

NSString *DWLoadStagedDirectory(NSString *root,NSString *runtime) {
    if(![root isKindOfClass:NSString.class]||!runtimePath(runtime))return nil;
    return [NSString stringWithFormat:@"%@/%s%@",root,DW_STAGED_PREFIX,[runtime substringFromIndex:runtime.length-DW_STAGED_SUFFIX_LENGTH]];
}
NSString *DWLoadStagedPayloadPath(NSString *root,NSString *runtime) {
    NSString *directory=DWLoadStagedDirectory(root,runtime);
    return directory?[directory stringByAppendingString:@"/" DW_STAGED_NAME]:nil;
}

static BOOL writeAll(int fd,const void *bytes,size_t length) {
    const uint8_t *cursor=bytes;
    while(length){
        ssize_t count=write(fd,cursor,length);
        if(count<0&&errno==EINTR)continue;
        if(count<=0)return NO;
        cursor+=count;length-=(size_t)count;
    }
    return YES;
}

BOOL DWLoadStagePayload(NSString *root,NSString *runtime,NSData *payload,NSString *payloadSHA256,uid_t trusted,uid_t login,NSString *__autoreleasing *path,NSString *__autoreleasing *why) {
    #define REFUSE(text) do{if(why)*why=(text);return NO;}while(0)
    NSString *directory=DWLoadStagedDirectory(root,runtime),*target=DWLoadStagedPayloadPath(root,runtime);
    if(!directory||![payload isKindOfClass:NSData.class]||!payload.length||!hexDigest(payloadSHA256))REFUSE(@"nothing to stage, or no runtime to stage it for");
    // The new directory and file are made by this process, so they belong to whoever it is: root in the daemon.
    if(geteuid()!=trusted)REFUSE(@"the staged payload would belong to someone other than its trusted owner");
    if(mkdir(directory.fileSystemRepresentation,0700))REFUSE(errno==EEXIST?@"a payload is already staged for this runtime":@"couldn't make the staged payload directory");
    int dirFD=open(directory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    NSString *failure=nil;
    // Written inside a directory only this process can enter (0700), read back, and only then opened to the Dock.
    int fd=dirFD>=0?openat(dirFD,DW_STAGED_NAME,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600):-1;
    if(fd<0)failure=@"couldn't create the staged payload";
    else{
        BOOL wrote=writeAll(fd,payload.bytes,payload.length)&&fsync(fd)==0&&fchmod(fd,0644)==0;
        if(close(fd)||!wrote)failure=@"couldn't write the staged payload";
    }
    if(!failure&&![(DWLoadFileSHA256(target,64u<<20,NULL)?:@"") isEqualToString:payloadSHA256])failure=@"the staged payload does not read back as the checked bytes";
    if(!failure&&(fchmod(dirFD,0755)||fsync(dirFD)))failure=@"couldn't open the staged payload directory to the Dock";
    if(!failure){const char *rule=dw_staged_payload_refusal(target.fileSystemRepresentation,root.fileSystemRepresentation,trusted,login);if(rule)failure=[NSString stringWithFormat:@"the staged payload fails the staged-payload rule: %s",rule];}
    if(failure){
        if(dirFD>=0)unlinkat(dirFD,DW_STAGED_NAME,0);
        rmdir(directory.fileSystemRepresentation);
        if(dirFD>=0)close(dirFD);
        REFUSE(failure);
    }
    close(dirFD);
    if(path)*path=target;
    #undef REFUSE
    return YES;
}

NSString *DWLoadStagedPayloadDigest(NSString *root,NSString *runtime,uid_t trusted,uid_t login,NSString *__autoreleasing *directory,NSString *__autoreleasing *why) {
    NSString *target=DWLoadStagedPayloadPath(root,runtime);
    if(!target){if(why)*why=@"not a private runtime";return nil;}
    const char *rule=dw_staged_payload_refusal(target.fileSystemRepresentation,root.fileSystemRepresentation,trusted,login);
    if(rule){if(why)*why=@(rule);return nil;}
    NSString *digest=DWLoadFileSHA256(target,64u<<20,NULL);
    if(!digest){if(why)*why=@"the staged payload cannot be read";return nil;}
    if(directory)*directory=DWLoadStagedDirectory(root,runtime);
    return digest;
}

NSUInteger DWLoadPruneStaged(NSString *root,NSString *keepRuntime,uid_t trusted,uid_t login) {
    NSString *keep=DWLoadStagedDirectory(root,keepRuntime).lastPathComponent;
    DIR *directory=opendir(root.fileSystemRepresentation);
    if(!directory)return 0;
    NSMutableArray<NSString *> *names=[NSMutableArray array];
    size_t prefix=strlen(DW_STAGED_PREFIX);
    for(struct dirent *entry;(entry=readdir(directory));){
        if(entry->d_namlen!=prefix+DW_STAGED_SUFFIX_LENGTH||strncmp(entry->d_name,DW_STAGED_PREFIX,prefix))continue;
        BOOL exact=YES;
        for(size_t i=prefix;i<entry->d_namlen;i++)if(!alnum((unichar)entry->d_name[i]))exact=NO;
        NSString *name=@(entry->d_name);
        if(exact&&![name isEqualToString:keep])[names addObject:name];
    }
    closedir(directory);
    NSUInteger removed=0;
    for(NSString *name in names){
        NSString *path=[root stringByAppendingPathComponent:name];
        struct stat st;
        if(lstat(path.fileSystemRepresentation,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=trusted||(st.st_mode&0022))continue;
        int fd=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(fd<0)continue;
        // Another user's load (fast user switching) has a sidecar of that user's: its Dock may still hold the payload.
        struct stat sidecar;
        if(fstatat(fd,DW_STAGED_NAME ".json",&sidecar,AT_SYMLINK_NOFOLLOW)==0&&sidecar.st_uid!=login){close(fd);continue;}
        unlinkat(fd,DW_STAGED_NAME,0);
        unlinkat(fd,DW_STAGED_NAME ".json",0);
        close(fd);
        if(rmdir(path.fileSystemRepresentation)==0)removed++;
    }
    return removed;
}
