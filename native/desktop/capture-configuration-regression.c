// SPDX-License-Identifier: GPL-3.0-or-later
// Pure configuration bookkeeping: no windows, capture streams, permissions or input.
#include "capture-configuration.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    unsigned checks=0;
#define CHECK(value) do { assert(value);checks++; } while(0)
    DWCaptureConfiguration state={0};
    CGSize full=CGSizeMake(1700,1132),small=CGSizeMake(850,566),selected=CGSizeZero;
    CMTime sixty=CMTimeMake(1,60),fast=CMTimeMake(1,120);
    uint64_t start=DWCaptureConfigurationBegin(&state,full,sixty);
    CHECK(start&&DWCaptureConfigurationPending(state,start));
    CHECK(!state.acknowledgedSerial);
    CHECK(!DWCaptureConfigurationUpdate(state,full,fast,true,&selected));
    CHECK(!DWCaptureConfigurationBegin(&state,small,fast));
    CHECK(DWCaptureConfigurationComplete(&state,start,true));
    CHECK(!DWCaptureConfigurationPending(state,start));
    CHECK(state.acknowledgedSerial==start&&CMTimeCompare(state.acknowledgedInterval,sixty)==0);
    CHECK(!DWCaptureConfigurationComplete(&state,start,true));

    // Startup at fallback60 then a120Hz display appears, with identical pixels.
    CHECK(DWCaptureConfigurationUpdate(state,full,fast,true,&selected));
    CHECK(CGSizeEqualToSize(selected,full));
    uint64_t faster=DWCaptureConfigurationBegin(&state,selected,fast);
    CHECK(faster!=start&&state.acknowledgedSerial==start);
    CHECK(!DWCaptureConfigurationPending(state,start)); // old start timeout
    CHECK(!DWCaptureConfigurationComplete(&state,start,false));
    CHECK(DWCaptureConfigurationComplete(&state,faster,true));
    CHECK(!DWCaptureConfigurationUpdate(state,full,CMTimeMake(2,240),true,&selected));

    // Moving back to60 updates the rate without accepting an unstable shrink.
    CHECK(DWCaptureConfigurationUpdate(state,small,sixty,false,&selected));
    CHECK(CGSizeEqualToSize(selected,full));
    uint64_t slower=DWCaptureConfigurationBegin(&state,selected,sixty);
    CHECK(!DWCaptureConfigurationUpdate(state,small,fast,true,&selected));
    CHECK(DWCaptureConfigurationComplete(&state,slower,true));
    CHECK(!DWCaptureConfigurationUpdate(state,small,sixty,false,&selected));
    CHECK(DWCaptureConfigurationUpdate(state,small,sixty,true,&selected));
    CHECK(CGSizeEqualToSize(selected,small));
    uint64_t shrink=DWCaptureConfigurationBegin(&state,selected,sixty);
    CHECK(DWCaptureConfigurationComplete(&state,shrink,true));
    CHECK(!DWCaptureConfigurationUpdate(state,small,sixty,true,&selected));

    // Failed requests never claim acknowledgement; teardown discards both
    // configurations. An old completion cannot install into the replacement.
    uint64_t failed=DWCaptureConfigurationBegin(&state,full,fast);
    CHECK(DWCaptureConfigurationComplete(&state,failed,false));
    CHECK(state.acknowledgedSerial==shrink&&CGSizeEqualToSize(state.acknowledgedPixels,small));
    DWCaptureConfigurationReset(&state);
    CHECK(!state.pending&&!state.acknowledgedSerial&&!CMTIME_IS_NUMERIC(state.requestedInterval));
    uint64_t replacement=DWCaptureConfigurationBegin(&state,full,fast);
    CHECK(replacement!=failed);
    CHECK(!DWCaptureConfigurationComplete(&state,failed,true));
    CHECK(DWCaptureConfigurationPending(state,replacement)&&!state.acknowledgedSerial);
    CHECK(DWCaptureConfigurationComplete(&state,replacement,true));
    CHECK(!DWCaptureConfigurationUpdate(state,full,fast,true,&selected));

    // A display changes again during the asynchronous update. Finish only that
    // request, then reconcile the latest desired interval on the next demand.
    uint64_t pending=DWCaptureConfigurationBegin(&state,full,sixty);
    CHECK(!DWCaptureConfigurationUpdate(state,full,fast,true,&selected));
    CHECK(DWCaptureConfigurationComplete(&state,pending,true));
    CHECK(DWCaptureConfigurationUpdate(state,full,fast,true,&selected));
    CHECK(CGSizeEqualToSize(selected,full));
    DWCaptureConfigurationReset(&state);
    CHECK(!DWCaptureConfigurationComplete(&state,pending,true));
    CHECK(!state.pending&&!state.acknowledgedSerial);
    printf("capture configuration: %u checks passed (no capture/native activity)\n",checks);
    return 0;
}
