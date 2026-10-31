// SPDX-License-Identifier: GPL-3.0-or-later
// Whether a newer Infinify is out (native/app/System/DWUpdateCheck.h), offline: versions compared, GitHub's answer read,
// the owner-only record, one notice per version, the Homebrew command from stand-in Caskroom folders, and a development
// build (this test names no release repository) that never reads the network. Writes only its scratch directory.
#import <Foundation/Foundation.h>
#import "DWUpdateCheck.h"
#include <sys/stat.h>

static int checks,failures;
static void check(BOOL ok,NSString *what) { checks++;if(!ok)failures++;printf("%s %s\n",ok?"ok  ":"FAIL",what.UTF8String); }
static NSData *json(NSDictionary *object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL]; }

int main(void) { @autoreleasepool {
    NSFileManager *files=NSFileManager.defaultManager;
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"update-check-%d",getpid()]];
    NSString *support=[root stringByAppendingPathComponent:@"Infinify"];
    [files createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];

    check(DWUpdateCompareVersions(@"0.2.10",@"0.2.9")==NSOrderedDescending,@"0.2.10 is after 0.2.9, number by number");
    check(DWUpdateCompareVersions(@"0.3",@"0.3.0")==NSOrderedSame,@"a missing part counts as 0");
    check(DWUpdateCompareVersions(@"0.2.2",@"1.0.0")==NSOrderedAscending,@"0.2.2 is before 1.0.0");

    NSString *page=@"https://github.com/iamgadmarconi/infinify/releases/tag/v0.2.3";
    NSDictionary *release=DWUpdateReleaseFromJSON(json(@{@"tag_name":@"v0.2.3",@"html_url":page,@"draft":@NO,@"prerelease":@NO}));
    check([release isEqual:@{@"version":@"0.2.3",@"page":page}],[NSString stringWithFormat:@"a release is read, the tag's v dropped (%@)",release]);
    check(!DWUpdateReleaseFromJSON(json(@{@"tag_name":@"v0.2.4",@"html_url":page,@"prerelease":@YES})),@"a prerelease is not offered");
    check(!DWUpdateReleaseFromJSON(json(@{@"tag_name":@"v0.2.4",@"html_url":page,@"draft":@YES})),@"nor a draft");
    check(!DWUpdateReleaseFromJSON(json(@{@"tag_name":@"nightly",@"html_url":page})),@"nor a tag that is no version");
    check(!DWUpdateReleaseFromJSON(json(@{@"tag_name":@"v0.2.4",@"html_url":@"http://example.com/"})),@"nor a page that is not https");
    check(!DWUpdateReleaseFromJSON(json(@{@"message":@"Not Found"})),@"nor GitHub's answer when there is no release");
    check(!DWUpdateReleaseFromJSON([@"not json" dataUsingEncoding:NSUTF8StringEncoding]),@"nor something that is not JSON");

    check(!DWUpdateNewerRecorded(support,@"0.2.2"),@"nothing recorded: nothing newer");
    check(DWUpdateRecordRelease(support,release,[NSDate date]),@"a release read is recorded, the support directory made on the way");
    struct stat st;
    check(lstat([support stringByAppendingPathComponent:@"updates.plist"].fileSystemRepresentation,&st)==0&&(st.st_mode&07777)==0600,@"in a record that is the owner's alone (0600)");
    check([DWUpdateNewerRecorded(support,@"0.2.2")[@"version"] isEqual:@"0.2.3"],@"0.2.3 recorded is newer than a running 0.2.2");
    check(!DWUpdateNewerRecorded(support,@"0.2.3"),@"and not than a running 0.2.3");
    check(DWUpdateRecordRelease(support,nil,[NSDate date])&&[DWUpdateNewerRecorded(support,@"0.2.2")[@"version"] isEqual:@"0.2.3"],@"a check that read no release keeps the one recorded");

    check(DWUpdateFirstNoticeOf(support,@"0.2.3"),@"the first time 0.2.3 is newer, the owner is told");
    check(!DWUpdateFirstNoticeOf(support,@"0.2.3"),@"not a second time");
    check(DWUpdateRecordRelease(support,@{@"version":@"0.2.4",@"page":page},[NSDate date])&&[DWUpdateNewerRecorded(support,@"0.2.2")[@"version"] isEqual:@"0.2.4"],@"a later release replaces it");
    check(DWUpdateFirstNoticeOf(support,@"0.2.4")&&!DWUpdateFirstNoticeOf(support,@"0.2.3"),@"and is told about once, an older one never again");

    chmod([support stringByAppendingPathComponent:@"updates.plist"].fileSystemRepresentation,0644);
    check(!DWUpdateNewerRecorded(support,@"0.2.2"),@"a record others could have written is not trusted");

    NSString *brew=[root stringByAppendingPathComponent:@"opt/Caskroom"],*other=[root stringByAppendingPathComponent:@"usr/Caskroom"];
    check(DWUpdateCommand(@[brew,other])==nil,@"no Caskroom: Homebrew did not install this copy");
    [files createDirectoryAtPath:[other stringByAppendingPathComponent:@"something-else"] withIntermediateDirectories:YES attributes:nil error:NULL];
    check(DWUpdateCommand(@[brew,other])==nil,@"a Caskroom without infinify is not this copy's");
    [files createDirectoryAtPath:[other stringByAppendingPathComponent:@"infinify/0.2.2"] withIntermediateDirectories:YES attributes:nil error:NULL];
    check([DWUpdateCommand(@[brew,other]) isEqual:@"brew upgrade --cask infinify"],@"a Caskroom holding infinify: brew upgrade");

    __block BOOL answered=NO;__block NSDictionary *newer=@{};
    DWUpdateCheckIfDue(support,^(NSDictionary<NSString *,NSString *> *found){answered=YES;newer=found;});
    for(int i=0;i<50&&!answered;i++)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.02]];
    check(answered&&newer==nil,@"a development build, which names no release repository, answers at once with nothing and reads no network");

    [files removeItemAtPath:root error:NULL];
    printf("%d checks, %d failed\n",checks,failures);
    return failures?1:0;
} }
