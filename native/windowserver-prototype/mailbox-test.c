// SPDX-License-Identifier: GPL-3.0-or-later
// VM-only kernel IPC contract. Creates no windows and loads no payload.
#include "mailbox.h"
#include <errno.h>
#include <fcntl.h>
#include <membership.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted;
static void stop(int signal_number) { (void)signal_number;interrupted=1; }
static int stage_file(const char *path,uid_t owner,uid_t reader) {
    int fd=open(path,O_CREAT|O_EXCL|O_RDWR|O_NOFOLLOW,0600);if(fd<0)return errno;
    int error=0;
    if(ftruncate(fd,sizeof(struct ifwsp_mailbox))||fchown(fd,owner,(gid_t)-1))error=errno;
    uuid_t uuid;acl_t acl=acl_init(1);acl_entry_t entry=NULL;acl_permset_t permissions=NULL;
    if(!error&&(!acl||mbr_uid_to_uuid(reader,uuid)||acl_create_entry(&acl,&entry)
        ||acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)||acl_set_qualifier(entry,uuid)
        ||acl_get_permset(entry,&permissions)||acl_clear_perms(permissions)
        ||acl_add_perm(permissions,ACL_READ_DATA)||acl_set_permset(entry,permissions)
        ||acl_set_fd_np(fd,acl,ACL_TYPE_EXTENDED)))error=errno?errno:EPERM;
    if(acl)acl_free(acl);close(fd);return error;
}
static int endpoint(const char *runtime,bool server) {
    if(setgid(server?88:20)||setuid(server?88:501))return 10;
    struct ifwsp_mb_mapping mapping;int error=ifwsp_mb_map(runtime,501,88,server,&mapping);
    if(error){dprintf(2,"map role=%d error=%d\n",server,error);return 11;}
    const char *peer_name=server?IFWSP_MB_REQUEST_FILE:IFWSP_MB_REPLY_FILE;
    int forbidden=openat(mapping.directory_fd,peer_name,O_RDWR|O_NOFOLLOW);
    if(forbidden>=0){close(forbidden);ifwsp_mb_unmap(&mapping);return 12;}
    if(errno!=EACCES){ifwsp_mb_unmap(&mapping);return 13;}
    for(uint64_t i=1;i<=256;i++) {
        struct ifwsp_mb_packet packet={.generation=7,.header={.length=sizeof(i),.type=DW2_PROBE,.seq=i}};
        memcpy(packet.body,&i,sizeof(i));
        if(server)error=ifwsp_mb_pop(&mapping,IFWSP_MB_CONTROL,&packet,1000);
        else error=ifwsp_mb_push(&mapping,IFWSP_MB_CONTROL,&packet,1000);
        if(!error) {
            if(server){packet.header.type|=DW2_REPLY;error=ifwsp_mb_push(&mapping,IFWSP_MB_CONTROL,&packet,1000);}
            else error=ifwsp_mb_pop(&mapping,IFWSP_MB_CONTROL,&packet,1000);
        }
        uint64_t actual=0;memcpy(&actual,packet.body,sizeof(actual));
        if(error||packet.header.seq!=i||actual!=i||packet.generation!=7) {
            dprintf(2,"exchange role=%d index=%llu error=%d\n",server,(unsigned long long)i,error);
            ifwsp_mb_unmap(&mapping);return 14;
        }
    }
    ifwsp_mb_unmap(&mapping);return 0;
}
static bool rejects_directory_write_ace(const char *runtime) {
    uuid_t uuid;acl_t acl=acl_init(1);acl_entry_t entry=NULL;acl_permset_t permissions=NULL;
    bool ok=acl&&mbr_uid_to_uuid(501,uuid)==0&&acl_create_entry(&acl,&entry)==0
        &&acl_set_tag_type(entry,ACL_EXTENDED_ALLOW)==0&&acl_set_qualifier(entry,uuid)==0
        &&acl_get_permset(entry,&permissions)==0&&acl_clear_perms(permissions)==0
        &&acl_add_perm(permissions,ACL_WRITE_DATA)==0&&acl_set_permset(entry,permissions)==0
        &&acl_set_file(runtime,ACL_TYPE_EXTENDED,acl)==0;
    if(acl)acl_free(acl);
    if(ok) {
        struct ifwsp_mb_mapping mapping;
        int refused=ifwsp_mb_map(runtime,501,88,false,&mapping);
        if(!refused)ifwsp_mb_unmap(&mapping);
        ok=refused!=0;
    }
    acl=acl_init(0);
    bool cleared=acl&&acl_set_file(runtime,ACL_TYPE_EXTENDED,acl)==0;
    if(acl)acl_free(acl);
    return ok&&cleared;
}
int main(void) {
    char model[64]={0};size_t size=sizeof(model);
    if(sysctlbyname("hw.model",model,&size,NULL,0)||strncmp(model,"VirtualMac",10)||geteuid()!=0) {
        fputs("requires explicit root execution inside the disposable VirtualMac VM\n",stderr);return 64;
    }
    char runtime[]="/private/tmp/if-mailbox-contract-XXXXXX";
    if(!mkdtemp(runtime))return 1;
    char request[256],reply[256];snprintf(request,sizeof(request),"%s/%s",runtime,IFWSP_MB_REQUEST_FILE);
    snprintf(reply,sizeof(reply),"%s/%s",runtime,IFWSP_MB_REPLY_FILE);
    pid_t children[2]={0};int result=1;
    if(chown(runtime,88,(gid_t)-1)||chmod(runtime,0711)
        ||stage_file(request,501,88)||stage_file(reply,88,501))goto cleanup;
    char nonce[64];memset(nonce,'a',sizeof(nonce));
    struct ifwsp_mb_attestation attestation={.version=IFWSP_MB_VERSION,.size=sizeof(attestation),.start_ns=7};
    ifwsp_mb_sign_attestation(&attestation,nonce);
    if(!ifwsp_mb_verify_attestation(&attestation,nonce))goto cleanup;
    attestation.start_ns++;
    if(ifwsp_mb_verify_attestation(&attestation,nonce))goto cleanup;
    signal(SIGINT,stop);signal(SIGTERM,stop);signal(SIGHUP,stop);
    for(unsigned i=0;i<2;i++) {
        children[i]=fork();if(children[i]<0)goto cleanup;
        if(children[i]==0){alarm(5);_exit(endpoint(runtime,i==0));}
    }
    result=0;
    for(unsigned i=0;i<2;i++) {
        int status=0;pid_t waited;
        do{waited=waitpid(children[i],&status,0);}while(waited<0&&errno==EINTR&&!interrupted);
        if(waited==children[i])children[i]=0;
        if(waited<0||!WIFEXITED(status)||WEXITSTATUS(status)||interrupted){result=1;break;}
    }
    if(!result&&!rejects_directory_write_ace(runtime))result=1;
cleanup:
    for(unsigned i=0;i<2;i++)if(children[i]>0){kill(children[i],SIGTERM);waitpid(children[i],NULL,0);}
    unlink(request);unlink(reply);rmdir(runtime);
    if(!result)puts("PASS: 256 cross-UID mailbox round trips, read-only peer enforcement, directory write-ACE refusal, shared waits and HMAC tamper refusal; no windows or payload");
    else fputs("FAIL: mailbox kernel IPC contract\n",stderr);
    return result;
}
