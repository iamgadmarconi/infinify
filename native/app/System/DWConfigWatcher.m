// SPDX-License-Identifier: GPL-3.0-or-later
#import "DWConfigWatcher.h"
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

// Identity, size and modification time: what a save in place or by replacement changes.
static NSString *signature(NSString *path) {
    struct stat s;if(stat(path.fileSystemRepresentation,&s))return @"missing";
    return [NSString stringWithFormat:@"%llu:%lld:%ld:%ld",(unsigned long long)s.st_ino,(long long)s.st_size,(long)s.st_mtimespec.tv_sec,(long)s.st_mtimespec.tv_nsec];
}
@implementation DWConfigWatcher {
    void (^_changed)(void);
    NSString *_path,*_signature;
    dispatch_source_t _directory,_file;
    NSUInteger _token;
}
- (instancetype)initWithChanged:(void (^)(void))changed { if((self=[super init]))_changed=[changed copy];return self; }
- (dispatch_source_t)source:(NSString *)path {
    int descriptor=open(path.fileSystemRepresentation,O_EVTONLY|O_CLOEXEC);if(descriptor<0)return nil;
    dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,(uintptr_t)descriptor,DISPATCH_VNODE_WRITE|DISPATCH_VNODE_EXTEND|DISPATCH_VNODE_ATTRIB|DISPATCH_VNODE_DELETE|DISPATCH_VNODE_RENAME|DISPATCH_VNODE_REVOKE,dispatch_get_main_queue());
    __weak DWConfigWatcher *weak=self;
    dispatch_source_set_event_handler(source,^{[weak event];});
    dispatch_source_set_cancel_handler(source,^{close(descriptor);});
    dispatch_resume(source);return source;
}
- (void)arm {
    if(_directory)dispatch_source_cancel(_directory);if(_file)dispatch_source_cancel(_file);_directory=_file=nil;if(!_path)return;
    NSString *directory=_path.stringByDeletingLastPathComponent;
    while(!(_directory=[self source:directory])&&directory.length>1)directory=directory.stringByDeletingLastPathComponent;
    _file=[self source:_path];
}
- (void)event {
    NSUInteger token=++_token;__weak DWConfigWatcher *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(.15*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        DWConfigWatcher *watcher=weak;if(!watcher||watcher->_token!=token||!watcher->_path)return;
        // A replaced file is a new inode and a created directory a deeper one: observe those from here on.
        [watcher arm];NSString *current=signature(watcher->_path);
        if([current isEqual:watcher->_signature])return;
        watcher->_signature=current;watcher->_changed();
    });
}
- (void)watch:(NSString *)path {
    if(!path.length||[path isEqual:_path])return;
    _token++;_path=[path copy];_signature=signature(_path);[self arm];
}
- (void)stop { _token++;_path=nil;[self arm]; }
- (void)dealloc { if(_directory)dispatch_source_cancel(_directory);if(_file)dispatch_source_cancel(_file); }
@end
