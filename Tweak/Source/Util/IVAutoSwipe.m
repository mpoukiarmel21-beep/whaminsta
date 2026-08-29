#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "IVAutoSwipe.h"
#import "IVDiagnostics.h"

// Best-effort keyword sets (lowercased substring match over an element's
// accessibilityIdentifier + accessibilityLabel + button title). No Instagram private
// headers exist, so these are heuristics tuned to Instagram's visible/ax strings and
// broadened for EN/FR/ES. Bare "yes"/"no"/"non"/"ok" are kept OUT of the substring
// sets — they match unrelated words ("yesterday","notification","smoke","broke") and
// would mis-tap; a lone OK button is caught by an exact-title pass instead.
static NSArray<NSString *> *IVLikeKeywords(void)    { return @[@"like", @"heart", @"jaime", @"j'aime", @"vote_yes", @"yes_vote", @"favorite", @"btn_yes", @"coeur", @"cœur", @"me gusta"]; }
static NSArray<NSString *> *IVDislikeKeywords(void) { return @[@"dislike", @"nope", @"vote_no", @"no_vote", @"reject", @"btn_no", @"croix", @"skip", @"passer", @"no me gusta", @"not interested", @"cross", @"x_button", @"dismiss_card", @"swipe_left", @"decline", @"close_card"]; }
static NSArray<NSString *> *IVSwipeAvoidKeywords(void){ return @[@"super", @"boost", @"rewind", @"undo", @"back", @"retour", @"settings", @"réglage", @"reglage", @"ajustes", @"profile", @"profil", @"filter", @"filtre", @"menu", @"tab", @"onglet", @"spotlight", @"message", @"chat", @"crush", @"gift", @"cadeau", @"buy", @"acheter", @"premium", @"upgrade"]; }
static NSArray<NSString *> *IVMatchKeywords(void)   { return @[@"match", @"it's a match", @"its a match", @"un match", @"nouveau match", @"new match", @"vous vous plaisez", @"vous plaisez", @"you matched", @"c'est un match", @"mutual", @"you like each other", @"you both like", @"tu plais", @"es un match", @"hiciste match", @"nuevo match"]; }
static NSArray<NSString *> *IVMsgCTAKeywords(void)  { return @[@"send a message", @"send message", @"envoyer un message", @"say hi", @"say hello", @"dire bonjour", @"écrire", @"ecrire", @"start chatting", @"discuter", @"say something", @"escribir", @"enviar mensaje", @"send hi"]; }
static NSArray<NSString *> *IVSendKeywords(void)    { return @[@"send", @"envoyer", @"envoi", @"enviar"]; }
static NSArray<NSString *> *IVContinueKeywords(void){ return @[@"continue", @"continuer", @"keep swiping", @"keep playing", @"back to swiping", @"garder", @"maybe later", @"later", @"plus tard", @"not now", @"pas maintenant", @"fermer", @"close", @"got it", @"compris", @"no thanks", @"non merci", @"dismiss", @"seguir", @"continuar", @"cerrar", @"ahora no", @"d'accord", @"okay"]; }
// Never tap these on an interruptive popup — monetization / destructive / nav.
static NSArray<NSString *> *IVMoneyAvoidKeywords(void){ return @[@"buy", @"purchase", @"subscribe", @"abonn", @"acheter", @"premium", @"upgrade", @"payer", @"pay", @"restore", @"unlock", @"offer", @"discount", @"boost", @"superlike", @"super like", @"delete", @"supprimer", @"block", @"bloquer", @"report", @"signaler", @"logout", @"déconnex", @"deconnex", @"settings", @"réglage", @"reglage"]; }
// Lone confirm titles matched EXACTLY (trimmed button title only).
static NSArray<NSString *> *IVOKTitles(void)        { return @[@"ok", @"okay", @"ok!", @"d'accord", @"j'ai compris", @"got it"]; }

@implementation IVAutoSwipe {
    BOOL _running;
    NSArray<NSString *> *_messages;
    NSInteger _count;      // 0 == unlimited
    double _min, _max;     // seconds
    NSInteger _method;     // 0 == boutons (tap), 1 == gestes (finger swipe)
    NSInteger _likePercent;// 0..100 — probability an action is a LIKE
    NSInteger _done;
    NSInteger _gen;        // generation token — bumping it cancels pending ticks
    // Gesture health: a synthesized swipe that leaves the card unmoved means gestures
    // are ineffective on this Instagram build → fall back to buttons for the rest of the run.
    BOOL _gestureBroken;
    __weak UIView *_pendingCard;
    CGPoint _pendingCardCenter;
    BOOL _havePendingCard;
}
+ (instancetype)shared {
    static IVAutoSwipe *i; static dispatch_once_t o;
    dispatch_once(&o, ^{ i = [self new]; });
    return i;
}

- (BOOL)isRunning { return _running; }

- (void)startWithContainer:(IVContainer *)c {
    if (_running || !c) return;
    _messages = c.autoSwipeMessages.count ? [c.autoSwipeMessages copy] : nil;
    _count = c.autoSwipeCount > 0 ? c.autoSwipeCount : 0;
    _min = c.autoSwipeMinDelay >= 1.0 ? c.autoSwipeMinDelay : 1.0;
    _max = c.autoSwipeMaxDelay >= _min ? c.autoSwipeMaxDelay : _min;
    _method = (c.autoSwipeMethod == 1) ? 1 : 0;
    _likePercent = c.autoSwipeLikePercent < 0 ? 0 : (c.autoSwipeLikePercent > 100 ? 100 : c.autoSwipeLikePercent);
    _done = 0;
    _gestureBroken = NO;
    _havePendingCard = NO;
    _pendingCard = nil;
    _running = YES;
    _gen++;
    IVLog(@"auto-swipe: START cid=%@ count=%ld delay=[%.1f,%.1f] method=%@ like=%ld%% msgs=%lu",
          c.cid, (long)_count, _min, _max, _method == 1 ? @"gestes" : @"boutons",
          (long)_likePercent, (unsigned long)_messages.count);
    [self scheduleNextTick];   // first tick after a delay: lets the panel dismiss first
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    _gen++;
    IVLog(@"auto-swipe: STOP after %ld swipe(s)", (long)_done);
}

#pragma mark - Tick loop

- (double)randomDelay {
    double span = _max - _min;
    double r = span > 0 ? ((double)arc4random_uniform(1000000) / 1000000.0) * span : 0;
    return _min + r;
}
- (void)scheduleNextTick {
    if (!_running) return;
    NSInteger gen = _gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([self randomDelay] * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen != self->_gen || !self->_running) return;   // stopped/restarted meanwhile
        [self tick];
    });
}

- (void)tick {
    if (!_running) return;
    UIApplication *app = UIApplication.sharedApplication;
    if (app.applicationState != UIApplicationStateActive) {
        [self scheduleNextTick];   // backgrounded — act only when foreground-active
        return;
    }

    // One scan of Instagram's live UI per tick: every visible foreground window except our
    // own overlay + the keyboard windows, highest windowLevel first so popups (which
    // sit above the card stack) are seen before the encounters screen underneath.
    NSArray<UIWindow *> *windows = [self scanWindows];
    if (!windows.count) { IVLog(@"auto-swipe: no host window this tick"); [self scheduleNextTick]; return; }
    NSMutableArray<UIControl *> *controls = [NSMutableArray new];
    NSMutableArray<UILabel *> *labels = [NSMutableArray new];
    for (UIWindow *w in windows) {
        [self collectControlsIn:w into:controls];
        [self collectLabelsIn:w into:labels];
    }

    // 1) A match screen takes priority: send a phrase (or open the composer), else dismiss.
    if ([self handleMatchInControls:controls labels:labels windows:windows]) { [self scheduleNextTick]; return; }
    // 2) A generic interruptive popup blocks swiping: tap its dismiss/continue button,
    //    never a monetization/destructive one. No-ops on the plain encounters screen.
    if ([self handleInterruptivePopupInControls:controls]) { [self scheduleNextTick]; return; }

    // 3) Otherwise perform one swipe.
    BOOL wantLike = ((NSInteger)arc4random_uniform(100) < _likePercent);
    BOOL acted = [self performAction:wantLike controls:controls windows:windows];
    if (acted) {
        _done++;
        IVLog(@"auto-swipe: %@ (%ld%@)", wantLike ? @"like" : @"dislike", (long)_done,
              _count > 0 ? [NSString stringWithFormat:@"/%ld", (long)_count] : @"");
        if (_count > 0 && _done >= _count) { IVLog(@"auto-swipe: count reached — stopping"); [self stop]; return; }
    } else {
        IVLog(@"auto-swipe: no actionable control/card found this tick");
    }
    [self scheduleNextTick];
}
#pragma mark - Action dispatch (method + like/dislike)

// One swipe action. In "gestes" mode: first verify LAST tick's synthesized swipe
// actually moved the card — if it left the card untouched (still on screen at the same
// center), gestures are ineffective on this build → switch to buttons permanently
// (this is the "l'option geste ne fonctionne pas, juste les boutons" fix: instead of
// silently doing nothing, we detect the no-op and fall back). Otherwise synthesize a
// finger swipe on the top card and remember it so the next tick can verify movement.
- (BOOL)performAction:(BOOL)wantLike controls:(NSArray<UIControl *> *)controls windows:(NSArray<UIWindow *> *)windows {
    if (_method == 1 && !_gestureBroken) {
        if (_havePendingCard) {
            UIView *pend = _pendingCard;
            BOOL moved = (!pend || pend.window == nil ||
                          fabs(pend.center.x - _pendingCardCenter.x) > 12.0 ||
                          fabs(pend.center.y - _pendingCardCenter.y) > 12.0);
            _havePendingCard = NO;
            _pendingCard = nil;
            if (!moved) {
                _gestureBroken = YES;
                IVLog(@"auto-swipe: gesture had no effect (card unmoved) — buttons from now on");
            }
        }
        if (!_gestureBroken) {
            UIView *card = [self findCardInWindows:windows];
            if (card && card.window) {
                if ([self synthesizeSwipeOnCard:card like:wantLike]) {
                    _pendingCard = card;
                    _pendingCardCenter = card.center;
                    _havePendingCard = YES;
                    return YES;
                }
                _gestureBroken = YES;
                IVLog(@"auto-swipe: gesture synthesis unavailable — buttons from now on");
            } else {
                IVLog(@"auto-swipe: no swipeable card found — using buttons this tick");
            }
        }
    }
    return [self tapVoteLike:wantLike controls:controls];
}

// Tap Instagram's own like/dislike control for the EXACT vote requested. NO fallback to
// the opposite vote: falling through used to convert every missed dislike into a like,
// which is exactly the "je donne 50/50 et il fait 95% à droite" bug. If the desired
// control can't be located this tick, we log and do nothing — the next tick retries,
// so the like/dislike ratio stays faithful to _likePercent.
- (BOOL)tapVoteLike:(BOOL)wantLike controls:(NSArray<UIControl *> *)controls {
    UIControl *primary = wantLike ? [self findLikeControlIn:controls] : [self findDislikeControlIn:controls];
    if (primary) { [self tapControl:primary]; return YES; }
    IVLog(@"auto-swipe: desired %@ control not found this tick — skipped to keep the ratio",
          wantLike ? @"like" : @"dislike");
    return NO;
}
#pragma mark - Window scanning (multi-window, popups first)

// Every foreground-active window that belongs to Instagram's own UI, EXCLUDING our overlay
// (IVOverlayWindow) and the system keyboard/text-effect windows. Sorted by windowLevel
// DESCENDING so alerts / match modals / "It's a Match" overlays (which UIKit hosts on
// higher-level windows) are scanned before the encounters screen below them — the old
// single-window scan missed every popup, which is why "il n'arrive pas à détecter les
// popup de Instagram".
- (NSArray<UIWindow *> *)scanWindows {
    NSMutableArray<UIWindow *> *out = [NSMutableArray new];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.hidden || w.alpha < 0.01) continue;
            NSString *cls = NSStringFromClass([w class]);
            if ([cls isEqualToString:@"IVOverlayWindow"]) continue;                 // our own UI
            if ([cls containsString:@"Keyboard"] || [cls containsString:@"TextEffects"]) continue;
            [out addObject:w];
        }
    }
    [out sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel > b.windowLevel) return NSOrderedAscending;   // higher level first
        if (a.windowLevel < b.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return out;
}

- (void)collectControlsIn:(UIView *)v into:(NSMutableArray<UIControl *> *)out {
    if (v.hidden || v.alpha < 0.01) return;
    if ([v isKindOfClass:[UIControl class]] && ((UIControl *)v).enabled && v.userInteractionEnabled) {
        [out addObject:(UIControl *)v];
    }
    for (UIView *sub in v.subviews) [self collectControlsIn:sub into:out];
}

- (void)collectLabelsIn:(UIView *)v into:(NSMutableArray<UILabel *> *)out {
    if (v.hidden || v.alpha < 0.01) return;
    if ([v isKindOfClass:[UILabel class]]) [out addObject:(UILabel *)v];
    for (UIView *sub in v.subviews) [self collectLabelsIn:sub into:out];
}
#pragma mark - Match screen + interruptive popups

// A match screen is present if any visible label/control identity matches a match
// keyword. Two-step flow, per the user's request ("il clique sur match et clique sur
// envoyer un message et inscrire le message ... choisir une ligne au hasard et cliquer
// sur envoyer"): composer open → type a RANDOM phrase + Send; else tap the "send a
// message" CTA (next tick types+sends); else dismiss so the queue isn't blocked.
- (BOOL)handleMatchInControls:(NSArray<UIControl *> *)controls
                       labels:(NSArray<UILabel *> *)labels
                      windows:(NSArray<UIWindow *> *)windows {
    BOOL isMatch = NO;
    NSArray<NSString *> *mk = IVMatchKeywords();
    for (UILabel *l in labels) { if ([self text:l.text matchesAny:mk]) { isMatch = YES; break; } }
    if (!isMatch) {
        for (UIControl *c in controls) { if ([self text:[self identityFor:c] matchesAny:mk]) { isMatch = YES; break; } }
    }
    if (!isMatch) return NO;

    // No phrases configured → just clear the modal and keep swiping.
    if (!_messages.count) {
        UIControl *cont = [self findControlIn:controls keywords:IVContinueKeywords() avoid:IVMoneyAvoidKeywords()];
        if (!cont) cont = [self findExactTitleControlIn:controls titles:IVOKTitles()];
        if (cont) { IVLog(@"auto-swipe: match — no phrase set, dismissing"); [self tapControl:cont]; }
        return YES;
    }
    // Composer already open? Type a random phrase + tap Send.
    UITextView *tv = nil; UITextField *tf = nil;
    UIView *input = [self findTextInputInWindows:windows textView:&tv textField:&tf];
    if (input) {
        NSString *phrase = _messages[arc4random_uniform((uint32_t)_messages.count)];
        if (tv) tv.text = phrase; else if (tf) tf.text = phrase;
        if (tf) [tf sendActionsForControlEvents:UIControlEventEditingChanged];   // enable Send
        UIControl *send = [self findControlIn:controls keywords:IVSendKeywords() avoid:IVMoneyAvoidKeywords()];
        if (send) { IVLog(@"auto-swipe: match — typed phrase, sending"); [self tapControl:send]; }
        else IVLog(@"auto-swipe: match — phrase typed but no Send control found");
        return YES;
    }

    // Composer not open: tap the CTA to open it (next tick types + sends).
    UIControl *cta = [self findControlIn:controls keywords:IVMsgCTAKeywords() avoid:IVMoneyAvoidKeywords()];
    if (cta) { IVLog(@"auto-swipe: match — opening message composer"); [self tapControl:cta]; return YES; }

    // No composer, no CTA → dismiss so swiping resumes.
    UIControl *cont = [self findControlIn:controls keywords:IVContinueKeywords() avoid:IVMoneyAvoidKeywords()];
    if (!cont) cont = [self findExactTitleControlIn:controls titles:IVOKTitles()];
    if (cont) { IVLog(@"auto-swipe: match — no composer/CTA, dismissing"); [self tapControl:cont]; }
    return YES;
}

// A generic interruptive popup (rate-us, out-of-likes, "you've been busy", a permission
// nag, an upsell that also offers a decline, etc.) blocks the card stack. Tap a
// continue/close/"maybe later" button, or a lone exact-title OK — but NEVER a
// monetization or destructive one, so we don't buy Premium or delete anything. Returns
// NO on the plain encounters screen (no such control), letting the swipe run.
- (BOOL)handleInterruptivePopupInControls:(NSArray<UIControl *> *)controls {
    UIControl *c = [self findControlIn:controls keywords:IVContinueKeywords() avoid:IVMoneyAvoidKeywords()];
    if (!c) c = [self findExactTitleControlIn:controls titles:IVOKTitles()];
    if (!c) return NO;
    IVLog(@"auto-swipe: dismissing interruptive popup");
    [self tapControl:c];
    return YES;
}
#pragma mark - Control / card / text finders

// First enabled control whose identity contains ANY keyword and NONE of the avoid
// terms. Scans in collection order (highest-window-first, set by the tick).
- (UIControl *)findControlIn:(NSArray<UIControl *> *)controls
                    keywords:(NSArray<NSString *> *)keys
                       avoid:(NSArray<NSString *> *)avoid {
    for (UIControl *c in controls) {
        NSString *ident = [self identityFor:c];
        if (![self text:ident matchesAny:keys]) continue;
        if (avoid && [self text:ident matchesAny:avoid]) continue;
        return c;
    }
    return nil;
}

// A button whose TRIMMED title equals one of the exact titles (case-insensitive) — used
// to catch a lone "OK" / "D'accord" confirm without the substring hazard of matching
// "ok" inside "smoke"/"broke".
- (UIControl *)findExactTitleControlIn:(NSArray<UIControl *> *)controls
                                titles:(NSArray<NSString *> *)titles {
    for (UIControl *c in controls) {
        if (![c isKindOfClass:[UIButton class]]) continue;
        NSString *t = [[(UIButton *)c currentTitle]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
        if (!t.length) continue;
        for (NSString *want in titles) { if ([t isEqualToString:want]) return c; }
    }
    return nil;
}

- (UIControl *)findLikeControlIn:(NSArray<UIControl *> *)controls {
    // Dislike EXCLUDES like: "like" is a substring of "dislike", so a control whose
    // identity is "Dislike" / "dislike_button" must never be picked as a LIKE — that
    // cross-match made the ratio meaningless (nearly every vote went to the "like"
    // control even at 50/50). Merge the dislike keywords into the avoid set here.
    NSMutableArray<NSString *> *avoid = [NSMutableArray arrayWithArray:IVSwipeAvoidKeywords()];
    [avoid addObjectsFromArray:IVDislikeKeywords()];
    return [self findControlIn:controls keywords:IVLikeKeywords() avoid:avoid];
}

- (UIControl *)findDislikeControlIn:(NSArray<UIControl *> *)controls {
    NSMutableArray<NSString *> *avoid = [NSMutableArray arrayWithArray:IVSwipeAvoidKeywords()];
    [avoid addObjectsFromArray:IVLikeKeywords()];
    return [self findControlIn:controls keywords:IVDislikeKeywords() avoid:avoid];
}
// The top swipe card: the largest plausible card-shaped container across the scanned
// windows — a big, non-scrolling slab occupying 30–92% of the screen (not the whole
// window, not a list/collection). We only need one to swipe on and verify movement.
- (UIView *)findCardInWindows:(NSArray<UIWindow *> *)windows {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat screenArea = screen.size.width * screen.size.height;
    if (screenArea <= 0) return nil;
    UIView *best = nil;
    CGFloat bestArea = 0;
    for (UIWindow *w in windows) {
        [self scanCardIn:w screenArea:screenArea best:&best bestArea:&bestArea depth:0];
    }
    return best;
}

- (void)scanCardIn:(UIView *)v screenArea:(CGFloat)screenArea
              best:(UIView * __strong *)best bestArea:(CGFloat *)bestArea depth:(int)depth {
    if (v.hidden || v.alpha < 0.2 || depth > 40) return;
    CGSize sz = v.bounds.size;
    CGFloat area = sz.width * sz.height;
    CGFloat frac = area / screenArea;
    BOOL plausible = (frac >= 0.30 && frac <= 0.92 &&
                      ![v isKindOfClass:[UIControl class]] &&
                      ![v isKindOfClass:[UIScrollView class]] &&
                      ![v isKindOfClass:[UICollectionView class]] &&
                      ![v isKindOfClass:[UITableView class]]);
    if (plausible && area >= *bestArea) { *best = v; *bestArea = area; }
    for (UIView *sub in v.subviews) [self scanCardIn:sub screenArea:screenArea best:best bestArea:bestArea depth:depth + 1];
}
// First on-screen text input across the windows. Returns the view and, via out-params,
// its concrete kind so the caller can set .text on the right type.
- (UIView *)findTextInputInWindows:(NSArray<UIWindow *> *)windows
                          textView:(UITextView * __autoreleasing *)tvOut
                         textField:(UITextField * __autoreleasing *)tfOut {
    for (UIWindow *w in windows) {
        UIView *found = [self scanTextInputIn:w textView:tvOut textField:tfOut];
        if (found) return found;
    }
    return nil;
}

- (UIView *)scanTextInputIn:(UIView *)v
                   textView:(UITextView * __autoreleasing *)tvOut
                  textField:(UITextField * __autoreleasing *)tfOut {
    if (v.hidden || v.alpha < 0.01) return nil;
    if ([v isKindOfClass:[UITextView class]] && v.userInteractionEnabled) {
        if (tvOut) *tvOut = (UITextView *)v; return v;
    }
    if ([v isKindOfClass:[UITextField class]] && ((UITextField *)v).enabled) {
        if (tfOut) *tfOut = (UITextField *)v; return v;
    }
    for (UIView *sub in v.subviews) {
        UIView *f = [self scanTextInputIn:sub textView:tvOut textField:tfOut];
        if (f) return f;
    }
    return nil;
}
#pragma mark - Gesture synthesis (private UITouch/UIEvent, best-effort)

// Synthesize a horizontal finger swipe across the card (right = like, left = dislike)
// using private UITouch/UIEvent selectors. Every selector is respondsToSelector-guarded
// and wrapped in @try; on ANY gap we return NO so performAction: switches to buttons.
// Whether it actually worked is verified NEXT tick by checking the card moved.
- (BOOL)synthesizeSwipeOnCard:(UIView *)card like:(BOOL)like {
    UIWindow *win = card.window;
    if (!win) return NO;
    Class touchCls = NSClassFromString(@"UITouch");
    UIApplication *app = UIApplication.sharedApplication;
    SEL selPhase = NSSelectorFromString(@"setPhase:");
    SEL selLoc   = NSSelectorFromString(@"_setLocationInWindow:resetPrevious:");
    SEL selWin   = NSSelectorFromString(@"setWindow:");
    SEL selView  = NSSelectorFromString(@"setView:");
    SEL selTap   = NSSelectorFromString(@"setTapCount:");
    SEL selTs    = NSSelectorFromString(@"setTimestamp:");
    SEL selEvt   = NSSelectorFromString(@"_touchesEvent");
    SEL selAdd   = NSSelectorFromString(@"_addTouch:forDelayedDelivery:");
    SEL selClear = NSSelectorFromString(@"_clearTouches");
    UITouch *touch = touchCls ? [touchCls new] : nil;
    if (!touch || ![touch respondsToSelector:selPhase] || ![touch respondsToSelector:selLoc]
        || ![touch respondsToSelector:selWin] || ![touch respondsToSelector:selView]
        || ![app respondsToSelector:selEvt]) return NO;

    CGRect b = card.bounds;
    CGPoint startInWin = [card convertPoint:CGPointMake(b.size.width * 0.5, b.size.height * 0.55) toView:win];
    UIView *hit = [win hitTest:startInWin withEvent:nil] ?: card;
    CGFloat dx = win.bounds.size.width * (like ? 0.45 : -0.45);
    CGFloat startX = startInWin.x, y = startInWin.y;

    id evt = ((id(*)(id, SEL))objc_msgSend)(app, selEvt);
    if (!evt) return NO;

    void (^send)(NSInteger, CGPoint, BOOL) = ^(NSInteger phase, CGPoint p, BOOL reset) {
        @try {
            ((void(*)(id, SEL, id))objc_msgSend)(touch, selWin, win);
            ((void(*)(id, SEL, id))objc_msgSend)(touch, selView, hit);
            if ([touch respondsToSelector:selTap]) ((void(*)(id, SEL, NSUInteger))objc_msgSend)(touch, selTap, 1);
            if ([touch respondsToSelector:selTs])  ((void(*)(id, SEL, double))objc_msgSend)(touch, selTs, NSProcessInfo.processInfo.systemUptime);
            ((void(*)(id, SEL, CGPoint, BOOL))objc_msgSend)(touch, selLoc, p, reset);
            ((void(*)(id, SEL, NSInteger))objc_msgSend)(touch, selPhase, phase);
            if ([evt respondsToSelector:selClear]) ((void(*)(id, SEL))objc_msgSend)(evt, selClear);
            if ([evt respondsToSelector:selAdd])   ((void(*)(id, SEL, id, BOOL))objc_msgSend)(evt, selAdd, touch, NO);
            [app sendEvent:evt];
        } @catch (__unused NSException *e) {}
    };
    // Deliver began → 6 moves → ended, spaced over ~0.24s on the main queue, so the pan
    // recognizer sees distinct timestamps/locations. Generation-guarded: stop() bumps
    // _gen and the remaining steps become no-ops.
    NSInteger gen = _gen;
    const int steps = 6;
    send(UITouchPhaseBegan, CGPointMake(startX, y), YES);
    for (int i = 1; i <= steps; i++) {
        double t = 0.03 * i;
        CGFloat x = startX + dx * ((CGFloat)i / steps);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gen != self->_gen) return;
            send(UITouchPhaseMoved, CGPointMake(x, y), NO);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * (steps + 1) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != self->_gen) return;
        send(UITouchPhaseEnded, CGPointMake(startX + dx, y), NO);
    });
    return YES;
}
#pragma mark - Low-level helpers

// Tap a control the way UIKit would: send its touch-up-inside actions. More reliable
// than synthesizing a touch for a plain button, and enough for Instagram's like/dislike/OK.
- (void)tapControl:(UIControl *)c {
    if (!c) return;
    @try { [c sendActionsForControlEvents:UIControlEventTouchUpInside]; }
    @catch (__unused NSException *e) {}
}

// Lowercased identity string for keyword matching: accessibilityIdentifier +
// accessibilityLabel + (for buttons) the current title.
- (NSString *)identityFor:(UIView *)v {
    NSMutableString *s = [NSMutableString new];
    if (v.accessibilityIdentifier.length) [s appendFormat:@"%@ ", v.accessibilityIdentifier];
    if (v.accessibilityLabel.length)      [s appendFormat:@"%@ ", v.accessibilityLabel];
    if ([v isKindOfClass:[UIButton class]]) {
        NSString *t = [(UIButton *)v currentTitle];
        if (t.length) [s appendFormat:@"%@ ", t];
    }
    return s.lowercaseString;
}

- (BOOL)text:(NSString *)text matchesAny:(NSArray<NSString *> *)keys {
    if (!text.length) return NO;
    NSString *low = text.lowercaseString;
    for (NSString *k in keys) { if (k.length && [low containsString:k]) return YES; }
    return NO;
}

@end
