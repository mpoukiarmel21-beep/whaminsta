#import "IVPaths.h"
#import "IVDiagnostics.h"
#import <stdlib.h>

static NSString *gRealHome = nil;

// The data-protection class for EVERY control-plane path (control dir, its
// plists, and each container skeleton dir). Instagram provisions its container
// with com.apple.developer.default-data-protection = NSFileProtectionComplete,
// so anything we create under its sandbox INHERITS Complete by default — which
// means it is UNREADABLE while the device is locked. When iOS relaunches
// Instagram in the background during a lock (push wake / background refresh),
// our constructor's [store load] then fails to read containers.plist/active.plist,
// cannot resolve the active container, and silently degrades to the default
// (real) sandbox — the app comes back on the wrong identity and the container's
// session looks logged out. Downgrading OUR control files (never Instagram's own
// data) to CompleteUntilFirstUserAuthentication makes them readable during any
// post-boot locked relaunch, so the right container is resolved every time. It is
// never stricter than needed: these files hold only container metadata, no secrets
// (credentials live in the keychain, upgraded separately in IVKeychainHook).
//
// A #define (not a `static NSString *const`) because NSFileProtectionType values
// are extern symbols resolved at load time, so a file-scope static initialized
// from one is not a compile-time constant — the macro defers the reference to
// each (in-function) use site, where it is legal.
#define kIVFileProtection NSFileProtectionCompleteUntilFirstUserAuthentication

// Best-effort: stamp `path` with kIVFileProtection. Logs on failure but never
// aborts — a relaunch on the wrong protection class is a soft degrade, not a
// crash, and blocking here would be worse than the leak it guards.
static void IVApplyProtection(NSString *path) {
    if (!path.length) return;
    NSError *err = nil;
    if (![[NSFileManager defaultManager]
            setAttributes:@{ NSFileProtectionKey: kIVFileProtection }
             ofItemAtPath:path error:&err]) {
        IVErr(@"file-protection set failed at %@: %@", path, err);
    }
}

@implementation IVPaths

+ (void)captureRealHome {
    if (gRealHome) return;
    // Capture the REAL sandbox home before any CFFIXED_USER_HOME/HOME setenv.
    // Prefer the POSIX env var: reading getenv("HOME") does NOT prime
    // CoreFoundation's cached home directory (memoized on first resolution), so
    // a later CFFIXED_USER_HOME redirect is still honored. NSHomeDirectory() is
    // only the fallback because that call can seed the very cache we must avoid.
    const char *envHome = getenv("HOME");
    if (envHome && *envHome) {
        gRealHome = [[NSString stringWithUTF8String:envHome] copy];
    } else {
        gRealHome = [NSHomeDirectory() copy];
    }
    if (gRealHome.length) {
        // Persist for any code (or subprocess) that needs the real home after
        // the redirect — mirrors iCTK's ORIGINAL_HOME_PATH.
        setenv("ORIGINAL_HOME_PATH", gRealHome.UTF8String, 1);
    }
}

+ (NSString *)realHome {
    if (gRealHome.length) return gRealHome;
    const char *orig = getenv("ORIGINAL_HOME_PATH");
    if (orig && *orig) return [NSString stringWithUTF8String:orig];
    return NSHomeDirectory();   // last resort
}

+ (NSString *)controlDir {
    NSString *dir = [[[self realHome] stringByAppendingPathComponent:@"Documents"]
                        stringByAppendingPathComponent:@"whaminsta"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        NSError *err = nil;
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                            attributes:@{ NSFileProtectionKey: kIVFileProtection } error:&err]) {
            IVErr(@"controlDir create failed: %@", err);
        }
    } else {
        // Migration: a dir created before this fix inherited Complete — re-stamp it
        // so an already-installed user's control plane becomes lock-readable too.
        IVApplyProtection(dir);
    }
    return dir;
}

+ (NSString *)containersFile {
    return [[self controlDir] stringByAppendingPathComponent:@"containers.plist"];
}

+ (NSString *)activeFile {
    return [[self controlDir] stringByAppendingPathComponent:@"active.plist"];
}

+ (NSString *)containerRootForCID:(NSString *)cid {
    return [[[[self realHome] stringByAppendingPathComponent:@"Documents"]
                stringByAppendingPathComponent:@"Instances"]
                stringByAppendingPathComponent:cid];
}

+ (BOOL)ensureSkeletonAtRoot:(NSString *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *subdirs = @[ @"Documents",
                                      @"Library",
                                      @"Library/Caches",
                                      @"Library/Preferences",
                                      @"tmp" ];
    for (NSString *sub in subdirs) {
        NSString *path = [root stringByAppendingPathComponent:sub];
        if ([fm fileExistsAtPath:path]) { IVApplyProtection(path); continue; }
        NSError *err = nil;
        if (![fm createDirectoryAtPath:path withIntermediateDirectories:YES
                            attributes:@{ NSFileProtectionKey: kIVFileProtection } error:&err]) {
            IVErr(@"skeleton create failed at %@: %@", path, err);
            return NO;
        }
    }
    return YES;
}

+ (void)reapplyProtectionRecursivelyAtRoot:(NSString *)root {
    if (!root.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:root]) return;

    // Re-stamp the root itself, then walk the whole subtree. NSDirectoryEnumerator
    // yields relative sub-paths lazily (no giant in-memory array) and we skip its
    // per-item attribute prefetch — we only need the path, and we setAttributes
    // regardless of the current class. Best-effort: each failure is logged, never
    // aborts, so one unreadable item can't stop the rest of the session data from
    // being downgraded to lock-readable.
    IVApplyProtection(root);

    NSDirectoryEnumerator *en =
        [fm enumeratorAtURL:[NSURL fileURLWithPath:root isDirectory:YES]
 includingPropertiesForKeys:nil
                    options:0
               errorHandler:^BOOL(NSURL *url, NSError *err) {
                   IVErr(@"protection walk error at %@: %@", url.path, err);
                   return YES;   // keep going past an unreadable node
               }];
    NSUInteger stamped = 0;
    for (NSURL *url in en) {
        NSError *err = nil;
        if ([fm setAttributes:@{ NSFileProtectionKey: kIVFileProtection }
                 ofItemAtPath:url.path error:&err]) {
            stamped++;
        } else {
            IVErr(@"protection re-stamp failed at %@: %@", url.path, err);
        }
    }
    IVLog(@"reapplied protection to %lu item(s) under %@",
          (unsigned long)stamped, root.lastPathComponent);
}

+ (BOOL)wipeRealSessionFiles {
    NSString *realHome = [self realHome];
    if (!realHome.length) return YES;
    NSString *lib = [realHome stringByAppendingPathComponent:@"Library"];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL ok = YES;

    // The default/real account's login persists across these Library sub-trees.
    // We remove each whole dir (iOS recreates them empty on demand). The control
    // plane (Documents/whaminsta) and every container (Documents/Instances/<cid>)
    // live under Documents, disjoint from Library, so they are never touched.
    //   - Cookies / HTTPStorages / WebKit: HTTP + WebKit session state.
    //   - Caches: NSURLCache + image/profile caches. The user asked reset to clear
    //     "la totalité du cash"; a stale Caches can also re-seed a logged-in view.
    //   - Application Support: Instagram's local account DB (SQLite) — the most likely
    //     home of the "still logged in" record, which cookies alone never cleared
    //     (the "compte ne disparaît pas toujours" report).
    NSArray<NSString *> *sessionDirs =
        @[ @"Cookies", @"HTTPStorages", @"WebKit", @"Caches", @"Application Support" ];
    for (NSString *sub in sessionDirs) {
        NSString *path = [lib stringByAppendingPathComponent:sub];
        if (![fm fileExistsAtPath:path]) continue;
        NSError *err = nil;
        if (![fm removeItemAtPath:path error:&err]) {
            IVErr(@"wipeRealSessionFiles: failed to remove %@: %@", path, err);
            ok = NO;
        }
    }

    // NSUserDefaults / CFPreferences domains. Instagram keeps session flags and login
    // tokens here; the live cfprefsd cache is flushed separately in resetAll via
    // removePersistentDomainForName:, but the on-disk plists must go too so a reset
    // run from INSIDE a container (where the live API is redirected to the
    // container) still clears the real account. In Instagram's own sandbox the
    // Preferences dir only holds Instagram's domains plus Apple/system ones, so we
    // remove every top-level *.plist EXCEPT com.apple.* and .GlobalPreferences.
    NSString *prefs = [lib stringByAppendingPathComponent:@"Preferences"];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:prefs error:NULL];
    for (NSString *name in entries) {
        if (![name.pathExtension isEqualToString:@"plist"]) continue;
        if ([name hasPrefix:@"com.apple."]) continue;
        if ([name hasPrefix:@".GlobalPreferences"]) continue;
        NSError *err = nil;
        if (![fm removeItemAtPath:[prefs stringByAppendingPathComponent:name] error:&err]) {
            IVErr(@"wipeRealSessionFiles: failed to remove pref %@: %@", name, err);
            ok = NO;
        }
    }

    IVLog(@"wipeRealSessionFiles: real session surfaces %@", ok ? @"cleared" : @"PARTIAL (see errors)");
    return ok;
}

#pragma mark - Virtual-camera per-container videos

+ (NSString *)cameraDir {
    NSString *dir = [[self controlDir] stringByAppendingPathComponent:@"Cameras"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:dir]) {
        NSError *err = nil;
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                            attributes:@{ NSFileProtectionKey: kIVFileProtection } error:&err]) {
            IVErr(@"cameraDir create failed: %@", err);
        }
    } else {
        IVApplyProtection(dir);
    }
    return dir;
}

+ (NSString *)cameraVideoPathForCID:(NSString *)cid {
    if (!cid.length) return nil;
    NSString *file = [cid stringByAppendingPathExtension:@"mov"];
    return [[self cameraDir] stringByAppendingPathComponent:file];
}

+ (BOOL)importCameraVideoFromURL:(NSURL *)src forCID:(NSString *)cid {
    if (!src || !cid.length) return NO;
    NSString *dst = [self cameraVideoPathForCID:cid];
    if (!dst.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;

    // Replace any existing video atomically-ish: remove the old, then copy the new.
    if ([fm fileExistsAtPath:dst]) {
        if (![fm removeItemAtPath:dst error:&err]) {
            IVErr(@"importCameraVideo: failed to remove existing %@: %@", dst, err);
            return NO;
        }
    }
    // The picker's file representation URL is valid only during the completion
    // block, so this MUST run synchronously there. copyItemAtURL faithfully
    // duplicates the movie container.
    if (![fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:dst] error:&err]) {
        IVErr(@"importCameraVideo: copy failed %@ -> %@: %@", src.path, dst, err);
        // Leave no partial file behind.
        [fm removeItemAtPath:dst error:NULL];
        return NO;
    }
    IVApplyProtection(dst);
    IVLog(@"importCameraVideo: stored video for %@ (%llu bytes)", cid,
          (unsigned long long)[[fm attributesOfItemAtPath:dst error:NULL] fileSize]);
    return YES;
}

+ (void)removeCameraVideoForCID:(NSString *)cid {
    NSString *dst = [self cameraVideoPathForCID:cid];
    if (!dst.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:dst]) {
        NSError *err = nil;
        if (![fm removeItemAtPath:dst error:&err]) {
            IVErr(@"removeCameraVideo: failed to remove %@: %@", dst, err);
        }
    }
}

#pragma mark - Global virtual-camera video (shared by ALL containers)

+ (NSString *)globalCameraVideoPath {
    return [[self cameraDir] stringByAppendingPathComponent:@"global.mov"];
}

+ (BOOL)hasGlobalCameraVideo {
    NSString *p = [self globalCameraVideoPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    return [fm fileExistsAtPath:p isDirectory:&isDir] && !isDir &&
           [[fm attributesOfItemAtPath:p error:NULL] fileSize] > 0;
}

+ (BOOL)importGlobalCameraVideoFromURL:(NSURL *)src {
    if (!src) return NO;
    NSString *dst = [self globalCameraVideoPath];
    if (!dst.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;

    if ([fm fileExistsAtPath:dst]) {
        if (![fm removeItemAtPath:dst error:&err]) {
            IVErr(@"importGlobalCameraVideo: failed to remove existing %@: %@", dst, err);
            return NO;
        }
    }
    // Picker file URL is valid only during the completion block → copy synchronously.
    if (![fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:dst] error:&err]) {
        IVErr(@"importGlobalCameraVideo: copy failed %@ -> %@: %@", src.path, dst, err);
        [fm removeItemAtPath:dst error:NULL];
        return NO;
    }
    IVApplyProtection(dst);
    IVLog(@"importGlobalCameraVideo: stored global video (%llu bytes)",
          (unsigned long long)[[fm attributesOfItemAtPath:dst error:NULL] fileSize]);
    return YES;
}

+ (void)removeGlobalCameraVideo {
    NSString *dst = [self globalCameraVideoPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:dst]) {
        NSError *err = nil;
        if (![fm removeItemAtPath:dst error:&err]) {
            IVErr(@"removeGlobalCameraVideo: failed to remove %@: %@", dst, err);
        }
    }
}

@end
