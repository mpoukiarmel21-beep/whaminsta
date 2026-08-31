#import "IVDeviceSpoof.h"
#import "IVDeviceIdentity.h"
#import "../Core/IVContainerStore.h"
#import "../Util/IVDiagnostics.h"
#import "../vendor/fishhook/fishhook.h"
#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <sys/sysctl.h>
#import <sys/time.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <errno.h>
#import <string.h>

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

// `nchars` uppercase hex characters from SHA256(cid + tag). Deterministic.
static NSString *IVSeededHex(NSString *cid, NSString *tag, NSUInteger nchars) {
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    IVSeedBytes([NSString stringWithFormat:@"%@|%@", cid, tag], h);
    NSMutableString *s = [NSMutableString stringWithCapacity:nchars];
    for (NSUInteger i = 0; i < nchars; i++) {
        [s appendFormat:@"%1X", h[i % CC_SHA256_DIGEST_LENGTH] >> ((i & 1) ? 0 : 4) & 0xF];
    }
    return s;
}

// A plausible modern-iPhone UDID: 8 hex + '-' + 16 hex (25 chars), e.g.
// "00008120-0011223344556677". Deterministic per cid.
static NSString *IVSeededUDID(NSString *cid) {
    return [NSString stringWithFormat:@"%@-%@",
            IVSeededHex(cid, @"udid-hi", 8), IVSeededHex(cid, @"udid-lo", 16)];
}

#pragma mark - State

static NSString *gSpoofedModel = nil;   // e.g. @"iPhone14,2"
static char *gSpoofedModelC = NULL;     // strdup for C-level hooks
static NSString *gVendorUUID = nil;     // IDFV string
static NSString *gAdvUUID = nil;        // IDFA string

// iOS-version spoof (nil / NULL == report the real OS version untouched).
static NSString *gSpoofedIOSVersion = nil;   // marketing, e.g. @"26.6.1"
static NSString *gSpoofedBuild = nil;        // build,     e.g. @"23G83"
static char *gSpoofedProductVersionC = NULL; // kern.osproductversion
static char *gSpoofedBuildC = NULL;          // kern.osversion

// MobileGestalt spoof (P3) — per-container device identity as libMobileGestalt
// reports it. Populated only for non-default containers, keyed by the exact
// property string Instagram's anti-fraud code queries. Everything not in this
// dictionary passes straight through to the real MGCopyAnswer. ProductType is
// pinned to the SAME model string as hw.machine so the two never disagree (an
// unspoofed ProductType alongside a spoofed hw.machine is itself a tamper tell).
static NSDictionary<NSString *, NSString *> *gGestaltSpoof = nil;

// Saved originals.
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;
static int (*orig_uname)(struct utsname *) = NULL;
static CFPropertyListRef (*orig_MGCopyAnswer)(CFStringRef) = NULL;
static void *(*orig_dlsym)(void *, const char *) = NULL;

// GENUINE libc entry points, resolved via dlsym BEFORE we rebind (so the lookup
// uses the real dlsym). fishhook only writes orig_sysctlbyname/orig_sysctl/
// orig_uname when the corresponding symbol was found in an image's import table;
// if rebind_symbols fails to resolve one, its orig_* stays NULL and a forward
// would call a NULL function pointer (EXC_BAD_ACCESS at launch). These are the
// crash-safe fallback the forwards use when their orig_* was never populated.
static int (*gRealSysctlByName)(const char *, void *, size_t *, void *, size_t) = NULL;
static int (*gRealSysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;
static int (*gRealUname)(struct utsname *) = NULL;

// kern.boottime spoof (P4) — the boot timestamp is a device-GLOBAL constant: every
// app and every container on one physical handset reads the identical value, so an
// unspoofed boottime is a direct "many accounts, one phone" correlation key that
// survives all four storage redirects. We shift it per-cid to a stable earlier
// instant (deterministic, 1..5 days back) so two containers disagree. The paired
// NSProcessInfo.systemUptime swizzle adds the SAME offset to the monotonic uptime,
// keeping (wall_now - boottime) ≈ systemUptime — an inconsistency between the two
// would itself be a tamper tell. Populated only for isolated containers.
static struct timeval gSpoofedBoottime = {0, 0};
static BOOL gHasBoottime = NO;
static NSTimeInterval gUptimeAdd = 0;         // seconds added to the real uptime
static IMP gOrigSystemUptimeIMP = NULL;       // original -[NSProcessInfo systemUptime]

@implementation IVDeviceSpoof

+ (NSString *)effectiveModelForContainer:(IVContainer *)container {
    if (container.deviceModel.length) return container.deviceModel;   // explicit override
    // No explicit model: a UNIQUE per-cid model on the REAL chip family, so two
    // no-model containers (e.g. legacy ones created before per-container seeding)
    // never collide on the same identifier. Stays within the anti-fingerprint
    // constraint (never leaves the real chip family).
    return [IVDeviceIdentity seededModelForCID:container.cid].identifier;
}

#pragma mark - Version parsing

static NSOperatingSystemVersion IVParseOSVersion(NSString *v) {
    NSOperatingSystemVersion o = {0, 0, 0};
    NSArray<NSString *> *p = [(v ?: @"") componentsSeparatedByString:@"."];
    if (p.count > 0) o.majorVersion = [p[0] integerValue];
    if (p.count > 1) o.minorVersion = [p[1] integerValue];
    if (p.count > 2) o.patchVersion = [p[2] integerValue];
    return o;
}

#pragma mark - C-level hooks

static int iv_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    // kern.boottime — a `struct timeval`, NOT a C string, so it gets its own copy
    // path with the same size-query / EINVAL / ENOMEM / memcpy contract as the
    // string keys below. Must precede the string resolution (different value type).
    if (gHasBoottime && name && strcmp(name, "kern.boottime") == 0) {
        size_t need = sizeof(gSpoofedBoottime);
        if (!oldp) { if (oldlenp) *oldlenp = need; return 0; }        // size query
        if (!oldlenp) { errno = EINVAL; return -1; }                 // buffer with no length
        if (*oldlenp < need) { errno = ENOMEM; return -1; }          // caller's buffer too small
        memcpy(oldp, &gSpoofedBoottime, need);
        *oldlenp = need;
        return 0;
    }

    // Resolve the spoofed C string for the requested key (NULL == not spoofed).
    const char *spoof = NULL;
    if (name) {
        if (gSpoofedModelC && strcmp(name, "hw.machine") == 0) {
            spoof = gSpoofedModelC;
        } else if (gSpoofedProductVersionC && strcmp(name, "kern.osproductversion") == 0) {
            spoof = gSpoofedProductVersionC;
        } else if (gSpoofedBuildC && strcmp(name, "kern.osversion") == 0) {
            spoof = gSpoofedBuildC;
        }
    }
    if (spoof) {
        size_t need = strlen(spoof) + 1;
        if (!oldp) { if (oldlenp) *oldlenp = need; return 0; }        // size query
        if (!oldlenp) { errno = EINVAL; return -1; }                 // buffer with no length — copying would overflow
        if (*oldlenp < need) { errno = ENOMEM; return -1; }          // caller's buffer too small
        memcpy(oldp, spoof, need);
        *oldlenp = need;
        return 0;
    }
    if (orig_sysctlbyname) return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (gRealSysctlByName) return gRealSysctlByName(name, oldp, oldlenp, newp, newlen);
    errno = ENOSYS;
    return -1;
}

static int iv_uname(struct utsname *u) {
    int r;
    if (orig_uname) {
        r = orig_uname(u);
    } else if (gRealUname) {
        r = gRealUname(u);
    } else {
        errno = ENOSYS;
        return -1;
    }
    if (r == 0 && gSpoofedModelC && u) {
        strlcpy(u->machine, gSpoofedModelC, sizeof(u->machine));
    }
    return r;
}

// Raw MIB path: sysctl({CTL_HW, HW_MACHINE}) — some fingerprint libraries read
// the model this way instead of the string API. Mirror the hw.machine spoof with
// the same size-query / ENOMEM contract. Only HW_MACHINE is touched: HW_MODEL
// returns the board id (e.g. "D79AP"), a different value we must NOT rewrite to
// the marketing identifier or it would be internally inconsistent.
static int iv_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    // Raw MIB path for kern.boottime: sysctl({CTL_KERN, KERN_BOOTTIME}). Mirrors the
    // sysctlbyname("kern.boottime") struct-timeval spoof so a fingerprint library
    // reading the numeric MIB sees the same shifted boot instant as the string API.
    if (gHasBoottime && name && namelen >= 2 && name[0] == CTL_KERN && name[1] == KERN_BOOTTIME) {
        size_t need = sizeof(gSpoofedBoottime);
        if (!oldp) { if (oldlenp) *oldlenp = need; return 0; }        // size query
        if (!oldlenp) { errno = EINVAL; return -1; }                 // buffer with no length
        if (*oldlenp < need) { errno = ENOMEM; return -1; }          // caller's buffer too small
        memcpy(oldp, &gSpoofedBoottime, need);
        *oldlenp = need;
        return 0;
    }
    if (gSpoofedModelC && name && namelen >= 2 && name[0] == CTL_HW && name[1] == HW_MACHINE) {
        const char *spoof = gSpoofedModelC;
        size_t need = strlen(spoof) + 1;
        if (!oldp) { if (oldlenp) *oldlenp = need; return 0; }        // size query
        if (!oldlenp) { errno = EINVAL; return -1; }                 // buffer with no length
        if (*oldlenp < need) { errno = ENOMEM; return -1; }          // caller's buffer too small
        memcpy(oldp, spoof, need);
        *oldlenp = need;
        return 0;
    }
    if (orig_sysctl) return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (gRealSysctl) return gRealSysctl(name, namelen, oldp, oldlenp, newp, newlen);
    errno = ENOSYS;
    return -1;
}

#pragma mark - MobileGestalt hook (P3)

// libMobileGestalt's MGCopyAnswer is THE canonical device-identity oracle: it
// answers UniqueDeviceID, SerialNumber, ProductType, etc. Instagram's anti-fraud
// layer reads it to fingerprint the handset, so two containers that both report
// the real values look like one device with many accounts (the captcha trigger).
// We return per-container deterministic answers for a tight identity whitelist and
// pass everything else through untouched. Returned values are +1 retained
// (CFBridgingRetain), honoring the "Copy" ownership contract the caller expects.
static CFPropertyListRef iv_MGCopyAnswer(CFStringRef property) {
    if (property && gGestaltSpoof) {
        NSString *key = (__bridge NSString *)property;
        NSString *val = gGestaltSpoof[key];
        if (val) return (CFPropertyListRef)CFBridgingRetain(val);
    }
    if (orig_MGCopyAnswer) return orig_MGCopyAnswer(property);
    return NULL;
}

// Many apps resolve MGCopyAnswer at runtime via dlsym (the symbol is private, so
// it is rarely bound statically). fishhook can only rebind statically-bound
// imports, so we ALSO intercept dlsym and hand back our replacement whenever the
// exact "MGCopyAnswer" symbol is requested. Every other lookup — including the
// multi-argument "MGCopyAnswerWithError" (a different ABI we must never alias to
// our 1-arg function) — passes straight through to the real dlsym.
static void *iv_dlsym(void *handle, const char *symbol) {
    if (symbol && strcmp(symbol, "MGCopyAnswer") == 0 && orig_MGCopyAnswer) {
        return (void *)iv_MGCopyAnswer;
    }
    return orig_dlsym ? orig_dlsym(handle, symbol) : NULL;
}

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

static void IVSwizzleReturningString(Class cls, SEL sel, NSString *(^str)(void)) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP imp = imp_implementationWithBlock(^NSString *(id _self) { return str(); });
    method_setImplementation(m, imp);
}

// Install the coordinated iOS-version surfaces. Only called when the container
// pins a version AND we can resolve its real build number — so the three OS-level
// answers (marketing version, struct, build) always agree.
static void IVInstallIOSVersionSpoof(void) {
    if (gSpoofedIOSVersion.length == 0) return;

    // UIDevice.systemVersion -> marketing string.
    IVSwizzleReturningString([UIDevice class], @selector(systemVersion),
                             ^NSString *{ return gSpoofedIOSVersion; });

    // NSProcessInfo.operatingSystemVersionString -> Apple's "Version X (Build Y)".
    IVSwizzleReturningString([NSProcessInfo class], @selector(operatingSystemVersionString),
                             ^NSString *{
        return [NSString stringWithFormat:@"Version %@ (Build %@)",
                gSpoofedIOSVersion, gSpoofedBuild ?: @""];
    });

    // NSProcessInfo.operatingSystemVersion -> struct parsed from the marketing string.
    Method mv = class_getInstanceMethod([NSProcessInfo class], @selector(operatingSystemVersion));
    if (mv) {
        IMP imp = imp_implementationWithBlock(^NSOperatingSystemVersion(id _self) {
            return IVParseOSVersion(gSpoofedIOSVersion);
        });
        method_setImplementation(mv, imp);
    }
}

#pragma mark - Boot time spoof (P4)

// Swizzled -[NSProcessInfo systemUptime]: the real uptime plus the per-cid offset,
// so (wall_clock_now - spoofed_boottime) and systemUptime stay in agreement. A
// disagreement between the two clocks would itself be a tamper tell. Falls back to
// the raw uptime (offset 0) if the original IMP was never captured.
static NSTimeInterval iv_systemUptime(id self, SEL _cmd) {
    NSTimeInterval orig = gOrigSystemUptimeIMP
        ? ((NSTimeInterval (*)(id, SEL))gOrigSystemUptimeIMP)(self, _cmd)
        : 0;
    return orig + gUptimeAdd;
}

// Capture the REAL boot time, then shift it a stable per-cid amount into the past
// (1..5 days) and enable the spoof, bumping systemUptime by the same amount.
// MUST be called BEFORE the fishhook rebind: sysctlbyname here has to reach the
// genuine libc entry, not iv_sysctlbyname, or the read would recurse / self-spoof.
static void IVInstallBoottimeSpoof(NSString *cid) {
    struct timeval real = {0, 0};
    size_t len = sizeof(real);
    if (sysctlbyname("kern.boottime", &real, &len, NULL, 0) != 0 || real.tv_sec == 0) {
        return;  // couldn't read the real boot time — leave boottime untouched
    }

    // Deterministic 1..5 day backward shift from SHA256(cid | "boottime-offset").
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    IVSeedBytes([NSString stringWithFormat:@"%@|boottime-offset", cid ?: @""], h);
    uint32_t raw = ((uint32_t)h[0] << 24) | ((uint32_t)h[1] << 16) |
                   ((uint32_t)h[2] << 8)  |  (uint32_t)h[3];
    NSTimeInterval offset = (NSTimeInterval)(raw % 432000);   // 0 .. 5 days (seconds)
    if (offset < 86400) offset += 86400;                      // force ≥ 1 day back

    gSpoofedBoottime = real;
    gSpoofedBoottime.tv_sec = real.tv_sec - (time_t)offset;   // boot instant, earlier
    gUptimeAdd = offset;                                      // uptime grows to match
    gHasBoottime = YES;

    Method m = class_getInstanceMethod([NSProcessInfo class], @selector(systemUptime));
    if (m) {
        IMP prev = method_setImplementation(m, (IMP)iv_systemUptime);
        if (!gOrigSystemUptimeIMP) gOrigSystemUptimeIMP = prev;  // never capture our thunk
    }
}

#pragma mark - Install

+ (void)installForContainer:(IVContainer *)container {
    if (!container || container.isDefault) {
        IVLog(@"DeviceSpoof: default container — no spoofing");
        return;
    }

    gSpoofedModel = [self effectiveModelForContainer:container];
    if (gSpoofedModelC) { free(gSpoofedModelC); gSpoofedModelC = NULL; }
    gSpoofedModelC = strdup(gSpoofedModel.UTF8String);
    gVendorUUID = [IVSeededUUID(container.cid, @"idfv").UUIDString copy];
    gAdvUUID = [IVSeededUUID(container.cid, @"idfa").UUIDString copy];

    // Per-cid kern.boottime shift (P4). Installed here — BEFORE the fishhook rebind
    // below — so its internal sysctlbyname("kern.boottime") read reaches the real
    // libc entry and captures the genuine boot instant, not our own hook.
    IVInstallBoottimeSpoof(container.cid);

    // MobileGestalt identity whitelist (P3). ProductType MUST equal the spoofed
    // hw.machine model, or the two disagree and betray the spoof. SerialNumber is
    // sourced from IVDeviceIdentity — the SAME value the device-info sheet shows
    // the user — so a container's serial is identical wherever it surfaces (one
    // container == one phone). ProductVersion/BuildVersion are added below only
    // when the OS version is actually spoofed, keeping MobileGestalt consistent
    // with the kern.os* sysctl answers.
    NSMutableDictionary<NSString *, NSString *> *gestalt = [NSMutableDictionary dictionaryWithDictionary:@{
        @"UniqueDeviceID": IVSeededUDID(container.cid),
        @"SerialNumber":   [IVDeviceIdentity serialForCID:container.cid],
        @"ProductType":    gSpoofedModel ?: @"",
    }];

    // iOS version — only when the container pins one AND its build resolves, so
    // kern.osproductversion / kern.osversion / UIDevice / NSProcessInfo agree.
    if (container.iosVersion.length) {
        NSString *build = [IVDeviceIdentity buildForIOSVersion:container.iosVersion];
        if (build.length) {
            gSpoofedIOSVersion = [container.iosVersion copy];
            gSpoofedBuild = [build copy];
            if (gSpoofedProductVersionC) { free(gSpoofedProductVersionC); gSpoofedProductVersionC = NULL; }
            if (gSpoofedBuildC) { free(gSpoofedBuildC); gSpoofedBuildC = NULL; }
            gSpoofedProductVersionC = strdup(gSpoofedIOSVersion.UTF8String);
            gSpoofedBuildC = strdup(gSpoofedBuild.UTF8String);
        } else {
            IVErr(@"DeviceSpoof: no build number for iOS %@ — leaving OS version real", container.iosVersion);
        }
    }

    // Mirror the resolved OS version into MobileGestalt so ProductVersion/
    // BuildVersion never contradict the sysctl kern.os* spoof. Left untouched
    // (real passthrough) when the container pins no version.
    if (gSpoofedIOSVersion.length) {
        gestalt[@"ProductVersion"] = gSpoofedIOSVersion;
        if (gSpoofedBuild.length) gestalt[@"BuildVersion"] = gSpoofedBuild;
    }
    gGestaltSpoof = [gestalt copy];

    // IDFV — every app on a device shares one, so per-container is plausible.
    IVSwizzleReturningUUID([UIDevice class], @selector(identifierForVendor), ^NSString *{ return gVendorUUID; });

    // IDFA — ASIdentifierManager may be absent; look it up dynamically.
    // NB: `asm` is a reserved keyword in clang's GNU dialect (inline assembly),
    // so the class variable MUST NOT be named `asm` — it fails to compile.
    Class asmCls = NSClassFromString(@"ASIdentifierManager");
    IVSwizzleReturningUUID(asmCls, NSSelectorFromString(@"advertisingIdentifier"), ^NSString *{ return gAdvUUID; });

    // iOS-version ObjC surfaces (no-op when unset above).
    IVInstallIOSVersionSpoof();

    // Resolve the REAL MGCopyAnswer BEFORE rebinding dlsym (so this lookup uses
    // the genuine dlsym, not our interceptor). libMobileGestalt is loaded by
    // UIKit in every UI process, so RTLD_DEFAULT finds it; fall back to an
    // explicit dlopen if the shared-cache search misses.
    orig_MGCopyAnswer = (CFPropertyListRef (*)(CFStringRef))dlsym(RTLD_DEFAULT, "MGCopyAnswer");
    if (!orig_MGCopyAnswer) {
        void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (mg) orig_MGCopyAnswer = (CFPropertyListRef (*)(CFStringRef))dlsym(mg, "MGCopyAnswer");
    }

    // Resolve the GENUINE libc entry points BEFORE the rebind below (dlsym is not
    // yet intercepted here, so these return the real functions). If rebind_symbols
    // fails to bind one of these symbols, its orig_* stays NULL; the forwards fall
    // back to these so a launch-time lookup can never jump to a NULL pointer.
    gRealSysctlByName = (int (*)(const char *, void *, size_t *, void *, size_t))dlsym(RTLD_DEFAULT, "sysctlbyname");
    gRealSysctl       = (int (*)(int *, u_int, void *, size_t *, void *, size_t))dlsym(RTLD_DEFAULT, "sysctl");
    gRealUname        = (int (*)(struct utsname *))dlsym(RTLD_DEFAULT, "uname");

    // hw.machine (+ kern.os* when set) via sysctlbyname + sysctl (raw MIB) + uname,
    // plus MobileGestalt: rebind the bound MGCopyAnswer import AND intercept dlsym
    // to cover the (common) runtime-resolved path. Only wired when the real
    // MGCopyAnswer resolved, so a miss degrades to no MobileGestalt spoof rather
    // than a NULL-forward crash.
    struct rebinding r[] = {
        {"sysctlbyname", (void *)iv_sysctlbyname, (void **)&orig_sysctlbyname},
        {"sysctl",       (void *)iv_sysctl,       (void **)&orig_sysctl},
        {"uname",        (void *)iv_uname,        (void **)&orig_uname},
        {"MGCopyAnswer", (void *)iv_MGCopyAnswer, (void **)&orig_MGCopyAnswer},
        {"dlsym",        (void *)iv_dlsym,        (void **)&orig_dlsym},
    };
    // Drop the MobileGestalt pair if we could not resolve the original.
    unsigned count = orig_MGCopyAnswer ? (sizeof(r) / sizeof(r[0])) : 3;
    int rc = rebind_symbols(r, count);
    if (rc != 0) {
        IVErr(@"DeviceSpoof: rebind_symbols rc=%d (missing symbol?) — sysctl/uname forwards fall back to real libc, device spoof degraded", rc);
    }
    IVLog(@"DeviceSpoof: model=%@ ios=%@ (build %@) idfv=%@ udid=%@ mg=%d boot=%d(-%.1fd) rc=%d",
          gSpoofedModel, gSpoofedIOSVersion ?: @"real", gSpoofedBuild ?: @"-",
          gVendorUUID, gGestaltSpoof[@"UniqueDeviceID"], (orig_MGCopyAnswer != NULL),
          gHasBoottime, gUptimeAdd / 86400.0, rc);
}

@end
