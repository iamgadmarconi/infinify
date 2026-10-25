// SPDX-License-Identifier: GPL-3.0-or-later
// The arm64e bootstrap in bootstrap.h retains its separate pinned MIT licence.
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include "prototype.h"
#include "../privileged/preflight.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <libproc.h>
#include <limits.h>
#include <math.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <poll.h>
#include <ptrauth.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include "bootstrap.h"

typedef kern_return_t (*ConvertState)(thread_act_t,int,thread_state_flavor_t,thread_state_t,mach_msg_type_number_t,thread_state_t,mach_msg_type_number_t*);

static bool info(pid_t pid,struct proc_bsdinfo *value) {
    return pid>1&&proc_pidinfo(pid,PROC_PIDTBSDINFO,0,value,sizeof(*value))==sizeof(*value)
        &&value->pbi_pid==(uint32_t)pid&&value->pbi_start_tvsec&&value->pbi_start_tvusec<1000000;
}
static bool same_process(pid_t pid,const struct proc_bsdinfo *expected) {
    struct proc_bsdinfo now={0};
    return info(pid,&now)&&now.pbi_uid==expected->pbi_uid&&now.pbi_start_tvsec==expected->pbi_start_tvsec&&now.pbi_start_tvusec==expected->pbi_start_tvusec;
}
static bool same_fixture(const struct ifwsp_config *config,const struct proc_bsdinfo *expected) {
    struct proc_bsdinfo now={0};
    return config->fixture_pid==(pid_t)expected->pbi_pid&&config->fixture_uid==expected->pbi_uid
        &&info(config->fixture_pid,&now)&&now.pbi_uid==expected->pbi_uid
        &&now.pbi_start_tvsec==expected->pbi_start_tvsec&&now.pbi_start_tvusec==expected->pbi_start_tvusec
        &&now.pbi_ppid==expected->pbi_ppid
        &&ifwsp_kernel_identity_current(config->fixture_pid,config->fixture_uid,&config->fixture_kernel_identity);
}
static pid_t server_identity(struct proc_bsdinfo *value) {
    pid_t processes[4096];int bytes=proc_listpids(PROC_ALL_PIDS,0,processes,sizeof(processes));
    if(bytes<=0||bytes>=(int)sizeof(processes))return 0;
    pid_t found=0;
    for(unsigned i=0;i<(unsigned)bytes/sizeof(pid_t);i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE]={0};
        if(proc_pidpath(processes[i],path,sizeof(path))<=0)continue;
        if(strcmp(path,"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"))continue;
        struct proc_bsdinfo b={0};if(!info(processes[i],&b)||found)return 0;found=processes[i];*value=b;
    }return found;
}
static bool number(id value,uint64_t maximum,uint64_t *result) {
    if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()||CFNumberIsFloatType((__bridge CFNumberRef)value))return false;
    if([value compare:@0]==NSOrderedAscending||[value compare:@(maximum)]==NSOrderedDescending)return false;
    *result=[value unsignedLongLongValue];return true;
}
static bool numbers(id value,double *out,unsigned count) {
    if(![value isKindOfClass:NSArray.class]||[value count]!=count)return false;
    for(unsigned i=0;i<count;i++) {
        id n=value[i];if(![n isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)n)==CFBooleanGetTypeID())return false;
        out[i]=[n doubleValue];if(!isfinite(out[i]))return false;
    }return true;
}
static bool file_mode(const char *path,uid_t uid,mode_t permissions,struct stat *output) {
    struct stat st={0};if(lstat(path,&st)||!S_ISREG(st.st_mode)||st.st_uid!=uid||(st.st_mode&07777)!=permissions)return false;
    if(output)*output=st;return true;
}
static bool read_nonce(const char *path,uid_t uid,char nonce[64]) {
    struct stat st;if(!file_mode(path,uid,0600,&st)||(st.st_size!=64&&st.st_size!=65))return false;
    int fd=open(path,O_RDONLY|O_NOFOLLOW);if(fd<0)return false;char bytes[66]={0};ssize_t n=read(fd,bytes,sizeof(bytes));close(fd);
    if(n!=st.st_size||(n==65&&bytes[64]!='\n'))return false;
    for(unsigned i=0;i<64;i++)if(!((bytes[i]>='0'&&bytes[i]<='9')||(bytes[i]>='a'&&bytes[i]<='f')))return false;
    memcpy(nonce,bytes,64);return true;
}
static bool write_all(int fd,const void *raw,size_t length) {
    size_t used=0;while(used<length){ssize_t n=write(fd,(const char*)raw+used,length-used);if(n<0&&errno==EINTR)continue;if(n<=0)return false;used+=(size_t)n;}return true;
}
static bool executable_matches(NSDictionary *manifest,pid_t pid,const struct proc_bsdinfo *process) {
    id expected_path=manifest[@"host_path"],expected_hash=manifest[@"host_sha256"];
    uint64_t supervisor=0;
    if(![expected_path isKindOfClass:NSString.class]||![expected_path hasPrefix:@"/"]
        ||![expected_hash isKindOfClass:NSString.class]||[expected_hash length]!=64
        ||!number(manifest[@"supervisor_pid"],INT_MAX,&supervisor)||supervisor<=1||process->pbi_ppid!=supervisor)return false;
    char actual[PROC_PIDPATHINFO_MAXSIZE]={0};
    if(proc_pidpath(pid,actual,sizeof(actual))<=0||strcmp(actual,[expected_path fileSystemRepresentation]))return false;
    int fd=open(actual,O_RDONLY|O_NOFOLLOW);if(fd<0)return false;
    CC_SHA256_CTX hash;CC_SHA256_Init(&hash);unsigned char bytes[16384],digest[CC_SHA256_DIGEST_LENGTH];ssize_t n;
    while((n=read(fd,bytes,sizeof(bytes)))>0)CC_SHA256_Update(&hash,bytes,(CC_LONG)n);
    close(fd);if(n<0)return false;CC_SHA256_Final(digest,&hash);
    char hex[CC_SHA256_DIGEST_LENGTH*2+1];
    for(unsigned i=0;i<CC_SHA256_DIGEST_LENGTH;i++)snprintf(hex+i*2,3,"%02x",digest[i]);
    return !strcmp(hex,[expected_hash UTF8String]);
}
static bool manifest(const char *path,struct ifwsp_config *config,struct proc_bsdinfo *fixture) {
    struct stat st;if(lstat(path,&st)||!S_ISREG(st.st_mode)||st.st_size<1||st.st_size>65536||(st.st_mode&0022))return false;
    NSData *bytes=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path]];
    id raw=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL]:nil;
    if(![raw isKindOfClass:NSDictionary.class])return false;NSDictionary *m=raw;
    uint64_t schema,pid,sec,usec,uid;
    if(!number(m[@"schema"],1,&schema)||schema!=1||![m[@"fixture_kind"]isEqual:@"infinify-disposable-cooperative-host"]
        ||!number(m[@"pid"],INT_MAX,&pid)||pid<=1||!number(m[@"birth_sec"],UINT64_MAX,&sec)||!sec
        ||!number(m[@"birth_usec"],999999,&usec)||!number(m[@"uid"],UINT32_MAX,&uid)
        ||!info((pid_t)pid,fixture)||fixture->pbi_uid!=uid||fixture->pbi_start_tvsec!=sec||fixture->pbi_start_tvusec!=usec
        ||st.st_uid!=uid)return false;
    config->controller_uid=(uint32_t)uid;config->fixture_uid=(uint32_t)uid;config->fixture_pid=(pid_t)pid;
    config->fixture_birth_sec=sec;config->fixture_birth_usec=usec;
    // Bind the manifest's original birth/hash/parent guard to a kernel token
    // before hashing, then recheck both after hashing to exclude PID reuse/exec.
    if(!ifwsp_capture_kernel_identity((pid_t)pid,(uid_t)uid,&config->fixture_kernel_identity)
        ||!executable_matches(m,(pid_t)pid,fixture)||!same_fixture(config,fixture))return false;
    id list=m[@"windows"];if(![list isKindOfClass:NSArray.class]||![list count]||[list count]>IFWSP_MAX_WINDOWS)return false;
    config->window_count=(uint32_t)[list count];
    for(unsigned i=0;i<config->window_count;i++) {
        if(![list[i]isKindOfClass:NSDictionary.class])return false;NSDictionary *w=list[i];uint64_t wid,owner;
        if(!number(w[@"wid"],UINT32_MAX,&wid)||!wid||!number(w[@"owner"],INT_MAX,&owner)||!owner)return false;
        for(unsigned j=0;j<i;j++)if(config->windows[j].identity.wid==wid)return false;
        struct ifwsp_window *entry=&config->windows[i];entry->identity=(struct dw2_identity){.pid=(pid_t)pid,.wid=(uint32_t)wid,.birth_sec=sec,.birth_usec=usec};entry->owner=(int32_t)owner;
        if(!numbers(w[@"transform"],entry->original_transform,6)||!numbers(w[@"bounds"],entry->original_bounds,4)||!numbers(w[@"screen_rect"],entry->original_screen_rect,4))return false;
    }return true;
}
static int preflight(void) {
    uint32_t sip=0;int preview=0,policy=dw_preflight(&sip,&preview);
    struct proc_bsdinfo server={0};pid_t pid=server_identity(&server);struct ifwsp_abi abi=ifwsp_bind_server_abi();
    NSDictionary *report=@{@"schema":@1,@"backend":@"windowserver-resident-prototype",@"read_only":@YES,@"injection_executed":@NO,
        @"server_pid":@(pid),@"server_uid":@(server.pbi_uid),@"server_birth_sec":@(server.pbi_start_tvsec),@"server_birth_usec":@(server.pbi_start_tvusec),
        @"sip_config":@(sip),@"arm64e_preview_abi":@(preview),@"policy_prerequisites":@(policy==0),
        @"server_abi_verified":@(abi.verified),@"server_abi_reason":@(abi.reason?abi.reason:"unknown"),@"skylight_uuid":@(abi.image_uuid?abi.image_uuid:"unknown"),
        @"runtime_ready":@NO,@"performance_proven":@NO};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
    fwrite(json.bytes,1,json.length,stdout);fputc('\n',stdout);return pid>1&&policy==0&&abi.verified?0:3;
}
static bool socket_peer(const char *runtime,pid_t pid,uid_t uid) {
    struct sockaddr_un address={.sun_family=AF_UNIX};
    if(snprintf(address.sun_path,sizeof(address.sun_path),"%s/" DW2_SOCKET,runtime)>=(int)sizeof(address.sun_path))return false;
    int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return false;
    uid_t peer_uid=0;gid_t group=0;pid_t peer_pid=0;socklen_t length=sizeof(peer_pid);
    bool ok=connect(fd,(struct sockaddr*)&address,sizeof(address))==0&&getpeereid(fd,&peer_uid,&group)==0&&peer_uid==uid
        &&getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&peer_pid,&length)==0&&length==sizeof(peer_pid)&&peer_pid==pid;
    close(fd);return ok;
}
static int usage(void) {
    fputs("usage: ws-loader [--preflight]\n"
        "       ws-loader --inject-windowserver ABS_PAYLOAD ABS_RUNTIME --fixture ABS_MANIFEST --nonce-file ABS_FILE --lifetime-ms 1000..60000 --expected-server PID SEC USEC\n"
        "The default is read-only. Injection requires root, a pinned server ABI, and an exact disposable-fixture manifest.\n",stderr);return 64;
}
static bool integer_arg(const char *value,uint64_t limit,uint64_t *out) {
    if(!*value)return false;uint64_t n=0;
    for(const char *p=value;*p;p++){if(*p<'0'||*p>'9'||n>(limit-(unsigned)(*p-'0'))/10)return false;n=n*10+(unsigned)(*p-'0');}
    *out=n;return true;
}
int main(int argc,char **argv) { @autoreleasepool {
    if(argc==1||(argc==2&&!strcmp(argv[1],"--preflight")))return preflight();
    if(argc!=14||strcmp(argv[1],"--inject-windowserver")||strcmp(argv[4],"--fixture")||strcmp(argv[6],"--nonce-file")
        ||strcmp(argv[8],"--lifetime-ms")||strcmp(argv[10],"--expected-server"))return usage();
    const char *payload=argv[2],*runtime=argv[3],*fixture_path=argv[5],*nonce_path=argv[7];
    uint64_t lifetime,expected_pid,expected_sec,expected_usec;
    if(payload[0]!='/'||runtime[0]!='/'||fixture_path[0]!='/'||nonce_path[0]!='/'
        ||strlen(payload)>=sizeof(shell_code)-168||strlen(runtime)>=sizeof(((struct ifwsp_config*)0)->runtime)
        ||!integer_arg(argv[9],IFWSP_MAX_LIFETIME_MS,&lifetime)||lifetime<1000
        ||!integer_arg(argv[11],INT_MAX,&expected_pid)||expected_pid<=1||!integer_arg(argv[12],UINT64_MAX,&expected_sec)||!expected_sec
        ||!integer_arg(argv[13],999999,&expected_usec))return usage();
    uint32_t sip=0;int preview=0;struct ifwsp_abi abi=ifwsp_bind_server_abi();
    if(!abi.verified){fprintf(stderr,"server ABI not verified: %s\n",abi.reason);return 3;}
    if(dw_preflight(&sip,&preview)!=0){fputs("injection blocked by current SIP/arm64e policy; no settings changed\n",stderr);return 3;}
    if(geteuid()!=0){fputs("explicit root invocation is required for this loader\n",stderr);return 3;}
    struct proc_bsdinfo server={0},fixture={0};pid_t pid=server_identity(&server);
    if(pid!=(pid_t)expected_pid||server.pbi_start_tvsec!=expected_sec||server.pbi_start_tvusec!=expected_usec){fputs("WindowServer instance differs from explicit expected identity\n",stderr);return 3;}
    struct ifwsp_config config={.version=IFWSP_CONFIG_VERSION,.size=sizeof(config),.server_pid=pid,.server_birth_sec=server.pbi_start_tvsec,
        .server_birth_usec=server.pbi_start_tvusec,.lifetime_ms=(uint32_t)lifetime};
    memcpy(config.magic,IFWSP_CONFIG_MAGIC,8);strcpy(config.runtime,runtime);
    if(!manifest(fixture_path,&config,&fixture)||config.fixture_pid==pid||!read_nonce(nonce_path,config.controller_uid,config.nonce)) {
        fputs("invalid disposable fixture manifest/process identity or private nonce file\n",stderr);return 3;
    }
    struct stat payload_stat={0},runtime_stat={0};
    if(lstat(payload,&payload_stat)||!S_ISREG(payload_stat.st_mode)||payload_stat.st_uid!=config.controller_uid||(payload_stat.st_mode&0022)
        ||lstat(runtime,&runtime_stat)||!S_ISDIR(runtime_stat.st_mode)||runtime_stat.st_uid!=config.controller_uid||(runtime_stat.st_mode&07777)!=0700) {
        fputs("payload must be an unshared controller-owned regular file; runtime must be a fresh controller-owned 0700 directory\n",stderr);return 3;
    }
    NSString *payload_string=@(payload),*runtime_string=@(runtime);
    NSString *payload_directory=[payload_string stringByDeletingLastPathComponent];
    BOOL separate_payload_directory=![payload_directory isEqual:runtime_string];
    if(separate_payload_directory) {
        // The reviewed guest sandbox allows executable mappings from GPUBundles,
        // but permits temporary socket writes only in its temporary directories.
        // Stage only a fresh benchmark directory; never alter the sandbox profile.
        struct stat directory={0};
        if(![[payload_directory stringByDeletingLastPathComponent]isEqual:@"/Library/GPUBundles"]
            ||![[payload_directory lastPathComponent]hasPrefix:@"InfinifyPerf-"]
            ||lstat(payload_directory.fileSystemRepresentation,&directory)||!S_ISDIR(directory.st_mode)
            ||directory.st_uid!=config.controller_uid||(directory.st_mode&07777)!=0700) {
            fputs("separate payload must be inside a fresh controller-owned 0700 /Library/GPUBundles/InfinifyPerf-* directory\n",stderr);return 3;
        }
    }
    NSString *sidecar=[payload_string stringByAppendingString:@".ifwsp"];
    NSString *socket=[runtime_string stringByAppendingPathComponent:@DW2_SOCKET];struct stat existing={0};
    if(lstat(sidecar.fileSystemRepresentation,&existing)==0||errno!=ENOENT||lstat(socket.fileSystemRepresentation,&existing)==0||errno!=ENOENT){fputs("sidecar or socket exists; do not repeat an uncertain injection\n",stderr);return 3;}
    int config_fd=open(sidecar.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0400);
    bool staged=config_fd>=0&&write_all(config_fd,&config,sizeof(config))&&fchown(config_fd,server.pbi_uid,server.pbi_gid)==0&&fsync(config_fd)==0;
    if(config_fd>=0)close(config_fd);
    if(!staged){unlink(sidecar.fileSystemRepresentation);return 1;}
    // WindowServer's sandbox/UID must be able to load this isolated payload and
    // create its socket. The directory is not enumerable by the controller.
    if(chown(payload,server.pbi_uid,server.pbi_gid)||chmod(payload,0500)
        ||(separate_payload_directory&&(chown(payload_directory.fileSystemRepresentation,server.pbi_uid,server.pbi_gid)
            ||chmod(payload_directory.fileSystemRepresentation,0711)))
        ||chown(runtime,server.pbi_uid,server.pbi_gid)||chmod(runtime,0711)) {
        fputs("failed to stage WindowServer-owned runtime; retain it for explicit cleanup\n",stderr);return 1;
    }
    int result=1;bool executed=false,bootstrap=false;mach_port_t task=MACH_PORT_NULL;thread_act_t thread=MACH_PORT_NULL;
    mach_vm_address_t code=0,stack=0;const vm_size_t stack_size=16384;
    if(!same_process(pid,&server)||!same_fixture(&config,&fixture))goto cleanup;
    kern_return_t status=task_for_pid(mach_task_self(),pid,&task);
    if(status!=KERN_SUCCESS){fprintf(stderr,"WindowServer task_for_pid: %s\n",mach_error_string(status));goto cleanup;}
    if(!same_process(pid,&server)||!same_fixture(&config,&fixture)||mach_vm_allocate(task,&stack,stack_size,VM_FLAGS_ANYWHERE)!=KERN_SUCCESS
        ||mach_vm_allocate(task,&code,sizeof(shell_code),VM_FLAGS_ANYWHERE)!=KERN_SUCCESS)goto cleanup;
    uint64_t create=(uint64_t)ptrauth_strip(dlsym(RTLD_DEFAULT,"pthread_create_from_mach_thread"),ptrauth_key_function_pointer);
    uint64_t open_library=(uint64_t)ptrauth_strip(dlsym(RTLD_DEFAULT,"dlopen"),ptrauth_key_function_pointer);
    if(!create||!open_library)goto cleanup;
    memcpy(shell_code+88,&create,8);memcpy(shell_code+160,&open_library,8);memcpy(shell_code+168,payload,strlen(payload)+1);
    if(!same_process(pid,&server)||!same_fixture(&config,&fixture)
        ||mach_vm_write(task,code,(vm_address_t)shell_code,sizeof(shell_code))!=KERN_SUCCESS
        ||mach_vm_protect(task,code,sizeof(shell_code),false,VM_PROT_READ|VM_PROT_EXECUTE)!=KERN_SUCCESS)goto cleanup;
    void *kernel=dlopen("/usr/lib/system/libsystem_kernel.dylib",RTLD_NOW|RTLD_LOCAL);
    ConvertState convert=kernel?(ConvertState)dlsym(kernel,"thread_convert_thread_state"):NULL;
    if(!convert)goto cleanup;
    arm_thread_state64_t state={0},machine={0};mach_msg_type_number_t count=ARM_THREAD_STATE64_COUNT,machine_count=ARM_THREAD_STATE64_COUNT;
    __darwin_arm_thread_state64_set_pc_fptr(state,ptrauth_sign_unauthenticated((void*)code,ptrauth_key_asia,0));
    __darwin_arm_thread_state64_set_sp(state,stack+stack_size/2);
    if(thread_create(task,&thread)!=KERN_SUCCESS)goto cleanup;
    if(convert(thread,2,ARM_THREAD_STATE64,(thread_state_t)&state,count,(thread_state_t)&machine,&machine_count)!=KERN_SUCCESS)goto cleanup;
    if(thread_terminate(thread)!=KERN_SUCCESS)goto cleanup;mach_port_deallocate(mach_task_self(),thread);thread=MACH_PORT_NULL;
    if(!same_process(pid,&server)||!same_fixture(&config,&fixture)
        ||thread_create_running(task,ARM_THREAD_STATE64,(thread_state_t)&machine,machine_count,&thread)!=KERN_SUCCESS)goto cleanup;
    executed=true;
    for(unsigned i=0;i<100;i++) {
        usleep(20000);count=ARM_THREAD_STATE64_COUNT;
        if(thread_get_state(thread,ARM_THREAD_STATE64,(thread_state_t)&state,&count)!=KERN_SUCCESS)break;
        if(state.__x[0]==0x79616265){bootstrap=true;break;}
    }
    if(bootstrap)for(unsigned i=0;i<100;i++) {
        if(!same_process(pid,&server)||!same_fixture(&config,&fixture))break;
        if(socket_peer(runtime,pid,server.pbi_uid)){result=0;break;}usleep(20000);
    }
cleanup:
    if(thread){if(!executed||bootstrap)thread_terminate(thread);mach_port_deallocate(mach_task_self(),thread);}
    if(!executed){if(code)mach_vm_deallocate(task,code,sizeof(shell_code));if(stack)mach_vm_deallocate(task,stack,stack_size);}
    if(task)mach_port_deallocate(mach_task_self(),task);
    // Once started, the new pthread can still use the bootstrap allocation.
    // Retain it until this server instance exits; never restart WindowServer.
    printf("{\"schema\":1,\"backend\":\"windowserver-resident-prototype\",\"injection_executed\":%s,\"bootstrap_completed\":%s,\"socket_peer_verified\":%s,\"server_pid\":%d,\"server_uid\":%u,\"lifetime_ms\":%u,\"performance_proven\":false}\n",
        executed?"true":"false",bootstrap?"true":"false",result==0?"true":"false",pid,server.pbi_uid,config.lifetime_ms);
    if(result)fputs("prototype readiness unestablished; retain runtime and do not retry blindly\n",stderr);
    return result;
} }
