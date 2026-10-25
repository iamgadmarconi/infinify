// SPDX-License-Identifier: GPL-3.0-or-later
#include "mailbox-client.h"
#include "mailbox.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct ifwsp_mailbox_client {
    struct ifwsp_mb_mapping mapping;
    struct ifwsp_kernel_process_identity writer;
    uint64_t generation,deadline_ns,last_sent;
    unsigned lane;
    _Atomic bool stopped;
    bool claimed;
};
static int claim_producer(ifwsp_mailbox_client *client) {
    _Atomic uint64_t *owner=&client->mapping.own->lane[client->lane].producer_pid;
    uint64_t old=atomic_load_explicit(owner,memory_order_acquire),pid=(uint64_t)getpid();
    for(unsigned attempt=0;attempt<4;attempt++) {
        if(old) {
            if(old>INT_MAX)return EPROTO;
            struct proc_bsdshortinfo info={0};errno=0;
            int bytes=proc_pidinfo((pid_t)old,PROC_PIDT_SHORTBSDINFO,0,&info,sizeof(info));
            // A live/reused PID remains busy. Only positive kernel absence
            // permits recovery of an abandoned producer claim.
            if(bytes==(int)sizeof(info))return EBUSY;
            if(errno!=ESRCH)return errno?errno:EBUSY;
        }
        if(atomic_compare_exchange_weak_explicit(owner,&old,pid,memory_order_acq_rel,memory_order_acquire)) {
            client->claimed=true;return 0;
        }
    }
    return EBUSY;
}
void ifwsp_mb_shutdown(ifwsp_mailbox_client *client) {
    if(!client||atomic_exchange_explicit(&client->stopped,true,memory_order_acq_rel))return;
    if(client->claimed&&client->generation) {
        _Atomic uint64_t *closed=&client->mapping.own->lane[client->lane].closed_generation;
        uint64_t old=atomic_load_explicit(closed,memory_order_acquire);
        while(old<client->generation&&!atomic_compare_exchange_weak_explicit(closed,&old,client->generation,memory_order_release,memory_order_relaxed)){}
        ifwsp_mb_signal(client->mapping.own);
    }
}
void ifwsp_mb_close(ifwsp_mailbox_client *client) {
    if(!client)return;
    ifwsp_mb_shutdown(client);
    if(client->claimed) {
        uint64_t expected=(uint64_t)getpid();
        atomic_compare_exchange_strong_explicit(&client->mapping.own->lane[client->lane].producer_pid,
            &expected,0,memory_order_release,memory_order_relaxed);
        ifwsp_mb_signal(client->mapping.own);
    }
    ifwsp_mb_unmap(&client->mapping);free(client);
}
int ifwsp_mb_send(ifwsp_mailbox_client *client,uint16_t type,uint64_t seq,const void *body,uint32_t length) {
    if(!client||length>IFWSP_MB_BODY||(length&&!body)||!seq||seq<=client->last_sent)return EINVAL;
    if(atomic_load_explicit(&client->stopped,memory_order_acquire))return ECANCELED;
    struct ifwsp_mb_packet packet={.generation=client->generation,.writer=client->writer,
        .header={.length=length,.type=type,.seq=seq}};
    if(length)memcpy(packet.body,body,length);
    uint64_t end=ifwsp_mb_now_ns()+2000000000ull;
    if(end>client->deadline_ns)end=client->deadline_ns;
    while(ifwsp_mb_now_ns()<end) {
        int error=ifwsp_mb_push(&client->mapping,client->lane,&packet,100);
        if(!error){client->last_sent=seq;return 0;}
        if(error!=ETIMEDOUT&&error!=EAGAIN)return error;
        if(atomic_load_explicit(&client->stopped,memory_order_acquire))return ECANCELED;
    }
    return ETIMEDOUT;
}
int ifwsp_mb_recv(ifwsp_mailbox_client *client,uint16_t *type,uint64_t *seq,void *body,uint32_t capacity,uint32_t *length,uint32_t timeout_ms) {
    if(!client||!type||!seq||!body||!length||!timeout_ms)return EINVAL;
    uint64_t end=ifwsp_mb_now_ns()+(uint64_t)timeout_ms*1000000ull;
    if(end>client->deadline_ns)end=client->deadline_ns;
    while(ifwsp_mb_now_ns()<end) {
        if(atomic_load_explicit(&client->stopped,memory_order_acquire))return ECANCELED;
        struct ifwsp_mb_packet packet;
        int error=ifwsp_mb_pop(&client->mapping,client->lane,&packet,100);
        if(error==EAGAIN||error==ETIMEDOUT)continue;
        if(error)return error;
        if(packet.generation<client->generation)continue;
        if(packet.generation!=client->generation||!(packet.header.type&DW2_REPLY)
           ||packet.header.flags||packet.header.length>capacity)return EPROTO;
        if(packet.header.length)memcpy(body,packet.body,packet.header.length);
        *type=packet.header.type&~DW2_REPLY;*seq=packet.header.seq;*length=packet.header.length;
        return 0;
    }
    return ETIMEDOUT;
}
int ifwsp_mb_open(const char *runtime,const char nonce[64],pid_t server_pid,uid_t server_uid,
                 uint16_t role,const uint8_t token[16],struct dw2_hello_reply *hello,ifwsp_mailbox_client **out) {
    if(!runtime||!nonce||!token||!hello||!out||(role!=DW2_ROLE_CONTROL&&role!=DW2_ROLE_HEARTBEAT))return EINVAL;
    *out=NULL;
    ifwsp_mailbox_client *client=calloc(1,sizeof(*client));if(!client)return ENOMEM;
    client->mapping.directory_fd=client->mapping.request_fd=client->mapping.reply_fd=-1;
    client->lane=role==DW2_ROLE_CONTROL?IFWSP_MB_CONTROL:IFWSP_MB_HEARTBEAT;
    atomic_init(&client->stopped,false);
    int error=ifwsp_mb_map(runtime,getuid(),server_uid,false,&client->mapping);
    if(error)goto fail;
    uint64_t end=ifwsp_mb_now_ns()+5000000000ull;
    while(!atomic_load_explicit(&client->mapping.peer->ready,memory_order_acquire)) {
        if(ifwsp_mb_now_ns()>=end){error=ETIMEDOUT;goto fail;}
        uint64_t bell=atomic_load_explicit(&client->mapping.peer->doorbell,memory_order_acquire);
        if(atomic_load_explicit(&client->mapping.peer->ready,memory_order_acquire))break;
        error=ifwsp_mb_wait(&client->mapping,bell,100);
        if(error&&error!=ETIMEDOUT&&error!=EAGAIN)goto fail;
    }
    struct ifwsp_mb_attestation attestation=client->mapping.peer->attestation;
    uint8_t boot[16];
    if(memcmp(attestation.magic,IFWSP_MB_MAGIC,8)||attestation.version!=IFWSP_MB_VERSION
       ||attestation.size!=sizeof(struct ifwsp_mailbox)||attestation.server.pid!=server_pid
       ||attestation.server.uid!=server_uid||attestation.max_records<1||attestation.max_records>16
       ||attestation.max_body!=IFWSP_MB_BODY||attestation.lifetime_ms<1000||attestation.lifetime_ms>60000
       ||attestation.deadline_ns<attestation.start_ns
       ||attestation.deadline_ns-attestation.start_ns!=(uint64_t)attestation.lifetime_ms*1000000ull
       ||!ifwsp_mb_verify_attestation(&attestation,nonce)
       ||ifwsp_mb_boot_uuid(boot)||memcmp(boot,attestation.boot_uuid,16)
       ||!ifwsp_kernel_identity_current(server_pid,server_uid,&attestation.server)) {error=EACCES;goto fail;}
    client->deadline_ns=attestation.deadline_ns;
    if(ifwsp_mb_now_ns()>=client->deadline_ns||atomic_load_explicit(&client->mapping.peer->ended,memory_order_acquire)) {error=ETIMEDOUT;goto fail;}
    if(!ifwsp_capture_kernel_identity(getpid(),getuid(),&client->writer)){error=errno?errno:ESTALE;goto fail;}
    error=claim_producer(client);if(error)goto fail;
    if(role==DW2_ROLE_CONTROL) {
        while(atomic_load_explicit(&client->mapping.peer->active_generation,memory_order_acquire)) {
            uint64_t bell=atomic_load_explicit(&client->mapping.peer->doorbell,memory_order_acquire);
            if(!atomic_load_explicit(&client->mapping.peer->active_generation,memory_order_acquire))break;
            if(ifwsp_mb_now_ns()>=end){error=EBUSY;goto fail;}
            error=ifwsp_mb_wait(&client->mapping,bell,100);
            if(error&&error!=ETIMEDOUT&&error!=EAGAIN)goto fail;
        }
        client->generation=atomic_fetch_add_explicit(&client->mapping.own->next_generation,1,memory_order_acq_rel)+1;
        if(!client->generation){error=EOVERFLOW;goto fail;}
    }else {
        client->generation=atomic_load_explicit(&client->mapping.peer->active_generation,memory_order_acquire);
        if(!client->generation){error=ENOENT;goto fail;}
    }
    struct dw2_hello request={.version=DW2_VERSION,.role=role};
    memcpy(request.magic,DW2_MAGIC,sizeof(request.magic));
    memcpy(request.nonce,nonce,64);memcpy(request.token,token,16);
    error=ifwsp_mb_send(client,DW2_HELLO,1,&request,sizeof(request));if(error)goto fail;
    uint16_t kind=0;uint64_t seq=0;uint32_t length=0;
    error=ifwsp_mb_recv(client,&kind,&seq,hello,sizeof(*hello),&length,5000);if(error)goto fail;
    if(kind!=DW2_HELLO||seq!=1||length!=sizeof(*hello)||hello->status||hello->server_pid!=server_pid) {error=EPROTO;goto fail;}
    *out=client;return 0;
fail:
    ifwsp_mb_close(client);return error;
}
