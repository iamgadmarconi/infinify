// SPDX-License-Identifier: GPL-3.0-or-later
#include "mailbox.h"
#include <CommonCrypto/CommonHMAC.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <os/os_sync_wait_on_address.h>
#include <pthread.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <uuid/uuid.h>

static mach_timebase_info_data_t timebase;
static pthread_once_t timebase_once=PTHREAD_ONCE_INIT;

static void initialize_timebase(void) {
    if(mach_timebase_info(&timebase)!=KERN_SUCCESS)memset(&timebase,0,sizeof(timebase));
}
uint64_t ifwsp_mb_now_ns(void) {
    if(pthread_once(&timebase_once,initialize_timebase)||!timebase.denom)return 0;
    return (uint64_t)((__uint128_t)mach_absolute_time()*timebase.numer/timebase.denom);
}
int ifwsp_mb_boot_uuid(uint8_t uuid[16]) {
    if(!uuid)return EINVAL;
    char text[64]={0};size_t size=sizeof(text);
    if(sysctlbyname("kern.bootsessionuuid",text,&size,NULL,0))return errno;
    if(!size||size>sizeof(text)||!memchr(text,'\0',size)||uuid_parse(text,uuid))return EPROTO;
    return 0;
}

static bool same_inode(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev&&a->st_ino==b->st_ino;
}
static bool no_acl_flags(void *object,bool entry) {
    // ACL-level flags and entry flags have different namespaces: the defer
    // flag's bit is also the entry's ALLOW tag, so never query it on an ACE.
    static const acl_flag_t acl_flags[]={ACL_FLAG_DEFER_INHERIT,ACL_FLAG_NO_INHERIT};
    static const acl_flag_t entry_flags[]={ACL_ENTRY_INHERITED,ACL_ENTRY_FILE_INHERIT,
        ACL_ENTRY_DIRECTORY_INHERIT,ACL_ENTRY_LIMIT_INHERIT,ACL_ENTRY_ONLY_INHERIT};
    const acl_flag_t *flags=entry?entry_flags:acl_flags;
    unsigned count=entry?sizeof(entry_flags)/sizeof(entry_flags[0]):sizeof(acl_flags)/sizeof(acl_flags[0]);
    acl_flagset_t set=NULL;
    if(acl_get_flagset_np(object,&set))return false;
    for(unsigned i=0;i<count;i++)
        if(acl_get_flag_np(set,flags[i])!=0)return false;
    return true;
}
// The privileged loader resolves the two named UIDs to UUIDs and pins these
// inodes before starting the endpoint. Do not perform membership-service IPC
// from WindowServer. A non-owner O_RDONLY open of a mode0600 file additionally
// requires the kernel to match its single read-only ACE to the caller.
static bool read_only_peer_acl(int fd) {
    acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);if(!acl)return false;
    acl_entry_t entry=NULL,next=NULL;acl_tag_t tag=ACL_UNDEFINED_TAG;
    acl_permset_mask_t permissions=0;void *qualifier=NULL;
    errno=0;
    bool valid=acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==0
        &&no_acl_flags(acl,false)&&no_acl_flags(entry,true)
        &&acl_get_tag_type(entry,&tag)==0&&tag==ACL_EXTENDED_ALLOW
        &&acl_get_permset_mask_np(entry,&permissions)==0&&permissions==ACL_READ_DATA;
    if(valid){qualifier=acl_get_qualifier(entry);valid=qualifier&&!uuid_is_null(qualifier);}
    if(valid){errno=0;valid=acl_get_entry(acl,ACL_NEXT_ENTRY,&next)==-1&&errno==EINVAL;}
    int error=valid?0:(errno?errno:EPERM);
    if(qualifier)acl_free(qualifier);acl_free(acl);errno=error;return valid;
}
static bool no_directory_acl(int fd) {
    acl_t acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED);
    // Darwin also reports ENOENT for an absent extended ACL. This is a pinned,
    // already-fstat-verified directory FD, not an unchecked pathname lookup.
    if(!acl){bool absent=errno==ENOATTR||errno==ENOENT;if(absent)errno=0;return absent;}
    acl_entry_t entry=NULL;errno=0;
    bool valid=no_acl_flags(acl,false)
        &&acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==-1&&errno==EINVAL;
    int error=valid?0:(errno?errno:EPERM);acl_free(acl);errno=error;return valid;
}
static int open_file(int directory,const char *name,uid_t owner,bool writable,struct stat *result) {
    struct stat before={0},after={0},current={0};
    if(fstatat(directory,name,&before,AT_SYMLINK_NOFOLLOW))return -1;
    if(!S_ISREG(before.st_mode)||before.st_uid!=owner||(before.st_mode&07777)!=0600
        ||before.st_nlink!=1||before.st_size!=(off_t)sizeof(struct ifwsp_mailbox)){errno=EPERM;return -1;}
    int fd=openat(directory,name,(writable?O_RDWR:O_RDONLY)|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return -1;
    errno=0;
    bool valid=fstat(fd,&after)==0&&same_inode(&before,&after)
        &&S_ISREG(after.st_mode)&&after.st_uid==owner&&(after.st_mode&07777)==0600
        &&after.st_nlink==1&&after.st_size==(off_t)sizeof(struct ifwsp_mailbox)
        &&read_only_peer_acl(fd)
        &&fstatat(directory,name,&current,AT_SYMLINK_NOFOLLOW)==0
        &&same_inode(&after,&current)&&S_ISREG(current.st_mode)&&current.st_uid==owner
        &&(current.st_mode&07777)==0600&&current.st_nlink==1&&current.st_size==after.st_size;
    if(!valid){int error=errno?errno:EPERM;close(fd);errno=error;return -1;}
    *result=after;return fd;
}
void ifwsp_mb_unmap(struct ifwsp_mb_mapping *mapping) {
    if(!mapping)return;
    if(mapping->own&&mapping->own!=MAP_FAILED)munmap(mapping->own,sizeof(*mapping->own));
    if(mapping->peer&&mapping->peer!=MAP_FAILED)munmap((void*)mapping->peer,sizeof(*mapping->peer));
    if(mapping->request_fd>=0)close(mapping->request_fd);
    if(mapping->reply_fd>=0)close(mapping->reply_fd);
    if(mapping->directory_fd>=0)close(mapping->directory_fd);
    memset(mapping,0,sizeof(*mapping));
    mapping->directory_fd=mapping->request_fd=mapping->reply_fd=-1;
}
int ifwsp_mb_map(const char *runtime,uid_t controller,uid_t server,bool server_side,
                 struct ifwsp_mb_mapping *mapping) {
    if(!mapping)return EINVAL;
    memset(mapping,0,sizeof(*mapping));
    mapping->directory_fd=mapping->request_fd=mapping->reply_fd=-1;
    if(!runtime||runtime[0]!='/'||controller==server)return EINVAL;
    mapping->server=server_side;
    struct stat before={0},after={0};
    if(lstat(runtime,&before))return errno;
    if(!S_ISDIR(before.st_mode)||before.st_uid!=server||(before.st_mode&07777)!=0711)return EPERM;
    // O_SEARCH needs traversal, not directory enumeration; clients do not own
    // this protected0711 directory and must never open it for read/write data.
    mapping->directory_fd=open(runtime,O_SEARCH|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(mapping->directory_fd<0)return errno;
    int error=0;errno=0;
    if(fstat(mapping->directory_fd,&mapping->directory_stat)
        ||!same_inode(&before,&mapping->directory_stat)
        ||!S_ISDIR(mapping->directory_stat.st_mode)||mapping->directory_stat.st_uid!=server
        ||(mapping->directory_stat.st_mode&07777)!=0711
        ||!no_directory_acl(mapping->directory_fd)){error=errno?errno:EPERM;goto fail;}
    mapping->request_fd=open_file(mapping->directory_fd,IFWSP_MB_REQUEST_FILE,controller,!server_side,&mapping->request_stat);
    if(mapping->request_fd<0){error=errno;goto fail;}
    mapping->reply_fd=open_file(mapping->directory_fd,IFWSP_MB_REPLY_FILE,server,server_side,&mapping->reply_stat);
    if(mapping->reply_fd<0){error=errno;goto fail;}
    if(same_inode(&mapping->request_stat,&mapping->reply_stat)){error=EPERM;goto fail;}
    mapping->own=mmap(NULL,sizeof(*mapping->own),PROT_READ|PROT_WRITE,MAP_SHARED,
        server_side?mapping->reply_fd:mapping->request_fd,0);
    if(mapping->own==MAP_FAILED){error=errno;mapping->own=NULL;goto fail;}
    mapping->peer=mmap(NULL,sizeof(*mapping->peer),PROT_READ,MAP_SHARED,
        server_side?mapping->request_fd:mapping->reply_fd,0);
    if(mapping->peer==MAP_FAILED){error=errno;mapping->peer=NULL;goto fail;}
    if(!atomic_is_lock_free(&mapping->own->doorbell)
        ||!atomic_is_lock_free(&mapping->own->lane[0].published)){error=ENOTSUP;goto fail;}
    errno=0;
    if(lstat(runtime,&after)||!same_inode(&after,&mapping->directory_stat)
        ||!S_ISDIR(after.st_mode)||after.st_uid!=server||(after.st_mode&07777)!=0711){error=errno?errno:ESTALE;goto fail;}
    return 0;
fail:
    ifwsp_mb_unmap(mapping);return error?error:EIO;
}

void ifwsp_mb_signal(struct ifwsp_mailbox *own) {
    if(!own)return;
    atomic_fetch_add_explicit(&own->doorbell,1,memory_order_release);
    // Several client threads may await different lane predicates. Waking one
    // arbitrary waiter could strand the one whose response became available.
    if(os_sync_wake_by_address_all(&own->doorbell,sizeof(own->doorbell),OS_SYNC_WAKE_BY_ADDRESS_SHARED)<0
        &&errno!=ENOENT)atomic_store_explicit(&own->ended,1,memory_order_release);
}
static int mapping_current(struct ifwsp_mb_mapping *mapping) {
    if(!mapping||!mapping->own||!mapping->peer)return EINVAL;
    if(atomic_load_explicit(&mapping->own->ended,memory_order_acquire)
        ||atomic_load_explicit(&mapping->peer->ended,memory_order_acquire))return ECANCELED;
    return 0;
}
int ifwsp_mb_wait(struct ifwsp_mb_mapping *mapping,uint64_t observed,uint32_t timeout_ms) {
    int error=mapping_current(mapping);if(error)return error;
    if(atomic_load_explicit(&mapping->peer->doorbell,memory_order_acquire)!=observed)return 0;
    if(!timeout_ms)return EAGAIN;
    if(os_sync_wait_on_address_with_timeout((void*)&mapping->peer->doorbell,observed,
        sizeof(mapping->peer->doorbell),OS_SYNC_WAIT_ON_ADDRESS_SHARED,OS_CLOCK_MACH_ABSOLUTE_TIME,
        (uint64_t)timeout_ms*1000000)<0)return errno?errno:EIO;
    return mapping_current(mapping);
}
static int remaining_ms(uint64_t deadline,uint32_t *remaining) {
    uint64_t now=ifwsp_mb_now_ns();if(!now)return EIO;
    if(now>=deadline)return ETIMEDOUT;
    uint64_t ms=(deadline-now+999999)/1000000;
    *remaining=(uint32_t)(ms>UINT32_MAX?UINT32_MAX:ms);return 0;
}
static int operation_deadline(uint32_t timeout_ms,uint64_t *deadline) {
    uint64_t now=ifwsp_mb_now_ns(),duration=(uint64_t)timeout_ms*1000000;
    if(!now)return EIO;if(duration>UINT64_MAX-now)return EOVERFLOW;
    *deadline=now+duration;return 0;
}
int ifwsp_mb_push(struct ifwsp_mb_mapping *mapping,unsigned lane,
                  const struct ifwsp_mb_packet *packet,uint32_t timeout_ms) {
    if(!packet||lane>=IFWSP_MB_LANES||packet->header.length>IFWSP_MB_BODY)return EINVAL;
    int error=mapping_current(mapping);if(error)return error;
    uint64_t deadline=0;if((error=operation_deadline(timeout_ms,&deadline)))return error;
    for(;;) {
        if((error=mapping_current(mapping)))return error;
        uint64_t wake=atomic_load_explicit(&mapping->peer->doorbell,memory_order_acquire);
        struct ifwsp_mb_lane *own=&mapping->own->lane[lane];
        uint64_t published=atomic_load_explicit(&own->published,memory_order_relaxed);
        uint64_t consumed=atomic_load_explicit(&mapping->peer->lane[lane].consumed,memory_order_acquire);
        if(consumed>published||published-consumed>IFWSP_MB_SLOTS)return EPROTO;
        if(published-consumed<IFWSP_MB_SLOTS) {
            if(published==UINT64_MAX)return EOVERFLOW;
            struct ifwsp_mb_packet *slot=&own->slots[published%IFWSP_MB_SLOTS];
            memset(slot,0,sizeof(*slot));
            memcpy(slot,packet,offsetof(struct ifwsp_mb_packet,body)+packet->header.length);
            atomic_store_explicit(&own->published,published+1,memory_order_release);
            ifwsp_mb_signal(mapping->own);
            return mapping_current(mapping);
        }
        if(!timeout_ms)return EAGAIN;
        uint32_t remaining;if((error=remaining_ms(deadline,&remaining)))return error;
        error=ifwsp_mb_wait(mapping,wake,remaining);
        if(error&&error!=EINTR)return error;
    }
}
int ifwsp_mb_pop(struct ifwsp_mb_mapping *mapping,unsigned lane,
                 struct ifwsp_mb_packet *packet,uint32_t timeout_ms) {
    if(!packet||lane>=IFWSP_MB_LANES)return EINVAL;
    int error=mapping_current(mapping);if(error)return error;
    uint64_t deadline=0;if((error=operation_deadline(timeout_ms,&deadline)))return error;
    for(;;) {
        if((error=mapping_current(mapping)))return error;
        uint64_t wake=atomic_load_explicit(&mapping->peer->doorbell,memory_order_acquire);
        struct ifwsp_mb_lane *own=&mapping->own->lane[lane];
        uint64_t consumed=atomic_load_explicit(&own->consumed,memory_order_relaxed);
        uint64_t published=atomic_load_explicit(&mapping->peer->lane[lane].published,memory_order_acquire);
        if(consumed>published||published-consumed>IFWSP_MB_SLOTS)return EPROTO;
        if(consumed!=published) {
            const struct ifwsp_mb_packet *slot=&mapping->peer->lane[lane].slots[consumed%IFWSP_MB_SLOTS];
            if(slot->header.length>IFWSP_MB_BODY)return EMSGSIZE;
            memcpy(packet,slot,sizeof(*packet));
            atomic_store_explicit(&own->consumed,consumed+1,memory_order_release);
            ifwsp_mb_signal(mapping->own);
            return mapping_current(mapping);
        }
        if(!timeout_ms)return EAGAIN;
        uint32_t remaining;if((error=remaining_ms(deadline,&remaining)))return error;
        error=ifwsp_mb_wait(mapping,wake,remaining);
        if(error&&error!=EINTR)return error;
    }
}
int ifwsp_mb_peek(struct ifwsp_mb_mapping *mapping,unsigned lane,
                  struct dw2_header *header,uint64_t *generation) {
    if(lane>=IFWSP_MB_LANES||!header||!generation)return EINVAL;
    int error=mapping_current(mapping);if(error)return error;
    uint64_t consumed=atomic_load_explicit(&mapping->own->lane[lane].consumed,memory_order_relaxed);
    uint64_t published=atomic_load_explicit(&mapping->peer->lane[lane].published,memory_order_acquire);
    if(consumed>published||published-consumed>IFWSP_MB_SLOTS)return EPROTO;
    if(consumed==published)return EAGAIN;
    const struct ifwsp_mb_packet *slot=&mapping->peer->lane[lane].slots[consumed%IFWSP_MB_SLOTS];
    if(slot->header.length>IFWSP_MB_BODY)return EMSGSIZE;
    *header=slot->header;*generation=slot->generation;return 0;
}

void ifwsp_mb_sign_attestation(struct ifwsp_mb_attestation *attestation,const char nonce[64]) {
    CCHmac(kCCHmacAlgSHA256,nonce,64,attestation,offsetof(struct ifwsp_mb_attestation,proof),attestation->proof);
}
bool ifwsp_mb_verify_attestation(const struct ifwsp_mb_attestation *attestation,const char nonce[64]) {
    if(!attestation||!nonce)return false;
    unsigned char proof[32];unsigned char difference=0;
    CCHmac(kCCHmacAlgSHA256,nonce,64,attestation,offsetof(struct ifwsp_mb_attestation,proof),proof);
    for(unsigned i=0;i<sizeof(proof);i++)difference|=proof[i]^attestation->proof[i];
    return difference==0;
}
