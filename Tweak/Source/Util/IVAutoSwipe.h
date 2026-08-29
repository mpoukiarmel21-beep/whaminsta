#import <Foundation/Foundation.h>
#import "../Core/IVContainer.h"

NS_ASSUME_NONNULL_BEGIN

/// Per-container auto-swipe bot. Drives Instagram's OWN on-screen UI (the app's live
/// key window, never our floating-button overlay): finds and taps the "like"
/// control, watches for the "c'est un match" popup, and — when one appears — types
/// one of the user's phrases into the message field and sends it, then keeps
/// swiping. Delays between actions are randomized in [minDelay, maxDelay] seconds
/// so the cadence never looks robotic (ban-prone).
///
/// HONEST LIMITS (no Instagram private headers, substrate-free): detection is a
/// best-effort heuristic over the accessibility tree + visible labels. Instagram can
/// rename controls between versions; when the like control or the match UI can't
/// be located a tick is skipped (logged, never crashes) and the loop retries. It
/// runs ONLY while the app is foreground-active and only after the config panel is
/// dismissed (so Instagram's UI — not ours — is frontmost). Everything is logged
/// verbosely via IVLog for on-device tuning.
@interface IVAutoSwipe : NSObject

+ (instancetype)shared;

/// Start swiping using `container`'s persisted config (messages / count / delays).
/// No-op if already running. Safe to call from the main thread only.
- (void)startWithContainer:(IVContainer *)container;

/// Stop the loop. Any pending tick is cancelled (generation-token guarded).
- (void)stop;

@property (nonatomic, readonly, getter=isRunning) BOOL running;

@end

NS_ASSUME_NONNULL_END
