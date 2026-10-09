/* SPDX-License-Identifier: MIT
 * Adapted from yabai src/osax/loader.m at dd845723416f5fe92af49fad5ebab00369e07edd.
 * arm64e injection path by Jeremy Legendre; original attribution retained below.
 * DriftWM changes: explicit opt-in/preflight, absolute payload path, private
 * per-user runtime configuration, bounded completion status and cleanup.
 *
 * The MIT License (MIT)
 *
 * Copyright (c) 2019 Åsmund Vikane
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */
#include <Cocoa/Cocoa.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>
#include <libproc.h>
#include <fcntl.h>
#include "preflight.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <limits.h>

#ifdef __arm64__
#include <ptrauth.h>
kern_return_t (*_thread_convert_thread_state)(thread_act_t thread, int direction, thread_state_flavor_t flavor, thread_state_t in_state, mach_msg_type_number_t in_stateCnt, thread_state_t out_state, mach_msg_type_number_t *out_stateCnt);
#endif

static char *payload_path;

//
// :Attribution
//
// The arm64e injection path is based on work by Jeremy Legendre (https://github.com/jslegendre)
//

static char shell_code[168 + PATH_MAX] =
#ifdef __x86_64__
"\x55"                             // push       rbp
"\x48\x89\xE5"                     // mov        rbp, rsp
"\x48\x83\xEC\x10"                 // sub        rsp, 0x10
"\x48\x8D\x7D\xF8"                 // lea        rdi, qword [rbp+var_8]
"\x31\xC0"                         // xor        eax, eax
"\x89\xC1"                         // mov        ecx, eax
"\x48\x8D\x15\x1E\x00\x00\x00"     // lea        rdx, qword ptr [rip+0x1E]
"\x48\x89\xCE"                     // mov        rsi, rcx
"\x48\xB8"                         // movabs     rax, pthread_create_from_mach_thread
"\x00\x00\x00\x00\x00\x00\x00\x00" //
"\xFF\xD0"                         // call       rax
"\x48\x83\xC4\x10"                 // add        rsp, 0x10
"\x5D"                             // pop        rbp
"\x48\xC7\xC0\x65\x62\x61\x79"     // mov        rax, 0x79616265
"\xEB\xFE"                         // jmp        0x0
"\xC3"                             // ret
"\x55"                             // push       rbp
"\x48\x89\xE5"                     // mov        rbp, rsp
"\xBE\x01\x00\x00\x00"             // mov        esi, 0x1
"\x48\x8D\x3D\x16\x00\x00\x00"     // lea        rdi, qword ptr [rip+0x16]
"\x48\xB8"                         // movabs     rax, dlopen
"\x00\x00\x00\x00\x00\x00\x00\x00" //
"\xFF\xD0"                         // call       rax
"\x31\xF6"                         // xor        esi, esi
"\x89\xF7"                         // mov        edi, esi
"\x48\x89\xF8"                     // mov        rax, rdi
"\x5D"                             // pop        rbp
"\xC3"                             // ret
#elif __arm64__
"\xFF\xC3\x00\xD1"                 // sub        sp, sp, #0x30
"\xFD\x7B\x02\xA9"                 // stp        x29, x30, [sp, #0x20]
"\xFD\x83\x00\x91"                 // add        x29, sp, #0x20
"\xA0\xC3\x1F\xB8"                 // stur       w0, [x29, #-0x4]
"\xE1\x0B\x00\xF9"                 // str        x1, [sp, #0x10]
"\xE0\x23\x00\x91"                 // add        x0, sp, #0x8
"\x08\x00\x80\xD2"                 // mov        x8, #0
"\xE8\x07\x00\xF9"                 // str        x8, [sp, #0x8]
"\xE1\x03\x08\xAA"                 // mov        x1, x8
"\xE2\x01\x00\x10"                 // adr        x2, #0x3C
"\xE2\x23\xC1\xDA"                 // paciza     x2
"\xE3\x03\x08\xAA"                 // mov        x3, x8
"\x49\x01\x00\x10"                 // adr        x9, #0x28 ; pthread_create_from_mach_thread
"\x29\x01\x40\xF9"                 // ldr        x9, [x9]
"\x20\x01\x3F\xD6"                 // blr        x9
"\xA0\x4C\x8C\xD2"                 // movz       x0, #0x6265
"\x20\x2C\xAF\xF2"                 // movk       x0, #0x7961, lsl #16
"\x09\x00\x00\x10"                 // adr        x9, #0
"\x20\x01\x1F\xD6"                 // br         x9
"\xFD\x7B\x42\xA9"                 // ldp        x29, x30, [sp, #0x20]
"\xFF\xC3\x00\x91"                 // add        sp, sp, #0x30
"\xC0\x03\x5F\xD6"                 // ret
"\x00\x00\x00\x00\x00\x00\x00\x00" //
"\x7F\x23\x03\xD5"                 // pacibsp
"\xFF\xC3\x00\xD1"                 // sub        sp, sp, #0x30
"\xFD\x7B\x02\xA9"                 // stp        x29, x30, [sp, #0x20]
"\xFD\x83\x00\x91"                 // add        x29, sp, #0x20
"\xA0\xC3\x1F\xB8"                 // stur       w0, [x29, #-0x4]
"\xE1\x0B\x00\xF9"                 // str        x1, [sp, #0x10]
"\x21\x00\x80\xD2"                 // mov        x1, #1
"\x60\x01\x00\x10"                 // adr        x0, #0x2c ; payload_path
"\x09\x01\x00\x10"                 // adr        x9, #0x20 ; dlopen
"\x29\x01\x40\xF9"                 // ldr        x9, [x9]
"\x20\x01\x3F\xD6"                 // blr        x9
"\x09\x00\x80\x52"                 // mov        w9, #0
"\xE0\x03\x09\xAA"                 // mov        x0, x9
"\xFD\x7B\x42\xA9"                 // ldp        x29, x30, [sp, #0x20]
"\xFF\xC3\x00\x91"                 // add        sp, sp, #0x30
"\xFF\x0F\x5F\xD6"                 // retab
"\x00\x00\x00\x00\x00\x00\x00\x00" //
#endif
"\x00\x00\x00\x00\x00\x00\x00\x00" // empty space for payload_path
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00"
"\x00\x00\x00\x00\x00\x00\x00\x00";

static pid_t get_dock_pid(void)
{
    NSArray *list = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.dock"];

    if (list.count == 1) {
        NSRunningApplication *dock = list[0];
        if ([dock isFinishedLaunching] == YES) {
            return [dock processIdentifier];
        }
    }

    return 0;
}

// Readiness requires the authenticated v1 socket to be served by this Dock PID.
// The bootstrap sentinel proves only pthread dispatch, never dlopen completion.
static BOOL wait_for_helper(const char *runtime,const char *nonce,pid_t pid,uid_t uid) {
    struct sockaddr_un addr={.sun_family=AF_UNIX};
    if(snprintf(addr.sun_path,sizeof(addr.sun_path),"%s/helper.sock",runtime)>=(int)sizeof(addr.sun_path))return NO;
    for(int attempt=0;attempt<50;attempt++) {
        int fd=socket(AF_UNIX,SOCK_STREAM,0);
        if(fd<0)return NO;
        struct timeval timeout={.tv_sec=1};
        setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
        int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
        if(connect(fd,(struct sockaddr *)&addr,sizeof(addr))){close(fd);usleep(100000);continue;}
        uid_t peerUID;gid_t peerGID;pid_t peerPID=0;socklen_t len=sizeof(peerPID);
        if(getpeereid(fd,&peerUID,&peerGID)||peerUID!=uid||getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&peerPID,&len)||peerPID!=pid){close(fd);return NO;}
        char request[256];int count=snprintf(request,sizeof(request),"{\"v\":1,\"op\":\"probe\",\"nonce\":\"%s\"}\n",nonce);
        if(write(fd,request,count)!=count){close(fd);return NO;}
        char response[4096];size_t used=0;
        while(used<sizeof(response)){ssize_t n=read(fd,response+used,1);if(n!=1)break;if(response[used++]=='\n')break;}
        close(fd);
        if(!used||response[used-1]!='\n')return NO;
        id object=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:response length:used] options:0 error:NULL];
        return [object isKindOfClass:NSDictionary.class] && [object[@"v"] isEqual:@1] && [object[@"ok"] isEqual:@YES];
    }
    return NO;
}
int main(int argc, char **argv) { @autoreleasepool {
    if(argc!=5 || strcmp(argv[1],"--inject-dock")) {
        fprintf(stderr,"usage: loader --inject-dock /absolute/payload-arm64e.dylib /absolute/private-runtime nonce64hex\nExplicit opt-in only; run doctor first. No SIP/boot settings are changed.\n");return 2;
    }
    uint32_t sip;int preview;
    if(dw_preflight(&sip,&preview)!=0){fprintf(stderr,"injection unavailable: current SIP/arm64e boot policy fails preflight\n");return 3;}
    payload_path=argv[2];
    if(payload_path[0]!='/'||strlen(payload_path)>=sizeof(shell_code)-168||argv[3][0]!='/'||strlen(argv[4])!=64)return 2;
    for(const char *p=argv[4];*p;p++)if(!((*p>='0'&&*p<='9')||(*p>='a'&&*p<='f')))return 2;
    pid_t pid=get_dock_pid();
    struct proc_bsdinfo dockInfo={0};
    if(pid<=0||proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&dockInfo,sizeof(dockInfo))!=sizeof(dockInfo)){fprintf(stderr,"could not locate Dock identity\n");return 1;}
    // The IPC peer must be the login user. A root invoker drops effective UID only
    // for readiness probing; no user other than root or this login UID may load.
    if(getuid()!=0 && getuid()!=dockInfo.pbi_uid)return 1;
    struct stat st;
    if(lstat(payload_path,&st)||!S_ISREG(st.st_mode)||st.st_uid!=dockInfo.pbi_uid||(st.st_mode&0022)){fprintf(stderr,"payload ownership/mode invalid\n");return 1;}
    if(lstat(argv[3],&st)||!S_ISDIR(st.st_mode)||st.st_uid!=dockInfo.pbi_uid||(st.st_mode&0777)!=0700){fprintf(stderr,"create a fresh 0700 runtime directory as Dock login user first\n");return 1;}
    char socketPath[sizeof(((struct sockaddr_un *)0)->sun_path)];
    if(snprintf(socketPath,sizeof(socketPath),"%s/helper.sock",argv[3])>=(int)sizeof(socketPath)){fprintf(stderr,"Unix socket path exceeds 103 bytes\n");return 1;}
    if(lstat(socketPath,&st)==0){fprintf(stderr,"runtime socket already exists; refusing ambiguous retry\n");return 1;}
    NSString *recovery=[[NSString stringWithUTF8String:argv[3]] stringByAppendingPathComponent:@"recovery.json"];
    if(lstat(recovery.fileSystemRepresentation,&st)==0){fprintf(stderr,"runtime has a recovery journal; review it and use a fresh directory\n");return 1;}
    NSString *configPath=[[NSString stringWithUTF8String:payload_path] stringByAppendingString:@".json"];
    NSData *configuration=[NSJSONSerialization dataWithJSONObject:@{@"runtime":[NSString stringWithUTF8String:argv[3]],@"nonce":[NSString stringWithUTF8String:argv[4]]} options:0 error:NULL];
    int configFD=open(configPath.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(configFD<0){perror("create new payload sidecar");return 1;}
    BOOL configOK=(geteuid()==dockInfo.pbi_uid || fchown(configFD,dockInfo.pbi_uid,dockInfo.pbi_gid)==0) && write(configFD,configuration.bytes,configuration.length)==(ssize_t)configuration.length && fsync(configFD)==0;
    close(configFD);if(!configOK){unlink(configPath.fileSystemRepresentation);return 1;}

    int result=1;BOOL executed=NO,bootstrap=NO;
    mach_port_t task=MACH_PORT_NULL;thread_act_t thread=MACH_PORT_NULL;
    mach_vm_address_t code=0,stack=0;vm_size_t stack_size=16*1024;
    uint64_t stack_contents=0xCAFEBABE;
    kern_return_t error=task_for_pid(mach_task_self(),pid,&task);
    if(error!=KERN_SUCCESS){fprintf(stderr,"task_for_pid failed: %s\n",mach_error_string(error));goto cleanup;}
    if(mach_vm_allocate(task,&stack,stack_size,VM_FLAGS_ANYWHERE)!=KERN_SUCCESS)goto cleanup;
    if(mach_vm_write(task,stack,(vm_address_t)&stack_contents,sizeof(stack_contents))!=KERN_SUCCESS)goto cleanup;
    if(vm_protect(task,stack,stack_size,1,VM_PROT_READ|VM_PROT_WRITE)!=KERN_SUCCESS)goto cleanup;
    if(mach_vm_allocate(task,&code,sizeof(shell_code),VM_FLAGS_ANYWHERE)!=KERN_SUCCESS)goto cleanup;
    uint64_t pcfmt_address=(uint64_t)ptrauth_strip(dlsym(RTLD_DEFAULT,"pthread_create_from_mach_thread"),ptrauth_key_function_pointer);
    uint64_t dlopen_address=(uint64_t)ptrauth_strip(dlsym(RTLD_DEFAULT,"dlopen"),ptrauth_key_function_pointer);
    if(!pcfmt_address||!dlopen_address)goto cleanup;
    memcpy(shell_code+88,&pcfmt_address,sizeof(uint64_t));
    memcpy(shell_code+160,&dlopen_address,sizeof(uint64_t));
    memcpy(shell_code+168,payload_path,strlen(payload_path));
    if(mach_vm_write(task,code,(vm_address_t)shell_code,sizeof(shell_code))!=KERN_SUCCESS)goto cleanup;
    if(vm_protect(task,code,sizeof(shell_code),0,VM_PROT_EXECUTE|VM_PROT_READ)!=KERN_SUCCESS)goto cleanup;
    void *handle=dlopen("/usr/lib/system/libsystem_kernel.dylib",RTLD_GLOBAL|RTLD_LAZY);
    if(handle){_thread_convert_thread_state=dlsym(handle,"thread_convert_thread_state");dlclose(handle);}
    if(!_thread_convert_thread_state)goto cleanup;
    arm_thread_state64_t state={},machine={};
    mach_msg_type_number_t count=ARM_THREAD_STATE64_COUNT,machineCount=ARM_THREAD_STATE64_COUNT;
    __darwin_arm_thread_state64_set_pc_fptr(state,ptrauth_sign_unauthenticated((void *)code,ptrauth_key_asia,0));
    __darwin_arm_thread_state64_set_sp(state,stack+stack_size/2);
    if(thread_create(task,&thread)!=KERN_SUCCESS)goto cleanup;
    if(_thread_convert_thread_state(thread,2,ARM_THREAD_STATE64,(thread_state_t)&state,count,(thread_state_t)&machine,&machineCount)!=KERN_SUCCESS)goto cleanup;
    if(thread_terminate(thread)!=KERN_SUCCESS)goto cleanup;
    mach_port_deallocate(mach_task_self(),thread);thread=MACH_PORT_NULL;
    // macOS 26+ uses the converted-state create-running path from yabai.
    if(thread_create_running(task,ARM_THREAD_STATE64,(thread_state_t)&machine,machineCount,&thread)!=KERN_SUCCESS)goto cleanup;
    executed=YES;
    for(int i=0;i<50;i++) {
        usleep(20000);count=ARM_THREAD_STATE64_COUNT;
        if(thread_get_state(thread,ARM_THREAD_STATE64,(thread_state_t)&state,&count)!=KERN_SUCCESS)break;
        if(state.__x[0]==0x79616265){bootstrap=YES;break;}
    }
    if(bootstrap) {
        uid_t savedUID=geteuid();
        // getpeereid is checked by server as well: root must connect as login UID.
        if(seteuid(dockInfo.pbi_uid)==0) {
            BOOL ready=wait_for_helper(argv[3],argv[4],pid,dockInfo.pbi_uid);
            if(seteuid(savedUID)!=0){fprintf(stderr,"failed to restore effective UID\n");goto cleanup;}
            if(ready)result=0;
        }
    }
cleanup:
    if(thread) {
        // A running bootstrap can hold pthread/dyld locks until it reaches the
        // terminal spin. Terminating an unobserved state can wedge Dock forever.
        if(!executed || bootstrap) {
            kern_return_t terminated=thread_terminate(thread);
            if(terminated!=KERN_SUCCESS)fprintf(stderr,"remote bootstrap termination: %s\n",mach_error_string(terminated));
        } else {
            fprintf(stderr,"bootstrap completion unknown: remote thread left running; allocations and sidecar retained\n");
        }
        // Releasing our send right does not terminate the remote thread.
        mach_port_deallocate(mach_task_self(),thread);
    }
    if(!executed) {
        if(code)mach_vm_deallocate(task,code,sizeof(shell_code));
        if(stack)mach_vm_deallocate(task,stack,stack_size);
        unlink(configPath.fileSystemRepresentation);
    }
    // Once executed, the dlopen pthread may still use the remote code even after
    // bootstrap termination. Keep its tiny allocations and sidecar until Dock exits;
    // never restart Dock here, never free memory whose liveness is uncertain.
    if(task)mach_port_deallocate(mach_task_self(),task);
    if(result==0)fprintf(stderr,"authenticated helper ready in Dock; no window enrolled or transformed\n");
    else fprintf(stderr,"helper readiness not established%s\n",executed ? "; execution began, retain sidecar/runtime and do not retry blindly" : "; pre-execution resources and sidecar cleaned up");
    return result;
} }
