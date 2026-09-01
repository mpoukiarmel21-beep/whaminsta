#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The draggable Liquid Glass floating action button — the tweak's main entry
/// point. Lives at UIWindowLevelAlert on its own window, survives across the
/// app's key-window changes, snaps to screen edges, and persists its position.
/// Tapping opens the container panel (IVPanelVC).
@interface IVFloatingButton : NSObject

+ (instancetype)shared;

/// Create the overlay window + button and show it. Idempotent. Call after the
/// app's UI is up (e.g. hooked -[UIWindow makeKeyAndVisible] or a delayed
/// dispatch from the constructor).
- (void)show;
- (void)hide;

/// Re-show the floating button after the panel (or one of its pushed children,
/// e.g. the auto-swipe config) was dismissed programmatically rather than by the
/// Close button / swipe-down. A programmatic dismiss fires neither `onClose` nor
/// the presentation-controller delegate, so the button would stay hidden; the
/// dismisser calls this to restore it. Idempotent and safe to call when the
/// button is already visible.
- (void)restoreButtonAfterExternalDismiss;

/// Present an in-app alert surfacing any crash stack written since the last
/// time one was shown (so the user can copy it without touching the Files app).
/// Reads <realHome>/Documents/whaminsta/logs/crash.log, tracks the already-shown
/// byte offset in the same dir (crash.seen), and presents a "Copier la stack"
/// alert with the new entries when present. No-op otherwise.
- (void)presentPendingCrashReport;

@end

NS_ASSUME_NONNULL_END
