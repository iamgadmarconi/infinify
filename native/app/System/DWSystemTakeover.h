// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// While a normal run is the desktop, macOS must not move windows by itself: Stage Manager shrinks every
// window outside the current stage into a thumbnail, and window tiling snaps a dragged or resized window to
// an edge, both on top of the canvas's own placement. A normal run therefore switches them off in
// com.apple.WindowManager (GloballyEnabled, EnableTilingByEdgeDrag, EnableTopTilingByEdgeDrag,
// EnableTilingOptionAccelerator) and puts the user's settings back when it ends. Written through
// CFPreferences, as `defaults write` does: WindowManager follows it live, with no restart of anything
// (established on macOS 27.0.1 in the guest, docs/native/user-guide.md "Desktop mode").
// A translation of Sunlight's takeover preferences; DWSystemTakeover.m names each translated function and its lines.
//
// The rules that keep the user's settings theirs:
// - The originals are read first and persisted atomically (written aside, fsynced, renamed) to a file in
//   Application Support before the first value is written. A key that was absent is recorded as absent and
//   removed again on restore, never defaulted.
// - Writes are all or nothing: each is read back, and one that did not stick (a managed preference, a
//   failing store) puts every key back and leaves no file behind.
// - A file that is still there at the next launch is a run that did not end orderly: it is restored first,
//   and engage then takes over again keeping that file's originals if they could not all be put back, so a
//   second crash cannot make the off values look like the user's.
// - A key the user changed while the run was up is theirs: restore writes the original back only where the
//   key still holds the value this run wrote, and leaves any other value as the user set it.
// Main thread only; restore and engage are idempotent.

// One preference takeover manages: SystemPrefs.Pref.
@interface DWPref : NSObject
@property(readonly) NSString *domain,*key;
// The value a run holds it at. (Sunlight's nil, which deletes the key, is not used here.)
@property(readonly) id desired;
// "domain|key": what the snapshot is keyed by.
@property(readonly) NSString *identifier;
@end

// Preferences one at a time, property-list values; nil is absent.
@protocol DWPrefsStore <NSObject>
- (id)valueOfPref:(DWPref *)pref;
// nil removes the key. YES only when the key then reads back as asked.
- (BOOL)setValue:(id)value ofPref:(DWPref *)pref;
@end

// The current user's preferences through CFPreferences.
@interface DWCFPrefs : NSObject <DWPrefsStore>
@end

// Whether Stage Manager is on now (GloballyEnabled), read afresh. Never written here.
BOOL DWStageManagerOn(void);

// What a run says, once, on stderr when Stage Manager comes on under a canvas that is already open: every window outside
// the current stage is then a thumbnail in its strip. DWStageManagerNote for a run that does not manage the setting
// (--windowed, --manual, or one whose takeover failed), DWStageManagerBackNote for one that switched it off and now leaves it
// on, as the user set it.
extern NSString *const DWStageManagerNote;
extern NSString *const DWStageManagerBackNote;

@interface DWSystemTakeover : NSObject
// The real thing: the current user's preferences and ~/Library/Application Support/Infinify/window-prefs-snapshot.plist.
+ (instancetype)system;
- (instancetype)initWithStore:(id<DWPrefsStore>)store snapshotPath:(NSString *)path;
// Whether the settings are switched off by this object now.
@property(readonly) BOOL engaged;
// Restores a file left by an earlier run, then switches the settings off. YES: they are off (also when
// already engaged). NO: nothing was changed (or a failed attempt was undone). `note` is the stderr text to
// say (one line, two when a leftover was put back first), or nil when there is nothing new to say.
- (BOOL)engage:(NSString **)note;
// Puts back what engage changed, as above. YES: nothing of ours is left in the settings (also when there was
// nothing to put back). NO: a key could not be written; the file stays and the next launch tries again.
- (BOOL)restore:(NSString **)note;
@end
