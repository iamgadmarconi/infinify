// SPDX-License-Identifier: GPL-3.0-or-later
// Bounded file transport for the existing fixed-fixture request dispatcher.
// Included after perform_request; this adds no native operation or wider scope.
#include "mailbox.h"
#include <CommonCrypto/CommonDigest.h>
#include <uuid/uuid.h>

static uint64_t constructor_started_ns;
static char payload_image_path[4096];
static struct ifwsp_mb_mapping endpoint;

static bool endpoint_pins(void) {
    return (uint64_t)endpoint.directory_stat.st_dev==config.runtime_dev
        &&(uint64_t)endpoint.directory_stat.st_ino==config.runtime_ino
        &&(uint64_t)endpoint.request_stat.st_dev==config.request_dev
        &&(uint64_t)endpoint.request_stat.st_ino==config.request_ino
        &&(uint64_t)endpoint.reply_stat.st_dev==config.reply_dev
        &&(uint64_t)endpoint.reply_stat.st_ino==config.reply_ino;
}
static bool own_payload_matches(void) {
    int fd=open(payload_image_path,O_RDONLY|O_NOFOLLOW);if(fd<0)return false;
    CC_SHA256_CTX hash;CC_SHA256_Init(&hash);unsigned char bytes[16384],digest[32];ssize_t n;
    while((n=read(fd,bytes,sizeof(bytes)))>0)CC_SHA256_Update(&hash,bytes,(CC_LONG)n);
    close(fd);if(n<0)return false;CC_SHA256_Final(digest,&hash);
    return !memcmp(digest,config.payload_sha256,sizeof(digest));
}
static bool endpoint_ready(void) {
    int error=ifwsp_mb_map(config.runtime,config.controller_uid,geteuid(),true,&endpoint);
    if(error){startup_diagnostic("mailbox-map",error,"private directional mappings refused");return false;}
    uint8_t boot[16];
    if(!endpoint_pins()||!own_payload_matches()||ifwsp_mb_boot_uuid(boot)
        ||memcmp(boot,config.boot_uuid,sizeof(boot))
        ||!ifwsp_kernel_identity_current(getpid(),geteuid(),&config.server_kernel_identity)) {
        startup_diagnostic("mailbox-pins",errno,"immutable runtime, image or process pins differ");
        ifwsp_mb_unmap(&endpoint);return false;
    }
    struct ifwsp_mb_attestation attestation={.version=IFWSP_MB_VERSION,.size=sizeof(struct ifwsp_mailbox),
        .server=config.server_kernel_identity,.start_ns=constructor_started_ns,
        .deadline_ns=constructor_started_ns+(uint64_t)config.lifetime_ms*1000000ull,
        .lifetime_ms=config.lifetime_ms,.max_records=config.window_count,.max_body=IFWSP_MB_BODY};
    memcpy(attestation.magic,IFWSP_MB_MAGIC,sizeof(attestation.magic));
    memcpy(attestation.boot_uuid,boot,sizeof(boot));
    memcpy(attestation.payload_sha256,config.payload_sha256,sizeof(attestation.payload_sha256));
    CC_SHA256(&config,sizeof(config),attestation.config_sha256);
    struct ifwsp_abi abi=ifwsp_bind_server_abi();
    if(!abi.verified||uuid_parse(abi.image_uuid,attestation.image_uuid)
        ||!constructor_started_ns||ifwsp_mb_now_ns()>=attestation.deadline_ns) {
        startup_diagnostic("mailbox-deadline",0,"fixed lifetime or image identity refused");
        ifwsp_mb_unmap(&endpoint);return false;
    }
    ifwsp_mb_sign_attestation(&attestation,config.nonce);
    memcpy(&endpoint.own->attestation,&attestation,sizeof(attestation));
    atomic_store_explicit(&endpoint.own->ready,1,memory_order_release);
    ifwsp_mb_signal(endpoint.own);
    startup_diagnostic("mailbox-ready",0,"fixed-fixture file endpoint ready");return true;
}
static bool packet_writer_current(const struct ifwsp_mb_packet *packet) {
    return packet->writer.uid==config.controller_uid
        &&ifwsp_kernel_identity_current(packet->writer.pid,config.controller_uid,&packet->writer);
}
static bool same_writer(const struct ifwsp_kernel_process_identity *a,const struct ifwsp_kernel_process_identity *b) {
    return !memcmp(a,b,sizeof(*a));
}
static bool mailbox_reply(unsigned lane,const struct ifwsp_mb_packet *request,const void *body,uint32_t length) {
    if(length>IFWSP_MB_BODY)return false;
    struct ifwsp_mb_packet packet={.generation=request->generation,.writer=config.server_kernel_identity,
        .header={.length=length,.type=request->header.type|DW2_REPLY,.seq=request->header.seq}};
    if(length)memcpy(packet.body,body,length);
    return !ifwsp_mb_push(&endpoint,lane,&packet,100);
}
static bool mailbox_frame_valid(const struct ifwsp_mb_packet *packet) {
    const struct dw2_header *h=&packet->header;struct dw2_frame frame;
    if(h->type!=DW2_FRAME||h->flags||h->length<sizeof(frame)||h->length>IFWSP_MB_BODY)return false;
    memcpy(&frame,packet->body,sizeof(frame));
    return !frame.reserved&&frame.count<=config.window_count
        &&h->length==sizeof(frame)+frame.count*sizeof(struct dw2_record);
}
static bool mailbox_hello(unsigned lane,const struct ifwsp_mb_packet *packet,uint64_t *generation,
                          struct ifwsp_kernel_process_identity *writer,uint8_t token[16]) {
    const struct dw2_header *h=&packet->header;
    if(h->type!=DW2_HELLO||h->flags||!h->seq||h->length!=sizeof(struct dw2_hello)
        ||!packet->generation||!packet_writer_current(packet))return false;
    struct dw2_hello body;memcpy(&body,packet->body,sizeof(body));
    struct dw2_hello_reply reply={.lease_ms=DW2_LEASE_MS,.max_records=config.window_count,
        .max_body=IFWSP_MB_BODY,.caps=capabilities,.scope=DW2_SCOPE_ALLOWLIST,
        .queue=DW2_QUEUE_MAIN,.server_pid=getpid()};
    bool starting=false;
    if(memcmp(body.magic,DW2_MAGIC,sizeof(body.magic))||body.version!=DW2_VERSION
        ||memcmp(body.nonce,config.nonce,sizeof(body.nonce)))reply.status=DW2_HELLO_AUTH;
    else if(lane==IFWSP_MB_CONTROL&&body.role==DW2_ROLE_CONTROL) {
        if(*generation)reply.status=DW2_HELLO_BUSY;
        else {arc4random_buf(token,16);starting=true;}
    }else if(lane!=IFWSP_MB_HEARTBEAT||body.role!=DW2_ROLE_HEARTBEAT
        ||!*generation||packet->generation!=*generation||!same_writer(writer,&packet->writer)
        ||memcmp(body.token,token,16))reply.status=DW2_HELLO_TOKEN;
    memcpy(reply.token,token,16);
    if(starting){*generation=packet->generation;*writer=packet->writer;
        atomic_store_explicit(&endpoint.own->active_generation,*generation,memory_order_release);}
    bool ok=mailbox_reply(lane,packet,&reply,sizeof(reply))&&reply.status==DW2_HELLO_OK;
    if(starting&&!ok){*generation=0;memset(token,0,16);
        atomic_store_explicit(&endpoint.own->active_generation,0,memory_order_release);ifwsp_mb_signal(endpoint.own);}
    return ok;
}
static void *serve(void *unused) {
    (void)unused;if(!endpoint_ready())return NULL;
    const uint64_t end=endpoint.own->attestation.deadline_ns;
    uint64_t generation=0,completed=0,lease=end,last_sequence[2]={0};
    struct ifwsp_kernel_process_identity writer={0};uint8_t token[16]={0};unsigned sessions=0;
    bool heartbeat_accepted=false;
    while(ifwsp_mb_now_ns()<end&&fixture_current()) {
        // Snapshot before scanning BOTH lanes: neither heartbeat nor control
        // publication can be lost between the predicate scan and shared wait.
        uint64_t bell=atomic_load_explicit(&endpoint.peer->doorbell,memory_order_acquire);
        bool stopped=generation&&(ifwsp_mb_now_ns()>=lease
            ||atomic_load_explicit(&endpoint.peer->lane[0].closed_generation,memory_order_acquire)>=generation
            ||!ifwsp_kernel_identity_current(writer.pid,config.controller_uid,&writer));
        bool fatal=false,progress=false;
        for(unsigned lane=0;lane<IFWSP_MB_LANES&&!stopped;lane++) {
            struct ifwsp_mb_packet packet;int error=ifwsp_mb_pop(&endpoint,lane,&packet,0);
            if(error==EAGAIN)continue;
            if(error){fatal=true;stopped=true;break;}
            progress=true;
            if(packet.generation<=completed)continue;
            if(packet.header.type==DW2_HELLO) {
                if(!mailbox_hello(lane,&packet,&generation,&writer,token)){if(generation)stopped=true;continue;}
                if(lane==IFWSP_MB_HEARTBEAT)heartbeat_accepted=true;
                last_sequence[lane]=packet.header.seq;lease=ifwsp_mb_now_ns()+(uint64_t)DW2_LEASE_MS*1000000ull;continue;
            }
            if(!generation||packet.generation!=generation)continue;
            if(!same_writer(&writer,&packet.writer)||!packet_writer_current(&packet)
                ||packet.header.flags||!packet.header.seq||packet.header.seq<=last_sequence[lane]) {stopped=true;break;}
            if(lane==IFWSP_MB_HEARTBEAT) {
                if(!heartbeat_accepted||packet.header.type!=DW2_HEARTBEAT||packet.header.length){stopped=true;break;}
                struct dw2_heartbeat_reply reply={.lease_ms=DW2_LEASE_MS,.held=pending_restores()};
                if(!mailbox_reply(lane,&packet,&reply,sizeof(reply))){stopped=true;break;}
            }else {
                uint32_t superseded=0;
                if(packet.header.type==DW2_FRAME) {
                    if(!mailbox_frame_valid(&packet)){stopped=true;break;}
                    for(unsigned i=0;i<IFWSP_MB_SLOTS;i++) {
                        struct dw2_header next;uint64_t next_generation=0;
                        int peek=ifwsp_mb_peek(&endpoint,lane,&next,&next_generation);
                        if(peek==EAGAIN||(!peek&&(next.type!=DW2_FRAME||next_generation!=generation)))break;
                        if(peek){stopped=true;break;}
                        struct ifwsp_mb_packet newest;
                        if(ifwsp_mb_pop(&endpoint,lane,&newest,0)||!mailbox_frame_valid(&newest)
                            ||newest.header.seq<=packet.header.seq||!same_writer(&writer,&newest.writer)
                            ||!packet_writer_current(&newest)){stopped=true;break;}
                        packet=newest;superseded++;
                    }
                    if(stopped)break;
                }
                unsigned char reply[IFWSP_MB_BODY];
                struct request_context context={.header=&packet.header,.body=packet.body,.reply=reply,.superseded=superseded};
                if(ifwsp_mb_now_ns()>=end){stopped=true;break;}
                if(!ifwsp_server_call(&config,perform_request,&context)||!context.length
                    ||!mailbox_reply(lane,&packet,reply,context.length)){stopped=true;break;}
            }
            last_sequence[lane]=packet.header.seq;lease=ifwsp_mb_now_ns()+(uint64_t)DW2_LEASE_MS*1000000ull;
        }
        if(stopped) {
            bool restored=ifwsp_server_restore_call(&config,restore_operation,NULL)&&!pending_restores();
            completed=generation>completed?generation:completed;generation=0;
            atomic_store_explicit(&endpoint.own->active_generation,0,memory_order_release);
            ifwsp_mb_signal(endpoint.own);
            if(!restored||fatal)break;
            memset(token,0,sizeof(token));memset(&writer,0,sizeof(writer));memset(last_sequence,0,sizeof(last_sequence));
            received=applied=superseded_frames=0;heartbeat_accepted=false;lease=end;sessions++;continue;
        }
        if(!progress) {
            uint64_t now=ifwsp_mb_now_ns(),deadline=lease<end?lease:end;
            if(now>=deadline)continue;
            uint64_t ms=(deadline-now+999999)/1000000;
            int error=ifwsp_mb_wait(&endpoint,bell,(uint32_t)(ms>100?100:ms));
            if(error&&error!=ETIMEDOUT&&error!=EINTR)break;
        }
    }
    ifwsp_server_restore_call(&config,restore_operation,NULL);
    atomic_store_explicit(&endpoint.own->active_generation,0,memory_order_release);
    atomic_store_explicit(&endpoint.own->ended,1,memory_order_release);ifwsp_mb_signal(endpoint.own);
    char report[256];snprintf(report,sizeof(report),"%s/restoration.txt",config.runtime);
    int fd=open(report,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd>=0){dprintf(fd,"pending=%u\nsessions_completed=%u\n",pending_restores(),sessions);fsync(fd);close(fd);}
    ifwsp_mb_unmap(&endpoint);return NULL;
}
