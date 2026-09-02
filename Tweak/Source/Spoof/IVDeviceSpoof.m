#import "IVDeviceSpoof.h"
#import "IVDeviceIdentity.h"
#import "../Core/IVContainerStore.h"
#import "../Util/IVDiagnostics.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>

// ============================================================================
// Per-container device identity — the EXACT hook set InstaVault ships (the
// sibling project where Instagram account creation WORKS): IDFV + IDFA
// swizzles ONLY. whaminsta's previous version additionally rebinded
// sysctlbyname/sysctl/uname/MGCopyAnswer/dlsym via fishhook and swizzled
// UIDevice.systemVersion + NSProcessInfo.operatingSystemVersion(+String) +
// systemUptime + kern.boottime — every one of those is ABSENT from InstaVault,
// whose own IVHardwareHook comment documents removing the MobileGestalt hook
// "for stability", and they fired exactly during Instagram's signup
// fingerprinting (the account-name crash). Removed here; the container's
// model/iOS choices remain honored in the panel UI and are still derived
// deterministically per cid (IVDeviceIdentity) for future use.
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

    IVLog(@"DeviceSpoof: idfv=%@ idfa=%@ (InstaVault-aligned minimal hook set)",
          gVendorUUID, gAdvUUID);
}

@end
