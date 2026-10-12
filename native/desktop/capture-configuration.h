// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef DW_CAPTURE_CONFIGURATION_H
#define DW_CAPTURE_CONFIGURATION_H
#include <CoreMedia/CoreMedia.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

// Main-owned request bookkeeping. A successful SCK completion acknowledges the
// requested configuration; it does not establish the delivered frame cadence.
typedef struct {
    uint64_t serial,acknowledgedSerial;
    CGSize requestedPixels,acknowledgedPixels;
    CMTime requestedInterval,acknowledgedInterval;
    bool pending;
} DWCaptureConfiguration;

static inline void DWCaptureConfigurationReset(DWCaptureConfiguration *state) {
    uint64_t serial=state->serial+1;if(!serial)serial=1;
    *state=(DWCaptureConfiguration){.serial=serial};
}

static inline uint64_t DWCaptureConfigurationBegin(DWCaptureConfiguration *state,CGSize pixels,CMTime interval) {
    if(state->pending)return 0;
    if(!++state->serial)state->serial=1;
    state->requestedPixels=pixels;state->requestedInterval=interval;state->pending=true;
    return state->serial;
}

static inline bool DWCaptureConfigurationPending(DWCaptureConfiguration state,uint64_t serial) {
    return serial&&state.pending&&state.serial==serial;
}

static inline bool DWCaptureConfigurationComplete(DWCaptureConfiguration *state,uint64_t serial,bool success) {
    if(!DWCaptureConfigurationPending(*state,serial))return false;
    state->pending=false;
    if(success){state->acknowledgedSerial=serial;state->acknowledgedPixels=state->requestedPixels;state->acknowledgedInterval=state->requestedInterval;}
    return true;
}

// A rate-only update retains the current pixel budget while a shrink waits for
// the existing density/bucket stability period. Comparing rational CMTime values
// also avoids needless updates for equivalent interval representations.
static inline bool DWCaptureConfigurationUpdate(DWCaptureConfiguration state,CGSize wanted,CMTime interval,bool resizeReady,CGSize *pixels) {
    if(state.pending)return false;
    bool rateChanged=!state.acknowledgedSerial||!CMTIME_IS_NUMERIC(state.acknowledgedInterval)
        ||!CMTIME_IS_NUMERIC(interval)||CMTimeCompare(state.acknowledgedInterval,interval)!=0;
    bool sizeChanged=resizeReady&&!CGSizeEqualToSize(state.acknowledgedPixels,wanted);
    if(!rateChanged&&!sizeChanged)return false;
    *pixels=resizeReady||!state.acknowledgedSerial?wanted:state.acknowledgedPixels;
    return true;
}
#endif
