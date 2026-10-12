// SPDX-License-Identifier: GPL-3.0-or-later
// Test driver built on the client library (dwclient.h): what the shell will do, at
// the shell's rate, against windows named on stdin. Used by fixture_v2_test.py.
//   v2client bench RUNTIME NONCE HZ SECONDS   a frame of every window each tick
//   v2client hold  RUNTIME NONCE OFFSET       one frame, then only heartbeats; reports
//                                             the loss of the helper and exits 3
//   v2client enrollment RUNTIME NONCE         read-only finite process scope
//   v2client inspect RUNTIME NONCE PID WID SEC USEC  read-only window geometry
// stdin: one window per line, "pid wid birth_sec birth_usec x y w h" (its untouched
// screen rectangle), then "go". Each frame draws every window at half size, moved
// right by an offset in points (bench: the frame number modulo 200, and down by one
// point for every 200 frames, so that no two frames of a run draw the same rectangle).
#include "dwclient.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

struct window { struct dw2_identity id; double x, y, w, h; };
static struct window windows[64];
static uint32_t windowCount;
static uint64_t *submittedAt, submittedCapacity;
static _Atomic uint64_t worstReplyNS, lostAtMS;
static _Atomic int lostReason;

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static void frame_result(void *context, uint64_t seq, const uint8_t *status, uint32_t count) {
    (void)context;(void)status;(void)count;
    if(seq>=submittedCapacity || !submittedAt[seq])return;
    uint64_t took=now_ns()-submittedAt[seq];
    if(took>atomic_load(&worstReplyNS))atomic_store(&worstReplyNS,took);
}
static void lost(void *context, int reason) {
    (void)context;
    struct timeval tv;gettimeofday(&tv,NULL);
    atomic_store(&lostAtMS,(uint64_t)tv.tv_sec*1000+(uint64_t)tv.tv_usec/1000);atomic_store(&lostReason,reason);
}
static void fill(struct dw2_record *records, double offset, double down) {
    for(uint32_t i=0;i<windowCount;i++) {
        const struct window *w=&windows[i];
        // screen to window-local for target rectangle (x+offset, y+down, w/2, h/2)
        records[i]=(struct dw2_record){.id=w->id,.m={2,0,0,2,-(w->x+offset)*2,-(w->y+down)*2}};
    }
}
static int compare(const void *a, const void *b) { uint64_t x=*(const uint64_t *)a,y=*(const uint64_t *)b;return x<y ? -1 : x>y; }
static void print_stats(dw_client *client) {
    struct dw_client_stats s;dw_client_stats(client,&s);
    printf("\"submitted\":%llu,\"written\":%llu,\"dropped_local\":%llu,\"applied\":%llu,\"superseded\":%llu,\"discarded\":%llu,\"records_applied\":%llu,\"records_failed\":%llu,\"heartbeats_sent\":%llu,\"heartbeats_acked\":%llu,\"last_applied_seq\":%llu,\"lost\":%s,\"lost_reason\":%d,\"lost_at_unix_ms\":%llu",
        s.submitted,s.written,s.dropped_local,s.applied,s.superseded,s.discarded,s.records_applied,s.records_failed,s.heartbeats_sent,s.heartbeats_acked,s.last_applied_seq,
        atomic_load(&lostReason) ? "true" : "false",atomic_load(&lostReason),atomic_load(&lostAtMS));
}
static int decimal(const char *text,uint64_t maximum,uint64_t *value) {
    if(!text || !*text)return 0;
    for(const char *p=text;*p;p++)if(*p<'0'||*p>'9')return 0;
    errno=0;char *end=NULL;unsigned long long number=strtoull(text,&end,10);
    if(errno || *end || number>maximum)return 0;
    *value=number;return 1;
}
int main(int argc, char **argv) {
    int bench=argc==6 && !strcmp(argv[1],"bench"),hold=argc==5 && !strcmp(argv[1],"hold"),enrollment=argc==4 && !strcmp(argv[1],"enrollment"),inspect=argc==8 && !strcmp(argv[1],"inspect");
    if(!bench && !hold && !enrollment && !inspect){fprintf(stderr,"usage: v2client bench RUNTIME NONCE HZ SECONDS | v2client hold RUNTIME NONCE OFFSET | v2client enrollment RUNTIME NONCE | v2client inspect RUNTIME NONCE PID WID SEC USEC\n");return 2;}
    struct dw2_identity inspection={0};
    if(inspect){
        uint64_t pid=0,wid=0,sec=0,usec=0;
        if(!decimal(argv[4],INT_MAX,&pid)||!pid||!decimal(argv[5],UINT32_MAX,&wid)||!wid||!decimal(argv[6],UINT64_MAX,&sec)||!sec||!decimal(argv[7],999999,&usec))return 2;
        inspection=(struct dw2_identity){.pid=(int32_t)pid,.wid=(uint32_t)wid,.birth_sec=sec,.birth_usec=usec};
    }
    char line[256];
    while(!enrollment && !inspect && fgets(line,sizeof(line),stdin) && strncmp(line,"go",2) && windowCount<64) {
        struct window *w=&windows[windowCount];
        if(sscanf(line,"%d %u %llu %llu %lf %lf %lf %lf",&w->id.pid,&w->id.wid,&w->id.birth_sec,&w->id.birth_usec,&w->x,&w->y,&w->w,&w->h)!=8){fprintf(stderr,"bad window line\n");return 2;}
        windowCount++;
    }
    struct dw_client_callbacks callbacks={.frame_result=frame_result,.lost=lost};
    struct dw_client_info info;dw_client *client=NULL;
    int opened=dw_client_open(argv[2],argv[3],&callbacks,3000,&client,&info);
    if(opened){fprintf(stderr,"open failed: %d\n",opened);return 1;}
    if(inspect){
        struct dw2_inspect_reply reply={0};
        int result=dw_client_inspect(client,2000,&inspection,&reply);
        if(result){fprintf(stderr,"inspection failed: %d\n",result);dw_client_close(client);return 1;}
        printf("{\"status\":%u,\"owner\":%d,\"transform\":[",reply.status,reply.owner);
        for(int i=0;i<6;i++)printf("%s%.17g",i?",":"",reply.transform[i]);
        printf("],\"bounds\":[");for(int i=0;i<4;i++)printf("%s%.17g",i?",":"",reply.bounds[i]);
        printf("],\"screen_rect\":[");for(int i=0;i<4;i++)printf("%s%.17g",i?",":"",reply.screen_rect[i]);
        printf("]}\n");dw_client_close(client);return 0;
    }
    if(enrollment){
        struct dw2_process processes[DW2_MAX_PROCESSES];uint32_t count=0;
        int result=dw_client_enrollment(client,2000,processes,DW2_MAX_PROCESSES,&count);
        if(result){fprintf(stderr,"enrollment audit failed: %d\n",result);dw_client_close(client);return 1;}
        printf("{\"scope\":%u,\"server_pid\":%d,\"processes\":[",info.scope,info.server_pid);
        for(uint32_t i=0;i<count;i++)printf("%s{\"pid\":%d,\"birth_sec\":%llu,\"birth_usec\":%llu}",i?",":"",processes[i].pid,processes[i].birth_sec,processes[i].birth_usec);
        printf("]}\n");dw_client_close(client);return 0;
    }
    struct dw2_record records[64];
    if(hold) {
        uint64_t seq=0;
        fill(records,atof(argv[4]),0);
        int submitted=dw_client_submit_frame(client,records,windowCount,&seq);
        struct dw_client_stats s={0};
        for(int i=0;i<300 && !submitted && s.last_applied_seq<seq;i++){usleep(10000);dw_client_stats(client,&s);}
        printf("{\"held\":%s,\"records_applied\":%llu,\"records_failed\":%llu}\n",s.last_applied_seq==seq && seq ? "true" : "false",s.records_applied,s.records_failed);fflush(stdout);
        // Nothing but the library's heartbeat thread runs from here, until a signal
        // or until the library says the helper is lost.
        while(!atomic_load(&lostReason))usleep(20000);
        printf("{");print_stats(client);printf("}\n");fflush(stdout);
        dw_client_close(client);
        return 3;
    }
    int hz=atoi(argv[4]),seconds=atoi(argv[5]);
    if(hz<1 || hz>1000 || seconds<1 || seconds>60)return 2;
    uint64_t frames=(uint64_t)hz*(uint64_t)seconds,period=1000000000ull/(uint64_t)hz,worst=0,refused=0,lastSeq=0;
    submittedCapacity=frames+16;submittedAt=calloc(submittedCapacity,sizeof(*submittedAt));
    uint64_t *took=calloc(frames,sizeof(*took));
    if(!submittedAt || !took)return 1;
    double lastOffset=0,lastDown=0;
    uint64_t start=now_ns();
    for(uint64_t i=0;i<frames;i++) {
        uint64_t due=start+i*period,now=now_ns(),seq=0;
        if(due>now){struct timespec wait={.tv_sec=(due-now)/1000000000ull,.tv_nsec=(due-now)%1000000000ull};nanosleep(&wait,NULL);}
        double offset=(double)(i%200),down=(double)(i/200);
        fill(records,offset,down);
        // The clock is read before the call and the time recorded for the sequence
        // number the call is about to take: this loop is the only submitter.
        uint64_t before=now_ns();
        if(lastSeq+1<submittedCapacity)submittedAt[lastSeq+1]=before;
        int result=dw_client_submit_frame(client,records,windowCount,&seq);
        took[i]=now_ns()-before;
        if(took[i]>worst)worst=took[i];
        if(result==DW_CLIENT_OK){lastSeq=seq;lastOffset=offset;lastDown=down;}
        else refused++;
    }
    // Let the last frame be answered (or the helper be declared lost).
    struct dw_client_stats s={0};
    for(int i=0;i<300;i++) {
        dw_client_stats(client,&s);
        if(atomic_load(&lostReason) || s.last_applied_seq==lastSeq)break;
        usleep(10000);
    }
    // The table as the helper reports it, through the library's own probe call.
    size_t probeLength=0;
    struct dw2_probe_reply *probe=malloc(DW2_MAX_BODY);
    int probed=probe ? dw_client_probe(client,2000,probe,DW2_MAX_BODY,&probeLength) : DW_CLIENT_INVALID;
    uint32_t table=probed==DW_CLIENT_OK && probeLength>=sizeof(*probe) ? probe->table_count : 0;
    qsort(took,frames,sizeof(*took),compare);
    printf("{\"mode\":\"bench\",\"hz\":%d,\"seconds\":%d,\"windows\":%u,\"frames\":%llu,\"refused_after_loss\":%llu,\"last_seq\":%llu,\"last_offset\":%.1f,\"last_down\":%.1f,\"send_call_worst_us\":%.1f,\"send_call_p50_us\":%.1f,\"send_call_p99_us\":%.1f,\"reply_worst_ms\":%.3f,\"probe\":%d,\"probe_table\":%u,",
        hz,seconds,windowCount,frames,refused,lastSeq,lastOffset,lastDown,worst/1000.0,took[frames/2]/1000.0,took[frames*99/100]/1000.0,atomic_load(&worstReplyNS)/1000000.0,probed,table);
    print_stats(client);printf("}\n");fflush(stdout);
    // The windows stay where the last frame put them until the test has looked.
    int exitStatus=0;
    if(fgets(line,sizeof(line),stdin) && !strncmp(line,"restore",7)) {
        struct dw2_restore_result results[64];uint32_t count=0,pending=0,restored=0,journalPersisted=UINT32_MAX;
        int result=dw_client_restore_all(client,3000,results,64,&count,&pending,&journalPersisted);
        if(result==DW_CLIENT_OK || result==DW_CLIENT_UNDURABLE)
            for(uint32_t i=0;i<count && i<64;i++)if(results[i].outcome==DW2_RESTORED)restored++;
        printf("{\"restore_all\":%d,\"count\":%u,\"pending\":%u,\"journal_persisted\":",result,count,pending);
        if(journalPersisted==UINT32_MAX)printf("null");else printf("%s",journalPersisted?"true":"false");
        printf(",\"restored\":%u}\n",restored);fflush(stdout);
        if(result!=DW_CLIENT_OK || pending || journalPersisted!=1)exitStatus=1;
    }
    dw_client_close(client);
    return exitStatus;
}
