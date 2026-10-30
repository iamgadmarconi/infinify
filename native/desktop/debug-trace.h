// SPDX-License-Identifier: GPL-3.0-or-later
// INFINIFY_DEBUG in the environment, read once: the switch for the shell's stderr diagnostics.
#import <Foundation/Foundation.h>

static inline BOOL DWDebugTrace(void) { static int on=-1;if(on<0)on=getenv("INFINIFY_DEBUG")!=NULL;return on; }
