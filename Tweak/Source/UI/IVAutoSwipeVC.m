#import "IVAutoSwipeVC.h"
#import "IVTheme.h"
#import "IVFloatingButton.h"
#import "IVL10n.h"
#import "../Core/IVContainerStore.h"
#import "../Util/IVAutoSwipe.h"
#import "../Util/IVDiagnostics.h"

@interface IVAutoSwipeVC () <UITextViewDelegate>
@property (nonatomic, strong) IVContainer *container;
@property (nonatomic, strong) UITextView *phrasesView;
@property (nonatomic, strong) UISegmentedControl *methodControl;
@property (nonatomic, strong) UITextField *countField;
@property (nonatomic, strong) UITextField *likeField;
@property (nonatomic, strong) UITextField *dislikeField;
@property (nonatomic, strong) UITextField *minField;
@property (nonatomic, strong) UITextField *maxField;
@property (nonatomic, strong) UIButton *runButton;
@end

@implementation IVAutoSwipeVC

- (instancetype)initWithContainer:(IVContainer *)container {
    if ((self = [super init])) { _container = container; }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = IVLL(@"swipe.title", @"Auto-swipe");
    self.view.backgroundColor = IVTheme.panelBackground;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    UINavigationBar *bar = self.navigationController.navigationBar;
    bar.tintColor = IVTheme.accent;
    UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
    [ap configureWithOpaqueBackground];
    ap.backgroundColor = IVTheme.panelBackground;
    ap.shadowColor = UIColor.clearColor;
    ap.titleTextAttributes = @{ NSForegroundColorAttributeName: IVTheme.primaryText };
    bar.standardAppearance = ap;
    bar.scrollEdgeAppearance = ap;
    bar.compactAppearance = ap;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:IVLL(@"create.save", @"Enregistrer") style:UIBarButtonItemStyleDone
                                        target:self action:@selector(saveAndPop)];
    [self buildForm];
}

#pragma mark - Form

- (void)buildForm {
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];

    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:18],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-18],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-36],
    ]];

    [stack addArrangedSubview:[self sectionTitle:IVLL(@"swipe.msgSection", @"Phrases envoyées sur un match")]];
    [stack addArrangedSubview:[self hint:IVLL(@"swipe.msgHint", @"Une phrase par ligne. À chaque match, le bot en envoie une au hasard. Laisse vide pour liker sans écrire.")]];
    self.phrasesView = [self makeTextView];
    [self.phrasesView.heightAnchor constraintGreaterThanOrEqualToConstant:72].active = YES;
    self.phrasesView.text = [self.container.autoSwipeMessages componentsJoinedByString:@"\n"] ?: @"";
    [stack addArrangedSubview:self.phrasesView];

    [stack addArrangedSubview:[self sectionTitle:IVLL(@"swipe.method", @"Méthode")]];
    self.methodControl = [[UISegmentedControl alloc] initWithItems:@[ IVLL(@"swipe.buttons", @"Boutons"), IVLL(@"swipe.gestures", @"Gestes") ]];
    self.methodControl.selectedSegmentIndex = (self.container.autoSwipeMethod == 1) ? 1 : 0;
    self.methodControl.selectedSegmentTintColor = IVTheme.accent;
    [self.methodControl setTitleTextAttributes:@{ NSForegroundColorAttributeName: IVTheme.secondaryText } forState:UIControlStateNormal];
    [self.methodControl setTitleTextAttributes:@{ NSForegroundColorAttributeName: IVTheme.onAccent } forState:UIControlStateSelected];
    [self.methodControl.heightAnchor constraintEqualToConstant:36].active = YES;
    [stack addArrangedSubview:self.methodControl];
    [stack addArrangedSubview:[self hint:@"Boutons : appuie sur le ✕ / ♥ de Instagram (robuste). Gestes : simule un glissement du doigt gauche/droite (repli automatique sur Boutons si indisponible)."]];

    [stack addArrangedSubview:[self sectionTitle:IVLL(@"swipe.params", @"Paramètres de swipe")]];
    self.countField = [self fieldRowInStack:stack label:@"Nombre de swipes (0 = illimité)"
                                       value:(self.container.autoSwipeCount > 0 ? [NSString stringWithFormat:@"%ld", (long)self.container.autoSwipeCount] : @"0")];
    self.countField.keyboardType = UIKeyboardTypeNumberPad;

    NSInteger like = self.container.autoSwipeLikePercent;
    if (like < 0 || like > 100) like = 50;
    self.likeField = [self fieldRowInStack:stack label:IVLL(@"swipe.likeLabel", @"% de like (droite)")
                                      value:[NSString stringWithFormat:@"%ld", (long)like]];
    self.likeField.keyboardType = UIKeyboardTypeNumberPad;
    [self.likeField addTarget:self action:@selector(likeChanged) forControlEvents:UIControlEventEditingChanged];

    self.dislikeField = [self fieldRowInStack:stack label:@"% de dislike (gauche)"
                                         value:[NSString stringWithFormat:@"%ld", (long)(100 - like)]];
    self.dislikeField.keyboardType = UIKeyboardTypeNumberPad;
    [self.dislikeField addTarget:self action:@selector(dislikeChanged) forControlEvents:UIControlEventEditingChanged];

    self.minField = [self fieldRowInStack:stack label:IVLL(@"swipe.min", @"Délai min entre actions (s)")
                                     value:(self.container.autoSwipeMinDelay >= 1 ? [self fmt:self.container.autoSwipeMinDelay] : @"3")];
    self.maxField = [self fieldRowInStack:stack label:IVLL(@"swipe.max", @"Délai max entre actions (s)")
                                     value:(self.container.autoSwipeMaxDelay >= 1 ? [self fmt:self.container.autoSwipeMaxDelay] : @"7")];

    [stack addArrangedSubview:[self hint:IVLL(@"swipe.detectHint", @"Détection best-effort : le bot agit sur l'UI de Instagram (like/dislike + popup « match »). Selon la version de Instagram, un réglage sur l'appareil peut être nécessaire.")]];

    self.runButton = [self makeRunButton];
    [self.runButton.heightAnchor constraintEqualToConstant:52].active = YES;
    [stack addArrangedSubview:self.runButton];
    [self refreshRunButton];
}

#pragma mark - Builders

- (UILabel *)sectionTitle:(NSString *)text {
    UILabel *l = [UILabel new];
    l.text = text.uppercaseString;
    l.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    l.textColor = IVTheme.secondaryText;
    l.numberOfLines = 0;
    return l;
}

- (UILabel *)hint:(NSString *)text {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont systemFontOfSize:12];
    l.textColor = IVTheme.secondaryText;
    l.numberOfLines = 0;
    return l;
}

- (UITextView *)makeTextView {
    UITextView *tv = [UITextView new];
    tv.backgroundColor = IVTheme.glassFill;
    tv.textColor = IVTheme.primaryText;
    tv.font = [UIFont systemFontOfSize:15];
    tv.layer.cornerRadius = 10;
    tv.layer.borderWidth = 1;
    tv.layer.borderColor = IVTheme.glassStroke.CGColor;
    tv.textContainerInset = UIEdgeInsetsMake(10, 8, 10, 8);
    tv.keyboardAppearance = UIKeyboardAppearanceDark;
    tv.delegate = self;
    return tv;
}

// Trim trailing zeros: 3.0 -> "3", 3.5 -> "3.5".
- (NSString *)fmt:(double)v {
    if (v == floor(v)) return [NSString stringWithFormat:@"%ld", (long)v];
    return [NSString stringWithFormat:@"%.1f", v];
}

- (UITextField *)fieldRowInStack:(UIStackView *)stack label:(NSString *)label value:(NSString *)value {
    UIStackView *row = [UIStackView new];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8;

    UILabel *l = [UILabel new];
    l.text = label;
    l.font = [UIFont systemFontOfSize:15];
    l.textColor = IVTheme.primaryText;
    l.numberOfLines = 0;
    [l setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UITextField *tf = [UITextField new];
    tf.text = value;
    tf.textAlignment = NSTextAlignmentLeft;
    tf.textColor = IVTheme.primaryText;
    tf.font = [UIFont monospacedDigitSystemFontOfSize:16 weight:UIFontWeightSemibold];
    tf.keyboardType = UIKeyboardTypeDecimalPad;
    tf.keyboardAppearance = UIKeyboardAppearanceDark;
    tf.backgroundColor = IVTheme.glassFill;
    tf.layer.cornerRadius = 8;
    tf.layer.borderWidth = 1;
    tf.layer.borderColor = IVTheme.glassStroke.CGColor;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 0)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    // A "Fermer" toolbar above the numeric pad (number/decimal pads have NO return
    // key, so without this the keyboard stays up and blocks the fields below —
    // the "le clavier reste en permanence, je ne peux pas toucher le dernier
    // champ" bug). One shared toolbar instance per field target.
    tf.inputAccessoryView = [self makeInputToolbarTargetAction:@selector(dismissKeyboard)];
    [tf.widthAnchor constraintEqualToConstant:90].active = YES;
    [tf.heightAnchor constraintEqualToConstant:38].active = YES;
    [tf setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [tf setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    [row addArrangedSubview:l];
    [row addArrangedSubview:tf];
    [stack addArrangedSubview:row];
    return tf;
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

- (UIToolbar *)makeInputToolbarTargetAction:(SEL)action {
    UIToolbar *tb = [UIToolbar new];
    [tb sizeToFit];
    UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithTitle:IVLL(@"panel.close", @"Fermer") style:UIBarButtonItemStyleDone target:self action:action];
    tb.items = @[flex, done];
    return tb;
}

- (UIButton *)makeRunButton {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = 14;
    [b addTarget:self action:@selector(toggleRun) forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)refreshRunButton {
    BOOL running = [IVAutoSwipe shared].isRunning;
    [self.runButton setTitle:(running ? IVLL(@"swipe.stop", @"Arrêter l'auto-swipe") : IVLL(@"swipe.start", @"Démarrer l'auto-swipe")) forState:UIControlStateNormal];
    self.runButton.backgroundColor = running ? IVTheme.elevatedSurface : IVTheme.accent;
    [self.runButton setTitleColor:(running ? IVTheme.primaryText : IVTheme.onAccent) forState:UIControlStateNormal];
    self.runButton.layer.borderWidth = running ? 1 : 0;
    self.runButton.layer.borderColor = IVTheme.glassStroke.CGColor;
}

#pragma mark - Persist + actions

- (NSArray<NSString *> *)parsedPhrases {
    NSMutableArray<NSString *> *out = [NSMutableArray new];
    for (NSString *raw in [self.phrasesView.text componentsSeparatedByString:@"\n"]) {
        NSString *t = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.length) [out addObject:t];
    }
    return out;
}

// Auto-complement: like% + dislike% must sum to 100. Editing one fills the other.
// Clamp to 0..100 as the user types; leave the edited field's raw text alone so the
// caret doesn't jump, only rewrite the sibling.
- (void)likeChanged {
    NSInteger v = [self.likeField.text integerValue];
    if (v < 0) v = 0; if (v > 100) v = 100;
    self.dislikeField.text = [NSString stringWithFormat:@"%ld", (long)(100 - v)];
}

- (void)dislikeChanged {
    NSInteger v = [self.dislikeField.text integerValue];
    if (v < 0) v = 0; if (v > 100) v = 100;
    self.likeField.text = [NSString stringWithFormat:@"%ld", (long)(100 - v)];
}

// Read + clamp the form, reflect the clamped values back into the fields, persist.
- (BOOL)persistConfigEnabled:(BOOL)enabled {
    NSArray<NSString *> *msgs = [self parsedPhrases];
    NSInteger count = [self.countField.text integerValue];
    if (count < 0) count = 0;
    NSInteger method = self.methodControl.selectedSegmentIndex == 1 ? 1 : 0;
    NSInteger like = [self.likeField.text integerValue];
    if (like < 0) like = 0; if (like > 100) like = 100;
    double mn = [self.minField.text doubleValue];
    double mx = [self.maxField.text doubleValue];
    if (mn < 1) mn = 1;
    if (mx < mn) mx = mn;
    self.countField.text = [NSString stringWithFormat:@"%ld", (long)count];
    self.likeField.text = [NSString stringWithFormat:@"%ld", (long)like];
    self.dislikeField.text = [NSString stringWithFormat:@"%ld", (long)(100 - like)];
    self.minField.text = [self fmt:mn];
    self.maxField.text = [self fmt:mx];
    return [[IVContainerStore shared] setAutoSwipeEnabled:enabled messages:msgs
                                                    count:count minDelay:mn maxDelay:mx
                                                   method:method likePercent:like
                                             forContainer:self.container];
}

- (void)warn {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Échec"
        message:@"La configuration n'a pas pu être enregistrée (écriture disque). Réessaie."
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

// "Enregistrer": persist the config (lights the row icon), stay in the panel.
- (void)saveAndPop {
    [self.view endEditing:YES];
    if (![self persistConfigEnabled:YES]) { [self warn]; return; }
    [self.navigationController popViewControllerAnimated:YES];
}

// "Démarrer": persist, start the engine, and dismiss the WHOLE panel so Instagram's
// own UI is frontmost for the bot to drive. The floating button stays available:
// a programmatic dismiss fires neither the panel's onClose nor the presentation
// delegate, so the button (hidden while the panel was up) is restored explicitly
// in the dismiss completion — "les Swipe démarrent et le menu reste en place".
// "Arrêter": stop the engine, stay.
- (void)toggleRun {
    [self.view endEditing:YES];
    if ([IVAutoSwipe shared].isRunning) {
        [[IVAutoSwipe shared] stop];
        [self refreshRunButton];
        return;
    }
    if (![self persistConfigEnabled:YES]) { [self warn]; return; }
    [[IVAutoSwipe shared] startWithContainer:self.container];
    [self dismissViewControllerAnimated:YES completion:^{
        [[IVFloatingButton shared] restoreButtonAfterExternalDismiss];
    }];
}

@end
