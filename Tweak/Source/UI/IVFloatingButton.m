#import "IVFloatingButton.h"
#import "IVPanelVC.h"
#import "IVTheme.h"
#import "../Core/IVPaths.h"

#pragma mark - Overlay window (hosts the button AND the panel)

// A SINGLE full-screen, transparent window is the whole UI surface now. The old
// design used two windows — a tiny button window plus a throwaway per-tap
// presentation window — and the hand-off between them was the source of a string
// of device bugs: a zero-size presentation window (the sheet had no room to
// draw), and a stale presentation-window guard that a re-fired DidBecomeActive
// left set — the button reappeared on its own (show() un-hid it) while the guard
// still blocked the next tap, so "le bouton revient puis un 2e tap ne fait rien".
// One persistent window removes every seam:
//   * the button is a subview of the window's stable, full-screen rootVC;
//   * the panel is presented on that same rootVC — no second window to size,
//     retain, key, or leak;
//   * the "already showing" guard reads LIVE UIKit state
//     (rootViewController.presentedViewController), which cannot go stale.
// Touches pass through to the host app everywhere but the button — and, while the
// panel is up, the whole window goes live so the sheet is fully interactive.
@interface IVOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *liveView;   // the button container
@end

@implementation IVOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // While the panel is presented, behave like a normal window: the sheet and
    // its dimming view (both live in THIS window, above the rootVC) must receive
    // touches, or the menu would look frozen.
    if (self.rootViewController.presentedViewController) return hit;
    // Idle: only the button is live; everything else passes through to the app.
    if (self.liveView && (hit == self.liveView || [hit isDescendantOfView:self.liveView])) return hit;
    return nil;
}
@end

#pragma mark - Floating button

static NSString *const kIVBtnCenterKey = @"IVFloatingButtonCenter";
static const CGFloat kIVButtonSize = 60.0;
static const CGFloat kIVButtonCorner = 14.0;   // soft corner radius for the square face
static const CGFloat kIVEdgeMargin = 18.0;   // breathing room from the screen edges

@interface IVFloatingButton () <UIAdaptivePresentationControllerDelegate>
@property (nonatomic, strong) IVOverlayWindow *window;
@property (nonatomic, strong) UIView *container;            // the draggable button
@property (nonatomic, weak)   UIWindow *previousKeyWindow;  // host key window, restored on dismiss
@end

@implementation IVFloatingButton

+ (instancetype)shared {
    static IVFloatingButton *i;
    static dispatch_once_t o;
    dispatch_once(&o, ^{ i = [self new]; });
    return i;
}

#pragma mark - Show / hide

- (void)show {
    // Re-entrant: fired on every UIApplicationDidBecomeActive (and a 2.5s
    // fallback). If the window already exists just ensure it's visible and bail —
    // crucially we do NOT touch the button's own visibility here, so an
    // activation that fires while the panel is up can never strand the button
    // visible over a live menu nor re-arm anything. This kills the "button came
    // back on its own after a few seconds, then the next tap did nothing" bug.
    if (self.window) { self.window.hidden = NO; return; }

    // Need a foreground-active scene before building anything; otherwise the
    // window would never attach to a scene yet self.window would be set, and
    // every later activation would hit the early-return above. Bail and retry.
    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s; break;
        }
    }
    if (!scene) return;

    // Full-screen transparent host window. initWithWindowScene: does NOT size the
    // window (it comes up at CGRectZero — a previous bug), so set the frame to the
    // scene bounds explicitly. Sits above the app; the passthrough hitTest keeps
    // the app interactive everywhere but the button.
    IVOverlayWindow *w = [[IVOverlayWindow alloc] initWithWindowScene:scene];
    CGRect bounds = scene.coordinateSpace.bounds;
    if (CGRectIsEmpty(bounds)) bounds = UIScreen.mainScreen.bounds;
    w.frame = bounds;
    w.windowLevel = UIWindowLevelAlert + 1;
    w.backgroundColor = UIColor.clearColor;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    w.rootViewController = root;

    UIView *container = [self makeButtonContainer];
    [root.view addSubview:container];
    w.liveView = container;
    self.window = w;
    self.container = container;

    w.hidden = NO;
    [self restorePosition];
}

- (void)hide { self.window.hidden = YES; }

// Builds a dark translucent square "vault" button with subtle inlay motifs + the
// SF-symbol, plus the pan gesture. A deliberate move away from the old flat
// violet disc to a more engineered, professional look: a smoked-black glass face
// that stays legible over Instagram's bright content, a thin inner frame, faint
// concentric datum rings inlaid into the glass, and a restrained violet edge-glow
// that ties it to the rest of the theme. Positioned by center (see
// restorePosition); the shadow draws outside the bounds and the full-screen
// rootVC never clips it.
- (UIView *)makeButtonContainer {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kIVButtonSize, kIVButtonSize)];

    // Soft, wide violet glow instead of a flat drop shadow — reads as a premium
    // control while the face stays dark and neutral.
    container.layer.shadowColor = IVTheme.accentDeep.CGColor;
    container.layer.shadowOpacity = 0.50;
    container.layer.shadowRadius = 14.0;
    container.layer.shadowOffset = CGSizeMake(0, 7);
    container.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:container.bounds
                                                           cornerRadius:kIVButtonCorner].CGPath;

    // The glass face — a near-opaque smoked black that stays a "bouton
    // translucide noir" over any app background, with a violet-tinted tint so it
    // harmonizes with the theme rather than reading as a dead black slab.
    UIView *face = [[UIView alloc] initWithFrame:container.bounds];
    face.userInteractionEnabled = NO;                 // the button on top gets the tap
    face.backgroundColor = [UIColor colorWithRed:0.06 green:0.05 blue:0.10 alpha:0.92];
    face.layer.cornerRadius = kIVButtonCorner;
    face.layer.cornerCurve = kCACornerCurveContinuous;
    face.clipsToBounds = YES;
    face.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [container addSubview:face];

    // Radial dark glaze: lighter toward the top-left, deeper at the edge — gives
    // the square a manufactured, subtly-dimensional feel instead of flat fill.
    CAGradientLayer *fill = [CAGradientLayer layer];
    fill.frame = face.bounds;
    fill.type = kCAGradientLayerRadial;
    fill.colors = @[(id)[UIColor colorWithRed:0.30 green:0.26 blue:0.40 alpha:0.9].CGColor,
                    (id)[UIColor colorWithRed:0.07 green:0.06 blue:0.12 alpha:0.0].CGColor];
    fill.startPoint = CGPointMake(0.0, 0.0);
    fill.endPoint = CGPointMake(1.0, 1.0);
    [face.layer addSublayer:fill];

    // Faint concentric datum rings inlaid into the glass — the "motifs
    // professionnels" (think a lens/locate reticle): two hairline circles centered
    // on the icon, drawn very quietly so they don't overpower the glyph.
    for (NSInteger i = 0; i < 2; i++) {
        CAShapeLayer *ring = [CAShapeLayer layer];
        CGFloat r = kIVButtonSize * 0.22 + i * 8.0;
        ring.path = [UIBezierPath bezierPathWithOvalInRect:
                     CGRectMake(kIVButtonSize / 2.0 - r, kIVButtonSize / 2.0 - r, r * 2, r * 2)].CGPath;
        ring.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.10].CGColor;
        ring.fillColor = UIColor.clearColor.CGColor;
        ring.lineWidth = 0.8;
        [face.layer addSublayer:ring];
    }
    // A short vertical datum tick under the icon, closing the reticle.
    CAShapeLayer *tick = [CAShapeLayer layer];
    UIBezierPath *tp = [UIBezierPath bezierPath];
    CGFloat cx = kIVButtonSize / 2.0;
    [tp moveToPoint:CGPointMake(cx, kIVButtonSize * 0.66)];
    [tp addLineToPoint:CGPointMake(cx, kIVButtonSize * 0.76)];
    tick.path = tp.CGPath;
    tick.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    tick.lineWidth = 1.0;
    [face.layer addSublayer:tick];

    // Thin inner frame — a crisp hairline at the very edge keeps the square's
    // outline sharp against busy content (and its subtle violet read ties to the
    // brand without turning the whole face purple).
    CAShapeLayer *frame = [CAShapeLayer layer];
    frame.path = [UIBezierPath bezierPathWithRoundedRect:
                  CGRectInset(face.bounds, 1.0, 1.0) cornerRadius:kIVButtonCorner - 1.0].CGPath;
    frame.strokeColor = [UIColor colorWithRed:0.55 green:0.45 blue:0.95 alpha:0.35].CGColor;
    frame.fillColor = UIColor.clearColor.CGColor;
    frame.lineWidth = 1.0;
    [face.layer addSublayer:frame];

    // Top-edge gloss — a soft horizontal sheen that reads light hitting glass.
    CAGradientLayer *gloss = [CAGradientLayer layer];
    gloss.frame = CGRectMake(0, 0, container.bounds.size.width, container.bounds.size.height * 0.5);
    gloss.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.16].CGColor,
                     (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
    gloss.startPoint = CGPointMake(0.0, 0.0);
    gloss.endPoint = CGPointMake(0.0, 1.0);
    [face.layer addSublayer:gloss];

    // The real interactive layer: a UIButton reliably turns a stationary touch
    // into an action while coexisting with the drag pan on the container. The
    // glyph sits above the reticle so the motifs stay background.
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = container.bounds;
    btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
    UIImage *icon = [[UIImage systemImageNamed:@"square.stack.3d.up.fill" withConfiguration:cfg]
                        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [btn setImage:icon forState:UIControlStateNormal];
    btn.tintColor = UIColor.whiteColor;
    btn.adjustsImageWhenHighlighted = NO;
    [btn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
    btn.isAccessibilityElement = YES;
    btn.accessibilityLabel = @"WhamInsta";
    btn.accessibilityHint = @"Ouvre la gestion des conteneurs";
    [container addSubview:btn];

    [container addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];
    return container;
}

#pragma mark - Drag / snap / persist

- (CGRect)screenBounds {
    CGRect b = self.window.bounds;
    return b.size.width > 0 ? b : UIScreen.mainScreen.bounds;
}

// Our window is full-screen now, so its own safeAreaInsets are correct once laid
// out. Fall back to typical modern-iPhone insets if the window hasn't laid out
// yet (e.g. restorePosition called right after show).
- (UIEdgeInsets)screenSafeInsets {
    UIEdgeInsets ins = self.window.safeAreaInsets;
    if (!UIEdgeInsetsEqualToEdgeInsets(ins, UIEdgeInsetsZero)) return ins;
    return UIEdgeInsetsMake(44.0, 0.0, 34.0, 0.0);
}

// Snap horizontally to the nearer edge and clamp vertically inside the safe
// area. Shared by drag-end and restore so both agree on the same bounds.
- (CGPoint)clampedCenter:(CGPoint)c inBounds:(CGRect)b {
    CGFloat half = kIVButtonSize / 2.0;
    UIEdgeInsets safe = [self screenSafeInsets];
    c.x = (c.x < b.size.width / 2.0) ? (half + kIVEdgeMargin) : (b.size.width - half - kIVEdgeMargin);
    CGFloat minY = safe.top + half + kIVEdgeMargin;
    CGFloat maxY = b.size.height - safe.bottom - half - kIVEdgeMargin;
    c.y = MAX(minY, MIN(maxY, c.y));
    return c;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *parent = self.container.superview;
    CGPoint tr = [g translationInView:parent];
    CGPoint c = self.container.center;
    c.x += tr.x; c.y += tr.y;
    self.container.center = c;
    [g setTranslation:CGPointZero inView:parent];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self snapToEdgeAndSave];
    }
}

- (void)snapToEdgeAndSave {
    CGRect b = [self screenBounds];
    CGPoint c = [self clampedCenter:self.container.center inBounds:b];
    void (^persist)(void) = ^{
        [NSUserDefaults.standardUserDefaults setObject:NSStringFromCGPoint(c) forKey:kIVBtnCenterKey];
    };
    if (UIAccessibilityIsReduceMotionEnabled()) {
        self.container.center = c;
        persist();
        return;
    }
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ self.container.center = c; }
                     completion:^(BOOL done) { persist(); }];
}

- (void)restorePosition {
    CGRect b = [self screenBounds];
    CGFloat half = kIVButtonSize / 2.0;
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kIVBtnCenterKey];
    CGPoint c = saved ? CGPointFromString(saved)
                      : CGPointMake(b.size.width - half - kIVEdgeMargin, b.size.height * 0.72);
    self.container.center = [self clampedCenter:c inBounds:b];
}

#pragma mark - Tap → panel

- (void)onTap {
    UIViewController *host = self.window.rootViewController;
    if (!host) return;
    // Already showing the panel? Bail. This guard reads LIVE UIKit state, so it
    // can never be left stale by an activation re-fire (the old boolean/window
    // guard could — that was the "second tap does nothing" bug).
    if (host.presentedViewController) return;

    // Press feedback (skipped under Reduce Motion).
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        [UIView animateWithDuration:0.08 animations:^{
            self.container.transform = CGAffineTransformMakeScale(0.9, 0.9);
        } completion:^(BOOL d) {
            [UIView animateWithDuration:0.12 animations:^{ self.container.transform = CGAffineTransformIdentity; }];
        }];
    }

    IVPanelVC *panel = [IVPanelVC new];
    __weak typeof(self) ws = self;
    panel.onClose = ^{ [ws teardownPresentation]; };   // restore the button on close

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:panel];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    nav.presentationController.delegate = self;         // backup teardown on swipe-dismiss

    // The panel hosts text input (rename / create), so its window must be key for
    // the keyboard to attach. Remember the host's key window and hand it back on
    // dismiss so the app keeps working normally once the menu closes.
    self.previousKeyWindow = self.window.windowScene.keyWindow;
    [self.window makeKeyAndVisible];

    // Hide the button only once the sheet is actually on screen, never before —
    // if the present were ever a no-op the button would be stranded hidden with
    // no menu (the original dead-tap bug). presentedViewController is set
    // synchronously by this call, so the re-entry guard above is already armed.
    [host presentViewController:nav animated:YES completion:^{
        ws.container.hidden = YES;
    }];
}

// Idempotent: bring the button back and restore the host's key window. The panel
// dismisses ITSELF (Close button / swipe-down); this only undoes the cosmetic
// hide, so there is no second window to tear down and nothing left stale.
- (void)teardownPresentation {
    self.container.hidden = NO;
    UIWindow *restore = self.previousKeyWindow;
    self.previousKeyWindow = nil;
    if (!restore) {
        // No captured key window (rare) — hand key to any other window in the
        // scene so our overlay doesn't stay key and swallow the app's keyboard.
        for (UIWindow *w in self.window.windowScene.windows) {
            if (w != self.window) { restore = w; break; }
        }
    }
    [restore makeKeyWindow];
}

// Public restore for a PROGRAMMATIC dismiss (e.g. the auto-swipe panel calling
// -dismissViewControllerAnimated: when "Démarrer" is tapped). That path fires
// neither onClose nor presentationControllerDidDismiss:, so without this the
// button would stay hidden over Instagram. teardownPresentation is idempotent, so
// this is safe even if the button is already visible.
- (void)restoreButtonAfterExternalDismiss {
    [self teardownPresentation];
}

#pragma mark - Crash report surfacing

// Shows any crash stack logged since the last time one was surfaced. Reads
// <realHome>/Documents/whaminsta/logs/crash.log and mirrors the already-shown
// byte offset to crash.seen in the same dir, so each crash pops the alert exactly
// once and stays available for the user to inspect/copy without the Files app.
- (void)presentPendingCrashReport {
    if (!self.window) return;
    UIViewController *host = self.window.rootViewController;
    if (!host || host.presentedViewController) return;

    NSString *dir = [[[IVPaths realHome] stringByAppendingPathComponent:@"Documents"]
                        stringByAppendingPathComponent:@"whaminsta/logs"];
    NSString *crashPath = [dir stringByAppendingPathComponent:@"crash.log"];
    NSString *seenPath  = [dir stringByAppendingPathComponent:@"crash.seen"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:crashPath]) return;

    NSData *data = [NSData dataWithContentsOfFile:crashPath];
    if (!data.length) return;

    unsigned long long seen = 0;
    NSString *seenS = [NSString stringWithContentsOfFile:seenPath encoding:NSUTF8StringEncoding error:NULL];
    if (seenS.length) seen = [seenS longLongValue];

    unsigned long long total = (unsigned long long)data.length;
    if (total <= seen) return;                       // nothing new since last time

    NSString *newText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *slice = nil;
    if (newText.length > (NSUInteger)seen) {
        slice = [newText substringFromIndex:(NSUInteger)seen];
    }
    if (slice.length == 0) return;

    // Persist "seen" now so a crash can never re-alert the user on every launch.
    [[@(total) description] writeToFile:seenPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    // Trim to a readable chunk (first ~1800 chars) — the rest stays in crash.log
    // and can be consulted on demand; the alert is a teaser, not a dump.
    NSString *display = slice;
    if (display.length > 1800) display = [display substringToIndex:1800];
    NSString *title = @"Crash détecté";
    NSString *message = [NSString stringWithFormat:
        @"Un crash vient d'être capturé (création de compte ?). Copie la stack ci-dessous et colle-la à l'agent.\n\n%@",
        display];

    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Copier la stack" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        [UIPasteboard.generalPasteboard setString:slice];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [host presentViewController:a animated:YES completion:nil];
}

#pragma mark - UIAdaptivePresentationControllerDelegate

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self teardownPresentation];
}

@end
