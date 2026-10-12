// SPDX-License-Identifier: GPL-3.0-or-later
// Identity-boundary regression, not native compositing evidence. Compile the
// actual payload with native call substitutes; no window, Dock load or fault API.
#import <AppKit/AppKit.h>
#import <libproc.h>
#include <unistd.h>
#include <assert.h>
static CFArrayRef queryWindows(CGWindowListOption option,CGWindowID wid);
static int queryProcess(int pid,int flavor,uint64_t argument,void *buffer,int size);
static int journalSync(int fd);
#define CGWindowListCopyWindowInfo queryWindows
#define proc_pidinfo queryProcess
#define fsync journalSync
#import "payload.m"
#undef CGWindowListCopyWindowInfo
#undef proc_pidinfo
#undef fsync

static NSArray *rows;
static int ownerStatus,connectionStatus,ownerValue=7,processPID=123;
static BOOL processAvailable=YES;
static uint64_t seconds=100,microseconds=20;
static uid_t processUID;
static BOOL replaceOnSync,replaceAfterTransform;
static unsigned transformWrites,alphaWrites;
static CGAffineTransform nativeTransform;
static float nativeAlpha=1;
static int journalSync(int fd) {
    int status=fsync(fd);
    if(!status&&replaceOnSync&&fd==directoryFD){replaceOnSync=NO;ownerValue++;}
    return status;
}
static CGError readTransform(int cid,uint32_t wid,CGAffineTransform *value) {
    (void)cid;(void)wid;*value=nativeTransform;return 0;
}
static CGError writeTransform(int cid,uint32_t wid,CGAffineTransform value) {
    (void)cid;(void)wid;transformWrites++;nativeTransform=value;
    if(replaceAfterTransform){replaceAfterTransform=NO;ownerValue++;}
    return 0;
}
static CGError readBounds(int cid,uint32_t wid,CGRect *value) {
    (void)cid;(void)wid;*value=CGRectMake(0,0,300,200);return 0;
}
static CGError readAlpha(int cid,uint32_t wid,float *value) {
    (void)cid;(void)wid;*value=nativeAlpha;return 0;
}
static CGError writeAlpha(int cid,uint32_t wid,float value) {
    (void)cid;(void)wid;alphaWrites++;nativeAlpha=value;return 0;
}
static CFArrayRef queryWindows(CGWindowListOption option,CGWindowID wid) {
    (void)option;(void)wid;
    return rows ? CFRetain((__bridge CFArrayRef)rows) : NULL;
}
static int queryProcess(int pid,int flavor,uint64_t argument,void *buffer,int size) {
    (void)pid;(void)flavor;(void)argument;
    if(!processAvailable)return 0;
    assert(size==sizeof(struct proc_bsdinfo));
    struct proc_bsdinfo process={.pbi_start_tvsec=seconds,.pbi_start_tvusec=microseconds,.pbi_uid=processUID};
    memcpy(buffer,&process,sizeof(process));return size;
}
static int mainCID(void) { return 1; }
static CGError windowOwner(int cid,uint32_t wid,int *owner) {
    (void)cid;(void)wid;*owner=ownerValue;return ownerStatus;
}
static CGError ownerPID(int owner,pid_t *pid) {
    (void)owner;*pid=processPID;return connectionStatus;
}
static void expect(const struct dw2_identity *identity,int outcome) {
    assert(v2RestoreIdentity(identity,7)==outcome);
}
int main(void) { @autoreleasepool {
    mainConnection=mainCID;getOwner=windowOwner;connectionPID=ownerPID;
    fixtureOnly=NO;processUID=getuid();
    const struct dw2_identity recorded={.pid=123,.wid=42,.birth_sec=100,.birth_usec=20};
    expect(&recorded,DW2_INSTANCE_CURRENT);
    seconds=101;expect(&recorded,DW2_INSTANCE_GONE);seconds=100;
    processPID=124;expect(&recorded,DW2_INSTANCE_GONE);processPID=123;
    ownerValue=8;expect(&recorded,DW2_INSTANCE_GONE);ownerValue=7;
    processUID=getuid()+1;expect(&recorded,DW2_INSTANCE_UNCERTAIN);processUID=getuid();
    allowlist=@[@{@"pid":@124,@"birth_sec":@100,@"birth_usec":@20}];
    expect(&recorded,DW2_INSTANCE_UNCERTAIN);allowlist=nil;

    ownerStatus=1;
    rows=nil;expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[];expect(&recorded,DW2_INSTANCE_GONE);
    rows=@[@{}];expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@124}];
    expect(&recorded,DW2_INSTANCE_GONE);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    processAvailable=NO;expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    processAvailable=YES;expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    seconds=101;expect(&recorded,DW2_INSTANCE_GONE);seconds=100;
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@YES}];
    expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@1.5}];
    expect(&recorded,DW2_INSTANCE_UNCERTAIN);

    ownerStatus=0;connectionStatus=1;rows=nil;
    expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    rows=@[@{(id)kCGWindowNumber:@42,(id)kCGWindowOwnerPID:@123}];
    processAvailable=NO;expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    processAvailable=YES;expect(&recorded,DW2_INSTANCE_CURRENT);
    ownerValue=0;expect(&recorded,DW2_INSTANCE_UNCERTAIN);
    // Exercise the actual restore/table/journal path with unavailable queries.
    // Every native setter remains unset: this path must never call one.
    char directory[]="/tmp/infinify-restore-query.XXXXXX";
    assert(mkdtemp(directory));directoryFD=open(directory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW);
    assert(directoryFD>=0);v2q=dispatch_queue_create("dw.restore.query.test",DISPATCH_QUEUE_SERIAL);
    v2RetryScheduled=YES; // This regression drives each retry explicitly on its sole test thread.
    v2Table=[NSMutableDictionary dictionary];
    DW2Entry *entry=[DW2Entry new];entry->who=recorded;entry->owner=7;
    entry->transform=CGAffineTransformMake(1,0,0,1,-25,-35);entry->bounds=CGRectMake(0,0,300,200);
    v2Table[@42]=entry;rows=nil;
    struct dw2_restore_reply summary={0};NSMutableData *report=[NSMutableData data];
    v2Restore(@"query regression",NO,report,&summary);
    assert(summary.count==1 && summary.pending==1 && summary.journal_persisted==1);
    assert(v2Table[@42]==entry && entry->state==DW2_RESTORING);
    NSDictionary *journal=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[@(directory)stringByAppendingPathComponent:@"v2-journal.json"]] options:0 error:NULL];
    assert([journal[@"state"]isEqual:@"restoring"] && [journal[@"windows"]count]==1);
    assert([journal[@"windows"][0][@"transform"]isEqual:matrix(entry->transform)]);
    rows=@[];report=[NSMutableData data];v2Restore(@"proven absence",YES,report,&summary);
    assert(summary.count==1 && summary.pending==0 && summary.journal_persisted==1 && !v2Table.count);
    const struct dw2_restore_result *gone=report.bytes;assert(gone->outcome==DW2_GONE);

    // A replacement after durable enrollment must receive neither transform nor
    // alpha. These substitutes exercise v2Apply's actual journal/write ordering.
    ownerValue=7;connectionStatus=0;rows=nil;
    getTransform=readTransform;setTransform=writeTransform;getBounds=readBounds;getAlpha=readAlpha;setAlpha=writeAlpha;
    nativeTransform=CGAffineTransformMake(1,0,0,1,-25,-35);
    struct dw2_record frame={.id=recorded,.flags=DW2_RECORD_HAS_ALPHA,.m={2,0,0,2,-50,-70},.alpha=.5f};uint8_t status=255;
    replaceOnSync=YES;v2Apply(&frame,1,&status);
    assert(status==DW2_IDENTITY && transformWrites==0 && alphaWrites==0 && v2Table.count==1);
    v2Restore(@"replacement after journal",NO,nil,&summary);
    assert(summary.pending==0 && summary.journal_persisted==1 && !v2Table.count);

    // A window replaced during the transform cannot authorize a later alpha
    // write or a successful frame acknowledgement.
    ownerValue=7;replaceAfterTransform=YES;v2Apply(&frame,1,&status);
    assert(status==DW2_IDENTITY && transformWrites==1 && alphaWrites==0);
    v2Restore(@"replacement between setters",NO,nil,&summary);
    assert(summary.pending==0 && !v2Table.count);

    // Normal apply still changes and verifies both properties. Restoration has
    // the same boundary between its transform and alpha setters.
    ownerValue=7;v2Apply(&frame,1,&status);
    assert(status==DW2_APPLIED && transformWrites==2 && alphaWrites==1 && nativeAlpha==.5f);
    replaceAfterTransform=YES;v2Restore(@"replacement during restore",NO,nil,&summary);
    assert(summary.pending==1 && transformWrites==3 && alphaWrites==1 && v2Table.count==1);
    v2Restore(@"confirmed replacement",YES,nil,&summary);
    assert(summary.pending==0 && summary.journal_persisted==1 && !v2Table.count);
    // A transform-only record still needs the final identity fence, even
    // though no intervening alpha write asks for one.
    ownerValue=7;frame.flags=0;replaceAfterTransform=YES;v2Apply(&frame,1,&status);
    assert(status==DW2_IDENTITY && transformWrites==4 && alphaWrites==1 && v2Table.count==1);
    v2Restore(@"transform-only replacement",NO,nil,&summary);
    assert(summary.pending==0 && summary.journal_persisted==1 && !v2Table.count);
    assert(!unlinkat(directoryFD,"v2-journal.json",0));close(directoryFD);directoryFD=-1;assert(!rmdir(directory));
    puts("PASS: restore identity decisions, uncertain journal retention and replacement at journal/setter boundaries; no native window mutation");
} }
