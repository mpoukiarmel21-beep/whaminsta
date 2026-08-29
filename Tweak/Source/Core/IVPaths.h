#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resolves every path whaminsta needs, distinguishing:
///   - realHome     : the app's true sandbox home, captured BEFORE any HOME
///                    redirect (== NSHomeDirectory() at the first line of the
///                    constructor). All shared control files live here.
///   - container root: <realHome>/Documents/Instances/<cid>/  (the redirected
///                    HOME for a non-default container).
///
/// IMPORTANT: after the HOME redirect, NSHomeDirectory() points inside the
/// active container. Never use NSHomeDirectory() to reach the shared control
/// files — always go through +realHome. This is the BUG-01 class of failure.
@interface IVPaths : NSObject

/// Capture the real home. MUST be the first thing the constructor calls,
/// before any setenv. Idempotent.
+ (void)captureRealHome;

/// The true app sandbox home (un-redirected). Falls back to NSHomeDirectory()
/// if capture somehow didn't run.
+ (NSString *)realHome;

/// <realHome>/Documents/whaminsta  (shared control dir; created on demand).
+ (NSString *)controlDir;

/// <realHome>/Documents/whaminsta/containers.plist
+ (NSString *)containersFile;

/// <realHome>/Documents/whaminsta/active.plist
+ (NSString *)activeFile;

/// <realHome>/Documents/Instances/<cid>  (a non-default container's HOME root).
+ (NSString *)containerRootForCID:(NSString *)cid;

/// Create the skeleton dirs (Documents, Library, Library/Caches,
/// Library/Preferences, tmp) under a container root. Returns NO + logs on failure.
+ (BOOL)ensureSkeletonAtRoot:(NSString *)root;

/// Recursively re-stamp every file/dir under `root` to the lock-readable
/// protection class (CompleteUntilFirstUserAuthentication). Instagram writes new
/// session files under an isolated container inheriting NSFileProtectionComplete
/// (unreadable while locked) → a background relaunch during a lock reads them as
/// empty and the container looks logged out. Call this after isolation and on
/// every background transition, on the isolated-container root ONLY — never the
/// real sandbox. Best-effort, never aborts.
+ (void)reapplyProtectionRecursivelyAtRoot:(NSString *)root;

/// Wipe the DEFAULT/real account's on-disk session surfaces —
/// realHome/Library/{Cookies,HTTPStorages,WebKit}. Used by a global reset so the
/// principal account is logged out too, not just the containers. Leaves Caches
/// and the control plane (Documents/whaminsta) untouched. Returns NO if a
/// surface existed but could not be removed.
+ (BOOL)wipeRealSessionFiles;

/// <controlDir>/Cameras  (per-container virtual-camera videos; created on demand,
/// lock-readable). Lives under the shared control dir — OUTSIDE any redirected
/// container HOME — so Instagram never enumerates the video from inside its sandbox.
+ (NSString *)cameraDir;

/// <controlDir>/Cameras/<cid>.mov — the canonical per-container video path fed to
/// the virtual camera. Derived from cid; stable across HOME redirects.
+ (NSString *)cameraVideoPathForCID:(NSString *)cid;

/// Copy `src` (a picker temp URL, valid only synchronously) to the canonical
/// per-cid camera path, replacing any existing video, then stamp it lock-readable.
/// MUST be called synchronously inside the picker completion block. Returns NO +
/// logs on failure (leaves no partial file).
+ (BOOL)importCameraVideoFromURL:(NSURL *)src forCID:(NSString *)cid;

/// Delete the per-cid camera video (no-op if absent). Called when a container is
/// removed or its video is cleared.
+ (void)removeCameraVideoForCID:(NSString *)cid;

#pragma mark - Global virtual-camera video (shared by ALL containers)

/// <controlDir>/Cameras/global.mov — the SINGLE verification video shared by every
/// container. The user asked to "mettre le même système de caméra pour tous les
/// conteneurs" and just swap this one video per account, so the virtual camera is
/// global, not per-cid. Existence of this file IS the "camera configured" state
/// (derived, never a plist flag). Lives under the shared control dir, lock-readable.
+ (NSString *)globalCameraVideoPath;

/// YES iff a readable global verification video is present.
+ (BOOL)hasGlobalCameraVideo;

/// Copy `src` (a picker temp URL, valid only synchronously) to the global video
/// path, replacing any existing one, then stamp it lock-readable. MUST run
/// synchronously inside the picker completion block. Returns NO + logs on failure.
+ (BOOL)importGlobalCameraVideoFromURL:(NSURL *)src;

/// Delete the global verification video (no-op if absent).
+ (void)removeGlobalCameraVideo;

@end

NS_ASSUME_NONNULL_END
