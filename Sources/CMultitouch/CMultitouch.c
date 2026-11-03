#include "CMultitouch.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <stdbool.h>

// MARK: - MultitouchSupport private types (layout from long-standing reverse engineering)

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;
    int32_t fingerID;
    int32_t handID;
    MTVector normalized;
    float size;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;
    int32_t field14;
    int32_t field15;
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch *, int, double, int);

static CFMutableArrayRef (*pMTDeviceCreateList)(void);
static void (*pMTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*pMTUnregisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*pMTDeviceStart)(MTDeviceRef, int);
static void (*pMTDeviceStop)(MTDeviceRef);
static bool (*pMTDeviceIsBuiltIn)(MTDeviceRef);
static OSStatus (*pMTDeviceGetDeviceID)(MTDeviceRef, uint64_t *);
static OSStatus (*pMTDeviceGetFamilyID)(MTDeviceRef, int32_t *);

static int loaded = -1;

static int load_multitouch(void) {
    if (loaded >= 0) return loaded;
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!h) { loaded = 0; return 0; }
    pMTDeviceCreateList = dlsym(h, "MTDeviceCreateList");
    pMTRegisterContactFrameCallback = dlsym(h, "MTRegisterContactFrameCallback");
    pMTUnregisterContactFrameCallback = dlsym(h, "MTUnregisterContactFrameCallback");
    pMTDeviceStart = dlsym(h, "MTDeviceStart");
    pMTDeviceStop = dlsym(h, "MTDeviceStop");
    pMTDeviceIsBuiltIn = dlsym(h, "MTDeviceIsBuiltIn");
    pMTDeviceGetDeviceID = dlsym(h, "MTDeviceGetDeviceID");
    pMTDeviceGetFamilyID = dlsym(h, "MTDeviceGetFamilyID");
    loaded = (pMTDeviceCreateList && pMTRegisterContactFrameCallback && pMTDeviceStart && pMTDeviceStop) ? 1 : 0;
    return loaded;
}

int mr_multitouch_available(void) { return load_multitouch(); }

// MARK: - Device filtering

static bool is_magic_mouse(MTDeviceRef dev) {
    if (!pMTDeviceGetFamilyID) return false;
    int32_t family = 0;
    if (pMTDeviceGetFamilyID(dev, &family) != 0) return false;
    // Magic Mouse (112) and Magic Mouse 2 (113).
    return family == 112 || family == 113;
}

static bool wanted(MTDeviceRef dev, int include_external, int include_mouse) {
    if (is_magic_mouse(dev)) return include_mouse;
    bool builtIn = pMTDeviceIsBuiltIn ? pMTDeviceIsBuiltIn(dev) : true;
    return builtIn || include_external;
}

// MARK: - Frame forwarding

#define MR_MAX_TOUCHES 16

static MRFrameCallback userCallback = NULL;
static CFMutableArrayRef runningDevices = NULL;
static MTDeviceRef mouseDevices[8];
static int mouseDeviceCount = 0;

static int32_t device_is_mouse(MTDeviceRef dev) {
    for (int i = 0; i < mouseDeviceCount; i++) {
        if (mouseDevices[i] == dev) return 1;
    }
    return 0;
}

static int frame_trampoline(MTDeviceRef device, MTTouch *touches, int count, double timestamp, int frame) {
    (void)frame;
    MRFrameCallback cb = userCallback;
    if (!cb) return 0;

    MRTouch out[MR_MAX_TOUCHES];
    int n = count < MR_MAX_TOUCHES ? count : MR_MAX_TOUCHES;
    for (int i = 0; i < n; i++) {
        out[i].identifier = touches[i].identifier;
        out[i].state = touches[i].state;
        out[i].x = touches[i].normalized.position.x;
        out[i].y = touches[i].normalized.position.y;
        out[i].size = touches[i].size;
    }
    uint64_t deviceID = 0;
    if (pMTDeviceGetDeviceID) pMTDeviceGetDeviceID(device, &deviceID);
    cb(out, n, timestamp, deviceID, device_is_mouse(device));
    return 0;
}

int mr_start(MRFrameCallback callback, int include_external, int include_mouse) {
    if (!load_multitouch()) return 0;
    mr_stop();
    userCallback = callback;
    mouseDeviceCount = 0;

    CFMutableArrayRef list = pMTDeviceCreateList();
    if (!list) return 0;

    int started = 0;
    CFIndex total = CFArrayGetCount(list);
    for (CFIndex i = 0; i < total; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        if (!wanted(dev, include_external, include_mouse)) continue;
        if (is_magic_mouse(dev) && mouseDeviceCount < 8) mouseDevices[mouseDeviceCount++] = dev;
        pMTRegisterContactFrameCallback(dev, frame_trampoline);
        pMTDeviceStart(dev, 0);
        started++;
    }
    runningDevices = list;
    return started;
}

void mr_stop(void) {
    if (!runningDevices) return;
    CFIndex total = CFArrayGetCount(runningDevices);
    for (CFIndex i = 0; i < total; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(runningDevices, i);
        if (pMTUnregisterContactFrameCallback) pMTUnregisterContactFrameCallback(dev, frame_trampoline);
        pMTDeviceStop(dev);
    }
    // The list is intentionally not released: releasing stopped MTDevices has been known to
    // crash inside MultitouchSupport, and this only happens on wake / reconnect.
    runningDevices = NULL;
}

int mr_device_count(int include_external, int include_mouse) {
    if (!load_multitouch()) return 0;
    CFMutableArrayRef list = pMTDeviceCreateList();
    if (!list) return 0;
    int count = 0;
    CFIndex total = CFArrayGetCount(list);
    for (CFIndex i = 0; i < total; i++) {
        if (wanted((MTDeviceRef)CFArrayGetValueAtIndex(list, i), include_external, include_mouse)) count++;
    }
    CFRelease(list);
    return count;
}

// MARK: - Haptics

#define MR_MAX_ACTUATORS 8

static struct { uint64_t deviceID; CFTypeRef actuator; } actuators[MR_MAX_ACTUATORS];
static int actuatorCount = 0;

static CFTypeRef actuator_for(uint64_t deviceID) {
    static CFTypeRef (*create)(uint64_t) = NULL;
    static IOReturn (*open_)(CFTypeRef) = NULL;
    static int resolved = 0;
    if (!resolved) {
        resolved = 1;
        if (load_multitouch()) {
            void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
            create = dlsym(h, "MTActuatorCreateFromDeviceID");
            open_ = dlsym(h, "MTActuatorOpen");
        }
    }
    for (int i = 0; i < actuatorCount; i++) {
        if (actuators[i].deviceID == deviceID) return actuators[i].actuator;
    }
    if (!create || !open_ || actuatorCount >= MR_MAX_ACTUATORS) return NULL;

    CFTypeRef actuator = create(deviceID);
    if (actuator && open_(actuator) != 0) {
        CFRelease(actuator);
        actuator = NULL;
    }
    // Cache misses too (as NULL), so devices without a motor, like the Magic Mouse, aren't retried every tick.
    actuators[actuatorCount].deviceID = deviceID;
    actuators[actuatorCount].actuator = actuator;
    actuatorCount++;
    return actuator;
}

int mr_actuate(uint64_t device_id, int32_t actuation_id) {
    static IOReturn (*actuate)(CFTypeRef, int32_t, uint32_t, float, float) = NULL;
    static int resolved = 0;
    if (!resolved) {
        resolved = 1;
        void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
        if (h) actuate = dlsym(h, "MTActuatorActuate");
    }
    CFTypeRef actuator = actuator_for(device_id);
    if (!actuate || !actuator) return -1;
    return actuate(actuator, actuation_id, 0, 0.0f, 0.0f);
}

// MARK: - Cursor

typedef int CGSConnectionID;

void mr_allow_background_cursor_control(void) {
    CGSConnectionID (*defaultConnection)(void) = dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
    CGError (*setProperty)(CGSConnectionID, CGSConnectionID, CFStringRef, CFTypeRef) =
        dlsym(RTLD_DEFAULT, "CGSSetConnectionProperty");
    if (!defaultConnection || !setProperty) return;
    CGSConnectionID cid = defaultConnection();
    setProperty(cid, cid, CFSTR("SetsCursorInBackground"), kCFBooleanTrue);
}

// MARK: - Brightness

static int (*pGetBrightness)(CGDirectDisplayID, float *) = NULL;
static int (*pSetBrightness)(CGDirectDisplayID, float) = NULL;

static void load_display_services(void) {
    static int tried = 0;
    if (tried) return;
    tried = 1;
    void *h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
    if (!h) return;
    pGetBrightness = dlsym(h, "DisplayServicesGetBrightness");
    pSetBrightness = dlsym(h, "DisplayServicesSetBrightness");
}

// Prefer the built-in panel; fall back to the main display.
static CGDirectDisplayID brightness_display(void) {
    CGDirectDisplayID displays[16];
    uint32_t n = 0;
    CGGetOnlineDisplayList(16, displays, &n);
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayIsBuiltin(displays[i])) return displays[i];
    }
    return CGMainDisplayID();
}

int mr_get_brightness(float *out) {
    load_display_services();
    if (!pGetBrightness) return -1;
    return pGetBrightness(brightness_display(), out);
}

int mr_set_brightness(float value) {
    load_display_services();
    if (!pSetBrightness) return -1;
    return pSetBrightness(brightness_display(), value);
}
