#import "IVDeviceSpoof.h"
#import "IVDeviceIdentity.h"
#import "../Core/IVContainerStore.h"
#import "../Util/IVDiagnostics.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>

// ============================================================================
// Per-container device identity — the hook set InstaVault ships (the sibling
// project where Instagram account creation WORKS), plus the device name.
// whaminsta's previous version additionally rebound sysctlbyname/sysctl/uname/
// MGCopyAnswer/dlsym via fishhook and swizzled UIDevice.systemVersion +
// NSProcessInfo.operatingSystemVersion(+String) + systemUptime + kern.boottime
// — every one of those is ABSENT from InstaVault, whose own IVHardwareHook
// comment documents removing the MobileGestalt hook "for stability", and they
// fired exactly during Instagram's signup fingerprinting (the account-name
// crash). Removed here; the container's model/iOS choices remain honored in
// the panel UI and are still derived deterministically per cid
// (IVDeviceIdentity) for future use.
//
// ADDED here: -[UIDevice name]. It carries the same "one phone" signal as IDFV
// but was never covered, and unlike model/OS version it has no counterpart the
// rest of the process must stay consistent with, so answering it per-container
// introduces no contradiction — see IVSeededDeviceName.
// ============================================================================

#pragma mark - Deterministic seed

// 32-byte SHA256(cid). Stable across launches, unique per container.
static void IVSeedBytes(NSString *cid, unsigned char out[CC_SHA256_DIGEST_LENGTH]) {
    NSData *d = [(cid ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256(d.bytes, (CC_LONG)d.length, out);
}

// A stable NSUUID derived from SHA256(cid + tag) — first 16 bytes as the UUID.
static NSUUID *IVSeededUUID(NSString *cid, NSString *tag) {
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    IVSeedBytes([NSString stringWithFormat:@"%@|%@", cid, tag], h);
    return [[NSUUID alloc] initWithUUIDBytes:h];
}

#pragma mark - State

static NSString *gVendorUUID = nil;     // IDFV string
static NSString *gAdvUUID = nil;        // IDFA string

#pragma mark - ObjC swizzle helpers

static void IVSwizzleReturningUUID(Class cls, SEL sel, NSString *(^uuidStr)(void)) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP imp = imp_implementationWithBlock(^NSUUID *(id _self) {
        return [[NSUUID alloc] initWithUUIDString:uuidStr()];
    });
    method_setImplementation(m, imp);
}

// Replace an instance method returning NSString* with a constant provider.
static void IVSwizzleReturningString(Class cls, SEL sel, NSString *(^str)(void)) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP imp = imp_implementationWithBlock(^NSString *(id _self) { return str(); });
    method_setImplementation(m, imp);
}

// Per-container device NAME.
//
// -[UIDevice name] hands back the owner's own label for the phone (e.g.
// "Armel's iPhone") and every container read the SAME string — a free,
// always-available "these accounts sit on one phone" signal. Unlike the model
// and OS version (left REAL deliberately, so they keep agreeing with sysctl /
// NSProcessInfo and never contradict each other), the device name has no
// cross-check surface: nothing else in the process can corroborate it. Seeded
// from the cid, so a container always reports the same name across launches
// and two containers never report the same one.
static NSString *IVSeededDeviceName(NSString *cid) {
    static const char *kPool[] = {
        "Alex's iPhone",  "Sam's iPhone",   "Jordan's iPhone", "Riley's iPhone",
        "Casey's iPhone", "Morgan's iPhone", "Avery's iPhone", "Quinn's iPhone",
        "Jamie's iPhone", "Taylor's iPhone", "Drew's iPhone",  "Skyler's iPhone",
        "Reese's iPhone", "Emerson's iPhone", "Finley's iPhone", "Rowan's iPhone",
    };
    const size_t n = sizeof(kPool) / sizeof(kPool[0]);
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    IVSeedBytes([NSString stringWithFormat:@"%@|devname", cid ?: @""], h);
    return [NSString stringWithUTF8String:kPool[(size_t)h[0] % n]];
}

#pragma mark - Install

@implementation IVDeviceSpoof

+ (NSString *)effectiveModelForContainer:(IVContainer *)container {
    if (container.deviceModel.length) return container.deviceModel;   // explicit override
    // No explicit model: a UNIQUE per-cid model on the REAL chip family, so two
    // no-model containers (e.g. legacy ones created before per-container seeding)
    // never collide on the same identifier. Display-only (panel UI) — the app
    // itself is no longer force-fed a model, matching InstaVault's proven set.
    return [IVDeviceIdentity seededModelForCID:container.cid].identifier;
}

+ (void)installForContainer:(IVContainer *)container {
    if (!container || container.isDefault) {
        IVLog(@"DeviceSpoof: default container — no spoofing");
        return;
    }

    gVendorUUID = [IVSeededUUID(container.cid, @"idfv").UUIDString copy];
    gAdvUUID = [IVSeededUUID(container.cid, @"idfa").UUIDString copy];

    // IDFV — every app on a device shares one, so per-container is plausible.
    IVSwizzleReturningUUID([UIDevice class], @selector(identifierForVendor),
                           ^NSString *{ return gVendorUUID; });

    // IDFA — ASIdentifierManager may be absent; look it up dynamically.
    // NB: `asm` is a reserved keyword in clang's GNU dialect (inline assembly),
    // so the class variable MUST NOT be named `asm` — it fails to compile.
    Class asmCls = NSClassFromString(@"ASIdentifierManager");
    IVSwizzleReturningUUID(asmCls, NSSelectorFromString(@"advertisingIdentifier"),
                           ^NSString *{ return gAdvUUID; });

    // Device name — the one remaining shared string identifier. Model and OS
    // version stay real (see header) for sysctl consistency; the name has no
    // such counterpart to stay consistent with, so it is safe to give each
    // container its own.
    NSString *devName = [IVSeededDeviceName(container.cid) copy];
    IVSwizzleReturningString([UIDevice class], @selector(name),
                             ^NSString *{ return devName; });

    IVLog(@"DeviceSpoof: idfv=%@ idfa=%@ name=%@ (InstaVault-aligned minimal hook set)",
          gVendorUUID, gAdvUUID, devName);
}

@end
