#import <Foundation/Foundation.h>
#import "IVContainer.h"

NS_ASSUME_NONNULL_BEGIN

/// Per-container device fingerprint spoofing (plan-directeur §7). Everything is
/// derived deterministically from SHA256(cid) so a container's identity is
/// stable across launches and unique across containers.
///
/// Surfaces answered (all gated on active isolation, no-op for default):
///   • IDFV / IDFA — UIDevice.identifierForVendor + ASIdentifierManager.
///   • UIDevice.name — the owner's own label for the phone, shared by every
///     container and cross-checked by nothing, so it is safe to give each one
///     its own (seeded, natural-looking, stable per cid).
///
/// Deliberately NOT spoofed, and why:
///   • hw.machine / uname / OS-version surfaces (UIDevice.systemVersion,
///     NSProcessInfo.operatingSystemVersion, sysctl kern.osproductversion,
///     kern.osversion, sysctl hw.machine, uname, systemVersion, systemUptime,
///     kern.boottime) — REMOVED in build-15 when aligning on InstaVault's proven
///     minimal hook set. Reporting a model or a version the panel's settings do
///     not actually match is an internal-consistency tell, and it was the class
///     of hook implicated in the pre-build-15 signup crash. The device reports
///     its real model and real OS, consistently.
///   • hw.model board-id (unverified board IDs are a fresh inconsistency tell)
///   • UIScreen scale/bounds (mismatch would break layout on the real panel)
///   • battery / fonts / chip (physical or unverifiable from userspace)
/// See IVDeviceIdentity.h — serial/model number are display-only.
///
/// Honest scope: this masks locally-readable identifiers only. Instagram binds
/// accounts to its OWN stored tokens (device_id, phone_id, X-MID, sessionid),
/// which are isolated by the HOME + keychain + CFPreferences redirects, not by
/// hardware spoofing.
@interface IVDeviceSpoof : NSObject

/// Install the IDFV/IDFA swizzles + the per-container device name for the given
/// container. No-op for the default container. Run once at launch.
+ (void)installForContainer:(IVContainer *)container;

/// The device model identifier this container presents (explicit override, or
/// the newest model in the real chip family when unset).
+ (NSString *)effectiveModelForContainer:(IVContainer *)container;

@end

NS_ASSUME_NONNULL_END
