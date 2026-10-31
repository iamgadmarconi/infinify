// SPDX-License-Identifier: GPL-3.0-or-later
// New implementation. SecTranslocate is the Security framework's own reading of translocation (as Sparkle reads it); the
// do-not-translocate bit that Homebrew sets instead is in Homebrew's cask/quarantine.rb.
#import "DWInstall.h"
#import "DWSetupState.h"
#import "DWUninstall.h"
#include <dlfcn.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/xattr.h>

typedef Boolean (*IsTranslocatedFunction)(CFURLRef,bool *,CFErrorRef *);
typedef CFURLRef (*OriginalPathFunction)(CFURLRef,CFErrorRef *);

NSString *DWInstallTranslocatedOriginal(NSString *bundle) {
    static IsTranslocatedFunction isTranslocated;static OriginalPathFunction originalPath;static dispatch_once_t once;
    dispatch_once(&once,^{
        void *security=dlopen("/System/Library/Frameworks/Security.framework/Security",RTLD_LAZY);
        if(!security)return;
        isTranslocated=(IsTranslocatedFunction)dlsym(security,"SecTranslocateIsTranslocatedURL");
        originalPath=(OriginalPathFunction)dlsym(security,"SecTranslocateCreateOriginalPathForURL");
    });
    if(!isTranslocated||!originalPath)return nil;
    NSURL *url=[NSURL fileURLWithPath:bundle];bool translocated=false;
    if(!isTranslocated((__bridge CFURLRef)url,&translocated,NULL)||!translocated)return nil;
    NSURL *original=CFBridgingRelease(originalPath((__bridge CFURLRef)url,NULL));
    return original.path;
}

static BOOL onWritableVolume(NSString *path) { struct statfs fs;return statfs(path.fileSystemRepresentation,&fs)==0&&!(fs.f_flags&MNT_RDONLY); }

BOOL DWInstallIsInstalled(NSString *bundle) {
    if(DWInstallTranslocatedOriginal(bundle))return NO;
    return [bundle.stringByStandardizingPath.pathComponents containsObject:@"Applications"]&&onWritableVolume(bundle);
}

NSString *DWInstallPlace(NSArray<NSString *> *candidates) {
    for(NSString *candidate in candidates)if(DWSetupIsInfinifyAt(candidate))return candidate;
    for(NSString *candidate in candidates){
        NSString *folder=candidate.stringByDeletingLastPathComponent;BOOL directory=NO;
        if([NSFileManager.defaultManager fileExistsAtPath:folder isDirectory:&directory]&&directory&&access(folder.fileSystemRepresentation,W_OK)==0)return candidate;
    }
    return candidates.lastObject;
}

BOOL DWInstallClearQuarantine(NSString *bundle,NSString *__autoreleasing *why) {
    NSMutableArray<NSString *> *paths=[NSMutableArray arrayWithObject:bundle];
    for(NSString *relative in [NSFileManager.defaultManager enumeratorAtPath:bundle])[paths addObject:[bundle stringByAppendingPathComponent:relative]];
    for(NSString *path in paths){
        if(removexattr(path.fileSystemRepresentation,"com.apple.quarantine",XATTR_NOFOLLOW)==0||errno==ENOATTR)continue;
        if(why)*why=[NSString stringWithFormat:@"the quarantine of %@ could not be cleared: %s",path,strerror(errno)];
        return NO;
    }
    return YES;
}

void DWInstallLeaveTranslocation(void) {
    NSString *original=DWInstallTranslocatedOriginal(NSBundle.mainBundle.bundlePath),*why=nil;
    if(!original||!DWInstallIsInstalled(original))return;
    if(!DWInstallClearQuarantine(original,&why)){fprintf(stderr,"Infinify: macOS runs a temporary copy of %s, and %s\n",original.fileSystemRepresentation,why.UTF8String);return;}
    DWInstallOpenInstead(original);
}

int DWInstallOpenInstead(NSString *bundle) {
    // -n: LaunchServices still counts this process as Infinify running, and would only bring it forward.
    char *arguments[]={"open","-n",(char *)bundle.fileSystemRepresentation,NULL};
    execv("/usr/bin/open",arguments);perror("Infinify: open");return 69;
}

static BOOL trash(NSString *path,NSString *__autoreleasing *why) {
    NSError *error=nil;
    if([NSFileManager.defaultManager trashItemAtURL:[NSURL fileURLWithPath:path] resultingItemURL:nil error:&error])return YES;
    if(why)*why=[NSString stringWithFormat:@"%@ could not be moved to the Trash: %@",path,error.localizedDescription?:@"macOS gave no reason"];
    return NO;
}
static BOOL sameFile(NSString *one,NSString *other) {
    struct stat a,b;
    return stat(one.fileSystemRepresentation,&a)==0&&stat(other.fileSystemRepresentation,&b)==0&&a.st_dev==b.st_dev&&a.st_ino==b.st_ino;
}

BOOL DWInstallMove(NSString *source,NSString *original,NSString *place,BOOL (^discard)(NSString *,NSString *__autoreleasing *),NSString *__autoreleasing *why) {
    NSFileManager *files=NSFileManager.defaultManager;NSError *error=nil;
    if(!discard)discard=^BOOL(NSString *path,NSString *__autoreleasing *reason){return trash(path,reason);};
    NSString *folder=place.stringByDeletingLastPathComponent;
    if(![files createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error]){
        if(why)*why=[NSString stringWithFormat:@"%@ could not be made: %@",folder,error.localizedDescription];
        return NO;
    }
    struct stat st;BOOL taken=lstat(place.fileSystemRepresentation,&st)==0;
    if(taken&&!DWSetupIsInfinifyAt(place)){if(why)*why=[NSString stringWithFormat:@"%@ is not Infinify; move it away first.",place];return NO;}
    // The copy is made beside its place and renamed into it, so that the place never holds half an app; it is taken
    // before anything is discarded, which a translocated source (a view of the bundle it was made from) depends on.
    NSString *partial=[folder stringByAppendingPathComponent:[NSString stringWithFormat:@".Infinify-%d.partial.app",getpid()]];
    [files removeItemAtPath:partial error:NULL];
    if(![files copyItemAtPath:source toPath:partial error:&error]){
        if(why)*why=[NSString stringWithFormat:@"Infinify could not be copied to %@: %@",folder,error.localizedDescription];
        [files removeItemAtPath:partial error:NULL];return NO;
    }
    if(!DWInstallClearQuarantine(partial,why)){[files removeItemAtPath:partial error:NULL];return NO;}
    if(taken){
        if(!DWUninstallStopInstances(DWUninstallInstances([place stringByAppendingPathComponent:@"Contents/MacOS/Infinify"]),10)){
            if(why)*why=[NSString stringWithFormat:@"The Infinify at %@ did not quit; quit it and try again.",place];
            [files removeItemAtPath:partial error:NULL];return NO;
        }
        if(!discard(place,why)){[files removeItemAtPath:partial error:NULL];return NO;}
    }
    if(rename(partial.fileSystemRepresentation,place.fileSystemRepresentation)!=0){
        if(why)*why=[NSString stringWithFormat:@"Infinify could not be put at %@: %s",place,strerror(errno)];
        [files removeItemAtPath:partial error:NULL];return NO;
    }
    if(original.length&&!sameFile(original,place)&&onWritableVolume(original))discard(original,NULL);
    return YES;
}
