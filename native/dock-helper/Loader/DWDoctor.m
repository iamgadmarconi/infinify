// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#import "DWPreflight.h"
int main(void) { @autoreleasepool {
    uint32_t config;int preview;int result=dw_preflight(&config,&preview);
    NSDictionary *report=@{@"v":@1,@"sip_config":@(config),@"sip_query_ok":result>=0?@YES:@NO,@"task_for_pid_relaxed":(config&4)?@YES:@NO,@"filesystem_relaxed":(config&2)?@YES:@NO,@"arm64e_preview_abi":preview?@YES:@NO,@"injection_preflight_passed":result==0?@YES:@NO,@"injection_executed":@NO,@"settings_changed":@NO,@"status":result==0 ? @"prerequisites present; injection and foreign-window transforms unproven" : @"injection unavailable under current SIP/boot policy",@"implementation":@"read-only policy check; no injection, window changes or Space changes performed"};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
    fwrite(json.bytes,1,json.length,stdout);putchar('\n');return 0;
} }
