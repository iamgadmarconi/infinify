// Sunlight's live-window protocol (Sunbeam protocol v1), Sunlight's own code. Included by payload.m
// after the SkyLight declarations.
// No existing opcode or thumbnail-toggle semantics are changed.
#include <math.h>
#include <errno.h>
#include <sys/time.h>
#include <sys/un.h>     // LOCAL_PEERPID

#define SUNBEAM_CAPABILITY 0x70
#define SUNBEAM_SESSION    0x71
#define SUNBEAM_FRAME      0x72
#define SUNBEAM_HANDOFF    0x73
#define SUNBEAM_SHADOW     0x74
#define SUNBEAM_LIMIT      128
#define SUNBEAM_MAGIC      "SUNBEAM1\n"
// A frame's flags byte (since sunlight-8; a frame without one is taken the old way). Full: level and
// stacking are asserted for every window in it, and a leased window absent from it is put back. Without
// it the frame is partial: only transforms, only for the windows in it, and the rest stay as they are.
#define SUNBEAM_FRAME_FULL 0x01

extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);
extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
extern CGError SLSDisableUpdate(int cid);
extern CGError SLSReenableUpdate(int cid);
// A window-server transaction lands every ordering and transform change in it at once, so no frame
// can show a half-done handoff. (The screen-update freeze above doesn't promise that: a recording
// caught the entered window missing for one frame, between its restore and its raise, on two
// entries in seven.) The prototypes are yabai's. Weak, so the add-on still loads where SkyLight
// lacks them; the calls then go one by one, in an order whose in-between states look like the
// state before or the state after.
#ifndef SUNBEAM_WEAK
#define SUNBEAM_WEAK __attribute__((weak_import))   // the test harness defines its own and leaves this empty
#endif
extern CFTypeRef SLSTransactionCreate(int cid) SUNBEAM_WEAK;
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous) SUNBEAM_WEAK;
extern CGError SLSTransactionOrderWindow(CFTypeRef transaction, uint32_t wid, int order, uint32_t rel_wid) SUNBEAM_WEAK;
extern CGError SLSTransactionSetWindowTransform(CFTypeRef transaction, uint32_t wid, int unknown, int unknown2, CGAffineTransform t) SUNBEAM_WEAK;
extern CGError SLSTransactionSetWindowLevel(CFTypeRef transaction, uint32_t wid, int level) SUNBEAM_WEAK;

// MARK: The canvas's level
//
// A window the user's app opens is ordered in at the front of its level, and the normal level (0) is
// where every app window lives. With the canvas at that level too, a new window was born on top of
// the canvas, full size, and stayed there until the canvas had listed it and a frame had scaled it:
// a frame or two at 1x, however fast the canvas reacted. So while the canvas presents live windows,
// it, its backdrop and the windows it has taken sit one level up (sunlight-11): a new window is born
// behind the backdrop, out of sight, and first shows once a frame has scaled it and lifted it in.
// The handoff and the release put everything back at the normal level, so an entered window's own new
// windows (sheets, documents) come up in front of it as they always did, and the desktop is stock
// whenever the canvas isn't up.
#define SUNBEAM_LEVEL 1

// MARK: Shadows
//
// macOS keeps two shadow looks per window, which AppKit sets once as the window is made
// (`SLSTransactionSetWindowShadowProperties`: for a titled window radius 8, density 0.22, offset 7 when
// inactive; 20, 0.4, 18 when key), and the window server switches between them as the window becomes
// or stops being key (`SLSTransactionSetWindowActiveShadowLegacy`, from AppKit), in one frame. At the
// seam, right after the entered window has stopped growing, that was the shadow blink. The canvas has
// the two looks rewritten instead: the inactive one eased towards the active over the flight in, so the
// switch as the window becomes key changes nothing, and the active one eased back towards the inactive
// before the canvas takes the screen back, so the switch the other way changes nothing either; then
// the window's standard looks again, which is invisible, the other look being the one shown.
// The prototypes are yabai's and the CGS one with the SLS prefix; weak, as the transaction calls are.
extern CGError SLSWindowSetShadowProperties(uint32_t wid, CFDictionaryRef properties) SUNBEAM_WEAK;
extern CGError SLSGetWindowShadowAndRimParameters(int cid, uint32_t wid, float *deviation, float *density, int *offset_x, int *offset_y, unsigned int *flags) SUNBEAM_WEAK;
#define SUNBEAM_SHADOWS 16

/// A shadow look as AppKit's dictionary has it: the blur radius and vertical offset (whole points),
/// the shadow's density and the rim's.
struct sunbeam_look { float radius, density, rim_density, offset; };

/// A window whose looks the canvas has rewritten: the standard pair the request carried, to go back to,
/// and whether something else is in force. Kept across leases: a window is leased for the flight in,
/// but not when the canvas comes back for it.
struct sunbeam_shadow {
    uint32_t wid;
    int owner;
    struct sunbeam_look inactive, active;
    bool altered;
};
static struct sunbeam_shadow sunbeam_shadows[SUNBEAM_SHADOWS];
static int sunbeam_shadow_next;

struct sunbeam_saved {
    uint32_t wid;
    int owner, level;
    uint32_t below;
    CGAffineTransform transform;
    // What this session last set, so a frame that repeats it costs nothing (`sunbeam_frame`).
    CGAffineTransform applied;
    bool has_applied;
};
// For a frame without a flags byte (an app older than sunlight-8): level and stacking are asserted for
// every window when the order changes and at most this often otherwise. A frame with flags says itself
// whether it is full; the canvas sends one when its window set or order changes, when the window
// server's listing shows an order it didn't ask for, and once the camera has been still for a second.
#define SUNBEAM_REASSERT_SECONDS 1.0
struct sunbeam_session_state {
    uint32_t order[SUNBEAM_LIMIT];
    int order_count;
    uint32_t backdrop, overlay;
    double asserted_at;
};

static double sunbeam_now(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}
struct sunbeam_record { uint32_t wid; float matrix[6]; };
// Every request, from whichever lease, is applied under this lock, one at a time; it also guards the
// count below. `sunbeam_status` identifies the failed stage in an acknowledgment.
static pthread_mutex_t sunbeam_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t sunbeam_status = 1;

// A lease per canvas (sunlight-13): the app has a canvas on every display, each with its own windows,
// backdrop and overlay, and each holds a lease of its own. Up to this many at once, all from one
// process (the first lease's): another app, or another copy of Sunlight, is turned away while they last,
// as a second lease was before.
#define SUNBEAM_SESSIONS 8
static int sunbeam_sessions;
static pid_t sunbeam_sessions_pid;

static bool sunbeam_read(int fd, void *bytes, size_t length)
{
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = recv(fd, (char *)bytes + offset, length - offset, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        offset += count;
    }
    return true;
}

static bool sunbeam_owner_matches(struct sunbeam_saved *saved)
{
    if (!saved->wid) return false;
    int owner = 0;
    return SLSGetWindowOwner(SLSMainConnectionID(), saved->wid, &owner) == kCGErrorSuccess && owner == saved->owner;
}

/// The window server's listing; the test harness supplies its own.
#ifndef sunbeam_window_list
#define sunbeam_window_list CGWindowListCopyWindowInfo
#endif

/// Whether a window is on screen on the current Space; `level` gets its window level if so. A
/// minimized window is not (the Dock holds it), nor a hidden app's, nor one on another Space.
static bool sunbeam_on_screen(uint32_t wid, int *level)
{
    if (!wid) return false;
    bool result = false;
    CFArrayRef list = sunbeam_window_list(kCGWindowListOptionIncludingWindow, wid);
    if (list && CFArrayGetCount(list)) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(list, 0);
        CFBooleanRef on_screen = CFDictionaryGetValue(entry, kCGWindowIsOnscreen);
        result = on_screen && CFBooleanGetValue(on_screen);
        CFNumberRef layer = CFDictionaryGetValue(entry, kCGWindowLayer);
        if (result && level && layer) CFNumberGetValue(layer, kCFNumberIntType, level);
    }
    if (list) CFRelease(list);
    return result;
}

// MARK: Transactions

/// A transaction when SkyLight has them, else NULL: the ordering and transform calls below then go
/// to the window server one by one.
static CFTypeRef sunbeam_transaction_begin(int cid)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"   // real checks in the add-on, where the symbols are weak
    if (!SLSTransactionCreate || !SLSTransactionCommit || !SLSTransactionOrderWindow || !SLSTransactionSetWindowTransform) return NULL;
#pragma clang diagnostic pop
    return SLSTransactionCreate(cid);
}

/// Commits and releases; false if the window server refused the commit, in which case nothing in
/// it landed and the caller does the same steps without one.
static bool sunbeam_transaction_end(CFTypeRef transaction)
{
    if (!transaction) return true;
    bool ok = SLSTransactionCommit(transaction, 0) == kCGErrorSuccess;
    CFRelease(transaction);
    return ok;
}

static CGError sunbeam_order(CFTypeRef transaction, int cid, uint32_t wid, int order, uint32_t rel_wid)
{
    return transaction ? SLSTransactionOrderWindow(transaction, wid, order, rel_wid) : SLSOrderWindow(cid, wid, order, rel_wid);
}

static CGError sunbeam_transform(CFTypeRef transaction, int cid, uint32_t wid, CGAffineTransform t)
{
    return transaction ? SLSTransactionSetWindowTransform(transaction, wid, 0, 0, t) : SLSSetWindowTransform(cid, wid, t);
}

/// The window's level, in the transaction when there is one and SkyLight can; a window already at the
/// level is left alone (a level set puts the window at the front of that level, even its own). Ordering
/// relative to a window at another level does nothing, so a level change comes before any order that
/// depends on it. `changed` is set when something was asked for.
static CGError sunbeam_level(CFTypeRef transaction, int cid, uint32_t wid, int level, bool *changed)
{
    int current = level;
    if (SLSGetWindowLevel(cid, wid, &current) == kCGErrorSuccess && current == level) return kCGErrorSuccess;
    if (changed) *changed = true;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"   // weak symbol: a real check in the add-on
    if (transaction && SLSTransactionSetWindowLevel) return SLSTransactionSetWindowLevel(transaction, wid, level);
#pragma clang diagnostic pop
    return SLSSetWindowLevel(cid, wid, level);
}

// MARK: Shadow requests

static bool sunbeam_shadow_available(void)
{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wpointer-bool-conversion"   // real checks in the add-on, where the symbols are weak
    return SLSWindowSetShadowProperties && SLSGetWindowShadowAndRimParameters;
#pragma clang diagnostic pop
}

static struct sunbeam_shadow *sunbeam_shadow_find(uint32_t wid, int owner)
{
    for (int i = 0; i < SUNBEAM_SHADOWS; ++i) {
        if (sunbeam_shadows[i].wid == wid && sunbeam_shadows[i].owner == owner) return &sunbeam_shadows[i];
    }
    return NULL;
}

static bool sunbeam_look_sane(struct sunbeam_look look)
{
    return isfinite(look.radius) && look.radius >= 0 && look.radius <= 200
        && isfinite(look.density) && look.density >= 0 && look.density <= 1
        && isfinite(look.rim_density) && look.rim_density >= 0 && look.rim_density <= 1
        && isfinite(look.offset) && fabsf(look.offset) <= 200;
}

static struct sunbeam_look sunbeam_look_mix(struct sunbeam_look from, struct sunbeam_look to, float weight)
{
    struct sunbeam_look mixed = {
        from.radius + (to.radius - from.radius) * weight,
        from.density + (to.density - from.density) * weight,
        from.rim_density + (to.rim_density - from.rim_density) * weight,
        from.offset + (to.offset - from.offset) * weight,
    };
    return mixed;
}

static void sunbeam_shadow_number(CFMutableDictionaryRef dict, const char *name, const char *suffix, bool whole, double value)
{
    char key[96];
    snprintf(key, sizeof(key), "com.apple.WindowShadow%s%s", name, suffix);
    CFStringRef string = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    int rounded = (int)lround(value);
    CFNumberRef number = whole ? CFNumberCreate(NULL, kCFNumberIntType, &rounded) : CFNumberCreate(NULL, kCFNumberDoubleType, &value);
    CFDictionarySetValue(dict, string, number);
    CFRelease(number);
    CFRelease(string);
}

/// One look's keys, with the rim as AppKit sets it for a titled window. `suffix` is "Active" or "Inactive".
static void sunbeam_shadow_slot(CFMutableDictionaryRef dict, const char *suffix, struct sunbeam_look look)
{
    sunbeam_shadow_number(dict, "Radius", suffix, true, look.radius);
    sunbeam_shadow_number(dict, "Density", suffix, false, look.density);
    sunbeam_shadow_number(dict, "VerticalOffset", suffix, true, look.offset);
    sunbeam_shadow_number(dict, "RimDensity", suffix, false, look.rim_density);
    sunbeam_shadow_number(dict, "RimRadius", suffix, true, 3);
    sunbeam_shadow_number(dict, "RimStyleHard", suffix, true, 0);
    sunbeam_shadow_number(dict, "RimStyleWhite", suffix, true, 0);
    sunbeam_shadow_number(dict, "InnerRimDensity", suffix, false, 0.1);
    sunbeam_shadow_number(dict, "InnerRimRadius", suffix, true, 2);
    sunbeam_shadow_number(dict, "InnerRimStyleWhite", suffix, true, 1);
}

/// Writes a window's two looks: the whole dictionary AppKit writes, as the window server may take a
/// partial one for the whole.
static CGError sunbeam_shadow_write(uint32_t wid, struct sunbeam_look inactive, struct sunbeam_look active)
{
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    sunbeam_shadow_slot(dict, "Inactive", inactive);
    sunbeam_shadow_slot(dict, "Active", active);
    sunbeam_shadow_number(dict, "ContentAware", "Active", true, 1);
    sunbeam_shadow_number(dict, "ContentAware", "Inctive", true, 1);   // AppKit's own spelling of the key
    CGError error = SLSWindowSetShadowProperties(wid, dict);
    CFRelease(dict);
    return error;
}

/// Whether a window has the standard looks the request describes, as far as the window server tells:
/// its shadow parameters as read (`SLSGetWindowShadowAndRimParameters` answers with the active look's
/// density and offset) fall between the two looks. A window with another kind of shadow — a panel's, none —
/// is left alone, rather than given a titled window's.
static bool sunbeam_shadow_standard(int cid, uint32_t wid, struct sunbeam_look inactive, struct sunbeam_look active)
{
    float deviation = 0, density = 0;
    int offset_x = 0, offset_y = 0;
    unsigned int flags = 0;
    if (SLSGetWindowShadowAndRimParameters(cid, wid, &deviation, &density, &offset_x, &offset_y, &flags) != kCGErrorSuccess) return false;
    float low = fminf(inactive.density, active.density) - 0.02f, high = fmaxf(inactive.density, active.density) + 0.02f;
    int near = (int)lroundf(fminf(inactive.offset, active.offset)) - 1, far = (int)lroundf(fmaxf(inactive.offset, active.offset)) + 1;
    return deviation > 0 && density >= low && density <= high && offset_y >= near && offset_y <= far;
}

/// The request (44 bytes after the opcode): the window; two weights, for the inactive look and the
/// active one; then the window's standard inactive and active looks (radius, density, rim density,
/// offset, as floats). Each look is set the given way from the standard inactive look to the standard
/// active one: 0 and 1 are the window's own; 1 and 1 both the active look, which the switch to it then
/// doesn't change; 0 and 0 both the inactive. Status 1 for a request that makes no sense, 8 when the
/// window is gone or the window server won't, 9 for a window whose shadow isn't the standard one.
static uint8_t sunbeam_shadow_set(const char *bytes)
{
    uint32_t wid;
    float weights[2], values[8];
    memcpy(&wid, bytes, 4); memcpy(weights, bytes + 4, 8); memcpy(values, bytes + 12, 32);
    struct sunbeam_look inactive = { values[0], values[1], values[2], values[3] };
    struct sunbeam_look active = { values[4], values[5], values[6], values[7] };
    for (int i = 0; i < 2; ++i) if (!isfinite(weights[i]) || weights[i] < 0 || weights[i] > 1) return 1;
    if (!wid || !sunbeam_look_sane(inactive) || !sunbeam_look_sane(active)) return 1;
    if (!sunbeam_shadow_available()) return 8;
    int cid = SLSMainConnectionID(), owner = 0;
    if (SLSGetWindowOwner(cid, wid, &owner) != kCGErrorSuccess) return 8;
    struct sunbeam_shadow *shadow = sunbeam_shadow_find(wid, owner);
    if (!shadow) {
        if (!sunbeam_shadow_standard(cid, wid, inactive, active)) return 9;
        for (int i = 0; i < SUNBEAM_SHADOWS && !shadow; ++i) if (!sunbeam_shadows[i].wid) shadow = &sunbeam_shadows[i];
        if (!shadow) {
            shadow = &sunbeam_shadows[sunbeam_shadow_next];
            sunbeam_shadow_next = (sunbeam_shadow_next + 1) % SUNBEAM_SHADOWS;
        }
        struct sunbeam_shadow seen = { .wid = wid, .owner = owner };
        *shadow = seen;
    }
    shadow->inactive = inactive;
    shadow->active = active;
    if (sunbeam_shadow_write(wid, sunbeam_look_mix(inactive, active, weights[0]),
                             sunbeam_look_mix(inactive, active, weights[1])) != kCGErrorSuccess) return 8;
    shadow->altered = weights[0] != 0 || weights[1] != 1;
    return 0;
}

/// A window put back under the canvas with other looks in force (a flight cut short) gets its standard
/// ones back, where that shows nothing. An entered window isn't put back, and keeps both looks active
/// until the canvas, with the window key, asks for its standard ones.
static void sunbeam_shadow_reset(uint32_t wid, int owner)
{
    struct sunbeam_shadow *shadow = sunbeam_shadow_find(wid, owner);
    if (!shadow || !shadow->altered || !sunbeam_shadow_available()) return;
    if (sunbeam_shadow_write(wid, shadow->inactive, shadow->active) == kCGErrorSuccess) shadow->altered = false;
}

// MARK: Release

/// Puts a window back as the add-on found it: its place in the stacking order, its transform, and
/// its level. The place is above the window that was under it when it was taken, as long as that
/// one is still on screen at the same level and is neither the canvas (a window taken from between
/// the backdrop and the canvas, the one just left, goes under the backdrop with the rest) nor one of
/// `skip`, the window being entered and the ones kept with it, which are above the canvas by now
/// (ordered next to one of them, a window would be on show too). Otherwise it goes under
/// `*anchor`: the backdrop, or the window put there just before, so a run of them keeps its order.
/// Ordering against a window that is gone, on another Space, at another level or the canvas itself
/// left the window on top of everything, in front of the one being entered.
///
/// The place comes before the transform: under the backdrop (or next to a window that is), the
/// jump back to native size shows nothing. Without a transaction the two are separate updates, and
/// a window that first jumped and then went under flashed full-size over the canvas.
///
/// Its own level comes first of all: a leased window sits at the canvas's level, its neighbours at
/// its own, and an order against a window at another level does nothing. Set directly (no transaction)
/// the window lands at the front of its level, which is under the backdrop as long as the backdrop is
/// still at the canvas's level — so, one by one, the windows go back before the canvas comes down.
///
/// A window that isn't on screen — minimized while it was leased (the canvas keeps it on show through
/// the Dock's animation and hands it back once it has gone), or its app hidden — gets its level and
/// transform back but no place in the order (sunlight-12): from the Dock's connection, ordering a
/// minimized window brings it back on screen behind its app's back, and the canvas saw it come back
/// half a second after every minimize. Its level and transform are kept by the Dock through the
/// minimize and the restore, so it comes back as a window of its own level, at native size.
///
/// `settle` false leaves the transform (and shadow) for `sunbeam_settle` after the commit (sunlight-14):
/// in a transaction that also changes levels the window server may take a window's level change after
/// its order, which lands it at the front of the normal level, over the canvas, for a frame before the
/// orders are put right. At the canvas's transform it shows there only where the canvas already drew
/// it (a window off to the side, nowhere); at native size it flashed full-size over the canvas, under
/// the window being entered, on quick ⌘Tab switches.
static void sunbeam_restore(CFTypeRef transaction, struct sunbeam_saved *saved, uint32_t backdrop, uint32_t overlay,
                            uint32_t *anchor, const uint32_t *skip, int skip_count, bool settle)
{
    if (!sunbeam_owner_matches(saved)) return; // a closed window ID must not target a different app
    int cid = SLSMainConnectionID();
    sunbeam_level(transaction, cid, saved->wid, saved->level, NULL);
    if (sunbeam_on_screen(saved->wid, NULL)) {
        int below_level = 0;
        bool skipped = false;
        for (int i = 0; i < skip_count; ++i) if (saved->below == skip[i]) skipped = true;
        if (saved->below && saved->below != backdrop && saved->below != overlay && !skipped
            && sunbeam_on_screen(saved->below, &below_level) && below_level == saved->level) {
            sunbeam_order(transaction, cid, saved->wid, 1, saved->below);
        } else if (anchor && *anchor && sunbeam_on_screen(*anchor, NULL)) {
            if (sunbeam_order(transaction, cid, saved->wid, -1, *anchor) == kCGErrorSuccess) *anchor = saved->wid;
        }
    }
    if (settle) {
        sunbeam_transform(transaction, cid, saved->wid, saved->transform);
        sunbeam_shadow_reset(saved->wid, saved->owner);
    }
}

/// The rest of `sunbeam_restore` for a window put back without its transform: directly, once its level
/// and place are final, so the jump to native size happens under the backdrop.
static void sunbeam_settle(struct sunbeam_saved *saved)
{
    if (!sunbeam_owner_matches(saved)) return;
    sunbeam_transform(NULL, SLSMainConnectionID(), saved->wid, saved->transform);
    sunbeam_shadow_reset(saved->wid, saved->owner);
}

/// Where a window goes back when released: the nearest window under it at its own level, skipping
/// the canvas's own windows. 0 when there is none; `sunbeam_restore` then uses the backdrop.
static uint32_t sunbeam_below(uint32_t wid, int level, uint32_t backdrop, uint32_t overlay)
{
    uint32_t result = 0;
    CFArrayRef list = sunbeam_window_list(kCGWindowListOptionOnScreenBelowWindow, wid);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list) && !result; ++i) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(list, i);
        CFNumberRef number = CFDictionaryGetValue(entry, kCGWindowNumber);
        CFNumberRef layer = CFDictionaryGetValue(entry, kCGWindowLayer);
        uint32_t candidate = 0;
        int candidate_level = 0;
        if (number) CFNumberGetValue(number, kCFNumberSInt32Type, &candidate);
        if (layer) CFNumberGetValue(layer, kCFNumberIntType, &candidate_level);
        if (candidate && candidate != backdrop && candidate != overlay && candidate_level == level) result = candidate;
    }
    if (list) CFRelease(list);
    return result;
}

/// The lowest window on screen at the normal level owned by `pid`, skipping the canvas's own and the
/// leased ones: where the canvas goes back under when an app took the front while it was up (the
/// app's windows were raised to the front of the level, and the canvas, coming down to it, would land
/// above them). 0 when there is none.
static uint32_t sunbeam_lowest_of(int pid, uint32_t backdrop, uint32_t overlay, const struct sunbeam_saved *saved, int count)
{
    uint32_t result = 0;
    if (!pid) return 0;
    CFArrayRef list = sunbeam_window_list(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); ++i) {
        CFDictionaryRef entry = CFArrayGetValueAtIndex(list, i);
        CFNumberRef number = CFDictionaryGetValue(entry, kCGWindowNumber);
        CFNumberRef layer = CFDictionaryGetValue(entry, kCGWindowLayer);
        CFNumberRef owner = CFDictionaryGetValue(entry, kCGWindowOwnerPID);
        uint32_t candidate = 0;
        int candidate_level = -1, candidate_pid = 0;
        if (number) CFNumberGetValue(number, kCFNumberSInt32Type, &candidate);
        if (layer) CFNumberGetValue(layer, kCFNumberIntType, &candidate_level);
        if (owner) CFNumberGetValue(owner, kCFNumberIntType, &candidate_pid);
        if (!candidate || candidate_pid != pid || candidate_level != 0 || candidate == backdrop || candidate == overlay) continue;
        bool leased = false;
        for (int j = 0; j < count; ++j) if (saved[j].wid == candidate) leased = true;
        if (!leased) result = candidate;   // the list is front to back: the last match is the lowest
    }
    if (list) CFRelease(list);
    return result;
}

/// The canvas's two windows down to the normal level, backdrop first (so it lands under the overlay,
/// each set putting the window at the front).
static void sunbeam_canvas_down(CFTypeRef transaction, int cid, uint32_t backdrop, uint32_t overlay, bool *changed)
{
    if (backdrop) sunbeam_level(transaction, cid, backdrop, 0, changed);
    if (overlay) sunbeam_level(transaction, cid, overlay, 0, changed);
}

/// With the canvas down at the normal level: if an app has the front (`above_pid`), the canvas goes
/// under that app's windows, where it would have been had it never been lifted.
static void sunbeam_canvas_tuck(CFTypeRef transaction, int cid, uint32_t backdrop, uint32_t overlay, int above_pid,
                                const struct sunbeam_saved *saved, int count)
{
    uint32_t lowest = backdrop && overlay ? sunbeam_lowest_of(above_pid, backdrop, overlay, saved, count) : 0;
    if (!lowest) return;
    sunbeam_order(transaction, cid, backdrop, -1, lowest);
    sunbeam_order(transaction, cid, overlay, 1, backdrop);
}

/// Every leased window back where it was, the backdrop first up under the canvas when both are
/// known, so they go back out of sight: a lease that ended with the canvas still up (a stall, a
/// bad frame) is replaced by a new one within moments, and the windows would otherwise sit
/// full-size over the canvas until then.
///
/// Then the canvas itself comes down to the normal level (sunlight-11). In a transaction the levels go
/// first, since an order against a window at another level does nothing, and everything lands at once.
/// One call at a time, the windows go back first: each lands at the front of the normal level, which is
/// under the backdrop only while the backdrop is still up at the canvas's. `above_pid`: the app that
/// has the front, if one took it (the canvas deactivating for it); the canvas goes under its windows.
static void sunbeam_release_all(struct sunbeam_saved *saved, int count, uint32_t backdrop, uint32_t overlay, int above_pid)
{
    int cid = SLSMainConnectionID();
    bool canvas = backdrop && overlay && backdrop != overlay;
    bool changed = false, transacted = false;
    for (int attempt = 0; attempt < 2; ++attempt) {
        CFTypeRef transaction = attempt == 0 ? sunbeam_transaction_begin(cid) : NULL;
        uint32_t anchor = backdrop;
        if (transaction && canvas) sunbeam_canvas_down(transaction, cid, backdrop, overlay, &changed);
        if (canvas) sunbeam_order(transaction, cid, backdrop, -1, overlay);
        for (int i = count - 1; i >= 0; --i) sunbeam_restore(transaction, &saved[i], backdrop, overlay, &anchor, NULL, 0, !transaction);
        if (!transaction && canvas) sunbeam_canvas_down(NULL, cid, backdrop, overlay, &changed);
        if (canvas) sunbeam_canvas_tuck(transaction, cid, backdrop, overlay, above_pid, saved, count);
        transacted = transaction != NULL;
        if (sunbeam_transaction_end(transaction)) break;
    }
    // A transaction's level changes and its orders should land together, in order. Should the window
    // server have taken the orders first (against windows then at another level, so for nothing), the
    // canvas is on top of the windows it put back: the same orders directly, now that every level is
    // final, cost nothing when the transaction was right and put it right a frame later when it wasn't.
    if (changed && canvas) {
        uint32_t anchor = backdrop;
        sunbeam_order(NULL, cid, backdrop, -1, overlay);
        for (int i = count - 1; i >= 0; --i) sunbeam_restore(NULL, &saved[i], backdrop, overlay, &anchor, NULL, 0, false);
        sunbeam_canvas_tuck(NULL, cid, backdrop, overlay, above_pid, saved, count);
    }
    // Back at native size only now, where they are out of sight (see `sunbeam_restore`).
    if (transacted) for (int i = count - 1; i >= 0; --i) sunbeam_settle(&saved[i]);
}

// MARK: Frames

// Lengths are checked before any field is decoded. Read into memcpy-packed fields, not C structs.
// Since sunlight-8 a frame may carry a flags byte after the count (`SUNBEAM_FRAME_FULL`); its length
// says whether it does. A partial frame changes transforms only, in one window-server transaction when
// SkyLight has them, so every window moves in the same screen update; a full frame asserts level and
// stacking too, under the Dock's update freeze, as every frame once did.
static bool sunbeam_frame(char *bytes, int length, struct sunbeam_saved *saved, int *saved_count,
                          struct sunbeam_session_state *state)
{
    sunbeam_status = 1;
    if (length < 10) return false;
    uint32_t backdrop, overlay;
    uint16_t count;
    memcpy(&backdrop, bytes, 4); memcpy(&overlay, bytes + 4, 4); memcpy(&count, bytes + 8, 2);
    if (count > SUNBEAM_LIMIT) return false;
    // An empty frame may carry, after its flags byte, the pid of the app that has the front (sunlight-11).
    bool has_above = count == 0 && length == 15;
    bool has_flags = has_above || length == 11 + count * 28;
    if (!has_flags && length != 10 + count * 28) return false;
    uint8_t flags = has_flags ? (uint8_t)bytes[10] : 0;
    int above_pid = 0;
    if (has_above) memcpy(&above_pid, bytes + 11, 4);
    int base = has_flags ? 11 : 10;
    if (count && (!backdrop || !overlay || backdrop == overlay)) return false;
    struct sunbeam_record records[SUNBEAM_LIMIT];
    for (int i = 0; i < count; ++i) {
        memcpy(&records[i].wid, bytes + base + i * 28, 4);
        memcpy(records[i].matrix, bytes + base + 4 + i * 28, 24);
        if (!records[i].wid || records[i].wid == backdrop || records[i].wid == overlay) return false;
        for (int j = 0; j < i; ++j) if (records[j].wid == records[i].wid) return false;
        float *m = records[i].matrix;
        for (int j = 0; j < 6; ++j) if (!isfinite(m[j])) return false;
        // This extension deliberately exposes only positive scale + translation, the canvas's needs.
        if (m[0] < 0.01f || m[0] > 100.0f || m[3] < 0.01f || m[3] > 100.0f || m[1] || m[2]) return false;
    }
    double now = sunbeam_now();
    bool full;
    if (has_flags) {
        // The canvas says. A partial frame on a session that knows nothing yet, or one naming a window
        // this session hasn't taken, is done in full for what it carries: the canvas sends a full frame
        // whenever its set changes, so that is a fresh lease, with nothing to put back.
        full = (flags & SUNBEAM_FRAME_FULL) || backdrop != state->backdrop || overlay != state->overlay;
        if (!full && count && state->order_count < 0) full = true;
        for (int i = 0; !full && i < count; ++i) {
            bool known = false;
            for (int j = 0; j < *saved_count; ++j) if (saved[j].wid == records[i].wid && saved[j].has_applied) known = true;
            full = !known;
        }
    } else {
        // A frame with the same windows in the same order, inside the interval, only moves transforms
        // that changed; anything else asserts everything, as every frame used to.
        full = count != state->order_count || backdrop != state->backdrop || overlay != state->overlay
            || now - state->asserted_at >= SUNBEAM_REASSERT_SECONDS || now < state->asserted_at;
        for (int i = 0; !full && i < count; ++i) full = records[i].wid != state->order[i];
        for (int i = 0; !full && i < count; ++i) {
            bool known = false;
            for (int j = 0; j < *saved_count; ++j) if (saved[j].wid == records[i].wid && saved[j].has_applied) known = true;
            full = !known;
        }
    }
    if (!full) {
        // Only transforms, only the ones that changed, all in one transaction when there is one.
        int changed[SUNBEAM_LIMIT], changed_count = 0;
        for (int i = 0; i < count; ++i) {
            for (int j = 0; j < *saved_count; ++j) {
                if (saved[j].wid != records[i].wid) continue;
                float *m = records[i].matrix;
                CGAffineTransform t = CGAffineTransformMake(m[0], m[1], m[2], m[3], m[4], m[5]);
                if (!CGAffineTransformEqualToTransform(t, saved[j].applied)) changed[changed_count++] = i;
            }
        }
        if (!changed_count) return true;   // nothing to do: no update freeze, no window-server calls
        // In a transaction first; one by one, under the update freeze, if the window server won't take
        // that. A transaction's transform call is not the verdict (the handoff's never was: SkyLight
        // answers it with a code that isn't success while the commit goes through all the same);
        // taking it for one rejected a frame or two of every flight and every return (sunlight-8),
        // and a rejected frame ends the lease, which puts every window back at full size for a
        // moment: a blink on every window change and zoom. Only the direct calls are checked.
        int cid = SLSMainConnectionID();
        for (int attempt = 0; attempt < 2; ++attempt) {
            CFTypeRef transaction = attempt == 0 ? sunbeam_transaction_begin(cid) : NULL;
            if (!transaction && attempt == 0) continue;
            if (!transaction) SLSDisableUpdate(cid);
            bool ok = true;
            for (int k = 0; ok && k < changed_count; ++k) {
                int i = changed[k], index = -1;
                for (int j = 0; j < *saved_count; ++j) if (saved[j].wid == records[i].wid) index = j;
                if (index < 0 || !sunbeam_owner_matches(&saved[index])) continue;
                float *m = records[i].matrix;
                CGAffineTransform t = CGAffineTransformMake(m[0], m[1], m[2], m[3], m[4], m[5]);
                CGError error = sunbeam_transform(transaction, cid, records[i].wid, t);
                if (!transaction && error != kCGErrorSuccess) { sunbeam_status = 3; ok = false; }
                else saved[index].applied = t;
            }
            if (!transaction) { SLSReenableUpdate(cid); return ok; }
            if (sunbeam_transaction_end(transaction)) return true;
            // The commit was refused: nothing in it landed; the same moves go one by one.
        }
        return true;
    }
    // An empty frame releases every window; with the canvas's IDs (since sunlight-3) it is the
    // canvas going dormant with its live look kept (deactivating, say). Then the backdrop goes
    // straight under the canvas first, and the windows are put back out of sight under it — a
    // released window that was first taken over the backdrop (one entered before) would otherwise
    // show through the canvas's live look, and any of them could flash full-size for a frame.
    if (!count && backdrop && overlay && backdrop != overlay) {
        sunbeam_release_all(saved, *saved_count, backdrop, overlay, above_pid);
        *saved_count = 0;
        state->order_count = 0;
        state->backdrop = backdrop;
        state->overlay = overlay;
        state->asserted_at = now;
        return true;
    }
    int cid = SLSMainConnectionID();
    bool ok = true;
    uint32_t anchor = backdrop;
    // Windows the frame leaves out go back first, while the backdrop is still up at the canvas's level
    // (a window set to its own level lands at the front of it: under the backdrop, out of sight).
    SLSDisableUpdate(cid);
    for (int i = *saved_count - 1; i >= 0; --i) {
        bool keep = false;
        for (int j = 0; j < count; ++j) if (records[j].wid == saved[i].wid) keep = true;
        if (!keep) {
            sunbeam_restore(NULL, &saved[i], backdrop, overlay, &anchor, NULL, 0, true);
            memmove(&saved[i], &saved[i + 1], (*saved_count - i - 1) * sizeof(*saved));
            --*saved_count;
        }
    }
    SLSReenableUpdate(cid);
    // What each window is to be: taken (saved) now, so a window that closed mid-frame is skipped. One
    // that has left the screen since the canvas listed it (minimized as the frame was made) is scaled
    // and lifted but given no place in the order (sunlight-12; see `sunbeam_restore`).
    bool take[SUNBEAM_LIMIT], place[SUNBEAM_LIMIT];
    for (int i = 0; i < count; ++i) {
        uint32_t wid = records[i].wid;
        int index = -1;
        for (int j = 0; j < *saved_count; ++j) if (saved[j].wid == wid) index = j;
        if (index < 0) {
            struct sunbeam_saved entry = { .wid = wid };
            if (SLSGetWindowOwner(cid, wid, &entry.owner) != kCGErrorSuccess) { take[i] = place[i] = false; continue; } // closed mid-frame
            if (SLSGetWindowTransform(cid, wid, &entry.transform) != kCGErrorSuccess ||
                SLSGetWindowLevel(cid, wid, &entry.level) != kCGErrorSuccess) { sunbeam_status = 2; ok = false; break; }
            entry.below = sunbeam_below(wid, entry.level, backdrop, overlay);
            index = (*saved_count)++;
            saved[index] = entry;
        }
        take[i] = sunbeam_owner_matches(&saved[index]);
        place[i] = take[i] && sunbeam_on_screen(wid, NULL);
    }
    if (!ok) {
        state->order_count = -1;
        state->backdrop = backdrop;
        state->overlay = overlay;
        state->asserted_at = now;
        return false;
    }
    // Everything at the canvas's level, in the canvas's order, the backdrop under and the overlay over:
    // in one transaction, levels first (an order against a window at another level does nothing), so a
    // frame that lifts the canvas (its first after a return) shows the before or the after and nothing
    // between. One call at a time under the update freeze when there is none, or the commit was refused:
    // each window scaled and then lifted (it lands at the front: a miniature over the canvas, where it is
    // about to be), the overlay lifted, the backdrop lifted (over everything for the moment, which the
    // freeze is to hide) and the order asserted from the backdrop up.
    bool changed = false;
    for (int attempt = 0; attempt < 2 && ok; ++attempt) {
        CFTypeRef transaction = attempt == 0 ? sunbeam_transaction_begin(cid) : NULL;
        if (!transaction && attempt == 0) continue;
        if (!transaction) SLSDisableUpdate(cid);
        if (transaction) {
            sunbeam_level(transaction, cid, backdrop, SUNBEAM_LEVEL, &changed);
            for (int i = 0; i < count; ++i) if (take[i]) sunbeam_level(transaction, cid, records[i].wid, SUNBEAM_LEVEL, &changed);
            sunbeam_level(transaction, cid, overlay, SUNBEAM_LEVEL, &changed);
        }
        uint32_t previous = backdrop;
        for (int i = 0; i < count && ok; ++i) {
            if (!take[i]) continue;
            uint32_t wid = records[i].wid;
            int index = -1;
            for (int j = 0; j < *saved_count; ++j) if (saved[j].wid == wid) index = j;
            if (index < 0) continue;
            float *m = records[i].matrix;
            CGAffineTransform t = CGAffineTransformMake(m[0], m[1], m[2], m[3], m[4], m[5]);
            if (sunbeam_transform(transaction, cid, wid, t) != kCGErrorSuccess && !transaction) { sunbeam_status = 3; ok = false; break; }
            saved[index].applied = t;
            saved[index].has_applied = true;
            if (!transaction && sunbeam_level(NULL, cid, wid, SUNBEAM_LEVEL, &changed) != kCGErrorSuccess) { sunbeam_status = 4; ok = false; break; }
            if (!place[i]) continue;
            if (transaction) sunbeam_order(transaction, cid, wid, 1, previous);
            previous = wid;
        }
        if (!transaction && ok) {
            if (count && sunbeam_level(NULL, cid, overlay, SUNBEAM_LEVEL, &changed) != kCGErrorSuccess) { sunbeam_status = 6; ok = false; }
            if (ok && count && sunbeam_level(NULL, cid, backdrop, SUNBEAM_LEVEL, &changed) != kCGErrorSuccess) { sunbeam_status = 6; ok = false; }
            previous = backdrop;
            for (int i = 0; i < count && ok; ++i) {
                if (!place[i]) continue;
                if (SLSOrderWindow(cid, records[i].wid, 1, previous) != kCGErrorSuccess) { sunbeam_status = 5; ok = false; break; }
                previous = records[i].wid;
            }
        }
        if (ok && count && sunbeam_order(transaction, cid, overlay, 1, previous) != kCGErrorSuccess && !transaction) { sunbeam_status = 6; ok = false; }
        if (!transaction) { SLSReenableUpdate(cid); break; }
        if (sunbeam_transaction_end(transaction)) break;
        // The commit was refused: nothing in it landed; the same goes one call at a time.
    }
    // Levels changed in a transaction: the orders once more, directly, in case the window server took
    // them before the levels (see `sunbeam_release_all`). A no-op when it didn't.
    if (ok && changed && count) {
        uint32_t previous = backdrop;
        for (int i = 0; i < count; ++i) {
            if (!place[i]) continue;
            SLSOrderWindow(cid, records[i].wid, 1, previous);
            previous = records[i].wid;
        }
        SLSOrderWindow(cid, overlay, 1, previous);
    }
    // Only a frame that went through asserts the order; a failed one is asserted in full next time.
    state->order_count = ok ? count : -1;
    for (int i = 0; ok && i < count; ++i) state->order[i] = records[i].wid;
    state->backdrop = backdrop;
    state->overlay = overlay;
    state->asserted_at = now;
    return ok;
}

// MARK: Handoff

/// A window kept on show through a handoff (sunlight-10): one the canvas had in view around the entered
/// one. It goes to its place natively, as the entered window does, and stays in front of the canvas,
/// just under the entered window, to be used as it is.
struct sunbeam_kept {
    int index;                    // in the lease's saved windows
    CGAffineTransform settled;
};

/// The visible part of a handoff, in an order whose in-between states look like the state before
/// or the state after, in case it isn't one transaction:
/// 1. the entered window above the canvas — it looks no different there, the canvas is almost clear;
/// 2. its settled transform, which draws it exactly where the camera left it (its native position
///    was moved just before, which the transform in force hid);
/// 3. the windows kept with it, top first, each under the one before, with their settled transforms:
///    each is drawn where it was, now in front of the canvas;
/// 4. the backdrop up under the canvas: the moment every other window leaves;
/// 5. the others put back, out of sight under the backdrop.
///
/// Since sunlight-11 the canvas and its windows sit a level up while the canvas is up, and a handoff
/// brings everything on show down to the normal level, where the entered window's own new windows come
/// up in front of it. In a transaction the levels go first, since an order against a window at another
/// level does nothing, and all of it lands at once. One call at a time (no transaction, or the commit
/// refused) the others go back first, while the backdrop is still up at the canvas's level, so each lands
/// out of sight under it; then the backdrop, the overlay, the kept windows and the entered one come down
/// in that order, each landing at the front of the normal level — which is the order wanted — and the
/// orders are asserted once more for good measure.
///
/// `overlay` is the handoff's own (0 for the 13-byte form, which raises nothing); `canvas_overlay` and
/// `backdrop` are the canvas's windows as the session knows them, which come down either way.
static void sunbeam_handoff_apply(CFTypeRef transaction, uint32_t wid, int wid_level, CGAffineTransform settled, uint32_t overlay,
                                  uint32_t canvas_overlay, uint32_t backdrop, struct sunbeam_saved *saved, int count, int entered,
                                  const struct sunbeam_kept *kept, int kept_count, uint32_t anchor, bool *changed)
{
    int cid = SLSMainConnectionID();
    uint32_t skip[SUNBEAM_LIMIT + 1] = { wid };
    for (int k = 0; k < kept_count; ++k) skip[k + 1] = saved[kept[k].index].wid;
    if (transaction) {
        if (backdrop) sunbeam_level(transaction, cid, backdrop, 0, changed);
        if (canvas_overlay) sunbeam_level(transaction, cid, canvas_overlay, 0, changed);
        for (int k = 0; k < kept_count; ++k) sunbeam_level(transaction, cid, saved[kept[k].index].wid, saved[kept[k].index].level, changed);
        sunbeam_level(transaction, cid, wid, wid_level, changed);
    } else {
        for (int i = count - 1; i >= 0; --i) {
            bool on_show = i == entered;
            for (int k = 0; k < kept_count; ++k) if (kept[k].index == i) on_show = true;
            if (!on_show) sunbeam_restore(NULL, &saved[i], backdrop, overlay, &anchor, skip, kept_count + 1, true);
        }
        sunbeam_transform(NULL, cid, wid, settled);
        for (int k = 0; k < kept_count; ++k) sunbeam_transform(NULL, cid, saved[kept[k].index].wid, kept[k].settled);
        if (backdrop) sunbeam_level(NULL, cid, backdrop, 0, changed);
        if (canvas_overlay) sunbeam_level(NULL, cid, canvas_overlay, 0, changed);
        for (int k = 0; k < kept_count; ++k) sunbeam_level(NULL, cid, saved[kept[k].index].wid, saved[kept[k].index].level, changed);
        sunbeam_level(NULL, cid, wid, wid_level, changed);
    }
    if (overlay) sunbeam_order(transaction, cid, wid, 1, overlay);
    if (transaction) sunbeam_transform(transaction, cid, wid, settled);
    uint32_t above = wid;
    for (int k = kept_count - 1; k >= 0; --k) {
        uint32_t kid = saved[kept[k].index].wid;
        if (overlay) sunbeam_order(transaction, cid, kid, -1, above);
        if (transaction) sunbeam_transform(transaction, cid, kid, kept[k].settled);
        above = kid;
    }
    if (overlay && backdrop) sunbeam_order(transaction, cid, backdrop, -1, overlay);
    if (transaction) {
        for (int i = count - 1; i >= 0; --i) {
            bool on_show = i == entered;
            for (int k = 0; k < kept_count; ++k) if (kept[k].index == i) on_show = true;
            if (!on_show) sunbeam_restore(transaction, &saved[i], backdrop, overlay, &anchor, skip, kept_count + 1, false);
        }
    }
}

/// The entered window goes to `point` at its native size, in front of the canvas, and every other
/// window of the lease back where the add-on found it, except the ones in `keep` (wid, x, y each,
/// bottom to top; sunlight-10): those go to their points too and stay in front of the canvas under
/// it. The window needn't be leased (no frame has gone out on this lease, say): it is taken to its
/// place from wherever it is. A window to keep must be leased, and is put back with the rest if it
/// isn't, is gone, or won't move. False only when the entered window is gone or won't move.
static bool sunbeam_handoff(uint32_t wid, CGPoint point, uint32_t overlay, uint32_t backdrop,
                            const char *keep, int keep_count,
                            struct sunbeam_saved *saved, int count, const struct sunbeam_session_state *state)
{
    int cid = SLSMainConnectionID();
    int entered = -1;
    for (int i = 0; i < count; ++i) if (saved[i].wid == wid) entered = i;
    // A leased entry whose owner changed is a reused ID: not this window any more. The one asked
    // for is taken as found, and the stale entry is left alone.
    if (entered >= 0 && !sunbeam_owner_matches(&saved[entered])) { saved[entered].wid = 0; entered = -1; }
    int owner = 0;
    CGRect frame;
    if (SLSGetWindowOwner(cid, wid, &owner) != kCGErrorSuccess) return false;
    // The native position doesn't show while a transform is in force: the transform alone says
    // where the window is drawn. The settled transform is read back from where the window landed
    // (an app can clamp a move).
    if (SLSMoveWindowWithGroup(cid, wid, &point) != noErr) return false;
    if (SLSGetWindowBounds(cid, wid, &frame) != kCGErrorSuccess) return false;
    CGAffineTransform settled = CGAffineTransformMakeTranslation(-frame.origin.x, -frame.origin.y);
    // Its own level back (a frame put it at the canvas's), with the rest of the handoff: set now, it
    // would land at the front of the normal level, under the backdrop still up at the canvas's.
    int wid_level = 0;
    if (entered >= 0) wid_level = saved[entered].level;
    else if (SLSGetWindowLevel(cid, wid, &wid_level) != kCGErrorSuccess) wid_level = 0;   // not leased: left at its own
    // The ones kept on show: moved natively under the transform in force, so nothing shows yet.
    struct sunbeam_kept kept[SUNBEAM_LIMIT];
    int kept_count = 0;
    for (int k = 0; k < keep_count && overlay; ++k) {
        uint32_t kid; float kx, ky;
        memcpy(&kid, keep + k * 12, 4); memcpy(&kx, keep + k * 12 + 4, 4); memcpy(&ky, keep + k * 12 + 8, 4);
        int index = -1;
        for (int i = 0; i < count; ++i) if (saved[i].wid == kid && i != entered) index = i;
        if (index < 0 || !sunbeam_owner_matches(&saved[index])) continue;
        bool twice = false;
        for (int j = 0; j < kept_count; ++j) if (kept[j].index == index) twice = true;
        if (twice) continue;
        CGPoint kpoint = CGPointMake(kx, ky);
        CGRect kframe;
        if (SLSMoveWindowWithGroup(cid, kid, &kpoint) != noErr || SLSGetWindowBounds(cid, kid, &kframe) != kCGErrorSuccess) continue;
        kept[kept_count].index = index;
        kept[kept_count].settled = CGAffineTransformMakeTranslation(-kframe.origin.x, -kframe.origin.y);
        ++kept_count;
    }
    uint32_t ov = overlay ? overlay : state->overlay;
    uint32_t bd = backdrop ? backdrop : state->backdrop;
    uint32_t anchor = bd;
    bool changed = false, transacted = false;
    for (int attempt = 0; attempt < 2; ++attempt) {
        CFTypeRef transaction = attempt == 0 ? sunbeam_transaction_begin(cid) : NULL;
        sunbeam_handoff_apply(transaction, wid, wid_level, settled, overlay, ov, bd, saved, count, entered, kept, kept_count, anchor, &changed);
        transacted = transaction != NULL;
        if (sunbeam_transaction_end(transaction)) break;
    }
    // Levels changed in a transaction: the orders once more, directly, in case the window server took
    // them before the levels (see `sunbeam_release_all`). A no-op when it didn't.
    if (changed) {
        if (overlay) sunbeam_order(NULL, cid, wid, 1, overlay);
        uint32_t above = wid;
        for (int k = kept_count - 1; k >= 0; --k) { sunbeam_order(NULL, cid, saved[kept[k].index].wid, -1, above); above = saved[kept[k].index].wid; }
        if (overlay && bd) sunbeam_order(NULL, cid, bd, -1, overlay);
        uint32_t skip[SUNBEAM_LIMIT + 1] = { wid };
        for (int k = 0; k < kept_count; ++k) skip[k + 1] = saved[kept[k].index].wid;
        uint32_t redo_anchor = bd;
        for (int i = count - 1; i >= 0; --i) {
            bool on_show = i == entered;
            for (int k = 0; k < kept_count; ++k) if (kept[k].index == i) on_show = true;
            if (!on_show) sunbeam_restore(NULL, &saved[i], bd, ov, &redo_anchor, skip, kept_count + 1, false);
        }
    }
    // The windows put back go to native size only now, under the backdrop (see `sunbeam_restore`).
    if (transacted) {
        for (int i = count - 1; i >= 0; --i) {
            bool on_show = i == entered;
            for (int k = 0; k < kept_count; ++k) if (kept[k].index == i) on_show = true;
            if (!on_show) sunbeam_settle(&saved[i]);
        }
    }
    return true;
}

// MARK: Session

static void *sunbeam_session(void *context)
{
    int fd = (int)(intptr_t)context;
    struct sunbeam_saved saved[SUNBEAM_LIMIT];
    int count = 0;
    struct sunbeam_session_state state = { .order_count = -1 };
    // One app's canvases own transforms, a lease each. The stock yabai daemon remains free to accept commands.
    pid_t peer = 0;
    socklen_t peer_length = sizeof(peer);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &peer_length) != 0) peer = 0;
    pthread_mutex_lock(&sunbeam_lock);
    bool admitted = sunbeam_sessions == 0 || (sunbeam_sessions < SUNBEAM_SESSIONS && peer && peer == sunbeam_sessions_pid);
    if (admitted && sunbeam_sessions++ == 0) sunbeam_sessions_pid = peer;
    pthread_mutex_unlock(&sunbeam_lock);
    if (!admitted) { close(fd); return NULL; }
    struct timeval timeout = { .tv_sec = 3, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    if (send(fd, SUNBEAM_MAGIC, sizeof(SUNBEAM_MAGIC) - 1, 0) != sizeof(SUNBEAM_MAGIC) - 1) goto done;
    for (;;) {
        int16_t length;
        char bytes[SA_SOCKET_BUFF_LEN];
        if (!sunbeam_read(fd, &length, 2) || length <= 0 || length >= SA_SOCKET_BUFF_LEN ||
            !sunbeam_read(fd, bytes, length)) break;
        bool ok = false;
        pthread_mutex_lock(&sunbeam_lock);
        sunbeam_status = 1;
        if ((uint8_t)bytes[0] == SUNBEAM_FRAME) {
            ok = sunbeam_frame(bytes + 1, length - 1, saved, &count, &state);
        } else if ((uint8_t)bytes[0] == SUNBEAM_SHADOW && length == 45) {
            // Shadows are cosmetic: a refusal is answered with its status and the lease goes on, a frame
            // or a handoff behind it.
            uint8_t status = sunbeam_shadow_set(bytes + 1);
            pthread_mutex_unlock(&sunbeam_lock);
            if (send(fd, &status, 1, 0) != 1) break;
            continue;
        } else if ((uint8_t)bytes[0] == SUNBEAM_HANDOFF && (length == 13 || length == 21 ||
                   (length > 22 && (length - 22) % 12 == 0 && (uint8_t)bytes[21] == (length - 22) / 12))) {
            // 13 bytes: the window and its native position. 21 (since sunlight-3): also the canvas's
            // overlay and backdrop, so the raise above the canvas and the backdrop's tuck under it land
            // with the rest. Sent as separate requests after the acknowledgement, they could only be
            // made atomic by the canvas holding its own update freeze across this request — which
            // deadlocks against the Dock's own freeze until the window server's timeout. Longer (since
            // sunlight-10): a count, then the windows kept on show with it, 12 bytes each.
            sunbeam_status = 7;
            uint32_t wid, overlay = 0, backdrop = 0; float x, y;
            int keep_count = length > 21 ? (uint8_t)bytes[21] : 0;
            memcpy(&wid, bytes + 1, 4); memcpy(&x, bytes + 5, 4); memcpy(&y, bytes + 9, 4);
            if (length >= 21) { memcpy(&overlay, bytes + 13, 4); memcpy(&backdrop, bytes + 17, 4); }
            bool sane = keep_count <= SUNBEAM_LIMIT;
            for (int k = 0; sane && k < keep_count; ++k) {
                uint32_t kid; float kx, ky;
                memcpy(&kid, bytes + 22 + k * 12, 4); memcpy(&kx, bytes + 26 + k * 12, 4); memcpy(&ky, bytes + 30 + k * 12, 4);
                sane = kid && kid != wid && kid != overlay && kid != backdrop && isfinite(kx) && isfinite(ky);
            }
            if (sane && wid && isfinite(x) && isfinite(y) && wid != overlay && wid != backdrop && (!overlay || overlay != backdrop)) {
                ok = sunbeam_handoff(wid, CGPointMake(x, y), overlay, backdrop, bytes + 22, keep_count, saved, count, &state);
                if (ok) {
                    // Every window is back where the add-on found it, and the entered one (and any
                    // kept with it) keeps its committed position with the native identity transform
                    // on disconnect.
                    count = 0;
                    state.order_count = -1;
                }
            }
        }
        uint8_t status = ok ? 0 : sunbeam_status;
        pthread_mutex_unlock(&sunbeam_lock);
        if (send(fd, &status, 1, 0) != 1 || !ok) break;
    }
done:
    pthread_mutex_lock(&sunbeam_lock);
    sunbeam_release_all(saved, count, state.backdrop, state.overlay, 0);
    --sunbeam_sessions;
    pthread_mutex_unlock(&sunbeam_lock);
    shutdown(fd, SHUT_RDWR); close(fd);
    return NULL;
}

// Called only after the ordinary length-prefixed envelope has been read. Returning true transfers
// ownership of fd to the lease worker; the normal handler must not close it.
static bool sunbeam_dispatch(int fd, char *message)
{
    if ((uint8_t)message[0] == SUNBEAM_CAPABILITY) {
        send(fd, SUNBEAM_MAGIC, sizeof(SUNBEAM_MAGIC) - 1, 0);
    } else if ((uint8_t)message[0] == SUNBEAM_SESSION) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, sunbeam_session, (void *)(intptr_t)fd) == 0) {
            pthread_detach(thread);
            return true;
        }
    }
    return false;
}
