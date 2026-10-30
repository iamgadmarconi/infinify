// SPDX-License-Identifier: GPL-3.0-or-later
// Field checks shared by the loader and the Dock payload when each reads the recovery journal.
#ifndef DW_JOURNAL_FIELDS_H
#define DW_JOURNAL_FIELDS_H
#import <Foundation/Foundation.h>

// A boot session UUID as the kernel prints it: 36 characters, upper-case hexadecimal, dashes at 8, 13, 18 and 23.
static inline BOOL dw_boot_uuid_valid(id value) {
    if(![value isKindOfClass:NSString.class] || [value length]!=36)return NO;
    for(NSUInteger i=0;i<36;i++) {
        unichar c=[value characterAtIndex:i];
        if(i==8 || i==13 || i==18 || i==23) { if(c!='-')return NO; }
        else if(!((c>='0'&&c<='9')||(c>='A'&&c<='F')))return NO;
    }
    return YES;
}
// A dictionary whose keys are exactly `keys`.
static inline BOOL dw_exact_keys(NSDictionary *value,NSArray *keys) {
    return [value isKindOfClass:NSDictionary.class] && [[NSSet setWithArray:value.allKeys]isEqual:[NSSet setWithArray:keys]];
}
#endif
