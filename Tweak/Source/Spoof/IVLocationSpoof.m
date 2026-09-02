#import "IVLocationSpoof.h"
#import "../Core/IVContainer.h"
#import "../Core/IVContainerStore.h"
#import "../Util/IVDiagnostics.h"
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <time.h>

// ============================================================================
// Minimal, battle-tested location spoof — the EXACT hook set InstaVault ships
// (the sibling project where Instagram account creation WORKS). whaminsta's
// previous 9-surface version (authorizationStatus synthesis, requestWhenInUse/
// requestAlways interception, CLLocationUpdate, stopUpdatingLocation, and the
// 1s reconcile timer) crashed at the signup name step; every one of those
// extra surfaces is ABSENT from InstaVault and its IVHardwareHook comment
// documents removing similar C-level hooks "for stability". Aligned here:
// only `location`, `startUpdatingLocation` and `requestLocation` are hooked,
// each delivering ONE synthetic fix (main thread) when the active container
// has a location set, and passing through to the real implementation otherwise.
// ============================================================================

#pragma mark - Current fake location (read live from the active container)

// Returns a freshly-synthesized CLLocation at the active container's coordinate,
// or nil when the active container has no location set (real location flows).
static CLLocation *IVCurrentFakeLocation(void) {
    IVContainer *c = [IVContainerStore shared].activeContainer;
    if (!c.hasLocation) return nil;

    CLLocationDegrees lat = c.latitude.doubleValue;
    CLLocationDegrees lng = c.longitude.doubleValue;

    // Sub-meter jitter so successive reads aren't byte-identical (looks alive).
    double jLat = ((double)arc4random_uniform(2000) - 1000.0) / 1.0e8;   // ±~1m
    double jLng = ((double)arc4random_uniform(2000) - 1000.0) / 1.0e8;
    CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(lat + jLat, lng + jLng);

    return [[CLLocation alloc] initWithCoordinate:coord
                                         altitude:12.0
                               horizontalAccuracy:5.0
                                 verticalAccuracy:8.0
                                           course:-1
                                            speed:0
                                        timestamp:[NSDate date]];
}

// Saved originals.
static CLLocation *(*orig_location)(id, SEL) = NULL;
static void (*orig_start)(id, SEL) = NULL;
static void (*orig_request)(id, SEL) = NULL;
static BOOL gInstalled = NO;

// Loop insurance (kept from build-14): a delegate that restarts updates on
// every fix must not be able to drive an unbounded deliver->start->deliver
// loop. InstaVault survives without it, but the floor is invisible when the
// app behaves and costs nothing.
static const void *kIVLastFakeDeliverKey = &kIVLastFakeDeliverKey;

static NSTimeInterval IVMonotonicNow(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (NSTimeInterval)ts.tv_sec + ts.tv_nsec / 1e9;
}

// Deliver ONE synthetic fix to the manager's delegate (main thread, per the
// delegate contract). One-shot per start/request call — no recurring timer.
static void IVDeliverFakeOnce(CLLocationManager *mgr) {
    CLLocation *fake = IVCurrentFakeLocation();
    if (!fake) return;
    NSTimeInterval now = IVMonotonicNow();
    NSNumber *last = objc_getAssociatedObject(mgr, kIVLastFakeDeliverKey);
    if (last && (now - last.doubleValue) < 0.5) return;
    objc_setAssociatedObject(mgr, kIVLastFakeDeliverKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<CLLocationManagerDelegate> del = mgr.delegate;
    if ([del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [del locationManager:mgr didUpdateLocations:@[ fake ]];
    }
}

#pragma mark - Install

@implementation IVLocationSpoof

+ (void)install {
    if (gInstalled) return;
    gInstalled = YES;

    Class mgr = [CLLocationManager class];

    // -location getter: return the fake fix when active, else the real value.
    Method mLoc = class_getInstanceMethod(mgr, @selector(location));
    if (mLoc) {
        orig_location = (CLLocation *(*)(id, SEL))method_getImplementation(mLoc);
        method_setImplementation(mLoc, imp_implementationWithBlock(^CLLocation *(id _self) {
            CLLocation *fake = IVCurrentFakeLocation();
            return fake ?: orig_location(_self, @selector(location));
        }));
    }

    // -startUpdatingLocation: one-shot synthetic fix when faking (the real GPS
    // is never started, so no real coordinates can ever leak); the app keeps
    // receiving genuine fixes whenever it disables the container location.
    Method mStart = class_getInstanceMethod(mgr, @selector(startUpdatingLocation));
    if (mStart) {
        orig_start = (void (*)(id, SEL))method_getImplementation(mStart);
        method_setImplementation(mStart, imp_implementationWithBlock(^(id _self) {
            if ([IVLocationSpoof isActive]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    IVDeliverFakeOnce((CLLocationManager *)_self);
                });
            } else {
                orig_start(_self, @selector(startUpdatingLocation));
            }
        }));
    }

    // -requestLocation: one-shot. When faking, synthesize a single fix and never
    // touch the real GPS; otherwise defer to the real implementation.
    Method mReq = class_getInstanceMethod(mgr, @selector(requestLocation));
    if (mReq) {
        orig_request = (void (*)(id, SEL))method_getImplementation(mReq);
        method_setImplementation(mReq, imp_implementationWithBlock(^(id _self) {
            if ([IVLocationSpoof isActive]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    IVDeliverFakeOnce((CLLocationManager *)_self);
                });
            } else {
                orig_request(_self, @selector(requestLocation));
            }
        }));
    }

    IVLog(@"LocationSpoof installed (location/start/request — InstaVault-aligned minimal set)");
}

+ (BOOL)isActive {
    return [IVContainerStore shared].activeContainer.hasLocation;
}

@end
