// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from yabai (https://github.com/asmvik/yabai) dd845723416f5fe92af49fad5ebab00369e07edd (MIT, Copyright (c) 2019 Åsmund
// Vikane; the licence text is native/app/Resources/YABAI-NOTICE.txt): src/workspace.m, src/application.h, src/application.c, src/window.h, src/window.c
// (window_observe, window_unobserve), src/event_loop.c and src/window_manager.c, as DWWindowEvents.h says of each. Where this
// differs from yabai is said where it does.
// Adapted from Sunlight (https://github.com/spacefarm-digital/sunlight) afeea74b18e70ca49bf462d6fe462cf65deb2b32 (MIT, Copyright
// (c) 2026 spacefarm; the licence text is native/app/Resources/SUNLIGHT-NOTICE.txt):
// Sources/Canvas/RealWindows/WindowServerEvents.swift (the window-server events 1325/1326, their payload, main-thread delivery once an
// NSApplication exists).
// DWWindowEvents: the application catalog, its scan and reads, the NSWorkspace notices.
// Split from native/desktop/window-events.m at 37b27b1, moved verbatim.
#import "DWWindowEvents+Private.h"
@implementation DWWindowEvents (Applications)
- (DWApplicationWatch *)watchApplication:(NSRunningApplication *)running {
    if(self.stopped||!self.trusted||!running)return nil;
    DWApplicationWatch *record=[self.applicationWatches objectForKey:running];if(record)return record;
    record=[[DWApplicationWatch alloc]initWithRunning:running];__weak DWWindowEvents *weak=self;
    record.changed=^(DWApplicationWatch *changed){DWWindowEvents *events=weak;if(!events||events.stopped||!events.trusted||[events.applicationWatches objectForKey:changed.running]!=changed)return;
        changed.pending=YES;changed.retry=NO;[events queueApplicationRead];};
    [self.applicationWatches setObject:record forKey:running];self.catalogRevision++;return record;
}
- (void)forgetApplication:(DWApplicationWatch *)record ended:(BOOL)ended {
    if(!record||[self.applicationWatches objectForKey:record.running]!=record)return;
    [record invalidate];[self.applicationWatches removeObjectForKey:record.running];self.catalogRevision++;
    DWObservedApplication *application=self.applications[@(record.pid)];
    if(application.running==record.running)[self remove:record.pid ended:ended];
}
- (void)clearApplicationWatches {
    if([self.sink respondsToSelector:@selector(windowCreationInvalidated:)])[self.sink windowCreationInvalidated:0];
    self.observationEpoch++;self.catalogRevision++;self.hasApplicationCatalog=NO;
    [self.applicationCatalogWatch invalidate];self.applicationCatalogWatch=nil;self.appliedCatalogRevision=0;self.applicationCatalogDirty=NO;
    for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator)[record invalidate];
    [self.applicationWatches removeAllObjects];[self.applicationNotices removeAllObjects];
}
- (void)observeApplicationCatalog {
    if(self.applicationCatalogWatch||self.stopped||!self.trusted)return;
    DWApplicationCatalogWatch *watch=[[DWApplicationCatalogWatch alloc]initWithWorkspace:NSWorkspace.sharedWorkspace];__weak DWWindowEvents *weak=self;
    watch.changed=^(DWApplicationCatalogWatch *changed){DWWindowEvents *events=weak;if(!events||events.stopped||!events.trusted||events.applicationCatalogWatch!=changed)return;
        if(events.appliedCatalogRevision!=changed.revision){events.applicationCatalogDirty=YES;[events scanApplications];}
    };
    self.applicationCatalogWatch=watch;self.applicationCatalogDirty=YES;
}
- (void)reconcileApplications:(NSArray<NSRunningApplication *> *)running {
    self.hasApplicationCatalog=YES;
    NSHashTable *current=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality|NSPointerFunctionsStrongMemory];
    for(NSRunningApplication *application in running)[current addObject:application];
    for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator.allObjects)if(![current containsObject:record.running])[self forgetApplication:record ended:NO];
    for(NSRunningApplication *application in running)[self watchApplication:application];
    [self queueApplicationRead];
}
- (NSArray<DWApplicationMetadata *> *)applicationCatalogBindings {
    NSMutableArray<DWApplicationMetadata *> *bindings=[NSMutableArray array];
    for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator){
        DWApplicationMetadata *binding=[DWApplicationMetadata new];binding.watch=record;binding.revision=record.revision;binding.pid=record.pid;
        binding.seconds=record.boundSeconds;binding.microseconds=record.boundMicroseconds;
        binding.born=record.boundIdentityRevision==record.identityRevision&&record.boundPID==record.pid&&record.boundIdentityRevision!=0;
        [bindings addObject:binding];
    }return bindings;
}
- (BOOL)applicationBindingsCurrent:(NSArray<DWApplicationMetadata *> *)bindings {
    for(DWApplicationMetadata *binding in bindings)if([self.applicationWatches objectForKey:binding.watch.running]!=binding.watch||![binding.watch matches:binding.revision])return NO;
    return YES;
}
// NSRunningApplication.h tells callers to compare applications with isEqual:, not PID. runningApplications returns
// fresh wrappers in practice: pointer-only membership recreated all observers every second (2026-10-12 idle profile).
// Hashes are temporary numeric buckets, built off main on every pass; no mutable NSRunningApplication hash is a durable
// dictionary key. A semantic match is only a candidate: its exact record revision and kernel birth still have to agree.
static NSArray<DWApplicationMetadata *> *canonicalApplications(NSArray<NSRunningApplication *> *running,NSArray<DWApplicationMetadata *> *known) {
    NSMutableDictionary<NSNumber *,NSMutableArray<DWApplicationMetadata *> *> *buckets=[NSMutableDictionary dictionary];
    for(DWApplicationMetadata *binding in known)if([binding.watch matches:binding.revision]){
        NSNumber *hash=@(binding.watch.running.hash);if(!buckets[hash])buckets[hash]=[NSMutableArray array];[buckets[hash]addObject:binding];
    }
    NSMutableArray<DWApplicationMetadata *> *result=[NSMutableArray arrayWithCapacity:running.count];
    for(NSRunningApplication *application in running){
        DWApplicationMetadata *entry=[DWApplicationMetadata new];entry.running=application;
        for(DWApplicationMetadata *binding in buckets[@(application.hash)])if([binding.watch.running isEqual:application]&&[binding.watch matches:binding.revision]){
            entry.watch=binding.watch;entry.revision=binding.revision;entry.pid=binding.pid;entry.seconds=binding.seconds;entry.microseconds=binding.microseconds;
            uint64_t seconds=0,microseconds=0;
            entry.born=binding.born&&binding.pid>0&&dw_focus_birth(binding.pid,&seconds,&microseconds)&&seconds==binding.seconds&&microseconds==binding.microseconds;
            break;
        }
        [result addObject:entry];
    }return result;
}
- (BOOL)acceptApplicationCatalog:(NSArray<DWApplicationMetadata *> *)catalog {
    NSMutableArray<NSRunningApplication *> *running=[NSMutableArray arrayWithCapacity:catalog.count];
    for(DWApplicationMetadata *entry in catalog){DWApplicationWatch *record=entry.watch;BOOL current=record&&[self.applicationWatches objectForKey:record.running]==record&&[record matches:entry.revision];
        if(record&&!current){[self queueApplicationRead];return NO;}
        uint64_t seconds=0,microseconds=0;
        // An application without a PID has no native admission. Keep its semantic watcher so a later PID KVO can discover
        // it. Every positive PID, including accessory/out-of-scope applications, carries independently checked birth.
        BOOL born=current&&(entry.pid<=0||(entry.born&&dw_focus_birth(entry.pid,&seconds,&microseconds)&&seconds==entry.seconds&&microseconds==entry.microseconds));
        if(current){
            // Equality names the same application identity, even if the kernel fence now fails. Pointer freshness must
            // not give that identity a new birth affinity. Keep its observer, retire stale AX admission, and reread it.
            [running addObject:record.running];
            if(!born){record.pending=YES;DWObservedApplication *application=self.applications[@(record.pid)];
                if(application.running==record.running){record.retry=YES;[self remove:record.pid ended:NO];[self changed:0 pid:record.pid];}
            }
        }else [running addObject:entry.running];
    }
    [self reconcileApplications:running];return YES;
}
- (void)scanApplications {
    if(self.scanning||self.stopped||!self.trusted||!self.applicationCatalogDirty)return;
    DWApplicationCatalogWatch *watch=self.applicationCatalogWatch;if(!watch)return;
    self.scanning=YES;self.applicationCatalogDirty=NO;uint64_t epoch=self.observationEpoch,revision=self.catalogRevision,collectionRevision=watch.revision;__weak DWWindowEvents *weak=self;
    NSArray<DWApplicationMetadata *> *known=[self applicationCatalogBindings];
    dispatch_async(applicationWorker(),^{@autoreleasepool {
        NSArray<DWApplicationMetadata *> *running=[watch matches:collectionRevision]?canonicalApplications(watch.workspace.runningApplications,known):nil;
        dispatch_async(dispatch_get_main_queue(),^{DWWindowEvents *events=weak;if(!events)return;events.scanning=NO;
            if(events.stopped||!events.trusted)return;
            // A notification arriving during a read must produce a successor read without waiting for another event.
            BOOL current=events.observationEpoch==epoch&&events.applicationCatalogWatch==watch&&[watch matches:collectionRevision]&&events.catalogRevision==revision&&[events applicationBindingsCurrent:known];
            BOOL accepted=current&&[events acceptApplicationCatalog:running];
            if(accepted)events.appliedCatalogRevision=collectionRevision;
            events.applicationCatalogDirty=!accepted||![watch matches:collectionRevision];
            [events scanApplications];
        });
    }});
}
- (void)queueApplicationRead {
    if(self.stopped||!self.trusted||self.readingApplications||self.applicationReadQueued)return;
    BOOL pending=NO;for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator)if(record.pending){pending=YES;break;}if(!pending)return;
    self.applicationReadQueued=YES;__weak DWWindowEvents *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{DWWindowEvents *events=weak;if(!events)return;events.applicationReadQueued=NO;[events readApplications];});
}
- (void)readApplications {
    if(self.stopped||!self.trusted||self.readingApplications)return;
    NSMutableArray<DWApplicationMetadata *> *reads=[NSMutableArray array];
    for(DWApplicationWatch *record in self.applicationWatches.objectEnumerator)if(record.pending){record.pending=NO;
        DWApplicationMetadata *read=[DWApplicationMetadata new];read.watch=record;read.revision=record.revision;read.identityRevision=record.identityRevision;[reads addObject:read];}
    if(!reads.count)return;self.readingApplications=YES;uint64_t epoch=self.observationEpoch;__weak DWWindowEvents *weak=self;
    // One batch at a time, with one latest pending bit per live object. A notification storm cannot enqueue unbounded reads.
    dispatch_async(applicationWorker(),^{@autoreleasepool {
        for(DWApplicationMetadata *read in reads)if([read.watch matches:read.revision]){
            NSRunningApplication *running=read.watch.running;read.pid=running.processIdentifier;read.terminated=running.terminated;read.regular=running.activationPolicy==NSApplicationActivationPolicyRegular;
            uint64_t seconds=0,microseconds=0;read.born=read.pid>0&&!read.terminated&&dw_focus_birth(read.pid,&seconds,&microseconds);read.seconds=seconds;read.microseconds=microseconds;
        }
        dispatch_async(dispatch_get_main_queue(),^{DWWindowEvents *events=weak;if(!events)return;events.readingApplications=NO;
            if(!events.stopped&&events.trusted&&events.observationEpoch==epoch)for(DWApplicationMetadata *read in reads)[events acceptApplication:read];
            [events queueApplicationRead];
        });
    }});
}
- (void)acceptApplication:(DWApplicationMetadata *)read {
    DWApplicationWatch *record=read.watch;if([self.applicationWatches objectForKey:record.running]!=record)return;
    if(![record matches:read.revision]){record.pending=YES;return;}
    uint64_t seconds=0,microseconds=0;BOOL eligible=read.pid>0&&read.pid!=getpid()&&!read.terminated&&read.regular&&(!self.scope||self.scope[@(read.pid)]);
    // A failed worker/main identity fence cannot be repaired by silently assigning this unchanged object/PID a new
    // kernel birth on the next poll. Only a different application identity/PID, or an observed PID/termination lifecycle change, can
    // establish a new binding. Policy changes alone never do so.
    BOOL identity=YES;
    if(read.born){
        if(record.boundIdentityRevision!=read.identityRevision||record.boundPID!=read.pid){record.boundIdentityRevision=read.identityRevision;record.boundPID=read.pid;record.boundSeconds=read.seconds;record.boundMicroseconds=read.microseconds;}
        else identity=record.boundSeconds==read.seconds&&record.boundMicroseconds==read.microseconds;
    }
    // Metadata is discovery only. Admission rechecks the kernel birth now, as well as the caller's exact PID scope.
    BOOL born=eligible&&identity&&read.born&&dw_focus_birth(read.pid,&seconds,&microseconds)&&seconds==read.seconds&&microseconds==read.microseconds;
    BOOL admitted=born&&DWInScope(self.scope,read.pid);
    if(![record matches:read.revision]){record.pending=YES;return;}
    DWObservedApplication *old=self.applications[@(record.pid)];
    if(old.running==record.running&&(!born||old.pid!=read.pid||old.seconds!=seconds||old.microseconds!=microseconds)){
        [self remove:old.pid ended:read.terminated];[self changed:0 pid:old.pid];
    }
    record.pid=read.pid;record.retry=eligible&&!born;
    if(admitted){
        DWObservedApplication *application=self.applications[@(read.pid)];
        if(application&&application.running!=record.running){[self forgetApplication:[self.applicationWatches objectForKey:application.running] ended:NO];[self remove:read.pid ended:NO];application=nil;}
        if(!application){application=[DWObservedApplication new];application.pid=read.pid;application.seconds=seconds;application.microseconds=microseconds;
            application.running=record.running;application.events=self;application.contexts=[NSMutableArray array];
            application.windows=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);application.asked=CFSetCreateMutable(NULL,0,&kCFTypeSetCallBacks);
            self.applications[@(read.pid)]=application;[self observe:application];[self changed:appeared pid:read.pid];
        }else if(record.hints&applicationActivated)[self list:application];
    }
    NSUInteger hints=record.hints;record.hints=0;
    if(read.pid>0){if(hints&applicationAppeared)[self changed:appeared pid:read.pid];if(hints&applicationChanged)[self changed:0 pid:read.pid];}
}
// yabai's process manager has launch, end and front switch from Carbon; NSWorkspace says the same.
- (void)applyApplicationNotice:(DWApplicationMetadata *)notice {
    DWApplicationWatch *record=notice.watch;
    if(record&&([self.applicationWatches objectForKey:record.running]!=record||![record matches:notice.revision])){[self changed:appeared pid:0];return;}
    if(!record)record=[self watchApplication:notice.running];
    if(!record){[self changed:appeared pid:0];return;}
    record.hints|=notice.hints;
    if(notice.identityNotice)[record invalidateIdentityMetadata];else [record invalidateMetadata];
}
- (void)queueApplicationNotices {
    if(self.stopped||!self.trusted||self.resolvingApplicationNotices||self.applicationNoticeQueued||!self.applicationNotices.count)return;
    self.applicationNoticeQueued=YES;__weak DWWindowEvents *weak=self;
    dispatch_async(dispatch_get_main_queue(),^{DWWindowEvents *events=weak;if(!events)return;events.applicationNoticeQueued=NO;[events resolveApplicationNotices];});
}
- (void)resolveApplicationNotices {
    if(self.stopped||!self.trusted||self.resolvingApplicationNotices||!self.applicationNotices.count)return;
    self.resolvingApplicationNotices=YES;NSArray<DWApplicationMetadata *> *notices=self.applicationNotices.copy;[self.applicationNotices removeAllObjects];
    NSArray<DWApplicationMetadata *> *known=[self applicationCatalogBindings];uint64_t epoch=self.observationEpoch,revision=self.catalogRevision;__weak DWWindowEvents *weak=self;
    dispatch_async(applicationWorker(),^{@autoreleasepool {
        // Workspace notifications can contain fresh wrappers too. Coalesce equality on the worker; main uses only
        // exact object pointers. At most 64 notices wait here and 64 more wait for this single batch to finish.
        NSMutableDictionary<NSNumber *,NSMutableArray<DWApplicationMetadata *> *> *buckets=[NSMutableDictionary dictionary];
        NSMutableArray<DWApplicationMetadata *> *unique=[NSMutableArray array];NSMutableArray<NSRunningApplication *> *running=[NSMutableArray array];
        for(DWApplicationMetadata *notice in notices){NSNumber *hash=@(notice.running.hash);DWApplicationMetadata *same=nil;
            for(DWApplicationMetadata *prior in buckets[hash])if([prior.running isEqual:notice.running]){same=prior;break;}
            if(same){same.hints|=notice.hints;same.identityNotice|=notice.identityNotice;}
            else {if(!buckets[hash])buckets[hash]=[NSMutableArray array];[buckets[hash]addObject:notice];[unique addObject:notice];[running addObject:notice.running];}
        }
        NSArray<DWApplicationMetadata *> *resolved=canonicalApplications(running,known);
        for(NSUInteger i=0;i<resolved.count;i++){resolved[i].hints=unique[i].hints;resolved[i].identityNotice=unique[i].identityNotice;}
        dispatch_async(dispatch_get_main_queue(),^{DWWindowEvents *events=weak;if(!events)return;events.resolvingApplicationNotices=NO;
            if(!events.stopped&&events.trusted&&events.observationEpoch==epoch){
                if(events.catalogRevision==revision&&[events applicationBindingsCurrent:known])for(DWApplicationMetadata *notice in resolved)[events applyApplicationNotice:notice];
                else [events changed:appeared pid:0]; // A newer identity/catalog wins; the global hint still discovers windows.
            }
            [events queueApplicationNotices];
        });
    }});
}
- (void)applicationNotification:(NSNotification *)note hints:(NSUInteger)hints identity:(BOOL)identity {
    NSRunningApplication *running=note.userInfo[NSWorkspaceApplicationKey];if(self.stopped||!running)return;
    if(!self.trusted){[self changed:appeared pid:0];return;}
    DWApplicationWatch *record=[self.applicationWatches objectForKey:running];
    if((identity||(hints&(applicationAppeared|applicationChanged)))&&[self.sink respondsToSelector:@selector(windowCreationInvalidated:)])
        [self.sink windowCreationInvalidated:record.pid];
    if(record){DWApplicationMetadata *notice=[DWApplicationMetadata new];notice.watch=record;notice.revision=record.revision;notice.hints=hints;notice.identityNotice=identity;[self applyApplicationNotice:notice];return;}
    for(DWApplicationMetadata *pending in self.applicationNotices)if(pending.running==running){pending.hints|=hints;pending.identityNotice|=identity;return;}
    if(self.applicationNotices.count>=64){[self changed:appeared pid:0];return;}
    DWApplicationMetadata *notice=[DWApplicationMetadata new];notice.running=running;notice.hints=hints;notice.identityNotice=identity;[self.applicationNotices addObject:notice];[self queueApplicationNotices];
}
- (void)launched:(NSNotification *)note {
    if(!self.stopped)self.catalogRevision++;
    [self applicationNotification:note hints:applicationAppeared identity:YES];
}
// APPLICATION_TERMINATED: its observer is removed, and its windows are looked at, which finds their process gone.
- (void)terminated:(NSNotification *)note {
    if(self.stopped)return;self.catalogRevision++;DWApplicationWatch *record=[self.applicationWatches objectForKey:note.userInfo[NSWorkspaceApplicationKey]];
    pid_t pid=record.pid;[self forgetApplication:record ended:YES];
    // A different object in a late notification cannot remove the new record at a reused PID. The global hint/poll will
    // reconcile an unknown object without a synchronous main-thread LaunchServices read to guess which process it was.
    if(pid>0)[self changed:0 pid:pid];else [self changed:appeared pid:0];
}
// APPLICATION_FRONT_SWITCHED: windows of it not yet resolved are looked for again, and native focus may have moved.
- (void)activated:(NSNotification *)note {
    if(self.stopped)return;[self applicationNotification:note hints:applicationActivated identity:NO];[self changed:0 pid:0];
}
// APPLICATION_HIDDEN, APPLICATION_VISIBLE.
- (void)hidden:(NSNotification *)note { [self applicationNotification:note hints:applicationChanged identity:NO]; }
- (void)unhidden:(NSNotification *)note { [self applicationNotification:note hints:applicationAppeared|applicationChanged identity:NO]; }
// SPACE_CHANGED: every application lists the windows of the Space that is active now.
- (void)spaceChanged:(NSNotification *)note { (void)note;if(self.stopped)return;for(DWObservedApplication *application in self.applications.allValues)[self list:application];[self changed:appeared pid:0]; }
@end
