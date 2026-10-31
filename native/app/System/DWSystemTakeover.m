// SPDX-License-Identifier: GPL-3.0-or-later
// Translated, function by function, from Sunlight, repository https://github.com/spacefarm-digital/sunlight, commit
// afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright (c) 2026 spacefarm; license text: native/app/Resources/SUNLIGHT-NOTICE.txt).
// Swift to Objective-C, names kept where they carry over. Line ranges are those of the upstream files at that commit.
//
// Sources/Canvas/Takeover/SystemPrefs.swift
//    8-14  struct Pref                  -> DWPref
//   19     absent                       -> kAbsent
//   21-45  managed                      -> managed()
//   52-54  current(_:)                  -> -current:
//   56-64  snapshot(adding:)            -> -snapshotAdding:
//   66-70  apply()                      -> -applyPrefs:failed:
//   90-98  revert(snapshot:)            -> -revertSnapshot:restored:kept:failed:
//  100-108 write(_:)                    -> -write:stopAtFailure:written:failed:, and DWCFPrefs -setValue:ofPref:
//  110-116 equal(_:_:)                  -> equalValues()
// Sources/Canvas/Takeover/TakeoverMode.swift
//   26-31  Keys.applied, Keys.snapshot  -> the snapshot file: that it exists is `applied`, what it holds is the snapshot
//   63-78  startup(), the leftover      -> main()'s -restore: at launch, and the first step of -engage:
//          branch (75-78)
//  125-152 apply()                      -> -engage:
//  175-194 revert(reason:) and          -> -restore:
//  222-232 revertPrefs(restarting:)
// Not translated: Sunlight's Dock, Finder and widget rows (SystemPrefs.swift 21-45), `retired`, `retiredInSnapshot` and
// `restore(_:)` (47-91), `restart(domains:)` (118-132: WindowManager follows these keys live, so nothing is restarted),
// `describeCurrent()` (134-139), and everything in TakeoverMode.swift that is not preferences (consent, key tap, foreground
// watcher, login item, `--release`, one-instance handling; Infinify's own lease and login item do those).
//
// Deviations, all deliberate:
// - `managed` holds the four com.apple.WindowManager keys at false. EnableTiledWindowMargins stays alone: it only sets the gap
//   between tiled windows, and no window is tiled.
// - A fifth row is Infinify's own: NSGlobalDomain AppleActionOnDoubleClick at "None". The title-bar double-click zooms or fills
//   the native frame, which the canvas does not draw: the window jumps to the display while its drawn copy stays put. An
//   application reads the key once, at launch (HIToolbox keeps it in a static), so running ones are told afterwards: every write
//   of it posts the distributed notification System Settings' appearance pane posts, which makes AppKit applications read it
//   again (DWCFPrefs -setValue:ofPref:; measured in the guest, docs/native/user-guide.md "Desktop mode").
// - The snapshot is a file, written atomically before the first write (Sunlight: UserDefaults `takeover.snapshot`, 135-137).
// - `write` reads every value back, and `apply` stops at the first one that did not stick and is all or nothing: what was
//   written is put back (Sunlight writes and moves on).
// - `revert(snapshot:)` puts an original back only where the key still holds `desired`: a key the user changed while the run
//   was up is theirs (Sunlight overwrites it).
// - A leftover is put back at launch and again at the start of `apply`, and `apply` keeps the leftover's snapshot when some key
//   could not be put back (Sunlight applies over it keeping the snapshot, 129-138, without putting it back first).
// - Like Sunlight, a stored string "<absent>" cannot be told from an absent key; no WindowManager key holds a string.
// The regression (DWSystemTakeoverTests.m) drives this file with an in-memory store; the guest runs recorded in
// docs/native/user-guide.md ("Desktop mode") are what show WindowManager following the real keys.
#import "DWSystemTakeover.h"
#import "DWOwnerFile.h"
#include <unistd.h>

static NSString *const kDomain=@"com.apple.WindowManager";
// What `defaults -g` calls the global domain; CFPreferences names it kCFPreferencesAnyApplication (DWCFPrefs maps it).
static NSString *const kGlobalDomain=@"NSGlobalDomain";
static NSString *const kDoubleClickKey=@"AppleActionOnDoubleClick"; // "Maximize" (Zoom), "Fill", "Minimize" or "None"; absent is macOS's own default
static NSString *const kAbsent=@"<absent>"; // SystemPrefs.swift:19

@interface DWPref ()
- (instancetype)initWithDomain:(NSString *)domain key:(NSString *)key desired:(id)desired;
@end
@implementation DWPref // SystemPrefs.swift:8-14
- (instancetype)initWithDomain:(NSString *)domain key:(NSString *)key desired:(id)desired {
    if((self=[super init])){_domain=[domain copy];_key=[key copy];_desired=desired;}return self;
}
- (NSString *)identifier { return [NSString stringWithFormat:@"%@|%@",_domain,_key]; }
@end

// SystemPrefs.swift:21-45, in the order the keys are written and reported. The last row is Infinify's own (Sunlight has none):
// the title-bar double-click, which acts on the native frame the canvas does not draw.
static NSArray<DWPref *> *managed(void) {
    static NSArray<DWPref *> *rows;static dispatch_once_t once;
    dispatch_once(&once,^{NSMutableArray *list=[NSMutableArray array];
        for(NSString *key in @[@"GloballyEnabled",@"EnableTilingByEdgeDrag",@"EnableTopTilingByEdgeDrag",@"EnableTilingOptionAccelerator"])
            [list addObject:[[DWPref alloc]initWithDomain:kDomain key:key desired:@NO]];
        [list addObject:[[DWPref alloc]initWithDomain:kGlobalDomain key:kDoubleClickKey desired:@"None"]];
        rows=list;});
    return rows;
}

// SystemPrefs.swift:110-116
static BOOL equalValues(id a,id b) {
    if(!a&&!b)return YES;
    if(a&&b)return [a isEqual:b];
    return NO;
}

static CFStringRef cfDomain(DWPref *pref) { return [pref.domain isEqual:kGlobalDomain]?kCFPreferencesAnyApplication:(__bridge CFStringRef)pref.domain; }

// Applications read the double-click key once, at launch; this is what makes the running ones read it again (TextEdit, Finder and
// Chrome in the guest; no other notification tried did). Name of a notification AppKit listens for, not of ours.
static NSString *const kReloadNote=@"AppleNoRedisplayAppearancePreferenceChanged";

@implementation DWCFPrefs
// SystemPrefs.current (52-54), after a synchronize so a value another process just wrote is seen.
// The global domain is read from the user's own store, not through CFPreferencesCopyAppValue: once AppKit is loaded that call answers
// with AppKit's registered default ("Maximize" for the double-click) for a key the user never set, so an absent key would be saved as
// "Maximize" and written back as one (measured in the guest). A forced (managed) value is told apart by -setValue:ofPref:.
- (id)valueOfPref:(DWPref *)pref {
    CFStringRef domain=cfDomain(pref);CFPreferencesAppSynchronize(domain);
    if([pref.domain isEqual:kGlobalDomain])return CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)pref.key,domain,kCFPreferencesCurrentUser,kCFPreferencesAnyHost));
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)pref.key,domain));
}
// The body of SystemPrefs.write (100-108) for one pref, then the read-back: a managed (forced) preference, or any store that
// did not take the value, reads back as it was and is refused.
- (BOOL)setValue:(id)value ofPref:(DWPref *)pref {
    CFStringRef domain=cfDomain(pref);
    CFPreferencesSetAppValue((__bridge CFStringRef)pref.key,(__bridge CFPropertyListRef)value,domain);CFPreferencesAppSynchronize(domain);
    BOOL global=[pref.domain isEqual:kGlobalDomain];
    BOOL stuck=equalValues([self valueOfPref:pref],value)&&!(global&&CFPreferencesAppValueIsForced((__bridge CFStringRef)pref.key,domain));
    if(stuck&&global)[NSDistributedNotificationCenter.defaultCenter postNotificationName:kReloadNote object:nil userInfo:nil deliverImmediately:YES];
    return stuck;
}
@end

BOOL DWStageManagerOn(void) {
    CFStringRef domain=(__bridge CFStringRef)kDomain;CFPreferencesAppSynchronize(domain);
    Boolean known=false,on=CFPreferencesGetAppBooleanValue(CFSTR("GloballyEnabled"),domain,&known);return known&&on;
}
NSString *const DWStageManagerNote=@"Stage Manager is on: every window outside the current stage is a thumbnail in its strip, so it shows here blurred and still and cannot be clicked. Turn it off in Control Centre or in System Settings under Desktop & Dock.";
NSString *const DWStageManagerBackNote=@"Stage Manager was switched on again while Infinify runs: every window outside the current stage is a thumbnail in its strip, so it shows here blurred and still and cannot be clicked. Infinify leaves it on, as you set it, and keeps it on when it ends.";

// "GloballyEnabled=0 EnableTilingByEdgeDrag=absent": the snapshot's value of each pref named.
static NSString *listed(NSDictionary *snapshot,NSArray<DWPref *> *prefs) {
    NSMutableArray *parts=[NSMutableArray array];
    for(DWPref *p in prefs){id saved=snapshot[p.identifier];[parts addObject:[NSString stringWithFormat:@"%@=%@",p.key,saved?:kAbsent]];}
    return [parts componentsJoinedByString:@" "];
}
static NSString *named(NSArray<DWPref *> *prefs) {
    NSMutableArray *keys=[NSMutableArray array];for(DWPref *p in prefs)[keys addObject:p.key];return [keys componentsJoinedByString:@", "];
}
// Written aside, flushed, then renamed over the file (DWOwnerFile.h): a crash at any point leaves the old file or the whole new one.
static BOOL writeAtomically(NSData *data,NSString *path) {
    if(![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:NULL])return NO;
    return DWOwnerFileWrite(path,data);
}

@implementation DWSystemTakeover {
    id<DWPrefsStore> _store;
    NSString *_path;
    NSDictionary *_snapshot; // what the file holds while this object is engaged (TakeoverMode.isRunning)
}
+ (instancetype)system {
    return [[self alloc]initWithStore:[DWCFPrefs new] snapshotPath:[DWSupportDirectory() stringByAppendingPathComponent:@"window-prefs-snapshot.plist"]];
}
- (instancetype)initWithStore:(id<DWPrefsStore>)store snapshotPath:(NSString *)path {
    if((self=[super init])){_store=store;_path=[path copy];}return self;
}
- (BOOL)engaged { return _snapshot!=nil; }

- (id)current:(DWPref *)p { return [_store valueOfPref:p]; }

// SystemPrefs.snapshot(adding:), 56-64: the current value of every managed pref not already in `existing`, so a snapshot that is
// already there keeps the user's originals and is never re-taken over our own values.
- (NSDictionary *)snapshotAdding:(NSDictionary *)existing {
    NSMutableDictionary *s=[existing mutableCopy]?:[NSMutableDictionary dictionary];
    for(DWPref *p in managed())if(!s[p.identifier])s[p.identifier]=[self current:p]?:kAbsent;
    return s;
}

// SystemPrefs.write, 100-108: every target (a pref and its value, NSNull for absent) that differs from what is there. Sunlight goes
// through all of them; `stop` ends at the first one the store refuses, which -applyPrefs wants and a restore does not.
- (BOOL)write:(NSArray<NSArray *> *)targets stopAtFailure:(BOOL)stop written:(NSMutableArray<DWPref *> *)written failed:(NSMutableArray<DWPref *> *)failed {
    for(NSArray *target in targets){
        DWPref *p=target[0];id value=[target[1]isEqual:NSNull.null]?nil:target[1];
        if(equalValues([self current:p],value))continue;
        if([_store setValue:value ofPref:p])[written addObject:p];
        else{[failed addObject:p];if(stop)return NO;}
    }
    return failed.count==0;
}

// SystemPrefs.apply, 66-70: every managed pref at its takeover value.
- (BOOL)applyPrefs:(NSMutableArray<DWPref *> *)written failed:(NSMutableArray<DWPref *> *)failed {
    NSMutableArray *targets=[NSMutableArray array];for(DWPref *p in managed())[targets addObject:@[p,p.desired]];
    return [self write:targets stopAtFailure:YES written:written failed:failed];
}

// SystemPrefs.revert(snapshot:), 90-98: what the snapshot recorded goes back, an absent key removed and not defaulted. Only where
// the pref still holds the takeover value (deviation): any other value is the user's, and is listed in `kept` when it is not
// simply their original again.
- (BOOL)revertSnapshot:(NSDictionary *)snapshot restored:(NSMutableArray<DWPref *> *)restored kept:(NSMutableArray<DWPref *> *)kept failed:(NSMutableArray<DWPref *> *)failed {
    NSMutableArray *targets=[NSMutableArray array];
    for(DWPref *p in managed()){
        id saved=snapshot[p.identifier];if(!saved)continue;
        id original=([saved isKindOfClass:NSString.class]&&[saved isEqual:kAbsent])?nil:saved,now=[self current:p];
        if(!equalValues(now,p.desired)){if(!equalValues(now,original))[kept addObject:p];continue;}
        [targets addObject:@[p,original?:NSNull.null]];
    }
    // One at a time: a key the store refuses must not keep the others from coming back.
    for(NSArray *target in targets)[self write:@[target] stopAtFailure:NO written:restored failed:failed];
    return failed.count==0;
}

// TakeoverMode.swift:26-31 as a file. nil when there is none, or when it is not a snapshot: that one is moved aside, not deleted,
// since it can say what happened and nothing can be put back from it.
- (NSDictionary *)loadStored {
    NSData *data=[NSData dataWithContentsOfFile:_path];if(!data)return nil;
    id plist=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    NSDictionary *file=[plist isKindOfClass:NSDictionary.class]?plist:nil,*snapshot=file[@"snapshot"];
    BOOL whole=[file[@"version"]isEqual:@1]&&[snapshot isKindOfClass:NSDictionary.class];
    if(whole)for(id key in snapshot)if(![key isKindOfClass:NSString.class])whole=NO;
    if(!whole){rename(_path.fileSystemRepresentation,[_path stringByAppendingString:@".unreadable"].fileSystemRepresentation);return nil;}
    return snapshot;
}
- (BOOL)save:(NSDictionary *)snapshot {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:@{@"version":@1,@"snapshot":snapshot} format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    return data&&writeAtomically(data,_path);
}
- (void)removeFile { unlink(_path.fileSystemRepresentation); }

// TakeoverMode.apply, 125-152.
- (BOOL)engage:(NSString **)note {
    if(note)*note=nil;if(_snapshot)return YES; // 126
    NSMutableArray<NSString *> *lines=[NSMutableArray array];
    // 75-78: a record an earlier run left is put back first, so the system is the user's own again before it is taken over once more.
    NSDictionary *stored=[self loadStored],*leftover=stored;BOOL applied=stored!=nil; // 129, 131-132
    if(leftover){
        NSMutableArray *restored=[NSMutableArray array],*kept=[NSMutableArray array],*failed=[NSMutableArray array];
        if([self revertSnapshot:leftover restored:restored kept:kept failed:failed]){[self removeFile];stored=nil;applied=NO;}
        NSString *keptText=kept.count?[@"; left as you set them: " stringByAppendingString:named(kept)]:@"";
        if(failed.count)[lines addObject:[NSString stringWithFormat:@"Infinify: could not put back %@ left by an earlier run; its saved originals are kept and tried again at the end (%@)",named(failed),listed(leftover,failed)]];
        else if(restored.count||kept.count)[lines addObject:[NSString stringWithFormat:@"Infinify: put back the window settings an earlier run left changed (%@)%@",listed(leftover,restored),keptText]];
    }
    // 127-138: snapshot before anything is touched; an existing snapshot only gains the prefs added since, and is persisted before the first write.
    NSDictionary *snapshot=[self snapshotAdding:stored];
    if(!applied||snapshot.count!=stored.count){
        if(![self save:snapshot]){[lines addObject:@"Infinify: could not save the window settings first, so Stage Manager, window tiling and the title-bar double-click were left as they are"];if(note)*note=[lines componentsJoinedByString:@"\n"];return NO;}
    }
    NSMutableArray<DWPref *> *written=[NSMutableArray array],*failed=[NSMutableArray array];
    if(![self applyPrefs:written failed:failed]){
        // All or nothing: what was written goes back, and a file this call made goes with it. One that did not come back stays.
        BOOL back=YES;
        for(DWPref *p in written.reverseObjectEnumerator){id saved=snapshot[p.identifier],original=([saved isKindOfClass:NSString.class]&&[saved isEqual:kAbsent])?nil:saved;back=[_store setValue:original ofPref:p]&&back;}
        if(back&&!applied)[self removeFile];
        [lines addObject:[NSString stringWithFormat:@"Infinify: could not switch off %@, so Stage Manager, window tiling and the title-bar double-click were left as they were%@",named(failed),back?@"":@" (some could not be put back; the saved originals are restored at the next launch)"]];
        if(note)*note=[lines componentsJoinedByString:@"\n"];return NO;
    }
    _snapshot=snapshot;
    [lines addObject:written.count?[NSString stringWithFormat:@"Infinify: Stage Manager, window tiling and the title-bar double-click are off while it runs (were: %@); they go back when it ends",listed(snapshot,managed())]
        :@"Infinify: Stage Manager, window tiling and the title-bar double-click were already off; nothing was changed"]; // 151
    if(note)*note=[lines componentsJoinedByString:@"\n"];return YES;
}

// TakeoverMode.revert(reason:) 175-194 over revertPrefs 222-232: guard applied (224), revert the snapshot (226), drop it (228-229).
- (BOOL)restore:(NSString **)note {
    if(note)*note=nil;
    NSDictionary *snapshot=_snapshot?:[self loadStored];if(!snapshot)return YES;
    NSMutableArray *restored=[NSMutableArray array],*kept=[NSMutableArray array],*failed=[NSMutableArray array];
    BOOL ok=[self revertSnapshot:snapshot restored:restored kept:kept failed:failed];
    if(ok){[self removeFile];_snapshot=nil;}
    NSString *keptText=kept.count?[@"; left as you set them: " stringByAppendingString:named(kept)]:@"";
    if(note)*note=ok?[NSString stringWithFormat:@"Infinify: put back Stage Manager, window tiling and the title-bar double-click (%@)%@",listed(snapshot,managed()),keptText]
        :[NSString stringWithFormat:@"Infinify: could not put back %@; the saved originals stay and are restored at the next launch",named(failed)];
    return ok;
}
@end
