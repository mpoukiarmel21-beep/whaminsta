#import <UIKit/UIKit.h>
#import <signal.h>
#import <unistd.h>
#import <execinfo.h>
#import <fcntl.h>
#import <time.h>
#import <string.h>
#import "Core/IVPaths.h"
#import "Core/IVContainer.h"
#import "Core/IVContainerStore.h"
#import "Isolation/IVHomeRedirect.h"
#import "Isolation/IVKeychainHook.h"
#import "Isolation/IVPrefsHook.h"
#import "Isolation/IVAppGroupHook.h"
#import "Isolation/IVHardening.h"
#import "Isolation/IVCameraHook.h"
#import "Spoof/IVDeviceSpoof.h"
#import "Spoof/IVDeviceIdentity.h"
#import "Spoof/IVLocaleSpoof.h"
#import "Spoof/IVLocationSpoof.h"
#import "UI/IVFloatingButton.h"
#import "Util/IVDiagnostics.h"

// The per-container keychain namespace, e.g. "IV:<cid>:". Empty for default.
static NSString *IVKeychainPrefixForContainer(IVContainer *c) {
    if (!c || c.isDefault) return @"";
    return [NSString stringWithFormat:@"IV:%@:", c.cid];
}

// Shows the floating button once the app UI is up. Idempotent; observes
// UIApplicationDidBecomeActive and also fires a delayed fallback. After the
// FIRST presentation we also surface any crash stack captured on the previous
// run (in-app alert, no Files app needed) — deliberately only on the cold-launch
// fallback, never on DidBecomeActive re-fires, so a warm resume never re-alerts.
static void IVScheduleFloatingButton(void) {
    void (^present)(void) = ^{
        [[IVFloatingButton shared] show];
    };
    void (^presentAndReport)(void) = ^{
        [[IVFloatingButton shared] show];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[IVFloatingButton shared] presentPendingCrashReport];
        });
    };
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) { present(); }];
    // Fallback in case the app is already active by the time we get here.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), presentAndReport);
}

// The cid this process actually booted (and applied isolation) for. Set ONCE in
// the constructor to the RESOLVED active cid — even on a degraded boot, so the
// guard below compares against what we ran as, not what we wished we ran as.
static NSString *gBootstrappedCID = nil;

// Backstop for the app-switcher WARM-RESUME leak. The constructor runs exactly
// once per COLD launch, so the HOME/keychain/CFPreferences/App-Group redirects are
// applied only then. If the user switches the active container from the panel, the
// app tries to exit for a clean relaunch — but if it was only SUSPENDED (its card
// was never force-quit from the switcher) and iOS resumes it warm, the constructor
// does NOT re-run: the process keeps the OLD container's redirects while the
// on-disk activeCID now points to the newly chosen one, so the account surfaces on
// the wrong/default identity (exactly "revenu depuis le panel → le compte est
// apparu sur le compte par défaut"). Redirects can't be re-applied mid-process
// (they are one-shot at load), so on every foreground we compare the live
// activeCID to what we booted with and exit(0) on a mismatch; iOS then cold-
// launches us and the constructor applies the correct isolation. Coalesced to the
// default cid on both sides so a degraded boot (running as real/default) does NOT
// exit on every resume — only a genuine container switch trips it.
static void IVInstallStaleContainerGuard(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        NSString *booted  = gBootstrappedCID.length ? gBootstrappedCID : kIVDefaultCID;
        NSString *current = [IVContainerStore shared].activeCID;
        current = current.length ? current : kIVDefaultCID;
        if (![booted isEqualToString:current]) {
            IVLog(@"stale container on resume (booted=%@ now=%@) — exiting for a clean cold relaunch",
                  booted, current);
            exit(0);
        }
    }];
}

// Task C — keep the isolated container's SESSION data lock-readable "for life".
// New files Instagram writes at runtime (cookies, tokens, WebKit/HTTPStorages,
// prefs) inherit NSFileProtectionComplete, which is unreadable once the device
// locks — so hours later a background relaunch can't read the session and the
// account looks logged out. Each time the app backgrounds (the moment fresh
// session files have just been written), re-stamp the whole active-container tree
// down to CompleteUntilFirstUserAuthentication so it survives any post-boot lock.
// Guarded by a background task so iOS grants us the run time before suspending,
// and done off the main thread. Only ever the isolated container root is passed
// in — never Instagram's real sandbox.
static void IVInstallBackgroundReprotect(NSString *containerRoot) {
    if (!containerRoot.length) return;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        UIApplication *app = [UIApplication sharedApplication];
        __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
        task = [app beginBackgroundTaskWithName:@"IVReprotect" expirationHandler:^{
            if (task != UIBackgroundTaskInvalid) { [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid; }
        }];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [IVPaths reapplyProtectionRecursivelyAtRoot:containerRoot];
            if (task != UIBackgroundTaskInvalid) { [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid; }
        });
    }];
}

// Crash capture — the launch/create crashes were invisible because no handler
// dumped a stack. Two layers, both writing under the DIAGNOSTICS log dir (real
// home, readable via the Files app):
//
//  * NSSetUncaughtExceptionHandler — ObjC exceptions. Called with the app still
//    in a usable state, so it can safely write exception name/reason + the full
//    [NSThread callStackSymbols] via the file logger, then chain the prior handler.
//  * Async-signal-safe signal handler — hard crashes (SEGV/ABRT/BUS/ILL/FPE) that
//    can strike inside a swizzled/hooked path. A tiny async-signal-safe path is
//    used (backtrace + backtrace_symbols_fd to a pre-opened fd — no malloc, no
//    ObjC), then the default disposition is restored and the signal re-raised so
//    the OS still terminates us with the real signal.
//
// The install must run AFTER captureRealHome so the log directory resolves to the
// REAL (un-redirected) home — never a per-container sandbox.

static int IVCrashLogFD = -1;
static const int IVCrashSignals[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGSYS };

// Prior uncaught-exception handler, chained after ours. A plain C function
// pointer (NSUncaughtExceptionHandler is a function pointer, NOT a block — a
// block literal fails to compile on modern SDKs).
static NSUncaughtExceptionHandler *IVPriorExceptionHandler = NULL;

// Append a crash entry to the pre-opened crash.log fd. Safe to call from the
// ObjC exception handler (not async-signal context — that is the signal layer).
static void IVAppendCrashEntry(NSString *header, NSString *body) {
    if (IVCrashLogFD < 0) return;
    NSString *entry = [NSString stringWithFormat:@"\n======== %@ ========\n%@\n======== END %@ ========\n",
                       header, body, header];
    NSData *d = [entry dataUsingEncoding:NSUTF8StringEncoding];
    if (d.length) {
        write(IVCrashLogFD, d.bytes, (size_t)d.length);
        fsync(IVCrashLogFD);
    }
}

static void IVExceptionCrashHandler(NSException *ex) {
    NSString *body = [NSString stringWithFormat:
        @"UNCAUGHT EXCEPTION %@: %@\n%@",
        ex.name, ex.reason, [[ex callStackSymbols] componentsJoinedByString:@"\n"]];
    IVAppendCrashEntry(@"CRASH exception", body);
    @autoreleasepool {
        [[IVDiagnostics shared] error:body];
    }
    if (IVPriorExceptionHandler) IVPriorExceptionHandler(ex);
}

static void IVSignalCrashHandler(int signo, siginfo_t *info, void *context) {
    // Strictly async-signal-safe: no malloc, no ObjC, no dprintf/vsnprintf. Build
    // static buffers and write() them, then backtrace_symbols_fd (signal-safe).
    void *frames[128];
    int n = backtrace(frames, (int)(sizeof(frames) / sizeof(frames[0])));
    if (IVCrashLogFD >= 0) {
        char header[160];
        int hlen = snprintf(header, sizeof(header),
                            "\n======== CRASH signal=%d si_code=%d addr=%p time=%lld ========\n",
                            signo, info ? info->si_code : -1,
                            info ? info->si_addr : NULL, (long long)time(NULL));
        if (hlen > 0) { if (hlen >= (int)sizeof(header)) hlen = (int)sizeof(header) - 1; write(IVCrashLogFD, header, (size_t)hlen); }
        backtrace_symbols_fd(frames, n, IVCrashLogFD);
        static const char footer[] = "======== END CRASH ========\n";
        write(IVCrashLogFD, footer, sizeof(footer) - 1);
        fsync(IVCrashLogFD);
    }
    // Restore default and re-raise so the OS still reports the real crash.
    signal(signo, SIG_DFL);
    raise(signo);
}

static void IVInstallCrashLogger(void) {
    // Open the crash log fd ONCE (before any handler runs) so the signal path has a
    // valid fd and never needs to allocate.
    NSString *dir = [[[IVPaths realHome] stringByAppendingPathComponent:@"Documents"]
                        stringByAppendingPathComponent:@"whaminsta/logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *crashPath = [dir stringByAppendingPathComponent:@"crash.log"];
    IVCrashLogFD = open(crashPath.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);

    // Layer 1: ObjC exceptions (safe to write via the file logger). The handler
    // MUST be a C function (NSUncaughtExceptionHandler is a function pointer, not
    // a block) — a block literal is incompatible on the modern SDK.
    IVPriorExceptionHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(IVExceptionCrashHandler);

    // Layer 2: fatal signals (async-signal-safe path only). Run the handler on a
    // dedicated alternate stack: a stack-overflow crash (the exact class the
    // sister INSTA project found at the signup name step) faults on the
    // EXHAUSTED stack, so without sigaltstack the handler itself can't run and
    // NO log is written — the in-app alert then shows nothing and the crash
    // stays invisible. With an altstack the signal is always recorded.
    static char sIVAltStack[256 * 1024];
    stack_t ss;
    ss.ss_sp = sIVAltStack;
    ss.ss_size = sizeof(sIVAltStack);
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = IVSignalCrashHandler;
    sa.sa_flags = SA_SIGINFO | SA_RESETHAND | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    for (size_t i = 0; i < sizeof(IVCrashSignals) / sizeof(IVCrashSignals[0]); i++) {
        sigaction(IVCrashSignals[i], &sa, NULL);
    }

    IVLog(@"Crash logger installed (exceptions + signals) -> %@", crashPath);
}

__attribute__((constructor))
static void IVBootstrap(void) {
    @autoreleasepool {
        // 1. Capture the REAL sandbox home before any redirect touches env vars.
        [IVPaths captureRealHome];

        // 1b. Capture the REAL device chip family NOW — before IVDeviceSpoof rebinds
        //     sysctlbyname, otherwise the read would return the spoofed model and the
        //     model picker could offer cross-chip devices (an iPhone 11 as iPhone 17).
        [IVDeviceIdentity captureRealChip];

        // 1c. Crash capture — installed right after the real home is known so any
        //     crash in the isolation/spoof setup below (steps 2-8) dumps a stack.
        IVInstallCrashLogger();

        // 2. Load the container store from the shared (real-home) control dir.
        IVContainerStore *store = [IVContainerStore shared];
        [store load];

        // 3. Resolve the active container (falls back to default).
        IVContainer *active = store.activeContainer;
        BOOL isDefault = (!active || active.isDefault);
        // Remember what we booted as (resolved cid, default-coalesced) for the
        // warm-resume stale guard installed below.
        gBootstrappedCID = [(active.cid.length ? active.cid : kIVDefaultCID) copy];
        IVLog(@"TWEAK_LOAD begin — active=%@ (%@)", active.name, active.cid);

        // 4. Isolation redirects — applied ONCE, only for non-default containers,
        //    and ATOMICALLY: the HOME redirect (files), the keychain namespace,
        //    the CFPreferences redirect, and the App Group container redirect must
        //    ALL succeed together, or none takes effect. A half-applied state
        //    (e.g. files+keychain isolated but CFPreferences or the app-group
        //    container shared) is a cross-container identity leak: Instagram' FBSDK
        //    stack keeps device_id / session hints in NSUserDefaults AND in the
        //    shared App Group container, so a shared prefs/app-group store would
        //    let one container's session bleed into another — the exact "continue
        //    with the profile you logged in" bug. The default container keeps the
        //    real sandbox + real keychain + real app-group so an existing login
        //    survives.
        BOOL isolated = NO;
        if (!isDefault) {
            BOOL homeOK  = [IVHomeRedirect applyForContainer:active];              // redirect #1: files
            BOOL keyOK   = homeOK &&
                [IVKeychainHook installWithPrefix:IVKeychainPrefixForContainer(active)]; // redirect #2: keychain
            BOOL prefsOK = keyOK && [IVPrefsHook installForContainer:active];      // redirect #3: CFPreferences
            BOOL groupOK = prefsOK && [IVAppGroupHook installForContainer:active]; // redirect #4: App Group container
            if (homeOK && keyOK && prefsOK && groupOK) {
                isolated = YES;
            } else {
                // Roll back any partial redirect so the launch runs consistently
                // on the real sandbox rather than half-isolated (split-brain leak).
                [IVHomeRedirect revertToRealHome];
                // Flag the degraded launch so the UI warns the user: a non-default
                // container was requested but we are now on the REAL account/keychain.
                store.isolationDegraded = YES;
                IVErr(@"Isolation FAILED for %@ (home=%d key=%d prefs=%d group=%d) — reverted to real sandbox to avoid split-brain leak",
                      active.cid, homeOK, keyOK, prefsOK, groupOK);
            }
        } else {
            // Default container: install the keychain in HIDE mode so the real
            // account's view never includes another container's IV:-marked items.
            // This is the fix for an account appearing in the default container
            // after a container had been used: the default used to install NO
            // keychain hook and therefore enumerated the physically shared keychain,
            // surfacing every container's login (kSecAttrAccount is not namespaced)
            // AND its FBSDK/Meta device keypair (kSecClassKey, tag not namespaced).
            // Best-effort — a failure just keeps the prior passthrough, never blocks
            // launch, and never touches files/prefs (the real account stays intact).
            [IVKeychainHook installDefaultHideMode];
        }

        // 5. Device fingerprint spoof — only when isolation is actually active.
        //    Spoofing the device while files/keychain sit on the REAL account
        //    would make the primary login report a different device: pointless
        //    and suspicious. Deterministic per cid.
        if (isolated) {
            [IVDeviceSpoof installForContainer:active];
            // Locale/timezone spoof — same gate: only meaningful once files/keychain/
            // prefs are isolated. No-op when the container sets no language/region.
            [IVLocaleSpoof installForContainer:active];

            // In-process anti-correlation hardening — neutralize the device-global,
            // Apple-signed identity oracles that survive every redirect and answer
            // identically on every container (DeviceCheck / App Attest, the prime
            // "many accounts, one phone" ban signal), and suppress the AutoFill /
            // QuickType credential strip that re-surfaced a previous container's
            // email into a new container's signup field. Isolated containers only.
            [IVHardening installForContainer:active];

            // Task C — permanent login persistence. Downgrade the whole container
            // tree to CompleteUntilFirstUserAuthentication NOW (catch any session
            // files written under Complete on a previous launch), then re-stamp on
            // every background so freshly-written session data stays lock-readable.
            // Isolated container root ONLY — never the real/default sandbox.
            NSString *root = [IVPaths containerRootForCID:active.cid];
            [IVPaths reapplyProtectionRecursivelyAtRoot:root];
            IVInstallBackgroundReprotect(root);
        }

        // 5b. Global virtual camera — GLOBAL, not gated to isolation: one shared
        //     verification VIDEO for every container (the user swaps the file per
        //     account). If a global video is set, feed it into Instagram's OWN native
        //     AVFoundation capture stream AND overlay it on the live preview so the
        //     on-screen camera shows the footage, not the real lens. No-op (real
        //     camera untouched) when no global video exists. HONEST LIMIT: reaches
        //     Instagram's in-app AVFoundation camera only; NOT Veriff's WebView
        //     getUserMedia ID/age selfie (a separate WKWebView process).
        [IVCameraHook installGlobal];

        // 6. Location spoof — safe to install always; reads the active container
        //    live and passes through when no location is set.
        [IVLocationSpoof install];

        // 7. Floating control button, once the UI is ready.
        IVScheduleFloatingButton();

        // 8. Warm-resume backstop: force a clean cold relaunch if the active
        //    container changed while we were only suspended (app-switcher resume).
        IVInstallStaleContainerGuard();

        IVLog(@"TWEAK_LOAD complete — isolation=%@", isolated ? @"ON" : @"OFF (default/real sandbox)");
    }
}
