// Reads the Siri Remote touch surface through the private MultitouchSupport framework.
// macOS presents the 1st-gen remote's glass surface as a multitouch device, the same way it
// presents a trackpad. The framework is loaded with dlopen and every symbol is checked, so
// a future macOS that changes it makes touch unavailable instead of crashing.
//
// Contact layout and sensor signatures follow VibeRemote (MIT, github.com/mengdream/VibeRemote).

#include "include/CMultitouch.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>

typedef struct { float x, y; } SMPoint;
typedef struct { SMPoint position, velocity; } SMVector;
typedef struct {
    int32_t frame; double timestamp; int32_t pathIndex; uint32_t state;
    int32_t fingerID, handID; SMVector normalized; float zTotal; int32_t field9;
    float angle, majorAxis, minorAxis; SMVector absolute; int32_t field14, field15;
    float zDensity;
} SMContact;
_Static_assert(offsetof(SMContact, normalized) == 32 && sizeof(SMContact) == 96, "Unexpected contact ABI");

typedef int (*SMFrameCallback)(void *, SMContact *, int, double, int, void *);

static void *framework;
static CFArrayRef (*createList)(void);
static int (*deviceStart)(void *, int);
static void (*deviceStop)(void *);
// Returns a one-byte bool: on x86_64 the rest of the return register is garbage, so it must
// not be declared as int.
static bool (*isBuiltIn)(void *);
static void (*sensorDimensions)(void *, int *, int *);
static void (*surfaceDimensions)(void *, int *, int *);
static int (*familyID)(void *, int *);
static void (*registerCallback)(void *, SMFrameCallback, void *);
static void (*unregisterCallback)(void *, SMFrameCallback);

static void *devices[8];
static int deviceCount;
static _Atomic(SMTouchCallback) sink;

static int onFrame(void *device, SMContact *contacts, int count, double time, int sequence, void *context) {
    (void)sequence; (void)context;
    SMTouchCallback callback = atomic_load(&sink);
    if (!callback || count < 0 || count > 16) return 0;
    int active = 0; float x = 0, y = 0;
    for (int i = 0; i < count; i++) {
        SMContact *c = &contacts[i];
        // States 3...5 are touching / making contact / lingering on the surface.
        if (c->state < 3 || c->state > 5) continue;
        float cx = c->normalized.position.x, cy = c->normalized.position.y;
        if (!isfinite(cx) || !isfinite(cy) || cx < 0 || cx > 1 || cy < 0 || cy > 1) continue;
        x += cx; y += cy; active++;
    }
    callback((uint64_t)(uintptr_t)device, active, active ? x / active : 0, active ? y / active : 0, time);
    return 0;
}

void sm_touch_stop(void) {
    atomic_store(&sink, NULL);
    for (int i = 0; i < deviceCount; i++) {
        deviceStop(devices[i]);
        unregisterCallback(devices[i], onFrame);
        CFRelease(devices[i]);
    }
    deviceCount = 0;
}

int sm_touch_start(SMTouchCallback callback) {
    sm_touch_stop();
    if (!framework) {
        framework = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
                           RTLD_LOCAL | RTLD_LAZY);
        if (!framework) return -1;
#define LOAD(variable, symbol) variable = dlsym(framework, symbol)
        LOAD(createList, "MTDeviceCreateList");
        LOAD(deviceStart, "MTDeviceStart");
        LOAD(deviceStop, "MTDeviceStop");
        LOAD(isBuiltIn, "MTDeviceIsBuiltIn");
        LOAD(sensorDimensions, "MTDeviceGetSensorDimensions");
        LOAD(surfaceDimensions, "MTDeviceGetSensorSurfaceDimensions");
        LOAD(familyID, "MTDeviceGetFamilyID");
        LOAD(registerCallback, "MTRegisterContactFrameCallbackWithRefcon");
        LOAD(unregisterCallback, "MTUnregisterContactFrameCallback");
#undef LOAD
    }
    if (!createList || !deviceStart || !deviceStop || !isBuiltIn || !sensorDimensions ||
        !surfaceDimensions || !registerCallback || !unregisterCallback) return -1;

    CFArrayRef list = createList();
    if (!list) return 0;
    atomic_store(&sink, callback);
    for (CFIndex i = 0; i < CFArrayGetCount(list) && deviceCount < 8; i++) {
        void *device = (void *)CFArrayGetValueAtIndex(list, i);
        if (isBuiltIn(device)) continue;
        int rows = 0, columns = 0, width = 0, height = 0;
        int family = 0;
        sensorDimensions(device, &rows, &columns);
        surfaceDimensions(device, &width, &height);
        if (familyID) familyID(device, &family);
        // Known Siri Remote sensor signatures; never attach to a Magic Trackpad or Magic Mouse.
        // 8x7 / 3460x3640 / family 160 is a 1st-gen remote (product 0x0266) on macOS 27.
        int known = (rows == 6 && columns == 12) || (rows == 12 && columns == 6) ||
                    (width == 2775 && height == 2775) ||
                    (rows == 8 && columns == 7) || (rows == 7 && columns == 8) ||
                    (width == 3460 && height == 3640) || family == 160;
        if (!known) continue;
        CFRetain(device);
        registerCallback(device, onFrame, NULL);
        if (deviceStart(device, 0) == 0) {
            devices[deviceCount++] = device;
        } else {
            unregisterCallback(device, onFrame);
            CFRelease(device);
        }
    }
    CFRelease(list);
    return deviceCount;
}
