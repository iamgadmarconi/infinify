// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation. Contract: dwclient.h. Protocol: protocol2.h.
#include "dwclient.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

struct dw_client {
    int control, beat;
    struct dw_client_info info;
    struct dw_client_callbacks callbacks;
    pthread_t writer, reader, heart;
    int threads;                       // how many of the three were started, in that order
    pthread_mutex_t lock;
    pthread_cond_t wake, done, tick;   // writer has work; a request finished; heartbeat sleep
    bool lost, closing;
    uint64_t next;
    // The one frame waiting for the writer. Two buffers of the largest frame are
    // allocated at open and swapped, so submitting never allocates or writes.
    struct dw2_record *slot, *writing;
    uint32_t slotCount;
    uint64_t slotSeq;
    bool slotFull;
    // The one probe or restore-all in flight.
    uint16_t request;
    uint64_t requestSeq;
    bool requestWritten, replyReady;
    void *reply;
    size_t replyCapacity, replyLength;
    struct dw_client_stats stats;
};

// The helper's lease runs on a clock that stops while the machine sleeps, and so
// must this one: on the monotonic clock every wake would look like a lost helper.
static uint64_t now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1000000; }
static bool write_parts(int fd, struct iovec *parts, int count, int *reason) {
    size_t left=0;
    for(int i=0;i<count;i++)left+=parts[i].iov_len;
    while(left) {
        ssize_t n=writev(fd,parts,count);
        if(n<0 && errno==EINTR)continue;
        // The socket has a send timeout: a helper that stopped reading costs the
        // writer thread one second, and the caller nothing.
        if(n<=0){*reason=n<0 && errno==EAGAIN ? DW_LOST_WRITE_TIMEOUT : DW_LOST_EOF;return false;}
        left-=(size_t)n;
        for(int i=0;i<count && n;i++) {
            size_t part=(size_t)n<parts[i].iov_len ? (size_t)n : parts[i].iov_len;
            parts[i].iov_base=(char *)parts[i].iov_base+part;parts[i].iov_len-=part;n-=part;
        }
    }
    return true;
}
static bool read_all(int fd, void *bytes, size_t count) {
    char *p=bytes;
    while(count) {
        ssize_t n=read(fd,p,count);
        if(n<0 && errno==EINTR)continue;
        if(n<=0)return false;
        p+=n;count-=(size_t)n;
    }
    return true;
}
// Once: wakes every waiter, closes the session from this side so that the helper
// restores as soon as it can, and tells the owner.
static void lose(dw_client *c, int reason) {
    pthread_mutex_lock(&c->lock);
    bool first=!c->lost && !c->closing;
    if(first)c->lost=true;
    pthread_cond_broadcast(&c->wake);pthread_cond_broadcast(&c->done);pthread_cond_broadcast(&c->tick);
    pthread_mutex_unlock(&c->lock);
    if(!first)return;
    shutdown(c->control,SHUT_RDWR);shutdown(c->beat,SHUT_RDWR);
    if(c->callbacks.lost)c->callbacks.lost(c->callbacks.context,reason);
}

static void *writer_main(void *argument) {
    dw_client *c=argument;
    pthread_mutex_lock(&c->lock);
    for(;;) {
        bool wanted=c->request && !c->requestWritten;
        while(!c->lost && !c->closing && !c->slotFull && !wanted){pthread_cond_wait(&c->wake,&c->lock);wanted=c->request && !c->requestWritten;}
        if(c->lost || c->closing)break;
        struct dw2_header header={0};struct dw2_frame frame={0};
        struct iovec parts[3];int count=1,reason=0;
        // In the order they were asked for, so frame sequence numbers only rise.
        if(c->slotFull && (!wanted || c->slotSeq<c->requestSeq)) {
            struct dw2_record *records=c->slot;c->slot=c->writing;c->writing=records;
            frame.count=c->slotCount;c->slotFull=false;
            header=(struct dw2_header){.length=(uint32_t)(sizeof(frame)+frame.count*sizeof(*records)),.type=DW2_FRAME,.seq=c->slotSeq};
            parts[1]=(struct iovec){&frame,sizeof(frame)};parts[2]=(struct iovec){records,frame.count*sizeof(*records)};count=3;
        } else {
            header=(struct dw2_header){.type=c->request,.seq=c->requestSeq};c->requestWritten=true;
        }
        parts[0]=(struct iovec){&header,sizeof(header)};
        pthread_mutex_unlock(&c->lock);
        bool ok=write_parts(c->control,parts,count,&reason);
        if(!ok)lose(c,reason);
        pthread_mutex_lock(&c->lock);
        if(!ok)break;
        if(count==3)c->stats.written++;
    }
    pthread_mutex_unlock(&c->lock);
    return NULL;
}
static void *reader_main(void *argument) {
    dw_client *c=argument;
    uint8_t *body=malloc(DW2_MAX_BODY);
    int reason=DW_LOST_EOF;
    for(;;) {
        struct dw2_header header;
        if(!body || !read_all(c->control,&header,sizeof(header)))break;
        if(header.length>DW2_MAX_BODY || !(header.type&DW2_REPLY)){reason=DW_LOST_PROTOCOL;break;}
        if(!read_all(c->control,body,header.length))break;
        uint16_t type=header.type&~DW2_REPLY;
        if(type==DW2_FRAME) {
            struct dw2_frame_reply head;
            if(header.length<sizeof(head)){reason=DW_LOST_PROTOCOL;break;}
            memcpy(&head,body,sizeof(head));
            if(header.length!=sizeof(head)+head.count){reason=DW_LOST_PROTOCOL;break;}
            const uint8_t *status=body+sizeof(head);
            pthread_mutex_lock(&c->lock);
            c->stats.superseded+=head.superseded;
            if(head.disposition==DW2_FRAME_APPLIED) {
                c->stats.applied++;c->stats.last_applied_seq=header.seq;
                for(uint32_t i=0;i<head.count;i++)if(status[i]==DW2_APPLIED)c->stats.records_applied++;else c->stats.records_failed++;
            } else c->stats.discarded++;
            pthread_mutex_unlock(&c->lock);
            if(head.disposition==DW2_FRAME_APPLIED && c->callbacks.frame_result)c->callbacks.frame_result(c->callbacks.context,header.seq,status,head.count);
        } else {
            pthread_mutex_lock(&c->lock);
            if(c->request==type && c->requestSeq==header.seq && !c->replyReady) {
                c->replyLength=header.length;
                memcpy(c->reply,body,header.length<c->replyCapacity ? header.length : c->replyCapacity);
                c->replyReady=true;pthread_cond_broadcast(&c->done);
            }
            pthread_mutex_unlock(&c->lock);
        }
    }
    free(body);
    lose(c,reason);
    return NULL;
}
// Keeps the lease on its own connection, so a caller whose frame loop is stalled
// keeps its windows where they are, and reports a helper that stopped answering.
static void *heart_main(void *argument) {
    dw_client *c=argument;
    uint32_t interval=c->info.lease_ms/4 ? c->info.lease_ms/4 : 1;
    uint64_t acked=now_ms();
    for(;;) {
        uint64_t started=now_ms();int reason=0;
        struct dw2_header header={.type=DW2_HEARTBEAT,.seq=started};
        struct iovec part={&header,sizeof(header)};
        pthread_mutex_lock(&c->lock);
        bool stop=c->lost || c->closing;
        if(!stop)c->stats.heartbeats_sent++;
        pthread_mutex_unlock(&c->lock);
        if(stop)break;
        if(!write_parts(c->beat,&part,1,&reason)){lose(c,reason);break;}
        // Take every answer that has arrived by the end of this interval.
        for(;;) {
            int64_t left=(int64_t)(started+interval)-(int64_t)now_ms();
            struct pollfd p={.fd=c->beat,.events=POLLIN};
            if(left<=0 || poll(&p,1,(int)left)<=0)break;
            struct dw2_heartbeat_reply reply;
            if(!read_all(c->beat,&header,sizeof(header)) || header.length!=sizeof(reply) || !read_all(c->beat,&reply,sizeof(reply))){reason=DW_LOST_EOF;break;}
            acked=now_ms();
            pthread_mutex_lock(&c->lock);c->stats.heartbeats_acked++;pthread_mutex_unlock(&c->lock);
        }
        if(!reason && now_ms()-acked>c->info.lease_ms)reason=DW_LOST_HEARTBEAT;
        if(reason){lose(c,reason);break;}
        int64_t left=(int64_t)(started+interval)-(int64_t)now_ms();
        pthread_mutex_lock(&c->lock);
        if(left>0 && !c->lost && !c->closing) {
            struct timespec wait={.tv_sec=left/1000,.tv_nsec=(left%1000)*1000000};
            pthread_cond_timedwait_relative_np(&c->tick,&c->lock,&wait);
        }
        pthread_mutex_unlock(&c->lock);
    }
    return NULL;
}

// One bounded attempt: connect, say hello, read the answer. Everything is
// non-blocking and polled against the caller's deadline.
static int hello(const struct sockaddr_un *address, uint16_t role, const char *nonce, const uint8_t *token,
                 uint64_t deadline, struct dw2_hello_reply *reply) {
    int fd=socket(AF_UNIX,SOCK_STREAM,0);
    if(fd<0)return -1;
    int one=1;uid_t uid;gid_t gid;
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK);
    struct { struct dw2_header header; struct dw2_hello hello; } out={.header={.length=sizeof(struct dw2_hello),.type=DW2_HELLO},.hello={.version=DW2_VERSION,.role=role}};
    struct { struct dw2_header header; struct dw2_hello_reply reply; } in;
    memcpy(out.hello.magic,DW2_MAGIC,4);memcpy(out.hello.nonce,nonce,64);
    if(token)memcpy(out.hello.token,token,16);
    bool ok=connect(fd,(const struct sockaddr *)address,sizeof(*address))==0;
    if(!ok && errno==EINPROGRESS) {
        struct pollfd p={.fd=fd,.events=POLLOUT};int error=0;socklen_t size=sizeof(error);
        int64_t left=(int64_t)deadline-(int64_t)now_ms();
        ok=left>0 && poll(&p,1,(int)left)>0 && getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&size)==0 && !error;
    }
    ok=ok && getpeereid(fd,&uid,&gid)==0 && uid==getuid() && write(fd,&out,sizeof(out))==(ssize_t)sizeof(out);
    size_t used=0;
    while(ok && used<sizeof(in)) {
        struct pollfd p={.fd=fd,.events=POLLIN};
        int64_t left=(int64_t)deadline-(int64_t)now_ms();
        if(left<=0 || poll(&p,1,(int)left)<=0){ok=false;break;}
        ssize_t n=read(fd,(char *)&in+used,sizeof(in)-used);
        if(n<0 && (errno==EINTR || errno==EAGAIN))continue;
        if(n<=0)ok=false;else used+=(size_t)n;
    }
    if(!ok || in.header.type!=(DW2_HELLO|DW2_REPLY) || in.header.length!=sizeof(in.reply)){close(fd);return -1;}
    *reply=in.reply;
    if(reply->status){close(fd);return -1;}
    // From here the threads use it blocking, with bounded writes.
    struct timeval second={.tv_sec=1};
    fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)&~O_NONBLOCK);
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&second,sizeof(second));
    return fd;
}
// A helper that serves protocol v1 and never opened v2's socket: v2 failed to start
// there (its log says why), which waiting longer will not change.
static bool v2_missing(const char *runtime) {
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];struct stat st;
    if(snprintf(path,sizeof(path),"%s/helper.sock",runtime)>=(int)sizeof(path) || lstat(path,&st) || !S_ISSOCK(st.st_mode))return false;
    return snprintf(path,sizeof(path),"%s/" DW2_SOCKET,runtime)<(int)sizeof(path) && lstat(path,&st) && errno==ENOENT;
}
int dw_client_open(const char *runtime, const char *nonce64, const struct dw_client_callbacks *callbacks,
                   uint32_t timeout_ms, dw_client **out, struct dw_client_info *info) {
    struct sockaddr_un address={.sun_family=AF_UNIX};
    if(!runtime || !nonce64 || strlen(nonce64)!=64 || !out)return DW_CLIENT_INVALID;
    if(snprintf(address.sun_path,sizeof(address.sun_path),"%s/" DW2_SOCKET,runtime)>=(int)sizeof(address.sun_path))return DW_CLIENT_INVALID;
    uint64_t deadline=now_ms()+timeout_ms;
    struct dw2_hello_reply reply={0};
    int control=-1,beat=-1;
    for(;;) {
        reply.status=DW2_HELLO_OK;
        control=hello(&address,DW2_ROLE_CONTROL,nonce64,NULL,deadline,&reply);
        if(control>=0)break;
        // Busy is another session still ending; no answer may be a helper not yet up.
        if(reply.status && reply.status!=DW2_HELLO_BUSY)return DW_CLIENT_REFUSED;
        if(now_ms()+20>=deadline)return v2_missing(runtime) ? DW_CLIENT_NO_V2 : DW_CLIENT_TIMEOUT;
        usleep(20000);
    }
    beat=hello(&address,DW2_ROLE_HEARTBEAT,nonce64,reply.token,deadline,&reply);
    dw_client *c=beat>=0 ? calloc(1,sizeof(*c)) : NULL;
    if(c){c->slot=malloc(reply.max_records*sizeof(*c->slot));c->writing=malloc(reply.max_records*sizeof(*c->writing));}
    if(!c || !c->slot || !c->writing) {
        if(c){free(c->slot);free(c->writing);free(c);}
        close(control);if(beat>=0)close(beat);
        return beat>=0 ? DW_CLIENT_INVALID : DW_CLIENT_TIMEOUT;
    }
    c->control=control;c->beat=beat;
    c->info=(struct dw_client_info){.lease_ms=reply.lease_ms,.max_records=reply.max_records,.caps=reply.caps,.scope=reply.scope,.queue=reply.queue,.server_pid=reply.server_pid};
    if(callbacks)c->callbacks=*callbacks;
    if(info)*info=c->info;
    pthread_mutex_init(&c->lock,NULL);pthread_cond_init(&c->wake,NULL);pthread_cond_init(&c->done,NULL);pthread_cond_init(&c->tick,NULL);
    if(!pthread_create(&c->writer,NULL,writer_main,c) && ++c->threads && !pthread_create(&c->reader,NULL,reader_main,c) && ++c->threads && !pthread_create(&c->heart,NULL,heart_main,c))c->threads++;
    // A thread short is no client: end those that started and give everything back.
    if(c->threads!=3){dw_client_close(c);return DW_CLIENT_INVALID;}
    *out=c;
    return DW_CLIENT_OK;
}
int dw_client_submit_frame(dw_client *c, const struct dw2_record *records, uint32_t count, uint64_t *seq) {
    if(!c || (count && !records) || count>c->info.max_records)return DW_CLIENT_INVALID;
    pthread_mutex_lock(&c->lock);
    int result=c->lost || c->closing ? DW_CLIENT_LOST : DW_CLIENT_OK;
    if(result==DW_CLIENT_OK) {
        memcpy(c->slot,records,count*sizeof(*records));
        if(c->slotFull)c->stats.dropped_local++;
        c->slotCount=count;c->slotSeq=++c->next;c->slotFull=true;c->stats.submitted++;
        if(seq)*seq=c->slotSeq;
        pthread_cond_signal(&c->wake);
    }
    pthread_mutex_unlock(&c->lock);
    return result;
}
// Waits on a condition for at most timeout_ms; the request itself is written by
// the writer thread.
static int ask(dw_client *c, uint16_t type, uint32_t timeout_ms, void *reply, size_t capacity, size_t *length) {
    uint64_t deadline=now_ms()+timeout_ms;
    int result=DW_CLIENT_OK;
    bool sent=false;
    pthread_mutex_lock(&c->lock);
    for(;;) {
        if(c->lost || c->closing){result=DW_CLIENT_LOST;break;}
        if(sent && c->replyReady)break;
        if(!sent && !c->request) {
            // What is asked to be restored must not be followed by an older frame.
            if(type==DW2_RESTORE_ALL && c->slotFull){c->slotFull=false;c->stats.dropped_local++;}
            c->request=type;c->requestSeq=++c->next;c->requestWritten=c->replyReady=false;
            c->reply=reply;c->replyCapacity=capacity;c->replyLength=0;sent=true;
            pthread_cond_signal(&c->wake);
            continue;
        }
        int64_t left=(int64_t)deadline-(int64_t)now_ms();
        if(left<=0){result=DW_CLIENT_TIMEOUT;break;}
        struct timespec wait={.tv_sec=left/1000,.tv_nsec=(left%1000)*1000000};
        pthread_cond_timedwait_relative_np(&c->done,&c->lock,&wait);
    }
    // Free the request for the next caller; a late answer is then ignored.
    if(sent) {
        if(length)*length=c->replyLength;
        if(result==DW_CLIENT_OK && c->replyLength>capacity)result=DW_CLIENT_INVALID;
        c->request=0;c->reply=NULL;c->replyCapacity=0;
        pthread_cond_broadcast(&c->done);
    }
    pthread_mutex_unlock(&c->lock);
    return result;
}
int dw_client_probe(dw_client *c, uint32_t timeout_ms, void *reply, size_t capacity, size_t *length) {
    if(!c || !reply)return DW_CLIENT_INVALID;
    return ask(c,DW2_PROBE,timeout_ms,reply,capacity,length);
}
int dw_client_restore_all(dw_client *c, uint32_t timeout_ms, struct dw2_restore_result *results,
                          uint32_t capacity, uint32_t *count, uint32_t *pending) {
    if(!c)return DW_CLIENT_INVALID;
    size_t size=sizeof(struct dw2_restore_reply)+DW2_MAX_TABLE*sizeof(struct dw2_restore_result),length=0;
    struct dw2_restore_reply *reply=malloc(size);
    if(!reply)return DW_CLIENT_INVALID;
    int result=ask(c,DW2_RESTORE_ALL,timeout_ms,reply,size,&length);
    if(result==DW_CLIENT_OK && (length<sizeof(*reply) || length!=sizeof(*reply)+reply->count*sizeof(*results)))result=DW_CLIENT_INVALID;
    if(result==DW_CLIENT_OK) {
        if(count)*count=reply->count;
        if(pending)*pending=reply->pending;
        if(results)memcpy(results,reply+1,(reply->count<capacity ? reply->count : capacity)*sizeof(*results));
    }
    free(reply);
    return result;
}
void dw_client_stats(dw_client *c, struct dw_client_stats *stats) {
    pthread_mutex_lock(&c->lock);*stats=c->stats;pthread_mutex_unlock(&c->lock);
}
void dw_client_close(dw_client *c) {
    if(!c)return;
    pthread_mutex_lock(&c->lock);
    c->closing=true;
    pthread_cond_broadcast(&c->wake);pthread_cond_broadcast(&c->done);pthread_cond_broadcast(&c->tick);
    pthread_mutex_unlock(&c->lock);
    shutdown(c->control,SHUT_RDWR);shutdown(c->beat,SHUT_RDWR);
    if(c->threads>0)pthread_join(c->writer,NULL);
    if(c->threads>1)pthread_join(c->reader,NULL);
    if(c->threads>2)pthread_join(c->heart,NULL);
    close(c->control);close(c->beat);
    pthread_mutex_destroy(&c->lock);pthread_cond_destroy(&c->wake);pthread_cond_destroy(&c->done);pthread_cond_destroy(&c->tick);
    free(c->slot);free(c->writing);free(c);
}
