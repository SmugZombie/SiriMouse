#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

#include <stdint.h>

/// Called once per contact frame from a MultitouchSupport thread.
/// `count` is the number of active fingers; `x`/`y` are their averaged normalized
/// position (0...1, origin bottom-left) and are 0 when `count` is 0.
typedef void (*SMTouchCallback)(uint64_t device, int count, float x, float y, double timestamp);

/// Attaches to every non-built-in multitouch surface whose sensor matches the Siri Remote.
/// Returns the number of surfaces attached, or -1 if the private framework is unavailable.
/// Call on the main thread.
int sm_touch_start(SMTouchCallback callback);

/// Detaches from all surfaces. Call on the main thread.
void sm_touch_stop(void);

#endif
