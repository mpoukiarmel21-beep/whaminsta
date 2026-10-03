#import "IVLocationSpoof.h"
#import "../Core/IVContainer.h"
#import "../Core/IVContainerStore.h"
#import "../Util/IVDiagnostics.h"
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

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

// Delivery guard.
//
// build-14 guarded the fake-fix path with a 0.5s time-based rate limit. That
// stopped the signup recursion, but it introduced a HANG: Instagram asks for
// location with -startUpdatingLocation and -requestLocation back-to-back while
// validating the signup NAME, so the second call landed inside the window and
// its callback was simply thrown away. The caller then waits forever on a
// callback that will never arrive — the app sits on a spinner at the name field.
//
// A DEPTH guard replaces it. It blocks only genuine re-entrancy (a delegate
// that restarts updates from inside -locationManager:didUpdateLocations:),
// which is the only shape that can actually recurse. Every fresh, independent
// request is always given a callback — a request is never silently dropped.
static BOOL gInDelivery = NO;

// Delivers ONE synthetic fix to the manager's delegate. Called synchronously
// when already on the main thread (CLLocationManager's delegate contract) so
// the depth guard spans the whole nested call, and hops to main only when the
// hook was entered off-main.
static void IVDeliverFakeOnce(CLLocationManager *mgr) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ IVDeliverFakeOnce(mgr); });
        return;
    }
    if (gInDelivery) return;   // re-entrant restart from inside our own delivery

    id<CLLocationManagerDelegate> del = mgr.delegate;
    CLLocation *fake = IVCurrentFakeLocation();
    gInDelivery = YES;
    @try {
        if (fake && [del respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [del locationManager:mgr didUpdateLocations:@[ fake ]];
        } else if ([del respondsToSelector:@selector(locationManager:didFailWithError:)]) {
            // Nothing usable to deliver, but the caller IS waiting on something.
            // Report the benign "location unknown" error so the app's flow can
            // continue instead of spinning forever. Deliberately NOT a fall back
            // to the real -startUpdatingLocation: that would start the device's
            // GPS and leak the true position, defeating the whole point of the
            // container's configured location.
            NSError *err = [NSError errorWithDomain:kCLErrorDomain
                                               code:kCLErrorLocationUnknown
                                           userInfo:nil];
            [del locationManager:mgr didFailWithError:err];
        }
    } @finally {
        gInDelivery = NO;
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
                IVDeliverFakeOnce((CLLocationManager *)_self);
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
                IVDeliverFakeOnce((CLLocationManager *)_self);
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
