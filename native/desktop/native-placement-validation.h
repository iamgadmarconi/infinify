// SPDX-License-Identifier: GPL-3.0-or-later
#import "native-presenter.h"

// Main-thread, read-only checks of an immutable requested/acknowledged placement.
// A fresh, complete native family must retain its exact process instances,
// ancestry, untransformed basis and independently observed placement. Every
// member must be on screen, have positive alpha and fit wholly in the viewport;
// partial native clipping is unsupported. The presenter receipt is fenced last.
// Success only settles presentation geometry at this call; it is not optical
// proof, authorization for later input, or a retained native usability token.
BOOL DWNativeValidateAppliedPlacementGeometry(DWNativePresenter *presenter,
    DWNativeAppliedPlacement *placement,NSString *__autoreleasing *why);

// The same fresh geometry checks, plus the event-eligible recipient at the actual
// physical screen point. recipient must contain exact integer pid, wid,
// birth_sec, birth_usec and a positive numeric native owner connection. Neither
// geometric containment nor an ACK substitutes for that event-hit query. Invoke
// immediately before input, and recheck the consumer's own transfer/grab fence.
// This posts no event and cannot authorize another point or a later packet.
BOOL DWNativeValidateAppliedPlacementInput(DWNativePresenter *presenter,
    DWNativeAppliedPlacement *placement,NSDictionary *recipient,CGPoint physicalPoint,
    NSString *__autoreleasing *why);
