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
static bool write_bytes(int fd,const void *bytes,size_t length) {
    size_t used=0;while(used<length) {
        ssize_t n=write(fd,(const char*)bytes+used,length-used);
        if(n<0&&errno==EINTR)continue;if(n<=0)return false;used+=(size_t)n;
    }return true;
}
static bool send_reply(int fd,const struct dw2_header *request,const void *body,uint32_t length) {
    struct dw2_header h={.length=length,.type=request->type|DW2_REPLY,.seq=request->seq};
    return write_bytes(fd,&h,sizeof(h))&&write_bytes(fd,body,length);
}
static bool frame_body_valid(const struct dw2_header *header,const unsigned char *body) {
    if(header->type!=DW2_FRAME||header->flags||header->length<sizeof(struct dw2_frame))return false;
    struct dw2_frame frame;memcpy(&frame,body,sizeof(frame));
    return !frame.reserved&&frame.count<=config.window_count
        &&header->length==sizeof(frame)+frame.count*sizeof(struct dw2_record);
}
static bool newest_complete_frame(int fd,struct dw2_header *header,unsigned char *body,uint32_t *superseded) {
    *superseded=0;if(!frame_body_valid(header,body))return false;
    // Drain only complete consecutive FRAME requests already in the socket.
    // Inspection, PROBE and RESTORE remain ordered barriers. Never wait for a
    // partial future frame or queue hundreds of obsolete camera poses.
    for(unsigned i=0;i<1024;i++) {
        int available=0;if(ioctl(fd,FIONREAD,&available)||available<(int)sizeof(*header))break;
        struct dw2_header next;
        ssize_t peeked=recv(fd,&next,sizeof(next),MSG_PEEK|MSG_DONTWAIT);
        if(peeked!=(ssize_t)sizeof(next)||next.type!=DW2_FRAME)break;
        if(next.flags||next.length>DW2_MAX_BODY||next.seq<=header->seq)return false;
        if((uint64_t)available<sizeof(next)+(uint64_t)next.length)break;
        if(!read_bytes(fd,&next,sizeof(next),milliseconds()+100)
            ||!read_bytes(fd,body,next.length,milliseconds()+100)||!frame_body_valid(&next,body))return false;
        *header=next;(*superseded)++;
    }return true;
}
static bool hello(int fd,uint16_t *role,uint8_t token[16],bool *session_started) {
    uid_t uid=0;gid_t gid=0;
    struct dw2_header h;struct dw2_hello body;
    if(getpeereid(fd,&uid,&gid)||uid!=config.controller_uid||!read_bytes(fd,&h,sizeof(h),milliseconds()+500)
        ||h.type!=DW2_HELLO||h.flags||h.length!=sizeof(body)
        ||!read_bytes(fd,&body,sizeof(body),milliseconds()+500))return false;
    struct dw2_hello_reply reply={.lease_ms=DW2_LEASE_MS,.max_records=config.window_count,.max_body=DW2_MAX_BODY,
        .caps=capabilities,.scope=DW2_SCOPE_ALLOWLIST,.queue=DW2_QUEUE_MAIN,.server_pid=getpid()};
    bool starting=false;
    if(memcmp(body.magic,DW2_MAGIC,4)||body.version!=DW2_VERSION||memcmp(body.nonce,config.nonce,64))reply.status=DW2_HELLO_AUTH;
    else if(body.role==DW2_ROLE_CONTROL) {
        if(*session_started)reply.status=DW2_HELLO_BUSY;
        else {arc4random_buf(token,16);starting=true;}
    } else if(body.role!=DW2_ROLE_HEARTBEAT||!*session_started||memcmp(body.token,token,16))reply.status=DW2_HELLO_TOKEN;
    memcpy(reply.token,token,16);*role=body.role;
    bool accepted=send_reply(fd,&h,&reply,sizeof(reply))&&reply.status==DW2_HELLO_OK;
    if(starting){if(accepted)*session_started=true;else memset(token,0,16);}
    return accepted;
}
static void *serve(void *unused) {
    startup_diagnostic("worker-enter",0,"bounded socket worker started");
    (void)unused;char path[sizeof(((struct sockaddr_un*)0)->sun_path)];
    int n=snprintf(path,sizeof(path),"%s/" DW2_SOCKET,config.runtime);
    if(n<0||(size_t)n>=sizeof(path)){startup_diagnostic("socket-path",ENAMETOOLONG,"socket address does not fit");return NULL;}
    struct sockaddr_un address={.sun_family=AF_UNIX};memcpy(address.sun_path,path,(size_t)n+1);
    int listener=socket(AF_UNIX,SOCK_STREAM,0);
    if(listener<0){startup_diagnostic("socket-create",errno,"socket creation failed");return NULL;}
    if(bind(listener,(struct sockaddr*)&address,sizeof(address))){int error=errno;close(listener);startup_diagnostic("socket-bind",error,"socket bind failed");return NULL;}
    startup_diagnostic("socket-bound",0,"socket bind completed");
    if(chmod(path,0666)){int error=errno;close(listener);startup_diagnostic("socket-mode",error,"socket chmod failed");return NULL;}
    if(listen(listener,2)){int error=errno;close(listener);startup_diagnostic("socket-listen",error,"socket listen failed");return NULL;}
    startup_diagnostic("socket-ready",0,"socket listener ready; no window mutation performed");
    uint64_t end=milliseconds()+config.lifetime_ms,lease=end;int control=-1,heartbeat=-1;
    uint8_t token[16]={0};bool started=false;unsigned sessions_completed=0;
    while(milliseconds()<end&&milliseconds()<lease&&fixture_current()) {
        struct pollfd fds[3]={{.fd=listener,.events=POLLIN},{.fd=control,.events=POLLIN},{.fd=heartbeat,.events=POLLIN}};
        if(poll(fds,3,50)<0){if(errno==EINTR)continue;break;}
        if(fds[0].revents&POLLIN) {
            int fd=accept(listener,NULL,NULL);if(fd>=0) {
                int one=1;struct timeval timeout={.tv_sec=1};
                setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
                uint16_t role=0;
                if(hello(fd,&role,token,&started)) {
                    if(role==DW2_ROLE_CONTROL&&control<0)control=fd;
                    else if(role==DW2_ROLE_HEARTBEAT&&heartbeat<0)heartbeat=fd;
                    else close(fd);
                    lease=milliseconds()+DW2_LEASE_MS;
                }else close(fd);
            }
        }
        bool stopped=false;
        for(unsigned i=1;i<3;i++)if(fds[i].fd>=0&&fds[i].revents) {
            int fd=fds[i].fd;struct dw2_header h;
            if(!read_bytes(fd,&h,sizeof(h),milliseconds()+500)||h.flags||h.length>DW2_MAX_BODY){stopped=true;break;}
            unsigned char body[DW2_MAX_BODY],reply[DW2_MAX_BODY];
            if(!read_bytes(fd,body,h.length,milliseconds()+500)){stopped=true;break;}
            lease=milliseconds()+DW2_LEASE_MS;
            if(h.type==DW2_HEARTBEAT&&!h.length) {
                uint32_t held=0;for(unsigned j=0;j<config.window_count;j++)held+=touched[j];
                struct dw2_heartbeat_reply response={.lease_ms=DW2_LEASE_MS,.held=held};
                if(!send_reply(fd,&h,&response,sizeof(response)))stopped=true;
            }else if(i==1) {
                struct request_context context={.header=&h,.body=body,.reply=reply};
                if(h.type==DW2_FRAME&&!newest_complete_frame(fd,&h,body,&context.superseded)){stopped=true;break;}
                if(!ifwsp_server_call(&config,perform_request,&context)||!context.length||!send_reply(fd,&h,reply,context.length))stopped=true;
            }else stopped=true;
            if(stopped)break;
        }
        if(stopped) {
            // Sequential benchmark trials may reconnect only after the previous
            // session's exact raw originals have been restored. There is still
            // one fixed outer lifetime and one fixed disposable fixture scope.
            if(!ifwsp_server_restore_call(&config,restore_operation,NULL)||pending_restores())break;
            if(control>=0)close(control);if(heartbeat>=0)close(heartbeat);
            control=-1;heartbeat=-1;started=false;memset(token,0,sizeof(token));
            received=0;applied=0;superseded_frames=0;lease=end;sessions_completed++;
        }
    }
    // Server callbacks restore before the worker terminates. A stalled server
    // cannot execute its own callbacks until it resumes; the fixture is disposable.
    ifwsp_server_restore_call(&config,restore_operation,NULL);
    if(control>=0)close(control);if(heartbeat>=0)close(heartbeat);close(listener);unlink(path);
    char report[140];snprintf(report,sizeof(report),"%s/restoration.txt",config.runtime);
    int fd=open(report,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd>=0){dprintf(fd,"pending=%u\nsessions_completed=%u\n",pending_restores(),sessions_completed);fsync(fd);close(fd);}
    return NULL;
}

__attribute__((constructor)) static void start(void) {
    // No sidecar means inert. In particular dlopen from a read-only inspection
    // process never opens a socket, creates a thread, or performs native queries.
    startup_diagnostic("constructor-enter",0,"payload constructor entered");
    Dl_info image={0};
    if(!dladdr((void*)&start,&image)||!image.dli_fname){startup_diagnostic("image-path",errno,"payload image lookup failed");return;}
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
