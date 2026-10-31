// SPDX-License-Identifier: GPL-3.0-or-later
// Where Infinify lives and the move to Applications (native/app/System/DWInstall.h), against stand-in bundles in a scratch
// directory: what counts as installed, where a move puts the app, clearing quarantine, and the move itself (a fresh place,
// a place holding an older copy, a place holding something else). Discarding is a removal inside the scratch directory, so
// nothing goes to the Trash; nothing is opened, registered or translocated.
#import <Foundation/Foundation.h>
#import "DWInstall.h"
#include <sys/stat.h>
#include <sys/xattr.h>

static int checks,failures;
static void check(BOOL ok,NSString *what) { checks++;if(!ok)failures++;printf("%s %s\n",ok?"ok  ":"FAIL",what.UTF8String); }

static const char *const kQuarantine="0081;6ae5679d;Safari;";
static NSString *standIn(NSString *bundle,NSString *identifier,NSString *version) {
    NSFileManager *files=NSFileManager.defaultManager;
    [files createDirectoryAtPath:[bundle stringByAppendingPathComponent:@"Contents/MacOS"] withIntermediateDirectories:YES attributes:nil error:NULL];
    [@{@"CFBundleIdentifier":identifier} writeToFile:[bundle stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES];
    NSString *executable=[bundle stringByAppendingPathComponent:@"Contents/MacOS/Infinify"];
    [[NSString stringWithFormat:@"#!/bin/sh\n# %@\n",version] writeToFile:executable atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    chmod(executable.fileSystemRepresentation,0755);
    return bundle;
}
static NSString *versionOf(NSString *bundle) {
    return [NSString stringWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Contents/MacOS/Infinify"] encoding:NSUTF8StringEncoding error:NULL];
}
static BOOL quarantined(NSString *path) { return getxattr(path.fileSystemRepresentation,"com.apple.quarantine",NULL,0,0,XATTR_NOFOLLOW)>0; }
static void quarantine(NSString *path) { setxattr(path.fileSystemRepresentation,"com.apple.quarantine",kQuarantine,strlen(kQuarantine),0,XATTR_NOFOLLOW); }

int main(void) { @autoreleasepool {
    NSFileManager *files=NSFileManager.defaultManager;
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"install-%d",getpid()]];
    [files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *(^at)(NSString *)=^NSString *(NSString *relative){return [root stringByAppendingPathComponent:relative];};
    NSMutableArray<NSString *> *discarded=[NSMutableArray array];
    BOOL (^discard)(NSString *,NSString *__autoreleasing *)=^BOOL(NSString *path,NSString *__autoreleasing *why){
        (void)why;[discarded addObject:path];return [files removeItemAtPath:path error:NULL];
    };

    NSString *installed=standIn(at(@"Applications/Infinify.app"),@"com.marengox.infinify",@"installed");
    NSString *downloaded=standIn(at(@"Downloads/Infinify.app"),@"com.marengox.infinify",@"new");
    check(DWInstallTranslocatedOriginal(downloaded)==nil,@"a bundle LaunchServices did not translocate has no original");
    check(DWInstallIsInstalled(installed),@"a bundle in an Applications folder on a writable volume is installed");
    check(!DWInstallIsInstalled(downloaded),@"one in Downloads is not");
    check(!DWInstallIsInstalled(@"/System/Applications/Calculator.app"),@"one in an Applications folder on a read-only volume is not (as on the disk image)");

    NSArray<NSString *> *candidates=@[at(@"system/Applications/Infinify.app"),at(@"home/Applications/Infinify.app")];
    check([DWInstallPlace(candidates) isEqual:candidates.lastObject],@"neither folder there: the last candidate, made by the move");
    [files createDirectoryAtPath:at(@"system/Applications") withIntermediateDirectories:YES attributes:nil error:NULL];
    check([DWInstallPlace(candidates) isEqual:candidates[0]],@"the first candidate whose folder this user can write");
    chmod(at(@"system/Applications").fileSystemRepresentation,0555);
    check([DWInstallPlace(candidates) isEqual:candidates[1]],@"the next one when this user cannot write the first");
    chmod(at(@"system/Applications").fileSystemRepresentation,0755);
    standIn(candidates[1],@"com.marengox.infinify",@"older");
    check([DWInstallPlace(candidates) isEqual:candidates[1]],@"a candidate holding an Infinify comes first: the move replaces it");

    quarantine(downloaded);quarantine([downloaded stringByAppendingPathComponent:@"Contents/MacOS/Infinify"]);
    NSString *why=nil;
    check(DWInstallClearQuarantine(downloaded,&why)&&!quarantined(downloaded)&&!quarantined([downloaded stringByAppendingPathComponent:@"Contents/MacOS/Infinify"]),@"quarantine is cleared from the bundle and every file in it");
    check(DWInstallClearQuarantine(downloaded,&why),@"clearing a bundle with none is no failure");

    quarantine(downloaded);quarantine([downloaded stringByAppendingPathComponent:@"Contents/MacOS/Infinify"]);
    NSString *fresh=at(@"fresh/Applications/Infinify.app");why=nil;
    check(DWInstallMove(downloaded,downloaded,fresh,discard,&why),[NSString stringWithFormat:@"a move to a place that is free (%@)",why]);
    check([versionOf(fresh) containsString:@"new"]&&!quarantined(fresh)&&!quarantined([fresh stringByAppendingPathComponent:@"Contents/MacOS/Infinify"]),@"puts the copy there, without quarantine");
    check(![files fileExistsAtPath:downloaded]&&[discarded containsObject:downloaded],@"and discards the original, which was on a writable volume");
    NSArray<NSString *> *left=[files contentsOfDirectoryAtPath:at(@"fresh/Applications") error:NULL];
    check(left.count==1,[NSString stringWithFormat:@"leaving nothing else beside it (%@)",left]);

    [discarded removeAllObjects];
    NSString *newer=standIn(at(@"image/Infinify.app"),@"com.marengox.infinify",@"newer");
    check(DWInstallMove(newer,nil,candidates[1],discard,&why),@"a move to a place holding an older Infinify");
    check([versionOf(candidates[1]) containsString:@"newer"]&&[discarded isEqual:@[candidates[1]]],@"discards the older copy and puts this one in its place, and nothing else");

    [discarded removeAllObjects];why=nil;
    NSString *other=standIn(at(@"taken/Applications/Infinify.app"),@"com.example.other",@"other");
    check(!DWInstallMove(newer,nil,other,discard,&why)&&[versionOf(other) containsString:@"other"]&&!discarded.count,@"a place holding something else is refused and left as it is");
    check([why containsString:@"is not Infinify"],[NSString stringWithFormat:@"saying so (%@)",why]);
    check([files contentsOfDirectoryAtPath:at(@"taken/Applications") error:NULL].count==1,@"with no half copy left beside it");

    [files removeItemAtPath:root error:NULL];
    printf("%d checks, %d failed\n",checks,failures);
    return failures?1:0;
} }
