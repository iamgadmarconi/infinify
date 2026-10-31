// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// Whether a newer Infinify is out. A release build names its GitHub repository in Info.plist (InfinifyReleaseRepository,
// stamped by scripts/build-release.sh); a development build names none and never checks. At most once a day the latest
// release is read from GitHub's API, with no account and nothing sent but the request, and kept in updates.plist in the
// support directory (owner-only, DWOwnerFile.h) with the newest version the owner has been told about. Homebrew is the
// update channel (`brew upgrade --cask infinify`); a copy from the disk image is pointed at the release page instead.
// `defaults write com.marengox.infinify CheckForUpdates -bool NO` turns checking off.

// Dotted versions compared number by number (0.2.10 is after 0.2.9); a missing part counts as 0.
NSComparisonResult DWUpdateCompareVersions(NSString *one,NSString *other);
// The release in an answer from GitHub's "latest release" endpoint: @{@"version":@"0.2.3",@"page":@"https://…"}, the tag's
// leading v dropped; nil for a draft, a prerelease, or anything malformed.
NSDictionary<NSString *,NSString *> *DWUpdateReleaseFromJSON(NSData *json);
// Records a release read at `checked`, keeping what the owner was told. YES when written.
BOOL DWUpdateRecordRelease(NSString *supportDirectory,NSDictionary<NSString *,NSString *> *release,NSDate *checked);
// The release recorded, when it is newer than `running`; else nil.
NSDictionary<NSString *,NSString *> *DWUpdateNewerRecorded(NSString *supportDirectory,NSString *running);
// YES once per version: the first time it is asked about `version`, which it records as told.
BOOL DWUpdateFirstNoticeOf(NSString *supportDirectory,NSString *version);
// Reads the latest release from GitHub when this is a release build, checking is on and the last read is a day old or
// more, and records it. Then calls `done` on the main queue with the newer release recorded, or nil. Never blocks.
void DWUpdateCheckIfDue(NSString *supportDirectory,void (^done)(NSDictionary<NSString *,NSString *> *newer));
// The command that updates this copy, `brew upgrade --cask infinify`, when one of `caskrooms` (Homebrew's, by default
// /opt/homebrew/Caskroom and /usr/local/Caskroom) holds infinify; nil for a copy Homebrew did not install.
NSString *DWUpdateCommand(NSArray<NSString *> *caskrooms);
NSArray<NSString *> *DWUpdateHomebrewCaskrooms(void);
