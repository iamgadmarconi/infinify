// SPDX-License-Identifier: GPL-3.0-or-later
// The launch daemon's decisions, as plain functions: which XPC callers it names, which requests it will run, and which files
// it takes as the loader and payload. No root process, XPC connection, Dock or window is involved; this is not evidence that the
// daemon loads the payload (that is the guest run recorded in native/privileged/README.md).
//   argv[1] (optional): an Infinify.app signed with a team identity, to check the caller requirement against a real signature.
#import "loadd-request.h"
#import <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <unistd.h>
#include <limits.h>
#include <mach/mach.h>
#import "staged-payload.h"

static int failures=0,checks=0;
#define CHECK(condition,...) do{checks++;if(!(condition)){failures++;fprintf(stderr,"FAIL line %d: %s -- ",__LINE__,#condition);fprintf(stderr,__VA_ARGS__);fputc('\n',stderr);}}while(0)

static NSString *sha256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString string];for(unsigned i=0;i<sizeof(digest);i++)[hex appendFormat:@"%02x",digest[i]];return hex;
}
static NSArray<NSString *> *fresh(NSString *runtime) {
    return @[runtime,@"--nonce-file",[runtime stringByAppendingString:@"/nonce"],@"--desktop",@"--expected-dock",@"612",@"1790000000",@"123456"];
}
static NSArray<NSString *> *recovery(NSString *runtime,NSString *old) {
    return [fresh(runtime) arrayByAddingObjectsFromArray:@[@"--recover-journal",[old stringByAppendingString:@"/v2-journal.json"],@"--expected-retired-dock",@"590",@"1789999000",@"7"]];
}
static NSArray<NSString *> *replace(NSArray<NSString *> *base,NSUInteger index,NSString *value) {
    NSMutableArray *copy=[base mutableCopy];copy[index]=value;return copy;
}
static void refused(NSString *label,NSArray<NSString *> *arguments) {
    CHECK(DWLoadArgumentsRefusal(arguments)!=nil,"%s was accepted",label.UTF8String);
}

static void callerRequirement(const char *signedApp) {
    NSString *requirement=DWLoadCallerRequirement(@"PBKWRHQV74");
    CHECK([requirement isEqualToString:@"anchor apple generic and identifier \"com.marengox.infinify\" and certificate leaf[subject.OU] = \"PBKWRHQV74\""],"requirement text: %s",requirement.UTF8String);
    for(NSString *team in @[@"",@"PBKWRHQV7",@"PBKWRHQV740",@"pbkwrhqv74",@"PBKWRHQV7\"",@"AAAAAAAAAA\" or true or \"",@"PBKWRH QV7"])
        CHECK(DWLoadCallerRequirement(team)==nil,"team %s produced a requirement",team.UTF8String);
    CHECK(DWLoadCallerRequirement(nil)==nil,"no team produced a requirement");
    // The requirement is valid requirement language, and a process signed only ad hoc (this one) does not meet it.
    SecRequirementRef parsed=NULL;
    CHECK(SecRequirementCreateWithString((__bridge CFStringRef)requirement,kSecCSDefaultFlags,&parsed)==errSecSuccess&&parsed,"requirement does not parse");
    SecCodeRef self=NULL;
    CHECK(SecCodeCopySelf(kSecCSDefaultFlags,&self)==errSecSuccess,"no self code");
    if(parsed&&self)CHECK(SecCodeCheckValidity(self,kSecCSDefaultFlags,parsed)!=errSecSuccess,"an ad-hoc process met the caller requirement");
    if(self)CFRelease(self);
    if(parsed)CFRelease(parsed);
    if(!signedApp)return;
    // A team-signed Infinify.app meets the requirement for its own team and not for another one.
    SecStaticCodeRef app=NULL;CFDictionaryRef info=NULL;
    CHECK(SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:@(signedApp)],kSecCSDefaultFlags,&app)==errSecSuccess,"cannot read %s",signedApp);
    CHECK(app&&SecCodeCopySigningInformation(app,kSecCSSigningInformation,&info)==errSecSuccess,"no signing information");
    NSString *team=info?((__bridge NSDictionary *)info)[(__bridge NSString *)kSecCodeInfoTeamIdentifier]:nil;
    CHECK(team.length==10,"the app has no team identifier (ad hoc?)");
    if(team.length==10){
        for(int other=0;other<2;other++){
            NSString *text=DWLoadCallerRequirement(other?@"AAAAAAAAAA":team);SecRequirementRef r=NULL;
            CHECK(SecRequirementCreateWithString((__bridge CFStringRef)text,kSecCSDefaultFlags,&r)==errSecSuccess,"parse");
            OSStatus result=r?SecStaticCodeCheckValidity(app,kSecCSDefaultFlags,r):-1;
            CHECK(other?result!=errSecSuccess:result==errSecSuccess,"%s team: status %d",other?"another":"the app's own",(int)result);
            if(r)CFRelease(r);
        }
    }
    if(info)CFRelease(info);
    if(app)CFRelease(app);
}

static void requests(void) {
    NSString *runtime=@"/tmp/if-native.AbC123",*old=@"/tmp/if-native.Zz9y8x";
    CHECK(DWLoadArgumentsRefusal(fresh(runtime))==nil,"the launcher's fresh form was refused: %s",DWLoadArgumentsRefusal(fresh(runtime)).UTF8String);
    CHECK(DWLoadArgumentsRefusal(recovery(runtime,old))==nil,"the launcher's recovery form was refused: %s",DWLoadArgumentsRefusal(recovery(runtime,old)).UTF8String);
    CHECK(DWLoadRefusal(@"ping",@[])==nil,"ping refused");
    CHECK(DWLoadRefusal(@"ping",@[@"x"])!=nil,"ping with an argument accepted");
    CHECK(DWLoadRefusal(@"load",fresh(runtime))==nil,"load refused");
    for(NSString *command in @[@"unload",@"bootarg",@"status",@"",@"load ",@"LOAD",@"sh"])CHECK(DWLoadRefusal(command,@[])!=nil,"command %s accepted",command.UTF8String);
    CHECK(DWLoadRefusal(nil,@[])!=nil,"no command accepted");
    // The wrong shapes: not the launcher's, so not run.
    refused(@"no arguments",@[]);
    refused(@"nil",(NSArray *)nil);
    refused(@"a fresh form without the Dock pin",[fresh(runtime) subarrayWithRange:NSMakeRange(0,4)]);
    // The payload is the daemon's to name: a request that names one (the form before this change) is not the launcher's.
    refused(@"the old form with the runtime's payload first",[@[[runtime stringByAppendingString:@"/payload-arm64e.dylib"]] arrayByAddingObjectsFromArray:fresh(runtime)]);
    refused(@"the old form with a payload elsewhere first",[@[@"/tmp/evil.dylib"] arrayByAddingObjectsFromArray:fresh(runtime)]);
    refused(@"a payload flag",[fresh(runtime) arrayByAddingObjectsFromArray:@[@"--payload",@"/tmp/evil.dylib"]]);
    refused(@"one argument more",[fresh(runtime) arrayByAddingObject:@"--extra"]);
    refused(@"a recovery form cut short",[recovery(runtime,old) subarrayWithRange:NSMakeRange(0,13)]);
    refused(@"--only-pid in place of --desktop",replace(fresh(runtime),3,@"--only-pid"));
    refused(@"the Dock pin renamed",replace(fresh(runtime),4,@"--expected-dack"));
    refused(@"the nonce flag renamed",replace(fresh(runtime),1,@"--nonce"));
    // Paths: every one must be the runtime's own, in the form the loader accepts.
    for(NSString *bad in @[@"/tmp/if-native.AbC12",@"/tmp/if-native.AbC1234",@"/tmp/if-native.AbC12!",@"/tmp/if-native.AbC12/",@"/tmp/if-native.",@"/tmp/other.AbC123",@"/private/tmp/if-native.AbC123",@"/tmp/if-native.AbC123/../if-native.AbC123",@"tmp/if-native.AbC123",@"/Users/me/if-native.AbC123",@"/tmp/if-native.AbC 23"])
        refused([NSString stringWithFormat:@"runtime %@",bad],fresh(bad));
    refused(@"a payload in place of the runtime",replace(fresh(runtime),0,@"/tmp/if-native.AbC123/payload-arm64e.dylib"));
    refused(@"a nonce elsewhere",replace(fresh(runtime),2,@"/Users/me/nonce"));
    refused(@"a nonce of another runtime",replace(fresh(runtime),2,@"/tmp/if-native.Zz9y8x/nonce"));
    // The pinned identities are canonical numbers in range.
    NSArray *bases=@[fresh(runtime),recovery(runtime,old)];
    for(NSArray *base in bases){
        NSUInteger first=5,second=base.count>8?11:5;
        for(NSNumber *at in @[@(first),@(second)]){
            NSUInteger i=at.unsignedIntegerValue;
            for(NSString *bad in @[@"",@"0",@"1",@"-5",@"+612",@"612 ",@" 612",@"0612",@"6e2",@"0x264",@"2147483648",@"99999999999999999999",@"612;rm"])
                refused([NSString stringWithFormat:@"pid %@ at %lu",bad,(unsigned long)i],replace(base,i,bad));
            for(NSString *bad in @[@"",@"0",@"-1",@"01",@"18446744073709551616",@"x"])
                refused([NSString stringWithFormat:@"seconds %@ at %lu",bad,(unsigned long)i],replace(base,i+1,bad));
            for(NSString *bad in @[@"",@"1000000",@"-1",@"00",@"1.5"])
                refused([NSString stringWithFormat:@"microseconds %@ at %lu",bad,(unsigned long)i],replace(base,i+2,bad));
        }
    }
    CHECK(DWLoadArgumentsRefusal(replace(fresh(runtime),6,@"18446744073709551615"))==nil,"the largest seconds value was refused");
    CHECK(DWLoadArgumentsRefusal(replace(fresh(runtime),7,@"0"))==nil,"microseconds 0 was refused");
    CHECK(DWLoadArgumentsRefusal(replace(fresh(runtime),5,@"2147483647"))==nil,"the largest pid was refused");
    // Recovery: the journal is the v2-journal.json of a different private runtime.
    refused(@"a journal of the runtime itself",recovery(runtime,runtime));
    refused(@"a journal elsewhere",replace(recovery(runtime,old),9,@"/Users/me/v2-journal.json"));
    refused(@"a journal of another name",replace(recovery(runtime,old),9,@"/tmp/if-native.Zz9y8x/v2-journal.next"));
    refused(@"a journal one directory down",replace(recovery(runtime,old),9,@"/tmp/if-native.Zz9y8x/sub/v2-journal.json"));
    refused(@"the retired flag renamed",replace(recovery(runtime,old),10,@"--expected-dock"));
    refused(@"the recovery flag renamed",replace(recovery(runtime,old),8,@"--recover"));
    // Elements that are not short strings.
    refused(@"a number for an argument",(NSArray *)replace(fresh(runtime),5,(NSString *)@5));
    refused(@"a very long argument",replace(fresh(runtime),2,[@"/tmp/if-native.AbC123/" stringByAppendingString:[@"" stringByPaddingToLength:300 withString:@"n" startingAtIndex:0]]));
}

static BOOL putFile(NSString *path,NSData *data,mode_t mode) {
    if(![data writeToFile:path atomically:NO])return NO;
    return chmod(path.fileSystemRepresentation,mode)==0;
}
static NSString *scratch(NSString *name) {
    // The real path: nothing the staged-payload rule walks may be a link, and /var/folders sits behind /var -> private/var.
    char resolved[PATH_MAX];   // realpath: stringByResolvingSymlinksInPath folds /private/var back to /var, a link
    NSString *base=realpath(NSTemporaryDirectory().fileSystemRepresentation,resolved)?@(resolved):NSTemporaryDirectory();
    NSString *root=[base stringByAppendingPathComponent:[NSString stringWithFormat:@"loadd-regression-%@-%d",name,getpid()]];
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    return root;
}
static void artifacts(void) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *root=scratch(@"artifacts");
    NSString *native=[root stringByAppendingPathComponent:@"Infinify.app/Contents/Resources/NativeDesktop"];
    [fm createDirectoryAtPath:native withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *loader=[@"the loader bytes" dataUsingEncoding:NSUTF8StringEncoding],*payload=[@"the payload bytes" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *loaderPath=[native stringByAppendingPathComponent:@"loader-arm64e"],*payloadPath=[native stringByAppendingPathComponent:@"payload-arm64e.dylib"];
    putFile(loaderPath,loader,0755);putFile(payloadPath,payload,0755);
    NSString *loaderDigest=sha256(loader),*payloadDigest=sha256(payload);
    CHECK([DWLoadFileSHA256(loaderPath,1024,NULL) isEqualToString:loaderDigest],"file digest");
    CHECK(DWLoadFileSHA256(loaderPath,4,NULL)==nil,"a file over the limit was read");
    CHECK(DWLoadFileSHA256([root stringByAppendingPathComponent:@"absent"],1024,NULL)==nil,"an absent file has a digest");
    NSData *gotLoader=nil,*gotPayload=nil;NSString *why=nil;
    BOOL ok=DWLoadVerifyArtifacts(native,loaderDigest,payloadDigest,&gotLoader,&gotPayload,&why);
    CHECK(ok&&[gotLoader isEqualToData:loader]&&[gotPayload isEqualToData:payload],"the matching loader and payload were refused: %s",why.UTF8String);
    // The bytes of the files the daemon read are what it hands back: either swapped afterwards is not what it checked.
    putFile(loaderPath,[@"swapped" dataUsingEncoding:NSUTF8StringEncoding],0755);
    CHECK(!DWLoadVerifyArtifacts(native,loaderDigest,payloadDigest,&gotLoader,&gotPayload,&why),"a swapped loader was accepted");
    putFile(loaderPath,loader,0755);
    putFile(payloadPath,[@"swapped" dataUsingEncoding:NSUTF8StringEncoding],0755);
    CHECK(!DWLoadVerifyArtifacts(native,loaderDigest,payloadDigest,&gotLoader,&gotPayload,&why),"a swapped bundle payload was accepted");
    putFile(payloadPath,payload,0755);
    // Links: neither file may be reached through one.
    NSString *real=[native stringByAppendingPathComponent:@"real-payload"];
    rename(payloadPath.fileSystemRepresentation,real.fileSystemRepresentation);symlink(real.fileSystemRepresentation,payloadPath.fileSystemRepresentation);
    CHECK(!DWLoadVerifyArtifacts(native,loaderDigest,payloadDigest,&gotLoader,&gotPayload,&why),"a payload symlink was followed");
    unlink(payloadPath.fileSystemRepresentation);rename(real.fileSystemRepresentation,payloadPath.fileSystemRepresentation);
    NSString *realLoader=[native stringByAppendingPathComponent:@"real-loader"];
    rename(loaderPath.fileSystemRepresentation,realLoader.fileSystemRepresentation);symlink(realLoader.fileSystemRepresentation,loaderPath.fileSystemRepresentation);
    CHECK(!DWLoadVerifyArtifacts(native,loaderDigest,payloadDigest,&gotLoader,&gotPayload,&why),"a loader symlink was followed");
    unlink(loaderPath.fileSystemRepresentation);rename(realLoader.fileSystemRepresentation,loaderPath.fileSystemRepresentation);
    NSString *linkedNative=[root stringByAppendingPathComponent:@"linked"];
    symlink(native.fileSystemRepresentation,linkedNative.fileSystemRepresentation);
    CHECK(!DWLoadVerifyArtifacts(linkedNative,loaderDigest,payloadDigest,&gotLoader,&gotPayload,&why),"a NativeDesktop symlink was followed");
    // A daemon built without the digests, or with malformed ones, loads nothing.
    CHECK(!DWLoadVerifyArtifacts(native,@"",payloadDigest,&gotLoader,&gotPayload,&why),"an empty loader digest was accepted");
    CHECK(!DWLoadVerifyArtifacts(native,loaderDigest,@"",&gotLoader,&gotPayload,&why),"an empty payload digest was accepted");
    CHECK(!DWLoadVerifyArtifacts(native,[loaderDigest uppercaseString],payloadDigest,&gotLoader,&gotPayload,&why),"an uppercase digest was accepted");
    [fm removeItemAtPath:root error:nil];
}

// The place the Dock opens the payload from (staged-payload.h): created by the daemon's code, checked by the loader's rule. The
// regression runs as an ordinary user, so the "trusted owner" is itself and ROOT a directory of its own; what the rule says of
// root and of the real /private/var/run is checked below with the trusted owner set to someone else.
static NSString *stagedPath(NSString *root,NSString *runtime) { return DWLoadStagedPayloadPath(root,runtime); }
static void stagedPayload(void) {
    NSFileManager *fm=NSFileManager.defaultManager;
    uid_t me=getuid();
    NSString *root=scratch(@"staged");
    NSString *runtime=@"/tmp/if-native.AbC123",*other=@"/tmp/if-native.Zz9y8x";
    NSData *payload=[@"the payload bytes" dataUsingEncoding:NSUTF8StringEncoding];NSString *digest=sha256(payload),*why=nil,*path=nil,*directory=nil;
    // Names: derived from the runtime's six characters, in the exact form the loader accepts, and only for a runtime of that form.
    CHECK([DWLoadStagedDirectory(root,runtime) isEqualToString:[root stringByAppendingString:@"/infinify-payload.AbC123"]],"staged directory name");
    CHECK([stagedPath(root,runtime) isEqualToString:[root stringByAppendingString:@"/infinify-payload.AbC123/payload-arm64e.dylib"]],"staged payload name");
    CHECK([DWLoadStagedDirectory(@"/private/var/run",runtime) isEqualToString:@"/private/var/run/infinify-payload.AbC123"],"the production root");
    CHECK([DWLoadStagedRoot isEqualToString:@"/private/var/run"],"the production root is not a link-free real path");
    for(NSString *bad in @[@"/tmp/if-native.AbC12",@"/tmp/if-native.AbC123/../x",@"/tmp/other.AbC123",@"/tmp/if-native.AbC12!",@""])
        CHECK(DWLoadStagedDirectory(root,bad)==nil,"a staged directory for %s",bad.UTF8String);
    // Staging: the bytes land in a directory the rule accepts, 0755, with a 0644 file of the staging user's.
    CHECK(DWLoadStagePayload(root,runtime,payload,digest,me,me,&path,&why),"staging failed: %s",why.UTF8String);
    CHECK([path isEqualToString:stagedPath(root,runtime)],"staged path %s",path.UTF8String);
    struct stat st;
    CHECK(lstat([DWLoadStagedDirectory(root,runtime) fileSystemRepresentation],&st)==0&&S_ISDIR(st.st_mode)&&(st.st_mode&07777)==0755&&st.st_uid==me,"the staged directory is not 0755 and the stager's");
    CHECK(lstat(path.fileSystemRepresentation,&st)==0&&S_ISREG(st.st_mode)&&(st.st_mode&07777)==0644&&st.st_uid==me&&st.st_nlink==1,"the staged file is not a 0644 regular file of the stager's");
    CHECK([DWLoadFileSHA256(path,1024,NULL) isEqualToString:digest],"the staged copy does not hash to the payload");
    CHECK(dw_staged_payload_refusal(path.fileSystemRepresentation,root.fileSystemRepresentation,me,me)==NULL,"the rule refuses what staging made: %s",dw_staged_payload_refusal(path.fileSystemRepresentation,root.fileSystemRepresentation,me,me));
    CHECK([DWLoadStagedPayloadDigest(root,runtime,me,me,&directory,&why) isEqualToString:digest]&&[directory isEqualToString:DWLoadStagedDirectory(root,runtime)],"the read-only report: %s",why.UTF8String);
    // Never into an existing directory, never with wrong bytes, nothing left behind.
    CHECK(!DWLoadStagePayload(root,runtime,payload,digest,me,me,&path,&why),"staging into an existing directory succeeded");
    CHECK(!DWLoadStagePayload(root,other,payload,sha256([@"other" dataUsingEncoding:NSUTF8StringEncoding]),me,me,&path,&why),"staging bytes that do not match the digest succeeded");
    CHECK(access([DWLoadStagedDirectory(root,other) fileSystemRepresentation],F_OK)!=0,"a failed staging left a directory");
    CHECK(!DWLoadStagePayload(root,other,payload,digest,me+1,me,&path,&why),"staging for a trusted owner other than the stager succeeded");
    CHECK(!DWLoadStagePayload(root,other,[NSData data],digest,me,me,&path,&why),"staging nothing succeeded");
    CHECK(!DWLoadStagePayload(root,@"/tmp/not-a-runtime",payload,digest,me,me,&path,&why),"staging for a bad runtime succeeded");
    // The rule, one mutation at a time. Every refusal must name something about the path or its owners.
    NSString *dir=DWLoadStagedDirectory(root,runtime),*file=stagedPath(root,runtime);
    #define RULE(label,expectRefused) do{const char *r=dw_staged_payload_refusal(file.fileSystemRepresentation,root.fileSystemRepresentation,me,me);CHECK((r!=NULL)==(expectRefused),"%s: %s",label,r?r:"accepted");}while(0)
    RULE("the staged payload",NO);
    // Written by the user after the fact: the file or the directory group-writable or world-writable is not root's.
    chmod(file.fileSystemRepresentation,0664);RULE("a group-writable payload",YES);
    chmod(file.fileSystemRepresentation,0646);RULE("a world-writable payload",YES);
    chmod(file.fileSystemRepresentation,04644);RULE("a setuid payload",YES);
    chmod(file.fileSystemRepresentation,0644);RULE("the payload restored",NO);
    chmod(dir.fileSystemRepresentation,0775);RULE("a group-writable staged directory",YES);
    chmod(dir.fileSystemRepresentation,0757);RULE("a world-writable staged directory",YES);
    chmod(dir.fileSystemRepresentation,01777);RULE("a sticky world-writable staged directory",YES);
    chmod(dir.fileSystemRepresentation,0755);RULE("the directory restored",NO);
    // A trusted owner that is not the file's owner (as root is not the login user): refused, whoever the chain belongs to.
    {const char *r=dw_staged_payload_refusal(file.fileSystemRepresentation,root.fileSystemRepresentation,me+1,me);CHECK(r!=NULL,"a payload of the login user passed as if root's");}
    // The chain above: a directory the user writes is the user's to swap. With the trusted owner someone else, the user's scratch
    // directories above the staged one are refused, which is the situation of a staged payload below the user's own directory.
    // (They are owned by the user, who is neither root nor the trusted owner then.)
    // A hard link, a symbolic link in place of the file or of the directory, the wrong name, a path off the form.
    NSString *hard=[root stringByAppendingPathComponent:@"hardlink"];
    link(file.fileSystemRepresentation,hard.fileSystemRepresentation);RULE("a payload with a second link",YES);
    unlink(hard.fileSystemRepresentation);RULE("the second link removed",NO);
    NSString *moved=[dir stringByAppendingString:@"/payload-moved"];
    rename(file.fileSystemRepresentation,moved.fileSystemRepresentation);symlink(moved.fileSystemRepresentation,file.fileSystemRepresentation);RULE("a symlink in place of the payload",YES);
    unlink(file.fileSystemRepresentation);rename(moved.fileSystemRepresentation,file.fileSystemRepresentation);RULE("the payload back",NO);
    NSString *realDir=[root stringByAppendingPathComponent:@"real-staged"];
    rename(dir.fileSystemRepresentation,realDir.fileSystemRepresentation);symlink(realDir.fileSystemRepresentation,dir.fileSystemRepresentation);RULE("a symlink in place of the staged directory",YES);
    unlink(dir.fileSystemRepresentation);rename(realDir.fileSystemRepresentation,dir.fileSystemRepresentation);RULE("the directory back",NO);
    NSString *linkedRoot=[scratch(@"staged-link") stringByAppendingPathComponent:@"root-link"];
    symlink(root.fileSystemRepresentation,linkedRoot.fileSystemRepresentation);
    {NSString *throughLink=[linkedRoot stringByAppendingString:@"/infinify-payload.AbC123/payload-arm64e.dylib"];
     const char *r=dw_staged_payload_refusal(throughLink.fileSystemRepresentation,linkedRoot.fileSystemRepresentation,me,me);CHECK(r!=NULL,"a payload below a symlinked root was accepted");}
    for(NSString *off in @[@"/tmp/payload-arm64e.dylib",@"relative/infinify-payload.AbC123/payload-arm64e.dylib",
                           [root stringByAppendingString:@"/infinify-payload.AbC12/payload-arm64e.dylib"],
                           [root stringByAppendingString:@"/infinify-payload.AbC1234/payload-arm64e.dylib"],
                           [root stringByAppendingString:@"/infinify-payload.AbC12!/payload-arm64e.dylib"],
                           [root stringByAppendingString:@"/other-payload.AbC123/payload-arm64e.dylib"],
                           [root stringByAppendingString:@"/infinify-payload.AbC123/payload-arm64.dylib"],
                           [root stringByAppendingString:@"/infinify-payload.AbC123/payload-arm64e.dylib/x"],
                           [root stringByAppendingString:@"/infinify-payload.AbC123/../infinify-payload.AbC123/payload-arm64e.dylib"],
                           [root stringByAppendingString:@"/x/infinify-payload.AbC123/payload-arm64e.dylib"]])
        CHECK(dw_staged_payload_refusal(off.fileSystemRepresentation,root.fileSystemRepresentation,me,me)!=NULL,"the path %s was accepted",off.UTF8String);
    CHECK(dw_staged_payload_refusal(NULL,root.fileSystemRepresentation,me,me)!=NULL,"a null path was accepted");
    // A file that is missing, a directory that is missing.
    unlink(file.fileSystemRepresentation);RULE("a missing payload",YES);
    rmdir(dir.fileSystemRepresentation);RULE("a missing staged directory",YES);
    // The real system: the production root is the chain the daemon stages below. As an ordinary user the check passes the chain
    // (/private, /private/var, /private/var/run: root's, /private/var/run group-writable by daemon, a group this user is not in)
    // and then fails on the missing staged directory, not on the chain: a staged directory with a made-up name proves the chain.
    {const char *r=dw_staged_payload_refusal("/private/var/run/infinify-payload.AbC123/payload-arm64e.dylib",DW_STAGED_ROOT,0,me);
     CHECK(r!=NULL&&strstr(r,"a component of the path is missing")!=NULL,"the production chain: %s",r?r:"accepted a payload that cannot exist");}
    {struct stat run;CHECK(stat(DW_STAGED_ROOT,&run)==0&&run.st_uid==0&&!(run.st_mode&S_IWOTH),"/private/var/run is not root's and closed to others");
     if(run.st_mode&S_IWGRP)CHECK(!dw_staged_user_in_group(me,run.st_gid)||getuid()==0,"/private/var/run is writable by a group this user is in");}
    // Another user's directory in the chain: the same scratch tree, with the trusted owner made someone else, is refused as
    // "can be changed by the login user" (the scratch tree belongs to this user, which stands for any non-root user).
    CHECK(DWLoadStagePayload(root,runtime,payload,digest,me,me,&path,&why),"staging again failed: %s",why.UTF8String);
    {const char *r=dw_staged_payload_refusal(path.fileSystemRepresentation,root.fileSystemRepresentation,0,me);
     CHECK(me==0||r!=NULL,"a chain of the login user's own directories was accepted with root as the trusted owner");}
    // Pruning removes other runtimes' staged copies and sidecars, only in the exact form, only the trusted owner's, never the kept one.
    CHECK(DWLoadStagePayload(root,other,payload,digest,me,me,&path,&why),"staging the second runtime failed: %s",why.UTF8String);
    NSString *sidecar=[stagedPath(root,other) stringByAppendingString:@".json"];
    putFile(sidecar,[@"{}" dataUsingEncoding:NSUTF8StringEncoding],0600);
    NSString *foreign=[root stringByAppendingPathComponent:@"infinify-payload-foreign"],*foreign2=[root stringByAppendingPathComponent:@"infinify-payload.Fo!eig"];
    [fm createDirectoryAtPath:foreign withIntermediateDirectories:NO attributes:nil error:nil];
    [fm createDirectoryAtPath:foreign2 withIntermediateDirectories:NO attributes:nil error:nil];
    NSString *extra=[[DWLoadStagedDirectory(root,@"/tmp/if-native.Qq1Ww2") stringByAppendingString:@"/keepme"] copy];
    [fm createDirectoryAtPath:DWLoadStagedDirectory(root,@"/tmp/if-native.Qq1Ww2") withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0755} error:nil];
    putFile(extra,[@"x" dataUsingEncoding:NSUTF8StringEncoding],0644);
    // A staged copy whose sidecar belongs to someone else is another user's Dock's: left alone.
    CHECK(DWLoadStagePayload(root,@"/tmp/if-native.Oo3Pp4",payload,digest,me,me,&path,&why),"staging the third runtime failed: %s",why.UTF8String);
    putFile([stagedPath(root,@"/tmp/if-native.Oo3Pp4") stringByAppendingString:@".json"],[@"{}" dataUsingEncoding:NSUTF8StringEncoding],0600);
    CHECK(DWLoadPruneStaged(root,runtime,me,me+1)==0,"pruning for another login user removed a copy whose sidecar is this user's");
    CHECK(access(DWLoadStagedDirectory(root,@"/tmp/if-native.Oo3Pp4").fileSystemRepresentation,F_OK)==0,"the other user's staged copy went");
    NSUInteger gone=DWLoadPruneStaged(root,runtime,me,me);
    CHECK(gone==2,"pruning removed %lu directories, wanted 2 (the second and third runtimes')",(unsigned long)gone);
    CHECK(access(DWLoadStagedDirectory(root,other).fileSystemRepresentation,F_OK)!=0,"the other runtime's staged directory is still there");
    CHECK(access(DWLoadStagedDirectory(root,runtime).fileSystemRepresentation,F_OK)==0,"pruning removed the kept runtime's staged directory");
    CHECK(access(foreign.fileSystemRepresentation,F_OK)==0&&access(foreign2.fileSystemRepresentation,F_OK)==0,"pruning removed a directory that is not in the staged form");
    CHECK(access(extra.fileSystemRepresentation,F_OK)==0,"pruning removed a file it does not own the name of");
    CHECK(DWLoadPruneStaged(root,runtime,me+1,me)==0,"pruning for another trusted owner removed something");
    [fm removeItemAtPath:root error:nil];
    [fm removeItemAtPath:linkedRoot.stringByDeletingLastPathComponent error:nil];
    #undef RULE
}

// The signature rules for the caller, as a plain function over flags, status and entitlements.
static void callerFlags(void) {
    enum { Runtime=0x10000,GetTaskAllow=0x4,Valid=0x1,Hard=0x100,Kill=0x200 };
    uint32_t good=Valid|Hard|Kill|Runtime;
    CHECK(DWLoadCallerFlagsRefusal(Runtime,good,@{})==nil,"a hardened caller was refused: %s",DWLoadCallerFlagsRefusal(Runtime,good,@{}).UTF8String);
    CHECK(DWLoadCallerFlagsRefusal(Runtime,good,nil)==nil,"a hardened caller without entitlements was refused");
    CHECK(DWLoadCallerFlagsRefusal(Runtime,good,@{@"com.apple.security.cs.allow-jit":@YES,@"com.apple.security.device.camera":@YES})==nil,"entitlements that do not open the process to injection were refused");
    CHECK(DWLoadCallerFlagsRefusal(0,good,@{})!=nil,"a signature without the runtime flag was accepted");
    CHECK(DWLoadCallerFlagsRefusal(Valid,good,@{})!=nil,"other signature flags were taken for the runtime flag");
    CHECK(DWLoadCallerFlagsRefusal(Runtime,Valid|Hard|Kill,@{})!=nil,"a process not enforcing the runtime was accepted");
    CHECK(DWLoadCallerFlagsRefusal(Runtime,good|GetTaskAllow,@{})!=nil,"a process with get-task-allow in force was accepted");
    for(NSString *key in @[@"com.apple.security.get-task-allow",@"com.apple.security.cs.allow-dyld-environment-variables",@"com.apple.security.cs.disable-library-validation"]){
        CHECK(DWLoadCallerFlagsRefusal(Runtime,good,@{key:@YES})!=nil,"%s was accepted",key.UTF8String);
        CHECK(DWLoadCallerFlagsRefusal(Runtime,good,@{key:@"true"})!=nil,"%s as a string was accepted",key.UTF8String);
        CHECK(DWLoadCallerFlagsRefusal(Runtime,good,@{key:@1})!=nil,"%s as 1 was accepted",key.UTF8String);
        CHECK(DWLoadCallerFlagsRefusal(Runtime,good,@{key:@NO})==nil,"%s false was refused",key.UTF8String);
    }
    CHECK(DWLoadCallerFlagsRefusal(Runtime,good,(NSDictionary *)@[@1])!=nil,"entitlements of the wrong type were accepted");
}

static void callerEnvironment(void) {
    CHECK(DWLoadCallerEnvironmentRefusal(@[@"PATH=/usr/bin",@"HOME=/Users/me",@"DYLD_NOT=1x"])!=nil,"a DYLD_ variable was accepted");
    CHECK(DWLoadCallerEnvironmentRefusal(@[@"PATH=/usr/bin",@"HOME=/Users/me",@"TMPDIR=/tmp/",@"MY_DYLD_THING=1",@"dyld_insert_libraries=x",@"X=DYLD_INSERT_LIBRARIES=x"])==nil,"unrelated variables that mention DYLD were refused");
    for(NSString *name in @[@"DYLD_INSERT_LIBRARIES",@"DYLD_LIBRARY_PATH",@"DYLD_FRAMEWORK_PATH",@"DYLD_FALLBACK_LIBRARY_PATH",@"DYLD_IMAGE_SUFFIX",@"__XPC_DYLD_INSERT_LIBRARIES",@"__XPC_DYLD_LIBRARY_PATH"])
        CHECK(DWLoadCallerEnvironmentRefusal(@[@"PATH=/usr/bin",[name stringByAppendingString:@"=/tmp/evil.dylib"]])!=nil,"%s was accepted",name.UTF8String);
    CHECK(DWLoadCallerEnvironmentRefusal(@[])==nil,"an empty environment was refused");
    CHECK(DWLoadCallerEnvironmentRefusal(nil)!=nil,"an unreadable environment was accepted");
    CHECK(DWLoadCallerEnvironmentRefusal((NSArray *)@[@5])!=nil,"a malformed environment was accepted");
    // The reader, on this process: its own environment as the kernel kept it, including one set before the exec.
    setenv("DWLOAD_REGRESSION_MARK","1",1);
    NSArray *mine=DWLoadProcessEnvironment(getpid());
    CHECK(mine.count>0,"this process's environment could not be read");
    BOOL later=NO;for(NSString *entry in mine)if([entry hasPrefix:@"DWLOAD_REGRESSION_MARK"])later=YES;
    CHECK(!later,"the starting environment shows a variable set after the start");
    CHECK(DWLoadProcessEnvironment(0)==nil&&DWLoadProcessEnvironment(1)==nil&&DWLoadProcessEnvironment(2147483000)==nil,"an impossible pid has an environment");
}

// This very process, judged by the live check: the e2e script runs this binary unsigned-with-flags, with the runtime flag, and with
// the runtime flag plus each entitlement that must be refused, and expects the exit status of --self-caller to follow.
static int selfCaller(void) {
    audit_token_t token;
    mach_msg_type_number_t count=TASK_AUDIT_TOKEN_COUNT;
    if(task_info(mach_task_self(),TASK_AUDIT_TOKEN,(task_info_t)&token,&count)!=KERN_SUCCESS){fputs("no audit token\n",stderr);return 2;}
    NSString *refusal=DWLoadCallerRefusal(token);
    printf("%s\n",refusal?refusal.UTF8String:"accepted");
    return refusal?1:0;
}

int main(int argc,char **argv) { @autoreleasepool {
    if(argc>1&&!strcmp(argv[1],"--self-caller"))return selfCaller();
    callerRequirement(argc>1?argv[1]:NULL);
    requests();
    artifacts();
    stagedPayload();
    callerFlags();
    callerEnvironment();
    if(failures){fprintf(stderr,"loadd-request-regression: %d of %d checks FAILED\n",failures,checks);return 1;}
    printf("loadd-request-regression: %d checks passed (%s)\n",checks,argc>1?"including a real team signature":"no signed app given: the caller requirement was checked as text and against this ad-hoc process only");
    return 0;
} }
