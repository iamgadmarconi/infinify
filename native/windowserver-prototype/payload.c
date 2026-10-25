// SPDX-License-Identifier: GPL-3.0-or-later
// Disposable-window experiment. No AppKit and no SkyLight client calls.
#include "prototype.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <math.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static struct ifwsp_config config;
static bool touched[IFWSP_MAX_WINDOWS];
static uint64_t received, applied, superseded_frames;
static const uint32_t capabilities=DW2_CAP_RESTORE_WINDOW|DW2_CAP_ENROLLMENT|DW2_CAP_INSPECT;

// Startup diagnostics only. Never log the nonce, sidecar bytes, window table or
// runtime/payload paths, and never add logging to the measured frame path.
static void startup_diagnostic(const char *stage,int error,const char *reason) {
    os_log_error(OS_LOG_DEFAULT,"InfinifyWSPrototype stage=%{public}s errno=%d reason=%{public}s",
                 stage,error,reason?reason:"");
}

static uint64_t milliseconds(void) {
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
    return (uint64_t)t.tv_sec*1000+(uint64_t)t.tv_nsec/1000000;
}
static bool process_current(pid_t pid,uint64_t sec,uint64_t usec,uid_t uid) {
    struct proc_bsdinfo b={0};
    return proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))==sizeof(b)
        && b.pbi_pid==(uint32_t)pid && b.pbi_uid==uid
        && b.pbi_start_tvsec==sec && b.pbi_start_tvusec==usec;
}
static bool fixture_current(void) {
    return ifwsp_kernel_identity_current(config.fixture_pid,config.fixture_uid,&config.fixture_kernel_identity);
}
static bool same_matrix(const double a[6],const double b[6]) {
    for(unsigned i=0;i<6;i++)if(!isfinite(a[i])||!isfinite(b[i])||(float)a[i]!=(float)b[i])return false;
    return true;
}
static bool matrix_valid(const double m[6]) {
    for(unsigned i=0;i<6;i++)if(!isfinite(m[i])||fabs(m[i])>1000000)return false;
    return fabs(m[0]*m[3]-m[1]*m[2])>=1e-8;
}
static int window_index(const struct dw2_identity *id) {
    for(unsigned i=0;i<config.window_count;i++) {
        const struct dw2_identity *w=&config.windows[i].identity;
        if(id->pid==w->pid&&id->wid==w->wid&&id->birth_sec==w->birth_sec&&id->birth_usec==w->birth_usec)return (int)i;
    }
    return -1;
}
static bool inspect_index(unsigned index,struct dw2_inspect_reply *reply) {
    memset(reply,0,sizeof(*reply));reply->id=config.windows[index].identity;reply->status=DW2_IDENTITY;
    int32_t owner=0,pid=0;
    if(!fixture_current() || !ifwsp_server_inspect(reply->id.wid,&owner,&pid,reply->transform,reply->bounds,reply->screen_rect)
        ||owner!=config.windows[index].owner||pid!=config.fixture_pid||!fixture_current())return false;
    reply->owner=owner;reply->status=DW2_APPLIED;return true;
}
static bool restore_index(unsigned index) {
    struct dw2_inspect_reply before,after;
    if(!inspect_index(index,&before))return false;
    // Always replay the saved raw placement, even if the public affine rounded
    // back to the original: its precise matrix/flags may still differ.
    if(!ifwsp_server_transform(config.windows[index].identity.wid,config.windows[index].original_transform))return false;
    if(!inspect_index(index,&after)||!same_matrix(after.transform,config.windows[index].original_transform)
        ||!ifwsp_server_original_restored(config.windows[index].identity.wid))return false;
    touched[index]=false;return true;
}
static void restore_operation(void *unused) {
    (void)unused;
    for(unsigned i=0;i<config.window_count;i++)if(touched[i])restore_index(i);
}
static unsigned pending_restores(void) {
    unsigned pending=0;for(unsigned i=0;i<config.window_count;i++)pending+=touched[i];return pending;
}

struct request_context {
    const struct dw2_header *header;
    const unsigned char *body;
    unsigned char *reply;
    uint32_t length;
    uint32_t superseded;
};
static void perform_request(void *raw) {
    struct request_context *c=raw;
    const struct dw2_header *h=c->header;
    if(h->type==DW2_INSPECT && h->length==sizeof(struct dw2_identity)) {
        struct dw2_identity identity;memcpy(&identity,c->body,sizeof(identity));
        struct dw2_inspect_reply reply={.id=identity,.status=DW2_SCOPE};
        int index=window_index(&identity);if(index>=0)inspect_index((unsigned)index,&reply);
        memcpy(c->reply,&reply,sizeof(reply));c->length=sizeof(reply);return;
    }
    if(h->type==DW2_FRAME && h->length>=sizeof(struct dw2_frame)) {
        struct dw2_frame frame;memcpy(&frame,c->body,sizeof(frame));
        if(frame.reserved||frame.count>config.window_count||h->length!=sizeof(frame)+frame.count*sizeof(struct dw2_record))return;
        struct dw2_frame_reply reply={.count=frame.count,.frames_applied=++applied,.superseded=c->superseded};
        unsigned char status[IFWSP_MAX_WINDOWS]={0};
        uint32_t ids[IFWSP_MAX_WINDOWS],record_index[IFWSP_MAX_WINDOWS],indices[IFWSP_MAX_WINDOWS],count=0;
        double matrices[IFWSP_MAX_WINDOWS][6];
        bool named[IFWSP_MAX_WINDOWS]={0};
        received+=(uint64_t)c->superseded+1;superseded_frames+=c->superseded;
        for(unsigned i=0;i<frame.count;i++) {
            struct dw2_record r;memcpy(&r,c->body+sizeof(frame)+i*sizeof(r),sizeof(r));
            int index=window_index(&r.id);
            if(index<0){status[i]=DW2_SCOPE;continue;}
            if(named[index]){status[i]=DW2_MALFORMED;continue;}named[index]=true;
            if(r.flags==DW2_RECORD_RESTORE){status[i]=restore_index((unsigned)index)?DW2_APPLIED:DW2_RESTORE_PENDING;continue;}
            if(r.flags){status[i]=r.flags&DW2_RECORD_HAS_ALPHA?DW2_ALPHA:DW2_MALFORMED;continue;}
            if(!matrix_valid(r.m)){status[i]=DW2_MATRIX;continue;}
            struct dw2_inspect_reply before;
            if(!inspect_index((unsigned)index,&before)){status[i]=DW2_IDENTITY;continue;}
            // Snapshot comparison is required once, before touching this fixture.
            if(!touched[index]&&!same_matrix(before.transform,config.windows[index].original_transform)){status[i]=DW2_SNAPSHOT;continue;}
            touched[index]=true; // Any attempted setter owes an original restore.
            ids[count]=r.id.wid;record_index[count]=i;indices[count]=(unsigned)index;
            memcpy(matrices[count],r.m,sizeof(r.m));count++;
        }
        if(count) {
            bool submitted=fixture_current()&&ifwsp_server_transform_many(count,ids,matrices);
            for(unsigned j=0;j<count;j++) {
                struct dw2_inspect_reply after;
                status[record_index[j]]=submitted&&inspect_index(indices[j],&after)&&same_matrix(after.transform,matrices[j])?DW2_APPLIED:DW2_NOT_APPLIED;
            }
        }
        memcpy(c->reply,&reply,sizeof(reply));memcpy(c->reply+sizeof(reply),status,frame.count);
        c->length=(uint32_t)sizeof(reply)+frame.count;return;
    }
    if(h->type==DW2_RESTORE_ALL && !h->length) {
        struct dw2_restore_result results[IFWSP_MAX_WINDOWS];uint32_t count=0,pending=0;
        for(unsigned i=0;i<config.window_count;i++)if(touched[i]) {
            bool ok=restore_index(i);if(!ok)pending++;
            results[count++]=(struct dw2_restore_result){.id=config.windows[i].identity,.outcome=ok?DW2_RESTORED:DW2_PENDING,.set_status=ok?0:-1};
        }
        // Fixed originals were fsynced before the loader's first remote write.
        struct dw2_restore_reply reply={.count=count,.pending=pending,.journal_persisted=1};
        memcpy(c->reply,&reply,sizeof(reply));memcpy(c->reply+sizeof(reply),results,count*sizeof(*results));
        c->length=(uint32_t)(sizeof(reply)+count*sizeof(*results));return;
    }
    if(h->type==DW2_PROBE && !h->length) {
        uint32_t held=0;for(unsigned i=0;i<config.window_count;i++)held+=touched[i];
        struct dw2_probe_reply reply={.scope=DW2_SCOPE_ALLOWLIST,.caps=capabilities,.queue=DW2_QUEUE_MAIN,
            .lease_ms=DW2_LEASE_MS,.server_pid=getpid(),.held=held,.frames_received=received,.frames_applied=applied,
            .frames_superseded=superseded_frames,.table_count=held};
        memcpy(c->reply,&reply,sizeof(reply));size_t offset=sizeof(reply);
        for(unsigned i=0;i<config.window_count;i++)if(touched[i]) {
            struct dw2_inspect_reply observation;bool ok=inspect_index(i,&observation);
            struct dw2_probe_entry entry={.id=config.windows[i].identity,.state=DW2_HELD,.alpha=1};
            if(ok){memcpy(entry.transform,observation.transform,sizeof(entry.transform));memcpy(entry.screen_rect,observation.screen_rect,sizeof(entry.screen_rect));}
            memcpy(c->reply+offset,&entry,sizeof(entry));offset+=sizeof(entry);
        }
        c->length=(uint32_t)offset;return;
    }
    if(h->type==DW2_ENROLLMENT&&!h->length) {
        struct dw2_enrollment_reply reply={.scope=DW2_SCOPE_ALLOWLIST,.count=1,.server_pid=getpid()};
        struct dw2_process process={.pid=config.fixture_pid,.birth_sec=config.fixture_birth_sec,.birth_usec=config.fixture_birth_usec};
        memcpy(c->reply,&reply,sizeof(reply));memcpy(c->reply+sizeof(reply),&process,sizeof(process));c->length=sizeof(reply)+sizeof(process);
    }
}

static bool read_bytes(int fd,void *bytes,size_t length,uint64_t deadline) {
    size_t used=0;
    while(used<length) {
        uint64_t now=milliseconds();if(now>=deadline)return false;
        struct pollfd p={.fd=fd,.events=POLLIN};int ready=poll(&p,1,(int)(deadline-now));
        if(ready<0&&errno==EINTR)continue;if(ready<=0)return false;
        ssize_t n=read(fd,(char*)bytes+used,length-used);
        if(n<0&&errno==EINTR)continue;if(n<=0)return false;used+=(size_t)n;
    }
    return true;
}
#include "mailbox-server.inc"

__attribute__((constructor)) static void start(void) {
    // No sidecar means inert. In particular dlopen from a read-only inspection
    // process never opens a socket, creates a thread, or performs native queries.
    constructor_started_ns=ifwsp_mb_now_ns();
    startup_diagnostic("constructor-enter",0,"payload constructor entered");
    Dl_info image={0};
    if(!dladdr((void*)&start,&image)||!image.dli_fname){startup_diagnostic("image-path",errno,"payload image lookup failed");return;}
    if(strlen(image.dli_fname)>=sizeof(payload_image_path))return;
    strcpy(payload_image_path,image.dli_fname);
    char path[4096];int n=snprintf(path,sizeof(path),"%s.ifwsp",image.dli_fname);
    if(n<0||(size_t)n>=sizeof(path)){startup_diagnostic("sidecar-path",ENAMETOOLONG,"sidecar path does not fit");return;}
    int fd=open(path,O_RDONLY|O_NOFOLLOW);
    if(fd<0){startup_diagnostic("sidecar-open",errno,"sidecar is absent or unreadable; payload remains inert");return;}
    struct stat st={0};
    if(fstat(fd,&st)){int error=errno;close(fd);startup_diagnostic("sidecar-stat",error,"sidecar fstat failed");return;}
    if(!S_ISREG(st.st_mode)){close(fd);startup_diagnostic("sidecar-type",0,"sidecar is not a regular file");return;}
    if(st.st_uid!=geteuid()){close(fd);startup_diagnostic("sidecar-owner",0,"sidecar owner differs from effective user");return;}
    if((st.st_mode&0777)!=0400){close(fd);startup_diagnostic("sidecar-mode",0,"sidecar permissions differ from required mode");return;}
    if(st.st_size!=sizeof(config)){close(fd);startup_diagnostic("sidecar-size",0,"sidecar size differs from config ABI");return;}
    errno=0;
    bool ok=read_bytes(fd,&config,sizeof(config),milliseconds()+1000);int read_error=errno;close(fd);
    if(!ok){startup_diagnostic("sidecar-read",read_error,"sidecar read did not complete");return;}
    startup_diagnostic("sidecar-read-complete",0,"sidecar metadata and read completed");
    if(memcmp(config.magic,IFWSP_CONFIG_MAGIC,8)){startup_diagnostic("config-magic",0,"config magic mismatch");return;}
    if(config.version!=IFWSP_CONFIG_VERSION){startup_diagnostic("config-version",0,"config version mismatch");return;}
    if(config.size!=sizeof(config)){startup_diagnostic("config-size",0,"config size mismatch");return;}
    if(config.server_pid!=getpid()){startup_diagnostic("config-server-pid",0,"config names a different server process");return;}
    if(config.window_count<1||config.window_count>IFWSP_MAX_WINDOWS){startup_diagnostic("config-window-count",0,"config window count is outside fixture bounds");return;}
    if(config.lifetime_ms<1000||config.lifetime_ms>IFWSP_MAX_LIFETIME_MS){startup_diagnostic("config-lifetime",0,"config lifetime is outside fixed bounds");return;}
    if(!memchr(config.runtime,0,sizeof(config.runtime))){startup_diagnostic("config-runtime-termination",0,"config runtime is not terminated");return;}
    errno=0;
    if(!process_current(config.server_pid,config.server_birth_sec,config.server_birth_usec,geteuid())){startup_diagnostic("server-identity",errno,"current server identity check failed");return;}
    errno=0;
    if(!fixture_current()){startup_diagnostic("fixture-identity",errno,"current disposable fixture identity check failed");return;}
    startup_diagnostic("identity-verified",0,"server and disposable fixture identities match");
    struct ifwsp_abi abi=ifwsp_bind_server_abi();
    if(!abi.verified){startup_diagnostic("server-abi",errno,abi.reason);return;}
    startup_diagnostic("server-abi-verified",0,abi.reason);
    pthread_t thread;int create_error=pthread_create(&thread,NULL,serve,NULL);
    if(create_error){startup_diagnostic("thread-create",create_error,"pthread_create failed");return;}
    int detach_error=pthread_detach(thread);
    startup_diagnostic(detach_error?"thread-detach-failed":"thread-created",detach_error,
                       detach_error?"pthread_detach failed":"bounded worker thread created and detached");
}
