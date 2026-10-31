// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// Where Infinify lives, and putting it there. Setup registers a login item and a launch daemon that run the app from its
// bundle's path, so that path has to last: an Applications folder on a writable volume. Two ways of opening a download
// give a path that does not. An app on the disk image is gone once the image is ejected. And LaunchServices starts a
// quarantined app that Finder did not move (opened on the disk image, or copied into place by a command) from a read-only
// copy under AppTranslocation, a new one at every launch, even after the owner allowed it once. A Finder move clears
// translocation, and Homebrew sets the quarantine's do-not-translocate bit for a cask, so neither needs any of this.

// The bundle that the translocated bundle at `bundle` is a copy of; nil when `bundle` is not translocated, or when macOS
// cannot say (SecTranslocate, looked up at run time).
NSString *DWInstallTranslocatedOriginal(NSString *bundle);
// YES when the bundle at `bundle` can be set up where it is: not translocated, inside an Applications folder, on a
// writable volume.
BOOL DWInstallIsInstalled(NSString *bundle);
// Where Move to Applications puts this copy: the first of `candidates` (DWSetupCopyCandidates) that holds an Infinify,
// which the move replaces, else the first whose folder this user can write, else the last (~/Applications, made then).
NSString *DWInstallPlace(NSArray<NSString *> *candidates);
// Removes the quarantine record from the bundle and from everything in it. Only for a bundle Gatekeeper has passed: the
// running one, or a copy of it.
BOOL DWInstallClearQuarantine(NSString *bundle,NSString *__autoreleasing *why);
// A plain launch that LaunchServices translocated, of a bundle that is in an Applications folder (copied there by a
// command): clears the quarantine of that bundle, which this launch has passed, and opens it instead (exec of open -n),
// so that it and every later launch run from its own path. Returns when there is nothing to do or it could not be done.
void DWInstallLeaveTranslocation(void);
// Replaces this process with open(1) of the bundle at `bundle`, a new instance, so that LaunchServices starts it as it
// starts an app from Finder. Returns only when the exec failed, with the exit status to use.
int DWInstallOpenInstead(NSString *bundle);
// Move to Applications, for setup's welcome pane: copies the bundle at `source` (the running one) to `place`, without
// quarantine. An Infinify already at `place` has its running processes stopped (SIGTERM, as at any quit) and is discarded
// first; something else there is refused. Then `original`, where `source` came from, is discarded when it is on a
// writable volume (a disk image is left as it is). `discard` defaults to moving to the Trash. Blocking: off the main
// thread. NO with the reason when Infinify is not at `place`.
BOOL DWInstallMove(NSString *source,NSString *original,NSString *place,BOOL (^discard)(NSString *path,NSString *__autoreleasing *why),NSString *__autoreleasing *why);
