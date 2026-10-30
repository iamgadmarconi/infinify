// SPDX-License-Identifier: MIT AND GPL-3.0-or-later
#import <Foundation/Foundation.h>
// The app's side of the launch daemon (native/privileged/loadd.m): its registration with SMAppService and the XPC
// request that has it load the Dock payload as root. Translated from Sunlight's `LiveWindowsService`
// (third_party/sunlight/Sources/Canvas/Setup/LiveWindowsService.swift, afeea74, MIT, Copyright (c) 2026 spacefarm);
// the line ranges are given in loader-service.m. Every call is a round trip to launchd or the daemon.
typedef NS_ENUM(NSInteger,DWLoaderState) {
    DWLoaderUnavailable,   // no daemon in this build (ad-hoc signed, or running outside a bundle)
    DWLoaderNotRegistered,
    DWLoaderNeedsApproval, // registered; the owner still has to turn it on in Login Items
    DWLoaderEnabled,
};
@interface DWLoaderService : NSObject
+ (DWLoaderState)state;
// Registers the daemon, and opens Login Items when it is waiting for the owner's approval there.
+ (DWLoaderState)registerDaemon;
+ (void)unregister;
// `ping` or `load ARGUMENTS` in the daemon, and the reply's status and output. Status -1 when it could not be reached.
+ (int)run:(NSString *)command arguments:(NSArray<NSString *> *)arguments timeout:(NSTimeInterval)timeout output:(NSString *__autoreleasing *)output;
+ (NSString *)describe:(DWLoaderState)state;
@end
