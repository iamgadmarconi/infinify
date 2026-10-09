// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// One complete request line without its newline in, one reply line out. Always
// called on the main queue, one request per connection at a time; nil hangs up.
typedef NSData *(^DWIPCHandler)(NSData *line);
// Line-delimited Unix-domain stream server for the current user only.
@interface DWIPCServer : NSObject
// nil and *error when the path is unusable or a live server already answers on it;
// that server's socket is left alone. Only a socket nobody answers is replaced.
+ (instancetype)serverAtPath:(NSString *)path handler:(DWIPCHandler)handler error:(NSString **)error;
// Main thread only. Writes replies already produced, closes every connection and
// unlinks the socket; no handler runs after it returns. Required before release.
- (void)stop;
@end
