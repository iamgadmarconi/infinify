// SPDX-License-Identifier: GPL-3.0-or-later
// Original implementation. Contract: DWHelperClient.h. Protocol: DWHelperProtocol.h.
#include "DWHelperClient.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <math.h>
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

// Bound acknowledgement bookkeeping independently of a peer's read rate. The
// writer waits for replies at this limit while the newest unsent frame remains
// replaceable in the single-frame slot.
#define DW_CLIENT_MAX_PENDING_FRAMES 1024u
_Static_assert((DW_CLIENT_MAX_PENDING_FRAMES&(DW_CLIENT_MAX_PENDING_FRAMES-1))==0,"pending frame ring size");

struct dw_client_pending_frame { uint64_t seq; uint32_t count; uint16_t type; };

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
    void *slot, *writing;
    uint32_t slotCount;
    uint16_t slotType;
    size_t slotBytes;
    uint64_t slotSeq;
    bool slotFull;
    struct dw_client_pending_frame *pendingFrames;
    uint32_t pendingHead, pendingCount;
    // The one inspection, probe, enrollment audit, veil request or restore-all in flight.
    uint16_t request;
    uint8_t requestBody[sizeof(struct dw2_move)]; // the largest request body (MOVE)
    size_t requestLength;
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
// A heartbeat may become readable with only part of a reply. Its lease still
// bounds the remaining bytes: a truncated reply cannot strand this thread and
// keep the control connection (and native transforms) alive forever.
static bool read_until(int fd, void *bytes, size_t count, uint64_t deadline) {
    char *p=bytes;
    while(count) {
        int64_t left=(int64_t)deadline-(int64_t)now_ms();
        if(left<=0)return false;
        struct pollfd ready={.fd=fd,.events=POLLIN};
        int result=poll(&ready,1,(int)left);
        if(result<0 && errno==EINTR)continue;
        if(result<=0)return false;
        ssize_t n=recv(fd,p,count,MSG_DONTWAIT);
        if(n<0 && (errno==EINTR || errno==EAGAIN))continue;
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

// Called with c->lock held. A reply must name a frame the writer actually
// handed to the socket, and the server's superseded count must account for
// exactly the older sent frames that have no reply. Locally coalesced frames
// never enter this queue.
static bool accept_frame_reply_locked(dw_client *c, uint16_t type, uint64_t seq, const struct dw2_frame_reply *reply,
                                      const uint8_t *status) {
    uint32_t offset=0;
    while(offset<c->pendingCount) {
        uint32_t index=(c->pendingHead+offset)&(DW_CLIENT_MAX_PENDING_FRAMES-1);
        if(c->pendingFrames[index].seq==seq)break;
        offset++;
    }
    if(offset==c->pendingCount || offset!=reply->superseded)return false;
    uint32_t index=(c->pendingHead+offset)&(DW_CLIENT_MAX_PENDING_FRAMES-1);
    struct dw_client_pending_frame frame=c->pendingFrames[index];
    if(type!=frame.type || (reply->disposition==DW2_FRAME_APPLIED && reply->count!=frame.count)
        || (reply->disposition==DW2_FRAME_DROPPED && reply->count))return false;

    c->pendingHead=(c->pendingHead+offset+1)&(DW_CLIENT_MAX_PENDING_FRAMES-1);
    c->pendingCount-=offset+1;
    c->stats.superseded+=reply->superseded;
    if(reply->disposition==DW2_FRAME_APPLIED) {
        c->stats.applied++;c->stats.last_applied_seq=seq;
        for(uint32_t i=0;i<reply->count;i++)if(status[i]==DW2_APPLIED)c->stats.records_applied++;else c->stats.records_failed++;
    } else c->stats.discarded++;
    return true;
}

static void *writer_main(void *argument) {
    dw_client *c=argument;
    pthread_mutex_lock(&c->lock);
    for(;;) {
        bool wanted=false,frameWanted=false;
        while(!c->lost && !c->closing) {
            wanted=c->request && !c->requestWritten;
            frameWanted=c->slotFull && (!wanted || c->slotSeq<c->requestSeq);
            if((frameWanted && c->pendingCount<DW_CLIENT_MAX_PENDING_FRAMES) || (!frameWanted && wanted))break;
            pthread_cond_wait(&c->wake,&c->lock);
        }
        if(c->lost || c->closing)break;
        struct dw2_header header={0};struct dw2_frame frame={0};uint8_t requestBody[sizeof(c->requestBody)]={0};
        struct iovec parts[3];int count=1,reason=0;
        // In the order they were asked for, so frame sequence numbers only rise.
        if(frameWanted) {
            void *records=c->slot;c->slot=c->writing;c->writing=records;
            frame.count=c->slotCount;c->slotFull=false;
            header=(struct dw2_header){.length=(uint32_t)(sizeof(frame)+c->slotBytes),.type=c->slotType,.seq=c->slotSeq};
            parts[1]=(struct iovec){&frame,sizeof(frame)};parts[2]=(struct iovec){records,c->slotBytes};count=3;
        } else {
            header=(struct dw2_header){.length=(uint32_t)c->requestLength,.type=c->request,.seq=c->requestSeq};c->requestWritten=true;
            if(c->requestLength){memcpy(requestBody,c->requestBody,c->requestLength);parts[1]=(struct iovec){requestBody,c->requestLength};count=2;}
        }
        if(count==3) {
            uint32_t index=(c->pendingHead+c->pendingCount)&(DW_CLIENT_MAX_PENDING_FRAMES-1);
            c->pendingFrames[index]=(struct dw_client_pending_frame){.seq=header.seq,.count=frame.count,.type=header.type};
            c->pendingCount++;
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
        if(header.length>DW2_MAX_BODY || header.flags || !(header.type&DW2_REPLY) || !header.seq){reason=DW_LOST_PROTOCOL;break;}
        if(!read_all(c->control,body,header.length))break;
        uint16_t type=header.type&~DW2_REPLY;
        if(type==DW2_FRAME || type==DW2_FRAME_SPACE) {
            struct dw2_frame_reply head;
            if(header.length<sizeof(head) || (type==DW2_FRAME_SPACE && !(c->info.caps&DW2_CAP_SPACE))){reason=DW_LOST_PROTOCOL;break;}
            memcpy(&head,body,sizeof(head));
            if(head.count>c->info.max_records || head.reserved || head.disposition>DW2_FRAME_DROPPED
                || (head.disposition==DW2_FRAME_DROPPED && head.count) || header.length!=sizeof(head)+head.count){reason=DW_LOST_PROTOCOL;break;}
            const uint8_t *status=body+sizeof(head);
            bool valid=true;for(uint32_t i=0;i<head.count;i++)if(status[i]>DW2_SUBLEVEL
                || (status[i]==DW2_SPACE && !(c->info.caps&DW2_CAP_SPACE))
                || (status[i]==DW2_SUBLEVEL && !(c->info.caps&DW2_CAP_PINNED))){valid=false;break;}
            if(!valid){reason=DW_LOST_PROTOCOL;break;}
            pthread_mutex_lock(&c->lock);
            valid=accept_frame_reply_locked(c,type,header.seq,&head,status);
            if(valid)pthread_cond_signal(&c->wake);
            pthread_mutex_unlock(&c->lock);
            if(!valid){reason=DW_LOST_PROTOCOL;break;}
            if(head.disposition==DW2_FRAME_APPLIED && c->callbacks.frame_result)c->callbacks.frame_result(c->callbacks.context,header.seq,status,head.count);
        } else if(type==DW2_PROBE || type==DW2_RESTORE_ALL || type==DW2_ENROLLMENT || type==DW2_INSPECT || type==DW2_VEIL || type==DW2_MOVE) {
            pthread_mutex_lock(&c->lock);
            if(c->request==type && c->requestSeq==header.seq && !c->replyReady) {
                c->replyLength=header.length;
                memcpy(c->reply,body,header.length<c->replyCapacity ? header.length : c->replyCapacity);
                c->replyReady=true;pthread_cond_broadcast(&c->done);
            }
            pthread_mutex_unlock(&c->lock);
        } else {reason=DW_LOST_PROTOCOL;break;}
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
    uint64_t acked=now_ms(),lastReply=0;
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
            uint64_t deadline=acked+c->info.lease_ms;
            if(!read_until(c->beat,&header,sizeof(header),deadline)){reason=DW_LOST_HEARTBEAT;break;}
            if(header.type!=(DW2_HEARTBEAT|DW2_REPLY) || header.flags || header.length!=sizeof(reply)
                || header.seq<=lastReply || header.seq>started){reason=DW_LOST_PROTOCOL;break;}
            if(!read_until(c->beat,&reply,sizeof(reply),deadline)){reason=DW_LOST_HEARTBEAT;break;}
            if(reply.status || reply.lease_ms!=c->info.lease_ms || reply.held>DW2_MAX_TABLE || reply.restoring>DW2_MAX_TABLE){reason=DW_LOST_PROTOCOL;break;}
            lastReply=header.seq;
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
    int one=1;uid_t uid;gid_t gid;pid_t peer=0;socklen_t peerSize=sizeof(peer);
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
    // The loader drops its effective UID to the login user for this audit while
    // retaining real UID 0. Authenticate the identity used by this connection.
    ok=ok && getpeereid(fd,&uid,&gid)==0 && uid==geteuid()
        && getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&peer,&peerSize)==0 && peerSize==sizeof(peer) && peer>1;
    size_t sent=0;
    while(ok && sent<sizeof(out)) {
        int64_t left=(int64_t)deadline-(int64_t)now_ms();struct pollfd ready={.fd=fd,.events=POLLOUT};
        if(left<=0 || poll(&ready,1,(int)left)<=0){ok=false;break;}
        ssize_t n=write(fd,(const char *)&out+sent,sizeof(out)-sent);
        if(n<0 && (errno==EINTR || errno==EAGAIN))continue;
        if(n<=0)ok=false;else sent+=(size_t)n;
    }
    size_t used=0;
    while(ok && used<sizeof(in)) {
        struct pollfd p={.fd=fd,.events=POLLIN};
        int64_t left=(int64_t)deadline-(int64_t)now_ms();
        if(left<=0 || poll(&p,1,(int)left)<=0){ok=false;break;}
        ssize_t n=read(fd,(char *)&in+used,sizeof(in)-used);
        if(n<0 && (errno==EINTR || errno==EAGAIN))continue;
        if(n<=0)ok=false;else used+=(size_t)n;
    }
    if(!ok || in.header.type!=(DW2_HELLO|DW2_REPLY) || in.header.flags || in.header.seq || in.header.length!=sizeof(in.reply)){close(fd);return -1;}
    *reply=in.reply;
    if(reply->status){close(fd);return -1;}
    bool nonzeroToken=false;for(size_t i=0;i<sizeof(reply->token);i++)nonzeroToken|=reply->token[i]!=0;
    if(reply->server_pid!=peer || !reply->lease_ms || reply->lease_ms>60000
        || !reply->max_records || reply->max_records>DW2_MAX_RECORDS || reply->max_body>DW2_MAX_BODY
        || reply->max_body<sizeof(struct dw2_frame)+(size_t)reply->max_records
            *(reply->caps&DW2_CAP_SPACE ? sizeof(struct dw2_space_record) : sizeof(struct dw2_record))
        || reply->scope<DW2_SCOPE_COOPERATIVE || reply->scope>DW2_SCOPE_SAME_USER || reply->queue>DW2_QUEUE_MAIN
        || !nonzeroToken || (token && memcmp(token,reply->token,sizeof(reply->token)))) {
        reply->status=DW2_HELLO_MALFORMED;close(fd);return -1;
    }
    // From here the threads use it blocking, with bounded writes.
    struct timeval second={.tv_sec=1};
    fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)&~O_NONBLOCK);
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&second,sizeof(second));
    return fd;
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
        if(now_ms()+20>=deadline)return DW_CLIENT_TIMEOUT;
        usleep(20000);
    }
    struct dw2_hello_reply beatReply={0};
    beat=hello(&address,DW2_ROLE_HEARTBEAT,nonce64,reply.token,deadline,&beatReply);
    if(beat>=0 && memcmp(&reply,&beatReply,sizeof(reply))){close(beat);beat=-1;beatReply.status=DW2_HELLO_MALFORMED;}
    dw_client *c=beat>=0 ? calloc(1,sizeof(*c)) : NULL;
    if(c){
        size_t bytes=reply.max_records*(reply.caps&DW2_CAP_SPACE ? sizeof(struct dw2_space_record) : sizeof(struct dw2_record));
        c->slot=malloc(bytes);c->writing=malloc(bytes);c->pendingFrames=calloc(DW_CLIENT_MAX_PENDING_FRAMES,sizeof(*c->pendingFrames));
    }
    if(!c || !c->slot || !c->writing || !c->pendingFrames) {
        if(c){free(c->slot);free(c->writing);free(c->pendingFrames);free(c);}
        close(control);if(beat>=0)close(beat);
        return beat>=0 ? DW_CLIENT_INVALID : beatReply.status ? DW_CLIENT_REFUSED : DW_CLIENT_TIMEOUT;
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
static int submit_frame(dw_client *c, const void *records, uint32_t count, uint16_t type, size_t recordSize, uint64_t *seq) {
    if(!c || (count && !records) || count>c->info.max_records)return DW_CLIENT_INVALID;
    if(type==DW2_FRAME_SPACE && !(c->info.caps&DW2_CAP_SPACE))return DW_CLIENT_INVALID;
    if(!(c->info.caps&DW2_CAP_PINNED))for(uint32_t i=0;i<count;i++){
        struct dw2_record record;memcpy(&record,(const uint8_t *)records+i*recordSize,sizeof(record));
        if(record.flags&DW2_RECORD_PINNED)return DW_CLIENT_INVALID;
    }
    pthread_mutex_lock(&c->lock);
    int result=c->lost || c->closing ? DW_CLIENT_LOST : DW_CLIENT_OK;
    if(result==DW_CLIENT_OK) {
        if(count)memcpy(c->slot,records,count*recordSize);
        if(c->slotFull)c->stats.dropped_local++;
        c->slotCount=count;c->slotType=type;c->slotBytes=count*recordSize;
        c->slotSeq=++c->next;c->slotFull=true;c->stats.submitted++;
        if(seq)*seq=c->slotSeq;
        pthread_cond_signal(&c->wake);
    }
    pthread_mutex_unlock(&c->lock);
    return result;
}
int dw_client_submit_frame(dw_client *c, const struct dw2_record *records, uint32_t count, uint64_t *seq) {
    return submit_frame(c,records,count,DW2_FRAME,sizeof(*records),seq);
}
int dw_client_submit_space_frame(dw_client *c, const struct dw2_space_record *records, uint32_t count, uint64_t *seq) {
    return submit_frame(c,records,count,DW2_FRAME_SPACE,sizeof(*records),seq);
}
// Waits on a condition for at most timeout_ms; the request itself is written by
// the writer thread.
static int ask(dw_client *c, uint16_t type, const void *body, size_t bodyLength, uint32_t timeout_ms, void *reply, size_t capacity, size_t *length) {
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
            c->requestLength=bodyLength;
            if(bodyLength)memcpy(c->requestBody,body,bodyLength);
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
    if(!c || !reply || capacity<sizeof(struct dw2_probe_reply))return DW_CLIENT_INVALID;
    size_t received=0;
    int result=ask(c,DW2_PROBE,NULL,0,timeout_ms,reply,capacity,&received);
    if(result!=DW_CLIENT_OK)return result;
    struct dw2_probe_reply head;
    if(received<sizeof(head))return DW_CLIENT_INVALID;
    memcpy(&head,reply,sizeof(head));
    if(head.scope!=c->info.scope || head.caps!=c->info.caps || head.queue!=c->info.queue || head.lease_ms!=c->info.lease_ms
        || head.server_pid!=c->info.server_pid || head.journal_pending>1 || head.table_count>DW2_MAX_TABLE || head.fixture_count>16
        || head.held>head.table_count || head.restoring!=head.table_count-head.held
        || received!=sizeof(head)+(size_t)head.table_count*sizeof(struct dw2_probe_entry)+(size_t)head.fixture_count*sizeof(struct dw2_identity))return DW_CLIENT_INVALID;
    if(length)*length=received;
    return DW_CLIENT_OK;
}
int dw_client_inspect(dw_client *c, uint32_t timeout_ms, const struct dw2_identity *identity, struct dw2_inspect_reply *reply) {
    if(!c || !identity || !reply || !(c->info.caps&DW2_CAP_INSPECT))return DW_CLIENT_INVALID;
    struct dw2_inspect_reply observed={0};size_t length=0;
    int result=ask(c,DW2_INSPECT,identity,sizeof(*identity),timeout_ms,&observed,sizeof(observed),&length);
    if(result!=DW_CLIENT_OK)return result;
    if(length!=sizeof(observed) || memcmp(&observed.id,identity,sizeof(*identity)))return DW_CLIENT_INVALID;
    if(observed.status) {
        if(observed.status!=DW2_SCOPE && observed.status!=DW2_IDENTITY && observed.status!=DW2_SNAPSHOT)return DW_CLIENT_INVALID;
        struct dw2_inspect_reply refused={.id=*identity,.status=observed.status};
        if(memcmp(&observed,&refused,sizeof(observed)))return DW_CLIENT_INVALID;
    } else {
        if(observed.owner<=0 || observed.bounds[2]<=0 || observed.bounds[3]<=0 || observed.screen_rect[2]<=0 || observed.screen_rect[3]<=0)return DW_CLIENT_INVALID;
        for(size_t i=0;i<6;i++)if(!isfinite(observed.transform[i]))return DW_CLIENT_INVALID;
        for(size_t i=0;i<4;i++)if(!isfinite(observed.bounds[i]) || !isfinite(observed.screen_rect[i]))return DW_CLIENT_INVALID;
    }
    *reply=observed;return DW_CLIENT_OK;
}
int dw_client_move(dw_client *c, uint32_t timeout_ms, const struct dw2_identity *identity, double x, double y, struct dw2_move_reply *reply) {
    if(!c || !identity || !reply || !(c->info.caps&DW2_CAP_MOVE) || !isfinite(x) || !isfinite(y))return DW_CLIENT_INVALID;
    struct dw2_move request={.id=*identity,.origin={x,y}};struct dw2_move_reply observed={0};size_t length=0;
    int result=ask(c,DW2_MOVE,&request,sizeof(request),timeout_ms,&observed,sizeof(observed),&length);
    if(result!=DW_CLIENT_OK)return result;
    if(length!=sizeof(observed) || memcmp(&observed.id,identity,sizeof(*identity)))return DW_CLIENT_INVALID;
    if(observed.status==DW2_APPLIED || observed.status==DW2_NOT_APPLIED) {
        if(observed.path>DW2_MOVE_DIRECT || (observed.status==DW2_APPLIED && (observed.path==DW2_MOVE_NONE || observed.bounds[2]<=0 || observed.bounds[3]<=0)))return DW_CLIENT_INVALID;
        for(size_t i=0;i<4;i++)if(!isfinite(observed.bounds[i]))return DW_CLIENT_INVALID;
    } else {
        // A refusal changed nothing and says nothing more.
        if(observed.status!=DW2_SCOPE && observed.status!=DW2_IDENTITY && observed.status!=DW2_SNAPSHOT && observed.status!=DW2_MALFORMED)return DW_CLIENT_INVALID;
        struct dw2_move_reply refused={.id=*identity,.status=observed.status};
        if(memcmp(&observed,&refused,sizeof(observed)))return DW_CLIENT_INVALID;
    }
    *reply=observed;return DW_CLIENT_OK;
}
int dw_client_veil(dw_client *c, uint32_t timeout_ms, bool enable, uint32_t *held_ms) {
    if(!c || !(c->info.caps&DW2_CAP_VEIL))return DW_CLIENT_INVALID;
    struct dw2_veil request={.mode=enable ? 1 : 0};struct dw2_veil_reply observed={0};size_t length=0;
    int result=ask(c,DW2_VEIL,&request,sizeof(request),timeout_ms,&observed,sizeof(observed),&length);
    if(result!=DW_CLIENT_OK)return result;
    if(length!=sizeof(observed) || (observed.status!=DW2_APPLIED && observed.status!=DW2_SCOPE) || !observed.timeout_ms || observed.timeout_ms>60000)return DW_CLIENT_INVALID;
    if(observed.status)return DW_CLIENT_REFUSED;
    if(held_ms)*held_ms=observed.timeout_ms;
    return DW_CLIENT_OK;
}
int dw_client_enrollment(dw_client *c, uint32_t timeout_ms, struct dw2_process *processes,
                         uint32_t capacity, uint32_t *count) {
    if(!c || !count || (capacity && !processes) || !(c->info.caps&DW2_CAP_ENROLLMENT))return DW_CLIENT_INVALID;
    size_t size=sizeof(struct dw2_enrollment_reply)+DW2_MAX_PROCESSES*sizeof(struct dw2_process),length=0;
    struct dw2_enrollment_reply *reply=malloc(size);
    if(!reply)return DW_CLIENT_INVALID;
    int result=ask(c,DW2_ENROLLMENT,NULL,0,timeout_ms,reply,size,&length);
    if(result==DW_CLIENT_OK && (length<sizeof(*reply) || reply->reserved || reply->scope!=c->info.scope || reply->server_pid!=c->info.server_pid || reply->count>DW2_MAX_PROCESSES || reply->count>capacity || length!=sizeof(*reply)+(size_t)reply->count*sizeof(*processes)))result=DW_CLIENT_INVALID;
    const struct dw2_process *entries=(const struct dw2_process *)(reply+1);
    if(result==DW_CLIENT_OK){
        if(reply->scope==DW2_SCOPE_COOPERATIVE && (reply->count!=1 || entries[0].pid!=reply->server_pid))result=DW_CLIENT_INVALID;
        else if(reply->scope==DW2_SCOPE_ALLOWLIST && !reply->count)result=DW_CLIENT_INVALID;
        else if(reply->scope==DW2_SCOPE_SAME_USER && reply->count)result=DW_CLIENT_INVALID;
        else if(reply->scope<DW2_SCOPE_COOPERATIVE || reply->scope>DW2_SCOPE_SAME_USER)result=DW_CLIENT_INVALID;
        for(uint32_t i=0;result==DW_CLIENT_OK && i<reply->count;i++){
            if(entries[i].pid<=0 || entries[i].reserved || !entries[i].birth_sec || entries[i].birth_usec>=1000000){result=DW_CLIENT_INVALID;break;}
            for(uint32_t j=0;j<i;j++)if(entries[j].pid==entries[i].pid){result=DW_CLIENT_INVALID;break;}
        }
    }
    if(result==DW_CLIENT_OK){if(reply->count)memcpy(processes,entries,reply->count*sizeof(*processes));*count=reply->count;}
    free(reply);return result;
}
int dw_client_restore_all(dw_client *c, uint32_t timeout_ms, struct dw2_restore_result *results,
                          uint32_t capacity, uint32_t *count, uint32_t *pending, uint32_t *journal_persisted) {
    if(!c || !journal_persisted || (capacity && !results))return DW_CLIENT_INVALID;
    size_t size=sizeof(struct dw2_restore_reply)+DW2_MAX_TABLE*sizeof(struct dw2_restore_result),length=0;
    struct dw2_restore_reply *reply=malloc(size);
    if(!reply)return DW_CLIENT_INVALID;
    int result=ask(c,DW2_RESTORE_ALL,NULL,0,timeout_ms,reply,size,&length);
    if(result==DW_CLIENT_OK && (length<sizeof(*reply) || reply->count>DW2_MAX_TABLE || reply->pending>reply->count
        || reply->journal_persisted>1 || reply->reserved || (results && reply->count>capacity)
        || length!=sizeof(*reply)+(size_t)reply->count*sizeof(struct dw2_restore_result)))result=DW_CLIENT_INVALID;
    if(result==DW_CLIENT_OK) {
        const struct dw2_restore_result *entries=(const struct dw2_restore_result *)(reply+1);
        uint32_t pendingEntries=0;
        for(uint32_t i=0;i<reply->count;i++) {
            const struct dw2_restore_result *entry=&entries[i];
            if(entry->id.pid<=0 || !entry->id.wid || !entry->id.birth_sec || entry->id.birth_usec>=1000000
                || entry->outcome>DW2_PENDING || (entry->outcome!=DW2_PENDING && entry->set_status)) {
                result=DW_CLIENT_INVALID;break;
            }
            if(entry->outcome==DW2_PENDING)pendingEntries++;
            for(uint32_t j=0;j<i;j++)if(entries[j].id.wid==entry->id.wid){result=DW_CLIENT_INVALID;break;}
            if(result!=DW_CLIENT_OK)break;
        }
        if(result==DW_CLIENT_OK && pendingEntries!=reply->pending)result=DW_CLIENT_INVALID;
        if(result==DW_CLIENT_OK) {
            if(count)*count=reply->count;
            if(pending)*pending=reply->pending;
            *journal_persisted=reply->journal_persisted;
            if(results && reply->count)memcpy(results,entries,(size_t)reply->count*sizeof(*results));
            if(!reply->journal_persisted)result=DW_CLIENT_UNDURABLE;
        }
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
    free(c->slot);free(c->writing);free(c->pendingFrames);free(c);
}
