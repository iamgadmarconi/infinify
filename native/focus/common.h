// SPDX-License-Identifier: GPL-3.0-or-later
#import <AppKit/AppKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import "focus.h"
#include <signal.h>
#include <unistd.h>
static volatile sig_atomic_t interrupted;
static void stop_signal(int s){interrupted=s;}
static void signals(void){signal(SIGINT,stop_signal);signal(SIGTERM,stop_signal);signal(SIGHUP,stop_signal);}
static NSString *hex(const unsigned char *bytes,size_t count){NSMutableString *s=[NSMutableString new];for(size_t n=0;n<count;n++)[s appendFormat:@"%02x",bytes[n]];return s;}
static NSString *digest(NSString *s){NSData *d=[s dataUsingEncoding:NSUTF8StringEncoding];unsigned char h[32];CC_SHA256(d.bytes,(CC_LONG)d.length,h);return hex(h,32);}
static NSString *signature(NSDictionary *v,NSString *key){NSData *d=[NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingSortedKeys error:NULL],*k=[key dataUsingEncoding:NSUTF8StringEncoding];unsigned char h[32];CCHmac(kCCHmacAlgSHA256,k.bytes,k.length,d.bytes,d.length,h);return hex(h,32);}
static bool save(NSDictionary *v,NSString *path){NSData *d=[NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];return d&&[d writeToFile:path atomically:YES];}
static NSDictionary *load(NSString *path){NSData *d=[NSData dataWithContentsOfFile:path];return d?[NSJSONSerialization JSONObjectWithData:d options:0 error:NULL]:nil;}
static NSArray *birth(pid_t p){uint64_t s,u;return dw_focus_birth(p,&s,&u)?@[@(s),@(u)]:nil;}
static void pump(double seconds){NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];do{NSEvent *e=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:.005] inMode:NSDefaultRunLoopMode dequeue:YES];if(e)[NSApp sendEvent:e];[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];}while(end.timeIntervalSinceNow>0&&!interrupted);}
static NSDictionary *ident(DWFocusIdentity i){return @{@"pid":@(i.pid),@"birth":@[@(i.seconds),@(i.microseconds)],@"window":@(i.window)};}
static inline DWFocusIdentity identity(NSDictionary *v){NSArray *b=v[@"birth"];return (DWFocusIdentity){.pid=[v[@"pid"]intValue],.seconds=b.count==2?[b[0]unsignedLongLongValue]:0,.microseconds=b.count==2?[b[1]unsignedLongLongValue]:0,.window=[v[@"window"]unsignedIntValue]};}
// Conditional restoration is the only operation allowed on a pre-existing app.
static BOOL restore(NSDictionary *prior,NSArray *owned){pid_t front=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;BOOL ours=NO;for(NSDictionary *v in owned)if([v[@"pid"]intValue]==front&&[birth(front)isEqual:v[@"birth"]])ours=YES;pid_t p=[prior[@"pid"]intValue];if(!ours||![birth(p)isEqual:prior[@"birth"]])return NO;return [[NSRunningApplication runningApplicationWithProcessIdentifier:p]activateWithOptions:0];}
