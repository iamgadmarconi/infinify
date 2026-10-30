// SPDX-License-Identifier: GPL-3.0-or-later
// Split from native/desktop/main.m at 37b27b1, moved verbatim.
// Desktop config: loading and reloading the config file.
#import "Desktop+Private.h"
#import "DWInputSources.h"
#import "DWDebugTrace.h"
#import "DWNativeFocus.h"
#import "DWWindowEvents.h"
#import "DWGeometryJSON.h"
#import "DesktopPanel.h"
#import "DWChildProcess.h"
@implementation Desktop (Config)
// Startup, a change of the config file, the reload-config action, and a canvas reopened
// after Return to desktop. Reload semantics are the controller's, which are upstream's:
// a file that fails to parse leaves the previous config in force and says why.
// What the file itself has wrong, the load's errors and warnings, is shown where upstream shows it and nowhere else: in the
// error bar, which the compositor draws from the controller's own message (snapshot.render.errors). Here those lines go to
// stderr and never to the resting status. The resting status keeps what the bar does not show: a --super chord or a load the
// controller refused (`problems`), and the bindings that were left out.
- (void)loadConfig:(BOOL)platform {
    NSMutableArray<NSString *> *problems=[NSMutableArray array],*file=[NSMutableArray array];
    if(platform&&![self call:@{@"op":@"set_platform",@"super":self.superChord?:@"ctrl+alt"}])[problems addObject:self.statusText?:@"set_platform failed"];
    NSDictionary *loaded=[self call:@{@"op":@"load_config",@"path":self.configPath?:NSNull.null}];if(!loaded)[problems addObject:self.statusText?:@"load_config failed"];
    // A reload can change what is saved (config bookmarks); the launch load precedes the scene and saves nothing.
    if(!platform&&[loaded[@"dirty"]isEqual:@YES])[self saveScene];
    // The launch load's effects are the config's autostart commands: kept for main() to run once. A reload's are never looked at.
    if(platform)self.autostart=asArray(loaded[@"effects"]);
    for(NSString *key in @[@"errors",@"warnings"])for(id message in asArray(loaded[key]))if(DWTyped(message,NSString.class))[file addObject:message];
    // The reply lists a load's warnings in the parser's order, which for a hash-mapped table differs between two loads of one file. They are
    // printed in byte order, the order the controller picks the bar's one line in, so the first line is the one the bar names at every load.
    [file sortUsingComparator:^NSComparisonResult(NSString *a,NSString *b){int order=strcmp(a.UTF8String,b.UTF8String);return order<0?NSOrderedAscending:order>0?NSOrderedDescending:NSOrderedSame;}];
    NSString *path=DWTyped(loaded[@"path"],NSString.class)?:self.configPath;NSArray<NSString *> *left=[self refreshBindings],*all=[problems arrayByAddingObjectsFromArray:left];
    for(NSArray<NSString *> *lines in @[problems,file,left])for(NSString *line in lines)fprintf(stderr,"%s\n",line.UTF8String);
    NSString *note=all.count?summary(problems.count?[@"Config " stringByAppendingString:(path?:@"").stringByAbbreviatingWithTildeInPath]:@"Bindings",all):nil;
    self.configNote=problems.count?note:nil;self.statusText=note?:[self restingStatus];
    if(!self.configWatcher){__weak Desktop *weak=self;self.configWatcher=[[DWConfigWatcher alloc]initWithChanged:^{[weak loadConfig:NO];}];}
    [self.configWatcher watch:path];[self render];
}
@end
