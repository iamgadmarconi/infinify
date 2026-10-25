// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef IFWSP_KERNEL_PROCESS_IDENTITY_H
#define IFWSP_KERNEL_PROCESS_IDENTITY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#include <libproc.h>

// Independently named ABI declarations; no Apple implementation is copied.
// Source: apple-oss-distributions/xnu at
// f6217f891ac0bb64f3d375211650a4c1ff8ca1ea:
// bsd/sys/proc_info_private.h:45-55,145-147
// SHA256 ccc01e88d5bf47bc9c3f5ba3a25c3e6202bbcd7b86aa967af31d714657571c3b
// bsd/kern/proc_info.c:1507-1516,2198-2205
// SHA256 557092f14fbad3341100f59e0391d2e812c54b79a7404c89b2af97471ad67082
// https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/proc_info_private.h
// https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/proc_info.c
// XNU exempts SHORTBSDINFO and UNIQIDENTIFIERINFO from the same-user check.
// This does not override a sandbox denial; any failed query refuses admission.
#define IFWSP_PROC_PIDUNIQIDENTIFIERINFO 17
struct ifwsp_proc_unique_identifier_info {
    uint8_t executable_uuid[16];
    uint64_t unique_id, parent_unique_id;
    int32_t pid_version, original_parent_pid_version;
    uint64_t reserved[2];
};
_Static_assert(sizeof(struct ifwsp_proc_unique_identifier_info)==56,"XNU unique-identifier ABI size");
_Static_assert(offsetof(struct ifwsp_proc_unique_identifier_info,unique_id)==16,"XNU unique ID offset");
_Static_assert(offsetof(struct ifwsp_proc_unique_identifier_info,pid_version)==32,"XNU PID version offset");
_Static_assert(PROC_PIDT_SHORTBSDINFO==13,"public short BSD query flavor");
_Static_assert(sizeof(struct proc_bsdshortinfo)==64,"public short BSD ABI size");
_Static_assert(offsetof(struct proc_bsdshortinfo,pbsi_uid)==36,"public short BSD UID offset");

// Captured by the root loader while its stronger manifest birth/hash/parent
// checks still hold, then treated as immutable in the WindowServer payload.
struct ifwsp_kernel_process_identity {
    int32_t pid;
    uint32_t uid;
    uint64_t unique_id;
    uint8_t executable_uuid[16];
    int32_t pid_version;
    uint32_t reserved;
};
_Static_assert(sizeof(struct ifwsp_kernel_process_identity)==40,"prototype kernel identity ABI size");

static inline bool ifwsp_unique_info_equal(const struct ifwsp_proc_unique_identifier_info *a,
                                          const struct ifwsp_proc_unique_identifier_info *b) {
    return a->unique_id==b->unique_id && a->pid_version==b->pid_version
        && !memcmp(a->executable_uuid,b->executable_uuid,sizeof(a->executable_uuid));
}

static inline bool ifwsp_capture_kernel_identity(pid_t pid,uid_t uid,
                                                struct ifwsp_kernel_process_identity *identity) {
    if(pid<=1||!identity)return false;
    struct ifwsp_proc_unique_identifier_info before={0},after={0};
    struct proc_bsdshortinfo short_info={0};
    // Bracket PID/UID with two complete kernel tokens, refusing process reuse
    // or exec during capture. Partial/denied queries never become a cached hint.
    if(proc_pidinfo(pid,IFWSP_PROC_PIDUNIQIDENTIFIERINFO,0,&before,sizeof(before))!=sizeof(before)
       ||proc_pidinfo(pid,PROC_PIDT_SHORTBSDINFO,0,&short_info,sizeof(short_info))!=sizeof(short_info)
       ||proc_pidinfo(pid,IFWSP_PROC_PIDUNIQIDENTIFIERINFO,0,&after,sizeof(after))!=sizeof(after)
       ||short_info.pbsi_pid!=(uint32_t)pid||short_info.pbsi_uid!=uid
       ||!before.unique_id||!ifwsp_unique_info_equal(&before,&after))return false;
    *identity=(struct ifwsp_kernel_process_identity){.pid=pid,.uid=uid,
        .unique_id=before.unique_id,.pid_version=before.pid_version};
    memcpy(identity->executable_uuid,before.executable_uuid,sizeof(identity->executable_uuid));
    return true;
}

static inline bool ifwsp_kernel_identity_current(pid_t pid,uid_t uid,
                                                const struct ifwsp_kernel_process_identity *expected) {
    if(!expected||expected->pid!=pid||expected->uid!=uid||!expected->unique_id||expected->reserved)return false;
    struct ifwsp_kernel_process_identity current={0};
    return ifwsp_capture_kernel_identity(pid,uid,&current)
        && current.unique_id==expected->unique_id && current.pid_version==expected->pid_version
        && !memcmp(current.executable_uuid,expected->executable_uuid,sizeof(current.executable_uuid));
}

#endif
