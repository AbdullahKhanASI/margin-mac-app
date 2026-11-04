#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

#include <stdint.h>

/// One finger in a trackpad frame. Coordinates are normalized:
/// x runs 0 (left) → 1 (right), y runs 0 (bottom) → 1 (top).
typedef struct {
    int32_t identifier;
    int32_t state;   // 1–7; 3 = touch down, 4 = touching, 5 = lift-off
    float x;
    float y;
    float size;
} MRTouch;

/// is_mouse is 1 for a Magic Mouse, 0 for a trackpad.
typedef void (*MRFrameCallback)(const MRTouch *touches, int32_t count, double timestamp, uint64_t deviceID, int32_t is_mouse);

/// Returns 1 if MultitouchSupport and its symbols could be loaded.
int mr_multitouch_available(void);

/// Registers the callback on every trackpad (built-in, plus external Magic Trackpads when
/// include_external is non-zero) and, when include_mouse is non-zero, on Magic Mice.
/// Returns the number of devices started.
int mr_start(MRFrameCallback callback, int include_external, int include_mouse);

/// Unregisters the callback and stops all devices started by mr_start.
void mr_stop(void);

/// Number of devices currently connected, using the same filter as mr_start.
int mr_device_count(int include_external, int include_mouse);

/// The device ID of the built-in trackpad among those mr_start started, else the first started
/// trackpad, else 0. The timer alarm uses it when it doesn't know which trackpad set the timer.
uint64_t mr_builtin_device_id(void);

/// Fires the haptic motor of the multitouch device with this ID (as passed to the frame callback).
/// Works for background apps, unlike NSHapticFeedbackManager. actuation_id: 3 weak, 4 medium, 6 strong.
/// Returns 0 on success.
int mr_actuate(uint64_t device_id, int32_t actuation_id);

/// Lets a background (LSUIElement) app hide the cursor with CGDisplayHideCursor.
void mr_allow_background_cursor_control(void);

/// Built-in display brightness, 0–1. Returns 0 on success.
int mr_get_brightness(float *out);

/// Sets built-in display brightness, 0–1, without the system HUD. Returns 0 on success.
int mr_set_brightness(float value);

#endif
