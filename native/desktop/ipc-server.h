// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
// One complete request line without its newline in, one reply line out. Always
// called on the main queue, one request per connection at a time; nil hangs up.
// A request that sets *subscribe makes its connection a subscriber once the reply
// is written: *event, when set, is the first line pushed to it, and every line
// given to -publish: follows. The connection keeps answering requests.
typedef NSData *(^DWIPCHandler)(NSData *line,BOOL *subscribe,NSData **event);
// Line-delimited Unix-domain stream server for the current user only.
@interface DWIPCServer : NSObject
// nil and *error when the path is unusable or a live server already answers on it;
// that server's socket is left alone. Only a socket nobody answers is replaced.
+ (instancetype)serverAtPath:(NSString *)path handler:(DWIPCHandler)handler error:(NSString **)error;
// How many connections are subscribed; while it is 0 an event is not worth producing.
@property (readonly) NSUInteger subscribers;
// Main thread only. One event line without its newline to every subscriber, never
// blocking: a subscriber still taking an earlier event gets this one after it, in
// place of any that already waited. Subscribers are few, never time out for
// being quiet, and are hung up on when they stop reading.
- (void)publish:(NSData *)event;
// Main thread only. Writes replies already produced, closes every connection and
// unlinks the socket; no handler runs after it returns. Required before release.
- (void)stop;
@end
