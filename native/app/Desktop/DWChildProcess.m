// SPDX-License-Identifier: GPL-3.0-or-later
// The open-file limit at launch and the exec effect's child process.
#import "DWChildProcess.h"
#import <signal.h>
#include <spawn.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <fcntl.h>
#import "DWTypedValue.h"
// v0.21.0's raise_nofile_limit and prepare_child (https://github.com/malbiruk/driftwm,
// commit df3de27b26c7998e8a460cffd8a4925cbed3a322, src/state/mod.rs): every client connection of the IPC server holds a descriptor and macOS
// starts a process with a soft limit of 256, so the soft limit goes up to what the system allows (kern.maxfilesperproc;
// its hard limit is unlimited). The limit the app started with is kept, and a command it starts gets it back, since
// some programs still select() on descriptors below 1024. posix_spawn has no hook between fork and exec, so sh restores
// it first. A relaunch (execv) carries the original in INFINIFY_ORIGINAL_NOFILE, which no command inherits.
static rlim_t originalOpenFiles=0;
void raiseOpenFileLimit(void) {
    struct rlimit limit;if(getrlimit(RLIMIT_NOFILE,&limit))return;
    const char *carried=getenv("INFINIFY_ORIGINAL_NOFILE");if(carried&&strtoull(carried,NULL,10)){originalOpenFiles=(rlim_t)strtoull(carried,NULL,10);return;}
    int perProcess=0;size_t size=sizeof(perProcess);rlim_t ceiling=limit.rlim_max;
    if(!sysctlbyname("kern.maxfilesperproc",&perProcess,&size,NULL,0)&&perProcess>0&&(ceiling==RLIM_INFINITY||(rlim_t)perProcess<ceiling))ceiling=(rlim_t)perProcess;
    if(ceiling==RLIM_INFINITY||ceiling<=limit.rlim_cur)return;
    rlim_t original=limit.rlim_cur;limit.rlim_cur=ceiling;
    if(setrlimit(RLIMIT_NOFILE,&limit)){fprintf(stderr,"Infinify: setrlimit(NOFILE): %s\n",strerror(errno));return;}
    originalOpenFiles=original;char text[24];snprintf(text,sizeof(text),"%llu",(unsigned long long)original);setenv("INFINIFY_ORIGINAL_NOFILE",text,1);
}
// The exec effect, as upstream's exec_command: /bin/sh -c in a session of its own on
// /dev/null, with no other descriptor inherited and never waited on by the main loop.
// env overlays this process's environment; a null value removes the variable.
// The config path and log filter this process was started with are not passed on (v0.21.0: "Spawned
// apps no longer inherit ... the DRIFTWM_CONFIG and RUST_LOG it was started with"), nor are the INFINIFY_ debug
// and test switches; what the caller's env adds is applied after, so an [env] entry or INFINIFY_SOCKET still arrives.
// `missing` runs on the main queue when sh exits as it does for a program it
// cannot find (127) or cannot execute (126).
NSString *execCommand(NSString *command,NSDictionary *env,void (^missing)(void)) {
    NSMutableDictionary<NSString *,NSString *> *environment=[NSProcessInfo.processInfo.environment mutableCopy];
    for(NSString *name in environment.allKeys)if([name isEqual:@"DRIFTWM_CONFIG"]||[name isEqual:@"RUST_LOG"]||[name hasPrefix:@"INFINIFY_"])[environment removeObjectForKey:name];
    for(NSString *name in env){if(DWTyped(env[name],NSString.class))environment[name]=env[name];else [environment removeObjectForKey:name];}
    NSMutableData *pointers=[NSMutableData data];const char *end=NULL;
    for(NSString *name in environment){const char *entry=[NSString stringWithFormat:@"%@=%@",name,environment[name]].UTF8String;if(entry)[pointers appendBytes:&entry length:sizeof(entry)];}
    [pointers appendBytes:&end length:sizeof(end)];
    char original[24];snprintf(original,sizeof(original),"%llu",(unsigned long long)originalOpenFiles);
    char *const direct[]={"sh","-c",(char *)command.UTF8String,NULL};
    char *const restoring[]={"sh","-c","ulimit -Sn \"$0\" 2>/dev/null; exec sh -c \"$1\"",original,(char *)command.UTF8String,NULL};
    char *const *arguments=originalOpenFiles?restoring:direct;
    posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
    for(int descriptor=0;descriptor<3;descriptor++)posix_spawn_file_actions_addopen(&actions,descriptor,"/dev/null",descriptor?O_WRONLY:O_RDONLY,0);
    posix_spawnattr_t attributes;posix_spawnattr_init(&attributes);sigset_t none,all;sigemptyset(&none);sigfillset(&all);
    posix_spawnattr_setsigmask(&attributes,&none);posix_spawnattr_setsigdefault(&attributes,&all);
    posix_spawnattr_setflags(&attributes,POSIX_SPAWN_SETSID|POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF);
    pid_t pid=0;int error=posix_spawn(&pid,"/bin/sh",&actions,&attributes,arguments,(char *const *)pointers.bytes);
    posix_spawn_file_actions_destroy(&actions);posix_spawnattr_destroy(&attributes);
    if(error)return [NSString stringWithFormat:@"exec failed: %s",strerror(error)];
    // Reaped off the main queue whenever it exits.
    dispatch_source_t exited=dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,(uintptr_t)pid,DISPATCH_PROC_EXIT,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_event_handler(exited,^{int status=0;pid_t reaped=waitpid(pid,&status,0);dispatch_source_cancel(exited);if(missing&&reaped==pid&&WIFEXITED(status)&&(WEXITSTATUS(status)==127||WEXITSTATUS(status)==126))dispatch_async(dispatch_get_main_queue(),missing);});
    dispatch_resume(exited);return nil;
}
