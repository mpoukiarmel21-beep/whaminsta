#import "IVAppRelaunch.h"
#import <UIKit/UIKit.h>

void IVCloseAppForRelaunch(void) {
    UIApplication *app = UIApplication.sharedApplication;
    SEL suspend = NSSelectorFromString(@"suspend");
    if ([app respondsToSelector:suspend]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [app performSelector:suspend];   // animate to home first (not a crash)
#pragma clang diagnostic pop
    }
    // Terminate so the NEXT open cold-launches on the freshly activated container.
    // The exit MUST NOT ride the main queue: once -suspend moves the app to the
    // background the main run loop stops being serviced, so a main-queue
    // dispatch_after may NEVER fire — the process is then left merely SUSPENDED
    // (resumable from the app switcher). A warm resume does not re-run the
    // constructor, so it reuses the OLD container's isolation while the store
    // already points at the newly activated one — surfacing the account on the
    // wrong (often default) identity. A background global-queue timer still runs
    // during the brief pre-suspension grace window; and even if the OS freezes it
    // first, Bootstrap's foreground stale-guard terminates the stale process on
    // the next resume, so the switch can never silently fail.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ exit(0); });
}
