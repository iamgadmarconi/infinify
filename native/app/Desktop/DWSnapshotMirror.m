// SPDX-License-Identifier: GPL-3.0-or-later
// The shell's side of the controller's snapshot transport: the last snapshot it rebuilt, kept apart from Desktop's own caches.
#import "DWSnapshotMirror.h"
#import "DWTypedValue.h"
@implementation DWSnapshotMirror {
    DriftDesktopSnapshotCursor *_cursor;
    DriftDesktop *_controller; // whose snapshots the baseline is
    NSDictionary *_base; // immutable; the controller's snapshot at _token, or nil when none is held
    uint64_t _token;
}
- (instancetype)init { if((self=[super init]))_cursor=driftwm_desktop_snapshot_cursor_new();return self; }
- (void)dealloc { driftwm_desktop_snapshot_cursor_free(_cursor); }
- (void)reset { _base=nil;_token=0; }
- (NSDictionary *)snapshotFrom:(DriftDesktop *)controller error:(NSString **)error {
    NSString *failure=@"Controller unavailable";
    // A different controller invalidates any baseline, whatever its token says.
    if(controller!=_controller){[self reset];_controller=controller;}
    // The second attempt is the full resynchronisation after a reply that could not be applied to the baseline.
    for(int attempt=0;_cursor&&attempt<2;attempt++){
        char *response=driftwm_desktop_snapshot_delta(controller,_cursor,_base?_token:0);if(!response){[self reset];break;}
        // The parsed tree copies what it needs; the bytes are only read for the parse.
        NSData *data=[NSData dataWithBytesNoCopy:response length:strlen(response) freeWhenDone:NO];
        NSDictionary *reply=DWTyped([NSJSONSerialization JSONObjectWithData:data options:0 error:nil],NSDictionary.class);driftwm_desktop_response_free(response);
        // A refusal carries the request envelope's error and changes nothing worth keeping.
        if(reply[@"ok"]&&![reply[@"ok"]isEqual:@YES]){[self reset];failure=DWTyped(reply[@"error"],NSString.class)?:@"Controller error";break;}
        NSNumber *token=DWTyped(reply[@"token"],NSNumber.class),*base=DWTyped(reply[@"base"],NSNumber.class);
        NSDictionary *full=DWTyped(reply[@"full"],NSDictionary.class),*replace=DWTyped(reply[@"replace"],NSDictionary.class);NSArray *remove=DWTyped(reply[@"remove"],NSArray.class);
        if(token&&full){_base=full;_token=token.unsignedLongLongValue;return full;}
        if(token&&_base&&base&&base.unsignedLongLongValue==_token&&replace&&remove){
            BOOL names=YES;for(id key in remove)if(!DWTyped(key,NSString.class))names=NO;
            if(names){
                // A shallow copy: the sections the controller did not resend are the previous snapshot's own objects, never mutated.
                NSMutableDictionary *next=[_base mutableCopy];[next addEntriesFromDictionary:replace];[next removeObjectsForKeys:remove];
                _base=[next copy];_token=token.unsignedLongLongValue;return _base;
            }
        }
        // Malformed, or not a patch of the baseline held: drop it and ask again for everything.
        [self reset];failure=@"Controller error";
    }
    if(error)*error=failure;
    return nil;
}
@end
