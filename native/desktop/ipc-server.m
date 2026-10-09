// SPDX-License-Identifier: GPL-3.0-or-later
// Framing adapted from malbiruk/driftwm 352333a8fa1b22171492d4b71a54102045c9a19d:
// src/ipc/mod.rs (IpcServer::new_at, accept_client, serve_connection, write_line,
// subscribe, Subscriber, broadcast_state_event, drain_subscriber, flush_pending_events):
// one request per line, one reply line each, in order, several per connection; an
// oversized line hangs up and a reply write is capped at one second. A subscriber
// is written to through its own duplicate of the descriptor and never blocked on:
// it holds at most the unwritten tail of one event and the newest event behind it,
// and a half-written event is finished before any reply on its connection. Whether
// an event repeats the last one is the controller's to say. New GCD code.
// Unlike upstream a socket that answers a connect is never replaced (the probe and
// the bind are not serialized between instances, so that is no lock), peers are
// checked by uid, connections are bounded and idle ones time out. Subscribers are
// bounded as well, and where upstream keeps one that stopped reading, one that
// takes nothing of an owed event for the idle time is hung up on.
#import "ipc-server.h"
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <fcntl.h>
#include <poll.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
enum { DWIPCMaxLine=64*1024,DWIPCMaxConnections=16,DWIPCMaxSubscribers=8,DWIPCIdleSeconds=30,DWIPCBacklog=16 };
@interface DWIPCConnection : NSObject
@property int fd;
@property dispatch_source_t reader,idle;
@property NSMutableData *buffer;
@property BOOL busy,paused,eof,closed; // busy: one request is with the handler
// A subscriber has a write source on `out`, its own duplicate of fd, resumed only
// while an event is owed: `owed` is the unwritten tail of the event in flight and
// `next` the newest event behind it.
@property dispatch_source_t writer;
@property int out;
@property BOOL writing;
@property NSMutableData *owed;
@property NSData *next;
@end
@implementation DWIPCConnection
@end
@interface DWIPCServer ()
@property (copy) DWIPCHandler handler; // main queue only, like stopped
@property BOOL stopped;
@property NSString *path;
@property dev_t device;
@property ino_t inode;
@property dispatch_queue_t queue;
@property dispatch_source_t listener;
@property NSMutableSet<DWIPCConnection *> *connections; // socket queue only
@end
static BOOL configure(int fd) { return !fcntl(fd,F_SETFL,O_NONBLOCK)&&!fcntl(fd,F_SETFD,FD_CLOEXEC); }
// A listening socket at path, or -1 and why. The mode is set before listen, so
// nothing can connect to a socket that is not yet 0600.
static int listenAt(NSString *path,struct stat *created,NSString *__autoreleasing *failure) {
    struct sockaddr_un address={.sun_family=AF_UNIX};const char *name=path.fileSystemRepresentation;struct stat info;
    if(strlen(name)>=sizeof(address.sun_path)){*failure=[NSString stringWithFormat:@"socket path is longer than %zu bytes",sizeof(address.sun_path)-1];return -1;}
    strlcpy(address.sun_path,name,sizeof(address.sun_path));
    if(stat(path.stringByDeletingLastPathComponent.fileSystemRepresentation,&info)||!S_ISDIR(info.st_mode)||info.st_uid!=geteuid()||(info.st_mode&(S_IWGRP|S_IWOTH))){*failure=@"socket directory must exist, be yours and not be writable by group or others";return -1;}
    if(!lstat(name,&info)){
        if(!S_ISSOCK(info.st_mode)){*failure=@"socket path is taken by a file that is not a socket";return -1;}
        int probe=socket(AF_UNIX,SOCK_STREAM,0),error=probe<0?errno:connect(probe,(struct sockaddr *)&address,sizeof(address))?errno:0;if(probe>=0)close(probe);
        if(!error){*failure=@"another running Infinify already answers on this socket";return -1;}
        if(error!=ECONNREFUSED){*failure=[NSString stringWithFormat:@"existing socket could not be checked: %s",strerror(error)];return -1;}
        unlink(name); // stale: nobody is listening
    }
    int fd=socket(AF_UNIX,SOCK_STREAM,0);
    if(fd<0||!configure(fd)||bind(fd,(struct sockaddr *)&address,sizeof(address))){*failure=[NSString stringWithFormat:@"socket could not be bound: %s",strerror(errno)];if(fd>=0)close(fd);return -1;}
    if(chmod(name,S_IRUSR|S_IWUSR)||listen(fd,DWIPCBacklog)||lstat(name,created)){*failure=[NSString stringWithFormat:@"socket could not be set up: %s",strerror(errno)];unlink(name);close(fd);return -1;}
    return fd;
}
// A stuck reader may hold the socket queue for one second, and never the main queue.
static BOOL writeBytes(int fd,NSData *out) {
    const char *p=out.bytes;size_t left=out.length;uint64_t deadline=clock_gettime_nsec_np(CLOCK_MONOTONIC)+NSEC_PER_SEC;
    while(left){
        ssize_t n=write(fd,p,left);
        if(n>0){p+=n;left-=(size_t)n;continue;}
        if(n<0&&errno==EINTR)continue;
        if(n==0||errno!=EAGAIN)return NO;
        uint64_t now=clock_gettime_nsec_np(CLOCK_MONOTONIC);struct pollfd ready={fd,POLLOUT,0};
        if(now>=deadline||poll(&ready,1,(int)((deadline-now)/NSEC_PER_MSEC)+1)<=0)return NO;
    }
    return YES;
}
static NSData *terminated(NSData *line) { NSMutableData *out=[line mutableCopy];[out appendBytes:"\n" length:1];return out; }
@implementation DWIPCServer { atomic_uint _subscribers; }
+ (instancetype)serverAtPath:(NSString *)path handler:(DWIPCHandler)handler error:(NSString *__autoreleasing *)error {
    NSString *failure=nil;struct stat created;int fd=listenAt(path,&created,&failure);
    if(fd<0){if(error)*error=failure;return nil;}
    DWIPCServer *server=[self new];server.path=path;server.device=created.st_dev;server.inode=created.st_ino;server.handler=handler;server.connections=[NSMutableSet set];
    server.queue=dispatch_queue_create("org.infinify.ipc",DISPATCH_QUEUE_SERIAL);
    server.listener=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,(uintptr_t)fd,0,server.queue);
    // Sources keep the server alive until -stop cancels them.
    dispatch_source_set_event_handler(server.listener,^{[server accept:fd];});
    dispatch_source_set_cancel_handler(server.listener,^{close(fd);});
    dispatch_resume(server.listener);return server;
}
- (void)accept:(int)listener {
    for(int fd;(fd=accept(listener,NULL,NULL))>=0;){
        uid_t user=0;gid_t group=0;int on=1;
        // Same user only. A flood is answered by hanging up, never by queueing. A
        // client that leaves mid-reply must not raise SIGPIPE in the app.
        if(getpeereid(fd,&user,&group)||user!=geteuid()||self.connections.count>=DWIPCMaxConnections||!configure(fd)||setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&on,sizeof(on))){close(fd);continue;}
        DWIPCConnection *c=[DWIPCConnection new];c.fd=fd;c.buffer=[NSMutableData data];
        c.reader=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,(uintptr_t)fd,0,self.queue);
        c.idle=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.queue);
        dispatch_source_set_event_handler(c.reader,^{[self read:c];});
        dispatch_source_set_cancel_handler(c.reader,^{close(fd);});
        dispatch_source_set_event_handler(c.idle,^{if(!c.busy)[self close:c];});
        [self.connections addObject:c];[self arm:c];dispatch_resume(c.idle);dispatch_resume(c.reader);
    }
}
// Idle means no completed request: accept and every reply restart the clock. A
// subscriber is never idle: its clock runs only while it leaves an owed event unread.
- (void)arm:(DWIPCConnection *)c {
    BOOL timed=!c.writer||c.owed.length;
    dispatch_source_set_timer(c.idle,timed?dispatch_time(DISPATCH_TIME_NOW,DWIPCIdleSeconds*(int64_t)NSEC_PER_SEC):DISPATCH_TIME_FOREVER,DISPATCH_TIME_FOREVER,NSEC_PER_SEC);
}
- (void)close:(DWIPCConnection *)c {
    if(c.closed)return;c.closed=YES;
    // The reader's cancel handler closes the descriptor; a suspended source never runs it.
    dispatch_source_cancel(c.idle);dispatch_source_cancel(c.reader);if(c.paused)dispatch_resume(c.reader);
    if(c.writer){dispatch_source_cancel(c.writer);if(!c.writing)dispatch_resume(c.writer);atomic_fetch_sub(&_subscribers,1);}
    [self.connections removeObject:c];
}
// Upstream's subscribe: the write half is duplicated before the ack, so a failure is
// an error reply and never a half-registered subscriber. Returns why not, or nil;
// a repeat on a subscribed connection only has the snapshot sent again.
- (NSString *)subscribe:(DWIPCConnection *)c {
    if(c.writer)return nil;
    if(atomic_load(&_subscribers)>=DWIPCMaxSubscribers)return [NSString stringWithFormat:@"cannot subscribe: %d subscribers are already connected",DWIPCMaxSubscribers];
    int out=fcntl(c.fd,F_DUPFD_CLOEXEC,0);if(out<0)return [NSString stringWithFormat:@"cannot subscribe: %s",strerror(errno)];
    c.out=out;c.owed=[NSMutableData data];
    c.writer=dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE,(uintptr_t)out,0,self.queue);
    dispatch_source_set_event_handler(c.writer,^{[self flush:c];});
    dispatch_source_set_cancel_handler(c.writer,^{close(out);});
    atomic_fetch_add(&_subscribers,1);return nil;
}
// Upstream's drain_subscriber: as much of the event in flight, then of the newest
// behind it, as the socket takes without blocking. The write source finishes a
// tail once the peer reads again; the idle clock runs from the last byte it took.
- (void)flush:(DWIPCConnection *)c {
    if(c.closed)return;BOOL stalled=c.writing,moved=NO;
    for(;;){
        if(!c.owed.length){if(!c.next)break;[c.owed setData:c.next];c.next=nil;}
        ssize_t n=write(c.out,c.owed.bytes,c.owed.length);
        if(n>0){[c.owed replaceBytesInRange:NSMakeRange(0,(NSUInteger)n) withBytes:NULL length:0];moved=YES;continue;}
        if(n<0&&errno==EINTR)continue;
        if(n<0&&errno==EAGAIN)break;
        [self close:c];return;
    }
    c.writing=c.owed.length!=0;
    if(c.writing!=stalled){if(c.writing)dispatch_resume(c.writer);else dispatch_suspend(c.writer);}
    if(moved||c.writing!=stalled)[self arm:c];
}
- (NSUInteger)subscribers { return atomic_load(&_subscribers); }
// Upstream's broadcast_state_event. Each event is a whole snapshot, so one that
// waits behind an event in flight replaces any that already waited there.
- (void)publish:(NSData *)event {
    if(self.stopped||!event.length||!self.subscribers)return;
    NSData *line=terminated(event);
    dispatch_async(self.queue,^{
        for(DWIPCConnection *c in self.connections.allObjects){
            if(!c.writer||c.closed)continue;
            if(c.owed.length)c.next=line;else [c.owed setData:line];
            [self flush:c];
        }
    });
}
- (void)read:(DWIPCConnection *)c {
    if(c.closed)return;
    char chunk[4096];ssize_t n=read(c.fd,chunk,sizeof(chunk));
    if(n<0&&(errno==EAGAIN||errno==EINTR))return;
    if(n<0){[self close:c];return;}
    // End of input still answers every complete line already received.
    if(n)[c.buffer appendBytes:chunk length:(NSUInteger)n];else {c.eof=YES;c.paused=YES;dispatch_suspend(c.reader);}
    [self drain:c];
}
// Hands over at most one request at a time and reads nothing more until it is
// answered, so the socket buffer, not this process, holds back a fast client.
- (void)drain:(DWIPCConnection *)c {
    if(c.closed||c.busy)return;
    const char *bytes=c.buffer.bytes,*newline=memchr(bytes,'\n',c.buffer.length);NSUInteger length=newline?(NSUInteger)(newline-bytes):c.buffer.length;
    if(length>DWIPCMaxLine||(!newline&&c.eof)){[self close:c];return;}
    if(!newline){if(c.paused){c.paused=NO;dispatch_resume(c.reader);}return;}
    NSData *line=[c.buffer subdataWithRange:NSMakeRange(0,length)];[c.buffer replaceBytesInRange:NSMakeRange(0,length+1) withBytes:NULL length:0];
    c.busy=YES;if(!c.paused){c.paused=YES;dispatch_suspend(c.reader);}
    dispatch_async(dispatch_get_main_queue(),^{
        BOOL subscribe=NO;NSData *event=nil,*reply=self.stopped?nil:self.handler(line,&subscribe,&event);
        dispatch_async(self.queue,^{
            if(c.closed)return;
            c.busy=NO;if(!reply){[self close:c];return;}
            NSString *refused=subscribe?[self subscribe:c]:nil;
            NSData *answer=refused?[NSJSONSerialization dataWithJSONObject:@{@"Err":refused} options:0 error:nil]:reply;
            // A half-written event is finished before the reply, which would otherwise land inside its line.
            NSMutableData *out=[NSMutableData data];if(c.owed.length)[out appendData:c.owed];if(c.next)[out appendData:c.next];[out appendData:terminated(answer)];
            if(!writeBytes(c.fd,out)){[self close:c];return;}
            if(c.writer){
                [c.owed setLength:0];c.next=nil;if(subscribe&&!refused&&event)[c.owed setData:terminated(event)];
                [self flush:c];if(c.closed)return;
            }
            [self arm:c];[self drain:c];
        });
    });
}
- (void)stop {
    if(self.stopped)return;self.stopped=YES;self.handler=nil;
    // Serial order: replies already handed to the queue are written before this runs.
    dispatch_sync(self.queue,^{
        dispatch_source_cancel(self.listener);
        for(DWIPCConnection *c in self.connections.allObjects)[self close:c];
        // Only the socket this server created; a path someone else has since taken stays.
        struct stat now;const char *name=self.path.fileSystemRepresentation;
        if(!lstat(name,&now)&&now.st_dev==self.device&&now.st_ino==self.inode)unlink(name);
    });
}
@end
