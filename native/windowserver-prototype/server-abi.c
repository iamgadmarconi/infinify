// SPDX-License-Identifier: GPL-3.0-or-later
// New adapter derived from read-only disassembly of Apple's installed SkyLight.
// No Apple implementation bytes or third-party implementation are copied here.
// Exact image/routine pins and ABI rationale: SERVER-ABI.md.
#include "prototype.h"
#include <CoreGraphics/CoreGraphics.h>
#include <QuartzCore/CATransform3D.h>
#include <CommonCrypto/CommonDigest.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <libproc.h>
#include <mach-o/loader.h>
#include <ptrauth.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>

typedef void (*session_dispatch_fn)(uint32_t, void (^)(void *));
typedef void *(*window_by_id_fn)(uint32_t);
typedef void *(*get_entry_fn)(void *, uint32_t);
typedef int (*transform_list_fn)(void *, const uint32_t *, uint32_t,
                                 const uint32_t *, uint32_t,
                                 const CGAffineTransform *, uint32_t);
typedef void (*set_raw_fn)(void *, void *, uint32_t, uint32_t, const CATransform3D *);
typedef int32_t (*window_integer_fn)(void *);
typedef CGRect (*window_rect_fn)(void *);

enum { PIN_DISPATCH, PIN_LOOKUP, PIN_ENTRY, PIN_LIST, PIN_PID, PIN_OWNER,
       PIN_SCREEN, PIN_BOUNDS, PIN_RAW_SET, PIN_COUNT };
struct pin { size_t offset, length; const char *sha256; };
static const struct pin pins[PIN_COUNT] = {
    {0x222098,204,"6d2c451a420b000c0707444d85d3ad433b96d83153a89787bda91afe36c3b0b9"},
    {0x3561c8,52,"07cda5c1082ebe13a48231ef02527c00c6fb1c9443e12b4175738b69c1cef7b9"},
    {0x134790,192,"72b2f6acfa9d8ecad54c11afd659ec692cf4fcb6658770e5e26bd7eb314b9547"},
    {0x135818,480,"c04710c7de2f7361bf1dd84e7c46ef187c2e8908da3013cd0300179a545d7254"},
    {0x36c318,220,"cca809ec630ae0673bb1e74cbb3f22da1a8a2c95f2fa5839175e54829f0dc11b"},
    {0x36c3f4,192,"1684a3aff059368d3e2171d641e89fdad8dcb96585d438309a405025d5a201af"},
    {0x369f7c,236,"63eb3bb6e74642733078099816ddb47a62f27f37b4af6754289aee582c8fb277"},
    {0x29b534,56,"6fdb9608bc10c71e0e12e85a3c6b5ec032a77f1c0d7fa5c7cb69edb32cf2d17e"},
    {0x1352a0,224,"72beecb830de9d5883ad1b6a1a9a3d64ce0a322a321d3c55adda157d4856eaf9"},
};
static const uint8_t pinned_uuid[16] = {
    0x8a,0x3b,0x34,0x8e,0x46,0x37,0x36,0x85,
    0x92,0xd0,0x6c,0xbc,0x2f,0x36,0xa2,0x34
};
static const char image_uuid[] = "8A3B348E-4637-3685-92D0-6CBC2F36A234";
static struct ifwsp_abi binding;
static pthread_once_t binding_once = PTHREAD_ONCE_INIT;
static session_dispatch_fn session_dispatch;
static window_by_id_fn window_by_id;
static get_entry_fn get_entry;
static transform_list_fn transform_list;
static set_raw_fn set_raw;
static window_integer_fn window_pid, window_owner;
static window_rect_fn window_screen, window_bounds;

static void *signed_function(const uint8_t *base, size_t offset) {
    return ptrauth_sign_unauthenticated((void *)(base + offset), ptrauth_key_function_pointer, 0);
}
static void bind_once(void) {
    binding = (struct ifwsp_abi){false,"SkyLight image unavailable",image_uuid};
    void *image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY|RTLD_LOCAL);
    if (!image) return;
    void *exported = dlsym(image,"SLXServer");
    Dl_info info = {0};
    if (!exported || !dladdr(exported,&info) || !info.dli_fbase) return;
    const uint8_t *base = info.dli_fbase;
    const struct mach_header_64 *header = (const struct mach_header_64 *)base;
    if (header->magic != MH_MAGIC_64 || header->sizeofcmds > 65536) {
        binding.reason = "SkyLight header invalid"; return;
    }
    const uint8_t *cursor = base + sizeof(*header), *end = cursor + header->sizeofcmds;
    bool uuid_matches = false;
    for (uint32_t i=0; i<header->ncmds && cursor+sizeof(struct load_command)<=end; ++i) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) || cursor+command->cmdsize>end) break;
        if (command->cmd==LC_UUID && command->cmdsize==sizeof(struct uuid_command))
            uuid_matches = !memcmp(((const struct uuid_command *)cursor)->uuid,pinned_uuid,16);
        cursor += command->cmdsize;
    }
    if (!uuid_matches) { binding.reason="SkyLight UUID is not the reviewed macOS 27.0.1/26A434 guest image"; return; }
    for (unsigned i=0; i<PIN_COUNT; ++i) {
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        char hex[CC_SHA256_DIGEST_LENGTH*2+1];
        CC_SHA256(base+pins[i].offset,(CC_LONG)pins[i].length,digest);
        static const char digits[]="0123456789abcdef";
        for (unsigned j=0;j<CC_SHA256_DIGEST_LENGTH;++j) {
            hex[j*2]=digits[digest[j]>>4]; hex[j*2+1]=digits[digest[j]&15];
        }
        hex[sizeof(hex)-1]=0;
        if (strcmp(hex,pins[i].sha256)) { binding.reason="reviewed server routine code hash mismatch"; return; }
    }
#define BIND(name,type,pin) name=(type)signed_function(base,pins[pin].offset)
    BIND(session_dispatch,session_dispatch_fn,PIN_DISPATCH);
    BIND(window_by_id,window_by_id_fn,PIN_LOOKUP);
    BIND(get_entry,get_entry_fn,PIN_ENTRY);
    BIND(transform_list,transform_list_fn,PIN_LIST);
    BIND(window_pid,window_integer_fn,PIN_PID);
    BIND(window_owner,window_integer_fn,PIN_OWNER);
    BIND(window_screen,window_rect_fn,PIN_SCREEN);
    BIND(window_bounds,window_rect_fn,PIN_BOUNDS);
    BIND(set_raw,set_raw_fn,PIN_RAW_SET);
#undef BIND
    binding.verified=true;
    binding.reason="reviewed server routines pinned; runtime fixture admission and native output remain to be checked";
}
struct ifwsp_abi ifwsp_bind_server_abi(void) {
    pthread_once(&binding_once,bind_once);
    return binding;
}

// These values exist only while a hoisted server operation is executing.
static _Thread_local const struct ifwsp_config *current_config;
struct original_entry { bool captured, present; uint32_t wid, flags; CATransform3D matrix; };
static struct original_entry originals[IFWSP_MAX_WINDOWS];
static const struct ifwsp_window *allowed_window(uint32_t wid, uint32_t *index) {
    if (!current_config || !pthread_main_np()) return NULL;
    for (uint32_t i=0;i<current_config->window_count && i<IFWSP_MAX_WINDOWS;++i)
        if (current_config->windows[i].identity.wid==wid) { if(index)*index=i; return &current_config->windows[i]; }
    return NULL;
}
static bool process_current(const struct ifwsp_config *config) {
    return config && config->server_pid==getpid() && config->fixture_pid>1
        && ifwsp_kernel_identity_current(config->fixture_pid,config->fixture_uid,&config->fixture_kernel_identity);
}
static bool finite_affine(const double m[6]) {
    for(unsigned i=0;i<6;++i) if(!isfinite(m[i]))return false;
    return isfinite(m[0]*m[3]-m[1]*m[2]) && fabs(m[0]*m[3]-m[1]*m[2])>1e-12;
}
static bool same_float_affine(const double a[6],const double b[6]) {
    for(unsigned i=0;i<6;++i) if((float)a[i]!=(float)b[i])return false;
    return true;
}
static void affine_values(CGAffineTransform a,double m[6]) {
    m[0]=a.a; m[1]=a.b; m[2]=a.c; m[3]=a.d; m[4]=a.tx; m[5]=a.ty;
}
static bool read_entry(void *window,CATransform3D *matrix,uint32_t *flags,bool *present) {
    const uint8_t *entry=get_entry(window,0);
    *present=entry!=NULL;
    if(!entry) { *matrix=CATransform3DIdentity; *flags=0; return true; }
    memcpy(flags,entry+4,sizeof(*flags));
    memcpy(matrix,entry+16,sizeof(*matrix));
    // 0x01000000 is the server's internal identity marker, hidden by its getter.
    return ((*flags&~0x01000000u)==0) && CATransform3DIsAffine(*matrix);
}
static bool reserved_entries_clear(void *window) {
    const uint32_t reserved[]={0x1ffffffe,0x1ffffffd};
    for(unsigned i=0;i<2;++i) {
        const uint8_t *entry=get_entry(window,reserved[i]);
        // The forward setter clears these reserved placements. Even a present
        // identity entry carries state we do not retain, so require absence.
        if(entry)return false;
    }
    return true;
}
static bool rect_values(CGRect rect,double out[4]) {
    out[0]=rect.origin.x; out[1]=rect.origin.y; out[2]=rect.size.width; out[3]=rect.size.height;
    for(unsigned i=0;i<4;++i)if(!isfinite(out[i]))return false;
    return out[2]>0&&out[3]>0;
}
bool ifwsp_server_inspect(uint32_t wid,int32_t *owner,int32_t *pid,
                          double m[6],double bounds[4],double screen[4]) {
    uint32_t index=0;
    const struct ifwsp_window *allowed=allowed_window(wid,&index);
    if(!binding.verified||!allowed||!owner||!pid||!m||!bounds||!screen||!process_current(current_config))return false;
    void *window=window_by_id(wid);
    if(!window)return false;
    *owner=window_owner(window); *pid=window_pid(window);
    if(*owner!=allowed->owner||*pid!=current_config->fixture_pid)return false;
    CATransform3D matrix; uint32_t flags; bool present;
    // An absent entry would need a separately reviewed removal API to restore
    // exact stack state. Do not admit it by substituting identity.
    if(!read_entry(window,&matrix,&flags,&present)||!present||!reserved_entries_clear(window))return false;
    affine_values(CATransform3DGetAffineTransform(matrix),m);
    if(!finite_affine(m)||!rect_values(window_bounds(window),bounds)||!rect_values(window_screen(window),screen))return false;
    struct original_entry *original=&originals[index];
    if(!original->captured) {
        if(!same_float_affine(m,allowed->original_transform))return false;
        *original=(struct original_entry){true,present,wid,flags,matrix};
    }
    return original->wid==wid;
}
bool ifwsp_server_transform_many(uint32_t count,const uint32_t *wids,const double (*transforms)[6]) {
    if(!binding.verified||!current_config||!count||count>IFWSP_MAX_WINDOWS||!wids||!transforms
       ||!pthread_main_np()||!process_current(current_config))return false;
    CGAffineTransform matrices[IFWSP_MAX_WINDOWS];
    for(uint32_t i=0;i<count;++i) {
        uint32_t index=0;
        const struct ifwsp_window *allowed=allowed_window(wids[i],&index);
        if(!allowed||!originals[index].captured||originals[index].wid!=wids[i]||!finite_affine(transforms[i]))return false;
        void *window=window_by_id(wids[i]);
        if(!window||window_pid(window)!=current_config->fixture_pid||window_owner(window)!=allowed->owner
           ||!reserved_entries_clear(window))return false;
        for(uint32_t j=0;j<i;++j)if(wids[j]==wids[i])return false;
        // The ordinary client narrows all six fields to float before the server.
        // Match that precision so the benchmark compares identical transforms.
        matrices[i]=CGAffineTransformMake((float)transforms[i][0],(float)transforms[i][1],
            (float)transforms[i][2],(float)transforms[i][3],(float)transforms[i][4],(float)transforms[i][5]);
    }
    // The reviewed server captures a fixed placement count of one, then clamps
    // every window's placement index to zero. Keep a complete zeroed array as
    // well; the matrix count remains the actual number of windows.
    const uint32_t placements[IFWSP_MAX_WINDOWS]={0};
    return transform_list(NULL,wids,count,placements,0,matrices,count)==0;
}
bool ifwsp_server_transform(uint32_t wid,const double m[6]) {
    uint32_t index=0;
    const struct ifwsp_window *allowed=allowed_window(wid,&index);
    if(!binding.verified||!allowed||!m||!finite_affine(m)||!process_current(current_config))return false;
    struct original_entry *original=&originals[index];
    void *window=window_by_id(wid);
    if(!window||!original->captured||original->wid!=wid||window_pid(window)!=current_config->fixture_pid
       ||window_owner(window)!=allowed->owner)return false;
    if(same_float_affine(m,allowed->original_transform)) {
        // Preserve the actual original 128-byte placement transform and flags,
        // rather than reconstructing them from a composed screen transform.
        set_raw(NULL,window,0,original->flags&~0x01000000u,&original->matrix);
        return true;
    }
    return ifwsp_server_transform_many(1,&wid,(const double (*)[6])m);
}
bool ifwsp_server_original_restored(uint32_t wid) {
    uint32_t index=0;
    const struct ifwsp_window *allowed=allowed_window(wid,&index);
    if(!binding.verified||!allowed||!process_current(current_config))return false;
    const struct original_entry *original=&originals[index];
    void *window=window_by_id(wid);
    if(!window||!original->captured||original->wid!=wid||window_pid(window)!=current_config->fixture_pid
       ||window_owner(window)!=allowed->owner)return false;
    CATransform3D matrix; uint32_t flags; bool present;
    return read_entry(window,&matrix,&flags,&present) && present==original->present
        && flags==original->flags && !memcmp(&matrix,&original->matrix,sizeof(matrix));
}

struct server_job {
    _Atomic unsigned refs,state;
    dispatch_semaphore_t done;
    const struct ifwsp_config *config;
    void (*operation)(void *);
    void *context;
    bool ran;
};
static void release_job(struct server_job *job) {
    if(atomic_fetch_sub_explicit(&job->refs,1,memory_order_acq_rel)==1) {
        dispatch_release(job->done); free(job);
    }
}
static bool server_call(const struct ifwsp_config *config,void (*operation)(void *),void *context,bool cancel_pending) {
    if(!ifwsp_bind_server_abi().verified||!operation||!config||pthread_main_np()
       ||!process_current(config)||config->window_count==0||config->window_count>IFWSP_MAX_WINDOWS)return false;
    struct server_job *job=calloc(1,sizeof(*job));
    if(!job)return false;
    atomic_init(&job->refs,2); atomic_init(&job->state,0);
    job->config=config; job->operation=operation; job->context=context;
    job->done=dispatch_semaphore_create(0);
    if(!job->done) { free(job); return false; }
    // ID 0 selects the server's default session. The callback is hoisted to its
    // main execution context with that session installed. All fixture lookups
    // remain inside the callback and fail if the fixture belongs elsewhere.
    session_dispatch(0,^(void *session) {
        unsigned pending=0;
        if(atomic_compare_exchange_strong(&job->state,&pending,1)) {
            if(session&&pthread_main_np()&&process_current(job->config)) {
                current_config=job->config;
                job->operation(job->context);
                current_config=NULL;
                job->ran=true;
            }
            atomic_store_explicit(&job->state,2,memory_order_release);
            dispatch_semaphore_signal(job->done);
        }
        release_job(job);
    });
    dispatch_time_t deadline=cancel_pending?dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC):DISPATCH_TIME_FOREVER;
    if(dispatch_semaphore_wait(job->done,deadline)) {
        unsigned pending=0;
        if(!atomic_compare_exchange_strong(&job->state,&pending,3)) {
            // A running server operation cannot be preempted. Keep borrowed
            // operation/context storage alive until it has completed.
            dispatch_semaphore_wait(job->done,DISPATCH_TIME_FOREVER);
        }
    }
    bool ran=job->ran;
    release_job(job);
    return ran;
}
bool ifwsp_server_call(const struct ifwsp_config *config,void (*operation)(void *),void *context) {
    return server_call(config,operation,context,true);
}
bool ifwsp_server_restore_call(const struct ifwsp_config *config,void (*operation)(void *),void *context) {
    // Once a frame may have applied, its queued final restoration cannot be
    // discarded because the server is temporarily busy. The socket worker owns
    // the borrowed context until the restore callback has actually completed.
    return server_call(config,operation,context,false);
}
