// SPDX-License-Identifier: GPL-3.0-or-later
// New implementation over GitHub's REST endpoint for a repository's latest release (GET /repos/OWNER/REPO/releases/latest).
#import "DWUpdateCheck.h"
#import "DWOwnerFile.h"

static NSString *const kUpdatesFile=@"updates.plist";
static const NSTimeInterval kCheckInterval=24*60*60;

NSComparisonResult DWUpdateCompareVersions(NSString *one,NSString *other) {
    NSArray<NSString *> *a=[one componentsSeparatedByString:@"."],*b=[other componentsSeparatedByString:@"."];
    for(NSUInteger i=0;i<MAX(a.count,b.count);i++){
        NSInteger x=i<a.count?a[i].integerValue:0,y=i<b.count?b[i].integerValue:0;
        if(x!=y)return x<y?NSOrderedAscending:NSOrderedDescending;
    }
    return NSOrderedSame;
}

NSDictionary<NSString *,NSString *> *DWUpdateReleaseFromJSON(NSData *json) {
    if(!json)return nil;
    NSDictionary *answer=[NSJSONSerialization JSONObjectWithData:json options:0 error:NULL];
    if(![answer isKindOfClass:NSDictionary.class]||[answer[@"draft"] boolValue]||[answer[@"prerelease"] boolValue])return nil;
    NSString *tag=answer[@"tag_name"],*page=answer[@"html_url"];
    if(![tag isKindOfClass:NSString.class]||![page isKindOfClass:NSString.class]||![page hasPrefix:@"https://"])return nil;
    NSString *version=[tag hasPrefix:@"v"]?[tag substringFromIndex:1]:tag;
    NSRegularExpression *dotted=[NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(\\.[0-9]+){1,3}$" options:0 error:NULL];
    if(![dotted firstMatchInString:version options:0 range:NSMakeRange(0,version.length)])return nil;
    return @{@"version":version,@"page":page};
}

static NSString *recordPath(NSString *support) { return [support stringByAppendingPathComponent:kUpdatesFile]; }
static BOOL writeRecord(NSString *support,NSDictionary *record) {
    struct stat st;
    if(lstat(support.fileSystemRepresentation,&st)!=0){
        if(![NSFileManager.defaultManager createDirectoryAtPath:support withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL])return NO;
    }else if(!S_ISDIR(st.st_mode)||st.st_uid!=getuid())return NO;
    return DWOwnerFileWritePlist(recordPath(support),record);
}

BOOL DWUpdateRecordRelease(NSString *support,NSDictionary<NSString *,NSString *> *release,NSDate *checked) {
    NSMutableDictionary *record=[DWOwnerFileReadPlist(recordPath(support))?:@{} mutableCopy];
    record[@"checked"]=checked;
    if(release){record[@"version"]=release[@"version"];record[@"page"]=release[@"page"];}
    return writeRecord(support,record);
}

NSDictionary<NSString *,NSString *> *DWUpdateNewerRecorded(NSString *support,NSString *running) {
    NSDictionary *record=DWOwnerFileReadPlist(recordPath(support));
    NSString *version=record[@"version"],*page=record[@"page"];
    if(![version isKindOfClass:NSString.class]||![page isKindOfClass:NSString.class]||!running.length)return nil;
    return DWUpdateCompareVersions(version,running)==NSOrderedDescending?@{@"version":version,@"page":page}:nil;
}

BOOL DWUpdateFirstNoticeOf(NSString *support,NSString *version) {
    NSMutableDictionary *record=[DWOwnerFileReadPlist(recordPath(support))?:@{} mutableCopy];
    NSString *told=record[@"told"];
    if([told isKindOfClass:NSString.class]&&DWUpdateCompareVersions(told,version)!=NSOrderedAscending)return NO;
    record[@"told"]=version;
    return writeRecord(support,record);
}

void DWUpdateCheckIfDue(NSString *support,void (^done)(NSDictionary<NSString *,NSString *> *newer)) {
    NSDictionary *info=NSBundle.mainBundle.infoDictionary;
    NSString *repository=info[@"InfinifyReleaseRepository"],*running=info[@"CFBundleShortVersionString"];
    id setting=[NSUserDefaults.standardUserDefaults objectForKey:@"CheckForUpdates"];
    void (^answer)(void)=^{NSDictionary *newer=DWUpdateNewerRecorded(support,running);dispatch_async(dispatch_get_main_queue(),^{done(newer);});};
    if(![repository isKindOfClass:NSString.class]||!repository.length||(setting&&![setting boolValue])){dispatch_async(dispatch_get_main_queue(),^{done(nil);});return;}
    NSDate *checked=DWOwnerFileReadPlist(recordPath(support))[@"checked"];
    if([checked isKindOfClass:NSDate.class]&&-checked.timeIntervalSinceNow<kCheckInterval&&checked.timeIntervalSinceNow<=0){answer();return;}
    NSURL *url=[NSURL URLWithString:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest",repository]];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [request setValue:[NSString stringWithFormat:@"Infinify/%@",running?:@"0"] forHTTPHeaderField:@"User-Agent"];
    NSURLSession *session=[NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        // An answer that is not a release (no release yet, a rate limit) still counts as a check; no answer at all is tried again next time.
        NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;
        if(!error&&status)DWUpdateRecordRelease(support,status==200?DWUpdateReleaseFromJSON(data):nil,[NSDate date]);
        answer();
    }] resume];
    [session finishTasksAndInvalidate];
}

NSArray<NSString *> *DWUpdateHomebrewCaskrooms(void) { return @[@"/opt/homebrew/Caskroom",@"/usr/local/Caskroom"]; }
NSString *DWUpdateCommand(NSArray<NSString *> *caskrooms) {
    for(NSString *caskroom in caskrooms){
        BOOL directory=NO;
        if([NSFileManager.defaultManager fileExistsAtPath:[caskroom stringByAppendingPathComponent:@"infinify"] isDirectory:&directory]&&directory)return @"brew upgrade --cask infinify";
    }
    return nil;
}
