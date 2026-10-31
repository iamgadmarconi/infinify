// SPDX-License-Identifier: GPL-3.0-or-later
// The snapshot/restore logic of DWSystemTakeover.m against an in-memory preferences store: no preference of the
// user's, no WindowManager, no window and no input is touched. What it cannot show is that macOS follows the real
// keys; the guest runs recorded in docs/native/user-guide.md ("Desktop mode") are that evidence.
#import <Foundation/Foundation.h>
#import "DWSystemTakeover.h"
#include <unistd.h>

static NSUInteger checks;
static void check(BOOL condition,const char *message) { checks++;if(!condition){fprintf(stderr,"FAIL: %s\n",message);exit(1);} }

@interface IFStore : NSObject <DWPrefsStore>
@property NSMutableDictionary *values;
@property NSUInteger writes;
@property NSUInteger failAt;   // the write (1 = the next one) that is refused; 0 none
@property BOOL failFromThen;   // and every one after it, until `failing` is cleared
@property BOOL failing;
@property NSString *path;      // checked before each write: the snapshot file must exist by then
@property BOOL fileMissingAtWrite;
@end
@implementation IFStore
- (instancetype)initWithValues:(NSDictionary *)values { if((self=[super init]))_values=[values mutableCopy];return self; }
- (id)valueOfPref:(DWPref *)pref { return _values[pref.key]; }
- (BOOL)setValue:(id)value ofPref:(DWPref *)pref {
    NSString *key=pref.key;
    _writes++;
    if(_path&&![NSFileManager.defaultManager fileExistsAtPath:_path])_fileMissingAtWrite=YES;
    if(_failing)return NO;
    if(_failAt&&--_failAt==0){_failing=_failFromThen;return NO;}
    if(value)_values[key]=value;else [_values removeObjectForKey:key];return YES;
}
@end

static NSString *const SM=@"GloballyEnabled",*EDGE=@"EnableTilingByEdgeDrag",*TOP=@"EnableTopTilingByEdgeDrag",*OPT=@"EnableTilingOptionAccelerator",*MARGINS=@"EnableTiledWindowMargins",*DC=@"AppleActionOnDoubleClick";
// Stage Manager as an integer, edge tiling as a bool, the top edge never set, the accelerator as a string: every shape a
// key can have, and a key of the user's that takeover must never touch.
// The title-bar double-click is absent here (macOS's own default, which acts), the case that has to come back absent.
static NSDictionary *mixed(void) { return @{SM:@1,EDGE:@YES,OPT:@"yes",MARGINS:@YES}; }
static NSDictionary *allOn(void) { return @{SM:@YES,EDGE:@YES,TOP:@YES,OPT:@YES,MARGINS:@YES,DC:@"Maximize"}; }
static BOOL allOff(NSDictionary *v) { for(NSString *k in @[SM,EDGE,TOP,OPT])if(![v[k]isEqual:@NO])return NO;return [v[DC]isEqual:@"None"]; }
#define ID(key) ([@"com.apple.WindowManager|" stringByAppendingString:key])
#define IDDC @"NSGlobalDomain|AppleActionOnDoubleClick"
static NSDictionary *fileAt(NSString *path) { NSData *d=[NSData dataWithContentsOfFile:path];return d?[NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:NULL]:nil; }

int main(void) { @autoreleasepool {
    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"infinify-takeover-%d",getpid()]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *path=[dir stringByAppendingPathComponent:@"snapshot.plist"];
    NSFileManager *fm=NSFileManager.defaultManager;NSString *note=nil;

    // A fresh takeover and its restore: present and absent keys, the file written before the first write, nothing else touched.
    IFStore *store=[[IFStore alloc]initWithValues:mixed()];store.path=path;
    DWSystemTakeover *run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check(!run.engaged,"nothing engaged at first");
    check([run engage:&note]&&run.engaged&&note.length,"engage switches them off and says so");
    check(!store.fileMissingAtWrite,"the snapshot file existed before the first write");
    check(allOff(store.values)&&[store.values[MARGINS]isEqual:@YES]&&store.values.count==6,"four keys off and the title-bar double-click None, the margins key untouched, no other key added");
    NSDictionary *held=fileAt(path);
    NSDictionary *saved=held[@"snapshot"];
    check([saved[ID(SM)]isEqual:@1]&&[saved[ID(EDGE)]isEqual:@YES]&&[saved[ID(OPT)]isEqual:@"yes"]&&[saved[ID(TOP)]isEqual:@"<absent>"]&&[saved[IDDC]isEqual:@"<absent>"]&&saved.count==5&&!saved[ID(MARGINS)],"the file holds the originals, the absent keys (also the double-click) as absent, and nothing of the margins key");
    check(([fm attributesOfItemAtPath:path error:NULL].filePosixPermissions&0077)==0,"the file is private to the user");
    NSArray *left=[fm contentsOfDirectoryAtPath:dir error:NULL];check(left.count==1,"no temporary file left beside it");

    // Idempotence: nothing is written, said or snapshotted twice.
    NSUInteger writes=store.writes;NSData *bytes=[NSData dataWithContentsOfFile:path];
    check([run engage:&note]&&note==nil&&store.writes==writes&&[[NSData dataWithContentsOfFile:path]isEqual:bytes],"a second engage changes nothing");
    check([run restore:&note]&&!run.engaged&&note.length,"restore puts them back and says so");
    check([store.values isEqual:mixed()]&&store.values[TOP]==nil&&store.values[DC]==nil,"the originals are back exactly, the absent keys (also the double-click) absent again");
    check(![fm fileExistsAtPath:path],"the file is gone once everything is back");
    writes=store.writes;
    check([run restore:&note]&&note==nil&&store.writes==writes,"a second restore changes nothing");
    check([run engage:&note]&&allOff(store.values)&&[run restore:&note]&&[store.values isEqual:mixed()],"a restored run can take over and restore again");

    // Keys that were already off, or all on: the same way back.
    store=[[IFStore alloc]initWithValues:@{SM:@NO,EDGE:@NO,TOP:@NO,OPT:@NO,DC:@"None"}];run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check([run engage:&note]&&store.writes==0&&[note containsString:@"already off"]&&[run restore:&note]&&allOff(store.values)&&![fm fileExistsAtPath:path],"settings that were already off are never written");
    store=[[IFStore alloc]initWithValues:allOn()];run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check([run engage:&note]&&allOff(store.values)&&[run restore:&note]&&[store.values isEqual:allOn()],"all on goes off and comes back");
    // The title-bar double-click in each shape a user has it: every action macOS offers comes back as it was, and "None" set by the user is never written.
    for(NSString *action in @[@"Maximize",@"Minimize",@"Fill"]){
        store=[[IFStore alloc]initWithValues:@{DC:action}];run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
        check([run engage:&note]&&[store.values[DC]isEqual:@"None"]&&[fileAt(path)[@"snapshot"][IDDC]isEqual:action]&&[run restore:&note]&&[store.values[DC]isEqual:action]&&![fm fileExistsAtPath:path],"the double-click action comes back as it was");
    }
    store=[[IFStore alloc]initWithValues:@{SM:@NO,EDGE:@NO,TOP:@NO,OPT:@NO}];run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check([run engage:&note]&&store.writes==1&&[store.values[DC]isEqual:@"None"]&&[run restore:&note]&&store.values[DC]==nil&&store.values.count==4,"an absent double-click is the only key written and is absent again");

    // A run that did not end: its file is still there. The next one puts the originals back first, takes over again keeping them, and a
    // second crash in a row cannot turn the off values into the user's.
    store=[[IFStore alloc]initWithValues:mixed()];
    DWSystemTakeover *crashed=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check([crashed engage:&note]&&allOff(store.values),"the run that is about to crash took over");
    NSDictionary *originals=fileAt(path);crashed=nil;
    DWSystemTakeover *next=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check([next restore:&note]&&[store.values isEqual:mixed()]&&![fm fileExistsAtPath:path]&&[note containsString:@"put back"],"a launch puts a leftover back");
    check(store.values[DC]==nil,"the double-click action a crash left at None is absent again, as it was");
    check([store.values[SM]isEqual:@1]&&CFGetTypeID((__bridge CFTypeRef)store.values[SM])!=CFBooleanGetTypeID()&&CFGetTypeID((__bridge CFTypeRef)store.values[EDGE])==CFBooleanGetTypeID(),"an integer comes back an integer and a bool a bool");
    // ...and the same when the launch goes straight to engage.
    crashed=nil;DWSystemTakeover *again=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];check([again engage:&note]&&allOff(store.values),"took over again");again=nil;
    next=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check([next engage:&note]&&allOff(store.values)&&[note containsString:@"earlier run"]&&[fileAt(path)[@"snapshot"]isEqual:originals[@"snapshot"]],"engage restores the leftover, then takes over with the same originals");
    check([next restore:&note]&&[store.values isEqual:mixed()],"the end gives the user's own values after two crashes");
    // The leftover cannot be put back (the store refuses): it stays, and it is what the next takeover keeps as the originals.
    crashed=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];check([crashed engage:&note],"crash again");crashed=nil;
    store.failAt=1;next=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check([next engage:&note]&&allOff(store.values)&&[fileAt(path)[@"snapshot"]isEqual:originals[@"snapshot"]]&&[note containsString:@"could not put back"],"a leftover that cannot be put back is kept as the originals");
    check([next restore:&note]&&[store.values isEqual:mixed()]&&![fm fileExistsAtPath:path],"and still gives them back at the end");

    // A write that is refused leaves nothing changed, whichever one it is, and no file behind.
    for(NSUInteger n=1;n<=5;n++){
        store=[[IFStore alloc]initWithValues:mixed()];store.failAt=n;run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
        check(![run engage:&note]&&!run.engaged&&note.length,"a refused write fails the takeover");
        check([store.values isEqual:mixed()]&&![fm fileExistsAtPath:path],"nothing changed and no file left after a refused write");
        check([run restore:&note]&&note==nil&&[store.values isEqual:mixed()],"restore after a failed takeover has nothing to do");
    }
    // The undo itself refused (every write from the third on): the file stays, so the next launch finishes the way back.
    store=[[IFStore alloc]initWithValues:mixed()];store.failAt=3;store.failFromThen=YES;run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check(![run engage:&note]&&[fm fileExistsAtPath:path],"an undo that fails keeps the file");
    store.failing=NO;next=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check([next restore:&note]&&[store.values isEqual:mixed()]&&![fm fileExistsAtPath:path],"the next launch finishes it");
    // A snapshot that cannot be saved: no key is written at all.
    NSString *blocked=[dir stringByAppendingPathComponent:@"a-file"];[@"x" writeToFile:blocked atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    store=[[IFStore alloc]initWithValues:mixed()];run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:[blocked stringByAppendingPathComponent:@"snapshot.plist"]];
    check(![run engage:&note]&&store.writes==0&&[store.values isEqual:mixed()]&&[note containsString:@"left as they are"],"no snapshot, no write");

    // What the user changes while the run is up is theirs: Stage Manager switched on again stays on, a key they removed stays removed.
    NSMutableDictionary *stageOff=[mixed() mutableCopy];stageOff[SM]=@NO;
    store=[[IFStore alloc]initWithValues:stageOff];run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];check([run engage:&note],"takeover");
    store.values[SM]=@YES;[store.values removeObjectForKey:OPT];
    check([run restore:&note]&&[store.values[SM]isEqual:@YES]&&store.values[OPT]==nil&&[store.values[EDGE]isEqual:@YES]&&[store.values[MARGINS]isEqual:@YES],"the user's own change is kept, the rest is put back");
    check([note containsString:@"left as you set them: GloballyEnabled, EnableTilingOptionAccelerator"]&&![fm fileExistsAtPath:path],"and said");
    // A restore that is refused keeps the file and the takeover, and a retry completes it.
    store=[[IFStore alloc]initWithValues:mixed()];run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];check([run engage:&note],"takeover");
    store.failAt=2;
    check(![run restore:&note]&&run.engaged&&[fm fileExistsAtPath:path]&&[note containsString:@"could not put back"],"a refused restore keeps the file");
    check([run restore:&note]&&!run.engaged&&[store.values isEqual:mixed()]&&![fm fileExistsAtPath:path],"and the retry puts everything back");

    // The user changes the double-click while the run is up: theirs, kept and named.
    store=[[IFStore alloc]initWithValues:allOn()];run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];check([run engage:&note],"takeover");
    store.values[DC]=@"Minimize";
    check([run restore:&note]&&[store.values[DC]isEqual:@"Minimize"]&&[store.values[SM]isEqual:@YES]&&[note containsString:@"left as you set them: AppleActionOnDoubleClick"],"a double-click action the user set meanwhile stays");
    // A snapshot an earlier build left (four keys, no double-click): the run restores those, then adds the double-click at its present value.
    store=[[IFStore alloc]initWithValues:mixed()];run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];check([run engage:&note],"takeover");
    NSMutableDictionary *old=[fileAt(path)mutableCopy];NSMutableDictionary *oldSnapshot=[old[@"snapshot"]mutableCopy];[oldSnapshot removeObjectForKey:IDDC];old[@"snapshot"]=oldSnapshot;
    [[NSPropertyListSerialization dataWithPropertyList:old format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL]writeToFile:path atomically:YES];
    store.values[DC]=nil;run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check([run engage:&note]&&allOff(store.values)&&[fileAt(path)[@"snapshot"][IDDC]isEqual:@"<absent>"]&&[fileAt(path)[@"snapshot"][ID(SM)]isEqual:@1],"an older four-key snapshot gains the double-click and keeps its originals");
    check([run restore:&note]&&[store.values isEqual:mixed()],"and gives everything back");

    // A file that is not a snapshot is moved aside, never trusted and never lost; the run takes over from the live values.
    [@"not a property list" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    store=[[IFStore alloc]initWithValues:mixed()];run=[[DWSystemTakeover alloc]initWithStore:store snapshotPath:path];
    check([run engage:&note]&&allOff(store.values)&&[fm fileExistsAtPath:[path stringByAppendingString:@".unreadable"]]&&[fileAt(path)[@"snapshot"][ID(SM)]isEqual:@1],"an unreadable file is set aside");
    check([run restore:&note]&&[store.values isEqual:mixed()],"and the run still restores its own originals");

    [fm removeItemAtPath:dir error:NULL];
    printf("system-takeover regression: %lu checks passed\n",(unsigned long)checks);
    return 0;
} }
