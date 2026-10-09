// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// The controller's {"op":"bindings"} reply as Carbon global hot keys. Main thread only.
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
// Unregisters, then resolves every key against the current layout. A key the reply
// marks "implemented": false is left out silently, its chord untouched.
- (void)setBindings:(NSDictionary *)bindings;
// Resolved keys, first of a physical chord only, in the reply's order: those the
// layout resolves, then those that fell back to "key_code". Each has "action",
// "combo", "chord" (DWChord), "modifiers" (⌃⌥⇧⌘), "key" (A, ←, F5) and "repeat".
@property (readonly) NSArray<NSDictionary *> *keys;
// Keys left out by -setBindings:, one line each.
@property (readonly) NSArray<NSString *> *notes;
- (BOOL)holds:(NSNumber *)chord;
// Display chords bound to one action, as "⌃⌥A".
- (NSArray<NSString *> *)chords:(NSString *)action;
// Registers every key; returns one line per chord macOS refused. No-op while started.
- (NSArray<NSString *> *)start;
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
