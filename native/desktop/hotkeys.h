// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
typedef NS_ENUM(NSUInteger, DWNativeWindowControl) {
    DWNativeWindowControlToggleFullscreen,
    DWNativeWindowControlFill,
    DWNativeWindowControlRestore,
    DWNativeWindowControlCenter,
    DWNativeWindowControlSuppressTiling,
};
// The controller's {"op":"bindings"} reply as global hot keys. Command-Tab and F3 use a session event filter
// (including the top-row Mission Control alias); other keys use Carbon. Main thread only.
// A key with a "character" is the key that types it in the current keyboard layout,
// unshifted, or with Shift for a chord that holds Shift. When no key types it,
// "key_code" is the key if the reply says layout_independent (or leaves it out), and
// otherwise the binding is left out and noted. A key without a "character" is its
// "key_code". A "repeat" key fires again while held: after repeat_delay_ms,
// then repeat_rate_hz times a second, until Carbon reports its release, another hot
// key is pressed, its modifiers are let go, or -stop.
@interface DWHotKeys : NSObject
// fire receives the "action" of a pressed key, once per press and once per repeat.
- (instancetype)initWithFire:(void (^)(NSString *action))fire;
// The keyboard input source changed: ask the controller again and call -setBindings:.
@property (copy) void (^changed)(void);
// Main-thread admission of an unbound Return/keypad Enter. A returned job owns
// this physical pair; it must revalidate its exact canvas target when dispatched.
@property (copy) dispatch_block_t (^standinEnter)(void);
// Optional native window controls: Fn-F / Control-Command-F, Fn-Control-F/R/C,
// and Fn-Control arrows with no extra modifier, Shift, or Option+Shift. Authored
// bindings and pass policy precede admission. The caller must prove exact native
// focus; nil leaves the pair native. A returned job owns the complete physical
// pair and revalidates its pinned target, including for SuppressTiling.
@property (copy) dispatch_block_t (^nativeWindowControl)(DWNativeWindowControl action);
// Unregisters, then resolves every key against the current layout. A key the reply
// marks "implemented": false is left out silently, its chord untouched.
- (void)setBindings:(NSDictionary *)bindings;
// Resolved keys, first of a physical chord only, in the reply's order: those the
// layout resolves, then those that fell back to "key_code". Each has "action",
// "combo", "chord" (DWChord), "modifiers" (⌃⌥⇧⌘), "key" (A, ←, F5), "repeat" and
// "passable" (the reply's; NO when it leaves it out).
@property (readonly) NSArray<NSDictionary *> *keys;
// Keys left out by -setBindings:, one line each.
@property (readonly) NSArray<NSString *> *notes;
- (BOOL)holds:(NSNumber *)chord;
// Display chords bound to one action, as "⌃⌥A".
- (NSArray<NSString *> *)chords:(NSString *)action;
// Registers every key that is not passed; system shortcut filters end on -stop; returns one line per chord macOS refused. No-op while started.
- (NSArray<NSString *> *)start;
// DriftWM's pass_keys: what the focused window's rule passes, as the controller's
// snapshot says it: true for every key, an array of "combo" strings for those keys,
// anything else for none. A passed key is not a hot key while it is passed, so macOS
// delivers the chord to the focused application itself: nothing is posted. Only a key
// the reply marks "passable" is ever passed, never one on `kept`, and never quit.
// Takes effect at once while started, except for a key that is down: it was pressed
// as a binding and stays one, repeat included, until it is released. Holds across
// -stop, -start and -setBindings: until the next call; the same value again does
// nothing. Returns one line per chord macOS refused to give back.
- (NSArray<NSString *> *)pass:(id)passKeys;
// A chord that stays a hot key whatever is passed: the shell's exit chord.
@property NSNumber *kept;
// Ends a running repeat: for the shell, when the command a held key runs cannot be started.
- (void)endRepeat;
// Unregisters every key and ends any repeat; the keys stay resolved for -start.
- (void)stop;
// -stop, and no further `changed`. Required before release.
- (void)invalidate;
@end
// A physical chord: virtual key code and Carbon modifier mask.
NSNumber *DWChord(uint32_t keyCode,uint32_t carbonModifiers);
// ⌃⌥⇧⌘ for a Carbon modifier mask.
NSString *DWModifierGlyphs(uint32_t carbonModifiers);
