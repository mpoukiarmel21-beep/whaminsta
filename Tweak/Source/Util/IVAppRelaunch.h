#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Cleanly close the app so the NEXT open cold-launches on the freshly activated
/// container. The active container is applied ONLY once, in the constructor
/// (HOME/keychain/prefs/app-group redirects + device/locale spoof), so switching
/// or creating+activating a container requires a real process restart. iOS forbids
/// an app relaunching itself, so we animate to the home screen (-suspend, not a
/// crash) then exit(0).
///
/// The exit MUST NOT ride the main queue: once -suspend backgrounds the app the
/// main run loop stops being serviced, so a main-queue dispatch_after may never
/// fire — leaving the process merely SUSPENDED (resumable warm from the switcher),
/// which reuses the OLD container's isolation while the store already points at the
/// new one. A background global-queue timer still runs during the pre-suspension
/// grace window; and Bootstrap's foreground stale-guard terminates any stale
/// process on the next resume, so the switch can never silently fail.
///
/// Shared by IVPanelVC (activate / reset) and IVCreateVC (create + activate) so the
/// subtle main-vs-global-queue correctness lives in exactly one place.
void IVCloseAppForRelaunch(void);

NS_ASSUME_NONNULL_END
