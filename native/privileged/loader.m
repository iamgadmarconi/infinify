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
#include <sys/sysctl.h>
#include <libproc.h>
#include <fcntl.h>
#include <errno.h>
#include <inttypes.h>
#include <CommonCrypto/CommonDigest.h>
#include "preflight.h"
#include "dwclient.h"
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

static BOOL process_info(pid_t pid,struct proc_bsdinfo *info) {
    memset(info,0,sizeof(*info));
    return pid>1 && proc_pidinfo(pid,PROC_PIDTBSDINFO,0,info,sizeof(*info))==sizeof(*info)
        && info->pbi_pid==(uint32_t)pid && info->pbi_start_tvsec && info->pbi_start_tvusec<1000000;
}
static BOOL current_dock(pid_t pid,const struct proc_bsdinfo *expected) {
    struct proc_bsdinfo now;
    return get_dock_pid()==pid && process_info(pid,&now) && now.pbi_uid==expected->pbi_uid
        && now.pbi_start_tvsec==expected->pbi_start_tvsec && now.pbi_start_tvusec==expected->pbi_start_tvusec;
}
static BOOL canonical_boot_uuid(id value) {
    if(![value isKindOfClass:NSString.class] || [value length]!=36)return NO;
    for(NSUInteger i=0;i<36;i++) {
        unichar c=[value characterAtIndex:i];
        if(i==8 || i==13 || i==18 || i==23) { if(c!='-')return NO; }
        else if(!((c>='0'&&c<='9')||(c>='A'&&c<='F')))return NO;
    }
    return YES;
}
static BOOL boot_session_uuid(char output[37]) {
    char value[37]={0};size_t size=sizeof(value);
    if(sysctlbyname("kern.bootsessionuuid",value,&size,NULL,0) || size!=sizeof(value) || value[36]!='\0')return NO;
    for(NSUInteger i=0;i<36;i++) {
        char c=value[i];
        if(i==8 || i==13 || i==18 || i==23) { if(c!='-')return NO; }
        else if(!((c>='0'&&c<='9')||(c>='A'&&c<='F')))return NO;
    }
    memcpy(output,value,sizeof(value));return YES;
}
static BOOL exact_json_keys(NSDictionary *value,NSArray *keys) {
    return [value isKindOfClass:NSDictionary.class]
        && [[NSSet setWithArray:value.allKeys]isEqual:[NSSet setWithArray:keys]];
}
static BOOL json_integer(id value,uint64_t minimum,uint64_t maximum) {
    return [value isKindOfClass:NSNumber.class]
        && CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()
        && !CFNumberIsFloatType((__bridge CFNumberRef)value)
        && [value compare:@(minimum)]!=NSOrderedAscending
        && [value compare:@(maximum)]!=NSOrderedDescending;
}
static BOOL private_runtime_path(const char *path) {
    static const char prefix[]="/tmp/if-native.";
    if(!path || strncmp(path,prefix,sizeof(prefix)-1))return NO;
    const char *suffix=path+sizeof(prefix)-1;
    if(strlen(suffix)!=6)return NO;
    for(const char *p=suffix;*p;p++)if(!((*p>='a'&&*p<='z')||(*p>='A'&&*p<='Z')||(*p>='0'&&*p<='9')))return NO;
    return YES;
}
static BOOL retired_process(pid_t pid,uint64_t birthSec,uint64_t birthUsec) {
    struct proc_bsdinfo current={0};
    errno=0;
    int length=proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&current,sizeof(current));
    if(length==(int)sizeof(current)) {
        if(current.pbi_pid!=(uint32_t)pid || !current.pbi_start_tvsec || current.pbi_start_tvusec>=1000000)return NO;
        return current.pbi_start_tvsec!=birthSec || current.pbi_start_tvusec!=birthUsec;
    }
    if(length!=0 && errno==ESRCH)return YES;
    if(length!=0)return NO;
    if(errno==ESRCH)return YES;
    if(kill(pid,0)==-1 && errno==ESRCH)return YES;
    return NO;
}
static BOOL write_all_fd(int fd,const void *bytes,size_t length) {
    const uint8_t *cursor=bytes;
    while(length) {
        ssize_t written=write(fd,cursor,length);
        if(written<0 && errno==EINTR)continue;
        if(written<=0)return NO;
        cursor+=(size_t)written;length-=(size_t)written;
    }
    return YES;
}
static NSString *sha256_hex(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if(!CC_SHA256(data.bytes,(CC_LONG)data.length,digest))return nil;
    NSMutableString *hex=[NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH*2];
    for(unsigned i=0;i<CC_SHA256_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];
    return hex;
}
static BOOL recovery_journal(const char *sourcePath,const char *runtime,const struct proc_bsdinfo *dock,
                             pid_t expectedPID,uint64_t expectedSec,uint64_t expectedUsec,
                             NSData **sourceBytes,NSDictionary **recoveryFields) {
    if(!sourcePath || sourcePath[0]!='/' || strlen(sourcePath)>=PATH_MAX || !private_runtime_path(runtime))return NO;
    const char *lastSlash=strrchr(sourcePath,'/');
    if(!lastSlash || strcmp(lastSlash+1,"v2-journal.json"))return NO;
    size_t directoryLength=(size_t)(lastSlash-sourcePath);
    if(!directoryLength || directoryLength>=PATH_MAX)return NO;
    char sourceDirectory[PATH_MAX];memcpy(sourceDirectory,sourcePath,directoryLength);sourceDirectory[directoryLength]=0;
    if(!private_runtime_path(sourceDirectory) || !strcmp(sourceDirectory,runtime))return NO;
    int sourceFD=open(sourceDirectory,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(sourceFD<0)return NO;
    struct stat directoryStat={0},stageStat={0};
    BOOL ok=fstat(sourceFD,&directoryStat)==0 && S_ISDIR(directoryStat.st_mode)
        && directoryStat.st_uid==dock->pbi_uid && (directoryStat.st_mode&07777)==0700;
    if(ok) {
        if(fstatat(sourceFD,"v2-journal.next",&stageStat,AT_SYMLINK_NOFOLLOW)==0 || errno!=ENOENT)ok=NO;
    }
    int journalFD=ok ? openat(sourceFD,"v2-journal.json",O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK) : -1;
    if(journalFD<0)ok=NO;
    struct stat fileStat={0};
    if(ok)ok=fstat(journalFD,&fileStat)==0 && S_ISREG(fileStat.st_mode) && fileStat.st_uid==dock->pbi_uid
        && (fileStat.st_mode&07777)==0600 && fileStat.st_size>0 && fileStat.st_size<=4*1024*1024;
    NSMutableData *data=ok ? [NSMutableData dataWithLength:(NSUInteger)fileStat.st_size] : nil;
    if(ok) {
        uint8_t *cursor=data.mutableBytes;size_t remaining=(size_t)fileStat.st_size;
        while(remaining) {
            ssize_t count=read(journalFD,cursor,remaining);
            if(count<0 && errno==EINTR)continue;
            if(count<=0){ok=NO;break;}
            cursor+=(size_t)count;remaining-=(size_t)count;
        }
        char extra;
        if(ok) {
            ssize_t count;
            do { count=read(journalFD,&extra,1); } while(count<0 && errno==EINTR);
            if(count!=0)ok=NO;
        }
    }
    if(journalFD>=0)close(journalFD);
    if(sourceFD>=0)close(sourceFD);
    if(!ok)return NO;

    NSDictionary *journal=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if(![journal isKindOfClass:NSDictionary.class])return NO;
    NSArray *keys=@[@"v",@"server_pid",@"server_birth_sec",@"server_birth_usec",@"server_uid",@"boot_uuid",
        @"generation",@"state",@"windows",@"released_windows",@"last_restore"];
    NSArray *windows=journal[@"windows"],*released=journal[@"released_windows"];
    char bootUUID[37];
    if(!boot_session_uuid(bootUUID) || !exact_json_keys(journal,keys)
        || !json_integer(journal[@"v"],3,3) || !json_integer(journal[@"server_pid"],2,INT_MAX)
        || !json_integer(journal[@"server_birth_sec"],1,UINT64_MAX) || !json_integer(journal[@"server_birth_usec"],0,999999)
        || !json_integer(journal[@"server_uid"],1,UINT32_MAX) || !canonical_boot_uuid(journal[@"boot_uuid"])
        || !json_integer(journal[@"generation"],0,UINT64_MAX-1)
        || ![@[@"empty",@"holding",@"restoring"] containsObject:journal[@"state"]]
        || ![windows isKindOfClass:NSArray.class] || ![released isKindOfClass:NSArray.class]
        || windows.count>1024 || released.count>1024 || windows.count+released.count>1024
        || (journal[@"last_restore"]!=NSNull.null && ![journal[@"last_restore"] isKindOfClass:NSDictionary.class]))return NO;
    if([journal[@"server_pid"]intValue]!=expectedPID || [journal[@"server_birth_sec"]unsignedLongLongValue]!=expectedSec
        || [journal[@"server_birth_usec"]unsignedLongLongValue]!=expectedUsec
        || [journal[@"server_uid"]unsignedIntValue]!=dock->pbi_uid
        || ![journal[@"boot_uuid"]isEqual:[NSString stringWithUTF8String:bootUUID]]
        || !retired_process(expectedPID,expectedSec,expectedUsec))return NO;
    NSString *digest=sha256_hex(data);
    if(!digest)return NO;
    *sourceBytes=data;
    *recoveryFields=@{@"recovery_source_sha256":digest,@"recovery_server_pid":journal[@"server_pid"],
        @"recovery_server_birth_sec":journal[@"server_birth_sec"],@"recovery_server_birth_usec":journal[@"server_birth_usec"],
        @"recovery_server_uid":journal[@"server_uid"],@"recovery_boot_uuid":journal[@"boot_uuid"]};
    return YES;
}
static BOOL parse_decimal(const char *text,uint64_t maximum,uint64_t *value) {
    if(!text || !*text)return NO;
    for(const char *p=text;*p;p++)if(*p<'0' || *p>'9')return NO;
    errno=0;char *end=NULL;unsigned long long number=strtoull(text,&end,10);
    if(errno==ERANGE || *end || number>maximum)return NO;
    *value=number;return YES;
}
static BOOL valid_nonce(const char *nonce) {
    if(strlen(nonce)!=64)return NO;
    for(const char *p=nonce;*p;p++)if(!((*p>='0' && *p<='9') || (*p>='a' && *p<='f')))return NO;
    return YES;
}
// The production launcher never places credentials in argv. O_NONBLOCK also
// avoids waiting on a substituted FIFO before fstat rejects its file type.
static BOOL read_nonce_file(const char *path,uid_t uid,char nonce[65]) {
    if(path[0]!='/')return NO;
    int fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0)return NO;
    struct stat st;
    BOOL ok=fstat(fd,&st)==0 && S_ISREG(st.st_mode) && st.st_uid==uid
        && (st.st_mode&07777)==0600 && (st.st_size==64 || st.st_size==65);
    char bytes[66];size_t used=0;
    while(ok && used<sizeof(bytes)) {
        ssize_t n=read(fd,bytes+used,sizeof(bytes)-used);
        if(n<0 && errno==EINTR)continue;
        if(n<0){ok=NO;break;}
        if(!n)break;
        used+=(size_t)n;
    }
    close(fd);
    if(!ok || (used!=64 && !(used==65 && bytes[64]=='\n')))return NO;
    memcpy(nonce,bytes,64);nonce[64]=0;
    return valid_nonce(nonce);
}
// Readiness audits protocol v2 without submitting a frame or enrolling a window.
// dwclient binds both authenticated peers to their kernel PID/effective UID; the
// process birth and exact requested scope are checked here. The bootstrap
// sentinel alone proves only pthread dispatch, never dlopen completion.
static BOOL wait_for_helper(const char *runtime,const char *nonce,pid_t pid,
                            const struct proc_bsdinfo *dock,const struct dw2_process *only,BOOL recovering) {
    if(geteuid()!=dock->pbi_uid || !current_dock(pid,dock))return NO;
    dw_client *client=NULL;struct dw_client_info info={0};
    int status=dw_client_open(runtime,nonce,NULL,5000,&client,&info);
    if(status!=DW_CLIENT_OK){fprintf(stderr,"protocol v2 readiness connection failed (%d)\n",status);return NO;}
    uint32_t scope=only ? DW2_SCOPE_ALLOWLIST : DW2_SCOPE_SAME_USER;
    uint32_t required=DW2_CAP_ALPHA|DW2_CAP_RESTORE_WINDOW|DW2_CAP_ENROLLMENT|DW2_CAP_INSPECT;
    BOOL ok=info.server_pid==pid && info.scope==scope && (info.caps&required)==required
        && !(info.caps&DW2_CAP_FIXTURE_FAMILY);
    struct dw2_process enrolled={0};uint32_t count=UINT32_MAX;
    if(ok)ok=dw_client_enrollment(client,2000,only ? &enrolled : NULL,only ? 1 : 0,&count)==DW_CLIENT_OK
        && count==(only ? 1U : 0U);
    if(ok && only) {
        struct proc_bsdinfo now;
        ok=enrolled.pid==only->pid && enrolled.birth_sec==only->birth_sec && enrolled.birth_usec==only->birth_usec
            && process_info(only->pid,&now) && now.pbi_uid==dock->pbi_uid
            && now.pbi_start_tvsec==only->birth_sec && now.pbi_start_tvusec==only->birth_usec;
    }
    struct dw2_probe_reply probe={0};size_t length=0;
    if(ok)ok=dw_client_probe(client,2000,&probe,sizeof(probe),&length)==DW_CLIENT_OK
        && length==sizeof(probe) && probe.scope==info.scope && probe.caps==info.caps
        && probe.queue==info.queue && probe.lease_ms==info.lease_ms && probe.server_pid==pid
        && !probe.journal_pending && !probe.held && !probe.restoring && !probe.table_count && !probe.fixture_count
        && !probe.frames_received && !probe.frames_applied && !probe.frames_superseded
        && (recovering ? probe.journal_writes>0 : probe.journal_writes==0);
    // Closing an empty, never-submitted session leaves no windows to restore.
    dw_client_close(client);
    ok=ok && current_dock(pid,dock);
    if(!ok)fprintf(stderr,"protocol v2 scope, process identity, capabilities or empty-window audit failed\n");
    return ok;
}
static int usage(void) {
    fprintf(stderr,"usage: loader --dock-identity\n"
        "       loader --inject-dock PAYLOAD RUNTIME --nonce-file ABS_FILE --desktop [--expected-dock PID SEC USEC] [--recover-journal ABS_PATH --expected-retired-dock PID SEC USEC]\n"
        "       loader --inject-dock PAYLOAD RUNTIME --nonce-file ABS_FILE --only-pid PID\n"
        "Paths must be absolute. Explicit scope is required; run doctor first. No SIP/boot settings are changed.\n"
        "--desktop authorizes same-login-user scope; --only-pid pins one process instance.\n");
    return 2;
}
int main(int argc, char **argv) { @autoreleasepool {
    if(argc==2 && !strcmp(argv[1],"--dock-identity")) {
        pid_t pid=get_dock_pid();struct proc_bsdinfo info;
        if(!process_info(pid,&info) || !current_dock(pid,&info)){fprintf(stderr,"could not locate stable Dock identity\n");return 1;}
        char bootUUID[37];
        if(!boot_session_uuid(bootUUID)){fprintf(stderr,"could not identify current boot session\n");return 1;}
        printf("{\"pid\":%d,\"birth_sec\":%" PRIu64 ",\"birth_usec\":%" PRIu64 ",\"uid\":%u,\"boot_uuid\":\"%s\"}\n",
            pid,(uint64_t)info.pbi_start_tvsec,(uint64_t)info.pbi_start_tvusec,info.pbi_uid,bootUUID);
        return 0;
    }
    if(argc<7 || strcmp(argv[1],"--inject-dock") || strcmp(argv[4],"--nonce-file"))return usage();
    const char *runtime=argv[3],*nonceFile=argv[5];
    int option=6;
    BOOL desktop=NO,pinned=NO;uint64_t onlyPID=0,expectedPID=0,expectedSec=0,expectedUsec=0;
    const char *recoveryJournalPath=NULL;uint64_t retiredPID=0,retiredSec=0,retiredUsec=0;
    if(option<argc && !strcmp(argv[option],"--desktop")) {
        desktop=YES;option++;
    } else if(option+1<argc && !strcmp(argv[option],"--only-pid")) {
        if(!parse_decimal(argv[option+1],INT_MAX,&onlyPID) || onlyPID<=1)return usage();
        option+=2;
    } else return usage();
    if(desktop && option<argc && !strcmp(argv[option],"--expected-dock")) {
        if(option+4>argc || !parse_decimal(argv[option+1],INT_MAX,&expectedPID) || expectedPID<=1
            || !parse_decimal(argv[option+2],UINT64_MAX,&expectedSec) || !expectedSec
            || !parse_decimal(argv[option+3],999999,&expectedUsec))return usage();
        pinned=YES;option+=4;
    }
    if(desktop && option<argc && !strcmp(argv[option],"--recover-journal")) {
        if(option+6!=argc || !pinned || !argv[option+1][0] || argv[option+1][0]!='/'
            || strcmp(argv[option+2],"--expected-retired-dock")
            || !parse_decimal(argv[option+3],INT_MAX,&retiredPID) || retiredPID<=1
            || !parse_decimal(argv[option+4],UINT64_MAX,&retiredSec) || !retiredSec
            || !parse_decimal(argv[option+5],999999,&retiredUsec))return usage();
        recoveryJournalPath=argv[option+1];option+=6;
    }
    if(option!=argc)return usage();
    uint32_t sip;int preview;
    if(dw_preflight(&sip,&preview)!=0){fprintf(stderr,"injection unavailable: current SIP/arm64e boot policy fails preflight\n");return 3;}
    payload_path=argv[2];
    if(payload_path[0]!='/' || strlen(payload_path)>=sizeof(shell_code)-168 || runtime[0]!='/')return usage();
    pid_t pid=get_dock_pid();
    struct proc_bsdinfo dockInfo={0};
    if(!process_info(pid,&dockInfo) || !current_dock(pid,&dockInfo)){fprintf(stderr,"could not locate stable Dock identity\n");return 1;}
    if(pinned && (pid!=(pid_t)expectedPID || dockInfo.pbi_start_tvsec!=expectedSec || dockInfo.pbi_start_tvusec!=expectedUsec)) {
        fprintf(stderr,"Dock no longer matches the launch record; refusing load\n");return 1;
    }
    // The IPC peer must be the login user. A root invoker drops effective UID only
    // for readiness probing; no user other than root or this login UID may load.
    if(getuid()!=0 && getuid()!=dockInfo.pbi_uid)return 1;
    struct stat st;
    if(lstat(payload_path,&st)||!S_ISREG(st.st_mode)||st.st_uid!=dockInfo.pbi_uid||(st.st_mode&0022)){fprintf(stderr,"payload ownership/mode invalid\n");return 1;}
    if(lstat(runtime,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=dockInfo.pbi_uid||(st.st_mode&07777)!=0700){fprintf(stderr,"create a fresh 0700 runtime directory as Dock login user first\n");return 1;}
    char nonce[65];
    if(!read_nonce_file(nonceFile,dockInfo.pbi_uid,nonce)){fprintf(stderr,"nonce file must be a login-user-owned regular 0600 file containing 64 lowercase hex bytes and optional newline\n");return 1;}
    // Resolve --only-pid into a single {pid,birth} allowlist entry. The
    // start time is read the same way the payload resolves window identity, so the
    // helper can pin itself to exactly that process and refuse every other window.
    NSArray *allowlist=nil;struct dw2_process only={0};
    if(!desktop) {
        if((pid_t)onlyPID==pid){fprintf(stderr,"--only-pid must not be Dock itself\n");return 1;}
        struct proc_bsdinfo onlyInfo={0};
        if(!process_info((pid_t)onlyPID,&onlyInfo)){fprintf(stderr,"could not resolve --only-pid process\n");return 1;}
        if(onlyInfo.pbi_uid!=dockInfo.pbi_uid){fprintf(stderr,"--only-pid must be owned by Dock's login user\n");return 1;}
        only=(struct dw2_process){.pid=(pid_t)onlyPID,.birth_sec=onlyInfo.pbi_start_tvsec,.birth_usec=onlyInfo.pbi_start_tvusec};
        allowlist=@[@{@"pid":@(only.pid),@"birth_sec":@(only.birth_sec),@"birth_usec":@(only.birth_usec)}];
    }
    NSData *recoveryBytes=nil;NSDictionary *recoveryFields=nil;
    if(recoveryJournalPath && !recovery_journal(recoveryJournalPath,runtime,&dockInfo,(pid_t)retiredPID,retiredSec,retiredUsec,&recoveryBytes,&recoveryFields)) {
        fprintf(stderr,"recovery journal is not a committed same-boot schema-3 record for a positively retired same-user Dock; refusing recovery\n");return 1;
    }
    char socketPath[sizeof(((struct sockaddr_un *)0)->sun_path)];
    if(snprintf(socketPath,sizeof(socketPath),"%s/" DW2_SOCKET,runtime)>=(int)sizeof(socketPath)){fprintf(stderr,"Unix socket path exceeds 103 bytes\n");return 1;}
    NSString *runtimeString=[NSString stringWithUTF8String:runtime],*payloadString=[NSString stringWithUTF8String:payload_path];
    if(!runtimeString || !payloadString)return usage();
    for(NSString *name in @[@"helper.sock",@DW2_SOCKET,@"recovery.json",@"recovery.next",@"v2-journal.json",@"v2-journal.next",@"recovery-source.json"]) {
        NSString *path=[runtimeString stringByAppendingPathComponent:name];
        if(lstat(path.fileSystemRepresentation,&st)==0 || errno!=ENOENT){fprintf(stderr,"runtime socket/journal exists or cannot be checked; refusing ambiguous retry\n");return 1;}
    }
    if(recoveryBytes) {
        int runtimeFD=open(runtime,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        if(runtimeFD<0){fprintf(stderr,"could not open fresh runtime for recovery source\n");return 1;}
        struct stat runtimeStat={0};
        BOOL staged=fstat(runtimeFD,&runtimeStat)==0 && S_ISDIR(runtimeStat.st_mode)
            && runtimeStat.st_uid==dockInfo.pbi_uid && (runtimeStat.st_mode&07777)==0700;
        int sourceFD=staged ? openat(runtimeFD,"recovery-source.json",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600) : -1;
        if(sourceFD<0)staged=NO;
        if(staged && geteuid()!=dockInfo.pbi_uid && fchown(sourceFD,dockInfo.pbi_uid,dockInfo.pbi_gid))staged=NO;
        struct stat sourceStat={0};
        if(staged)staged=fstat(sourceFD,&sourceStat)==0 && S_ISREG(sourceStat.st_mode)
            && sourceStat.st_uid==dockInfo.pbi_uid && (sourceStat.st_mode&07777)==0600;
        if(staged)staged=write_all_fd(sourceFD,recoveryBytes.bytes,recoveryBytes.length) && fsync(sourceFD)==0;
        if(sourceFD>=0 && close(sourceFD))staged=NO;
        if(staged)staged=fsync(runtimeFD)==0;
        close(runtimeFD);
        if(!staged){fprintf(stderr,"could not stage the validated recovery journal bytes\n");return 1;}
    }
    if(!current_dock(pid,&dockInfo)){fprintf(stderr,"Dock identity changed before sidecar creation\n");return 1;}
    NSString *configPath=[payloadString stringByAppendingString:@".json"];
    NSMutableDictionary *sidecar=[@{@"runtime":runtimeString,@"nonce":[NSString stringWithUTF8String:nonce]} mutableCopy];
    if(allowlist)sidecar[@"allowlist"]=allowlist;
    if(recoveryFields)[sidecar addEntriesFromDictionary:recoveryFields];
    NSData *configuration=[NSJSONSerialization dataWithJSONObject:sidecar options:0 error:NULL];
    int configFD=open(configPath.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(configFD<0){perror("create new payload sidecar");return 1;}
    BOOL configOK=(geteuid()==dockInfo.pbi_uid || fchown(configFD,dockInfo.pbi_uid,dockInfo.pbi_gid)==0) && write(configFD,configuration.bytes,configuration.length)==(ssize_t)configuration.length && fsync(configFD)==0;
    close(configFD);if(!configOK){unlink(configPath.fileSystemRepresentation);return 1;}

    int result=1;BOOL executed=NO,bootstrap=NO;
    mach_port_t task=MACH_PORT_NULL;thread_act_t thread=MACH_PORT_NULL;
    mach_vm_address_t code=0,stack=0;vm_size_t stack_size=16*1024;
    uint64_t stack_contents=0xCAFEBABE;
    if(!current_dock(pid,&dockInfo)){fprintf(stderr,"Dock identity changed before task access\n");goto cleanup;}
    kern_return_t error=task_for_pid(mach_task_self(),pid,&task);
    if(error!=KERN_SUCCESS){fprintf(stderr,"task_for_pid failed: %s\n",mach_error_string(error));goto cleanup;}
    if(!current_dock(pid,&dockInfo)){fprintf(stderr,"Dock identity changed during task access\n");goto cleanup;}
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
    if(!current_dock(pid,&dockInfo)){fprintf(stderr,"Dock identity changed before remote execution\n");goto cleanup;}
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
            BOOL ready=wait_for_helper(runtime,nonce,pid,&dockInfo,desktop ? NULL : &only,recoveryBytes!=nil);
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
    if(result==0)fprintf(stderr,"authenticated v2 helper ready in Dock (%s); empty window table, no frames submitted\n",desktop ? "same-user desktop scope" : "one-process scope");
    else fprintf(stderr,"helper readiness not established%s\n",executed ? "; execution began, retain sidecar/runtime and do not retry blindly" : "; pre-execution resources and sidecar cleaned up");
    return result;
} }
