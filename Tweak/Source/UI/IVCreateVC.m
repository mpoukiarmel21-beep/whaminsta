#import "IVCreateVC.h"
#import "IVListPickerVC.h"
#import "IVTheme.h"
#import "IVL10n.h"
#import "../Core/IVContainer.h"
#import "../Core/IVContainerStore.h"
#import "../Spoof/IVDeviceIdentity.h"
#import "../Spoof/IVLocaleSpoof.h"

#pragma mark - Create / edit

@interface IVCreateVC () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong, nullable) IVContainer *editing;   // nil == create
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UITextField *nameField;
@property (nonatomic, copy) NSString *chosenModel;        // identifier, e.g. "iPhone17,1"
@property (nonatomic, copy) NSString *chosenIOS;          // marketing, e.g. "26.6.1"
@property (nonatomic, copy, nullable) NSString *seedCID;  // create only: cid minted up-front to seed a unique fingerprint
@end

@implementation IVCreateVC

- (instancetype)initWithContainer:(IVContainer *)container {
    if ((self = [super init])) {
        _editing = container;
        if (container) {
            // Edit: keep the container's saved identity; if a legacy container has
            // none, fall back to a UNIQUE per-cid identity (never the shared newest).
            _chosenModel = container.deviceModel.length ? container.deviceModel
                            : [IVDeviceIdentity seededModelForCID:container.cid].identifier;
            _chosenIOS = container.iosVersion.length ? container.iosVersion
                            : [IVDeviceIdentity seededIOSVersionForCID:container.cid];
            _appLanguage = container.appLanguage ?: @"";
            _regionCountry = container.regionCountry ?: @"";
        } else {
            // Create: mint the cid NOW and derive a UNIQUE fingerprint from it, so
            // every new container defaults to a DISTINCT device + iOS instead of all
            // sharing the newest one (the multi-account fingerprint collision that
            // trips Instagram). The user can still override both in the pickers; the
            // same cid is handed to the store at save so the whole identity (model,
            // iOS, serial, UDID, IDFV) derives from one seed.
            _seedCID = [[NSUUID UUID] UUIDString];
            _chosenModel = [IVDeviceIdentity seededModelForCID:_seedCID].identifier;
            _chosenIOS = [IVDeviceIdentity seededIOSVersionForCID:_seedCID];
            // Auto-detect device language and region for the new container, matching
            // against Instagram's supported locales. The user sees these pre-selected and
            // can override them in the picker before saving ("détecter le système et la
            // langage du téléphone ... par défaut, il va sélectionner la langue anglais
            // et le pays US"). nil/empty = keep as "Automatique" (no override, real
            // device locale shown).
            _appLanguage = [IVLocaleSpoof deviceLanguage] ?: @"";
            _regionCountry = [IVLocaleSpoof deviceRegion] ?: @"";
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.editing ? IVLL(@"create.title.edit", @"Modifier") : IVLL(@"create.title.new", @"Nouveau conteneur");
    self.view.backgroundColor = IVTheme.panelBackground;
    // Pin Dark so the grouped table, its separators and system controls read as
    // one dark surface with the pickers pushed from here.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    // Opaque dark nav bar (same recipe as the main panel) so this screen AND the
    // model / iOS pickers pushed from it read as one dark surface — never the bare
    // white bar the default appearance would give.
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

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self action:@selector(save)];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.backgroundColor = UIColor.clearColor;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)save {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length == 0) name = @"Conteneur";
    NSString *marketing = [IVDeviceIdentity marketingNameForIdentifier:self.chosenModel];
    IVContainerStore *store = [IVContainerStore shared];

    IVContainer *target = self.editing;
    if (target) {
        if (![store renameContainer:target to:name]) { [self warnSaveFailed]; return; }
    } else {
        // Pass the up-front cid so the container adopts the exact identity previewed
        // above (model + iOS derived from this same seed).
        target = [store createWithName:name cid:self.seedCID];
        if (!target) { [self warnSaveFailed]; return; }
    }
    if (![store setDeviceModel:self.chosenModel
                    iosVersion:self.chosenIOS
                 marketingName:marketing
                  forContainer:target]) {
        [self warnSaveFailed];
        return;
    }

    // Persist the language/region selection (auto-detected for new containers,
    // kept for edits). Empty string == "Automatique" → no override.
    if (![store setAppLanguage:(self.appLanguage.length ? self.appLanguage : nil)
                        region:(self.regionCountry.length ? self.regionCountry : nil)
                  forContainer:target]) {
        [self warnSaveFailed];
        return;
    }

    // Création comme édition : le conteneur est enregistré, on revient simplement
    // au panneau (comportement historique rétabli en build-11, à la demande de
    // l'utilisateur). Créer un conteneur ne fait que l'AJOUTER à la liste ; pour
    // l'activer, l'utilisateur tape la ligne puis « Activer ce conteneur »
    // (IVPanelVC.activate: persiste le cid actif puis ferme l'app pour une relance
    // à froid). Plus aucun pop-up « Activer et fermer / Plus tard » après
    // l'enregistrement.
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)warnSaveFailed {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:IVLL(@"common.savefail.t", @"Échec de l'enregistrement")
        message:IVLL(@"common.savefail.m", @"Le conteneur n'a pas pu être enregistré (écriture disque échouée). Réessaie.")
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:IVLL(@"common.ok", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Table (row 0: name, row 1: model, row 2: iOS version, row 3: langue, row 4: région)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 1; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return 5; }

- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return [NSString stringWithFormat:@"Modèles limités à la puce réelle (%@). Chaque conteneur répond ces informations à Instagram.",
            [IVDeviceIdentity realChipFamily]];
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"n"];
        cell.backgroundColor = IVTheme.glassFill;
        if (!self.nameField) {
            self.nameField = [[UITextField alloc] initWithFrame:CGRectInset(cell.contentView.bounds, 16, 0)];
            self.nameField.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            self.nameField.placeholder = IVLL(@"create.name", @"Nom du conteneur");
            self.nameField.text = self.editing.name;
            self.nameField.textColor = IVTheme.primaryText;
            self.nameField.clearButtonMode = UITextFieldViewModeWhileEditing;
            self.nameField.delegate = self;
        }
        [cell.contentView addSubview:self.nameField];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"v"];
    cell.backgroundColor = IVTheme.glassFill;
    cell.textLabel.textColor = IVTheme.primaryText;
    cell.detailTextLabel.textColor = IVTheme.secondaryText;
    switch (ip.row) {
        case 1:
            cell.textLabel.text = IVLL(@"create.model", @"Modèle d'appareil");
            cell.detailTextLabel.text = [IVDeviceIdentity marketingNameForIdentifier:self.chosenModel];
            break;
        case 2: {
            NSString *build = [IVDeviceIdentity buildForIOSVersion:self.chosenIOS];
            cell.textLabel.text = IVLL(@"create.ios", @"Version iOS");
            cell.detailTextLabel.text = build.length
                ? [NSString stringWithFormat:@"%@ (%@)", self.chosenIOS, build]
                : self.chosenIOS;
            break;
        }
        case 3:
            cell.textLabel.text = IVLL(@"panel.locale", @"Langue de l'application");
            cell.detailTextLabel.text = self.appLanguage.length
                ? [IVLocaleSpoof displayNameForLanguage:self.appLanguage] : IVLL(@"panel.auto", @"Automatique (système)");
            break;
        case 4:
            cell.textLabel.text = IVLL(@"panel.region", @"Pays / région");
            cell.detailTextLabel.text = self.regionCountry.length
                ? [IVLocaleSpoof displayNameForRegion:self.regionCountry] : IVLL(@"panel.auto", @"Automatique (système)");
            break;
        default:
            break;
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    UIView *sel = [UIView new];
    sel.backgroundColor = IVTheme.elevatedSurface;
    cell.selectedBackgroundView = sel;
    return cell;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    switch (ip.row) {
        case 1: [self pickModel]; break;
        case 2: [self pickIOS]; break;
        case 3: [self pickLanguage]; break;
        case 4: [self pickRegion]; break;
        default: break;
    }
}

// Auto-detected language picker — same options as the settings sheet, so the user
// can override the device-detected value before saving.
- (void)pickLanguage {
    NSMutableArray<IVListOption *> *opts = [NSMutableArray new];
    [opts addObject:[IVListOption value:@"" title:IVLL(@"panel.auto", @"Automatique (système)") subtitle:nil]];
    for (NSString *code in [IVLocaleSpoof supportedLanguageCodes]) {
        [opts addObject:[IVListOption value:code title:[IVLocaleSpoof displayNameForLanguage:code] subtitle:code]];
    }
    __weak typeof(self) ws = self;
    IVListPickerVC *p = [[IVListPickerVC alloc] initWithTitle:IVLL(@"panel.locale", @"Langue de l'application")
                                                      options:opts
                                                selectedValue:self.appLanguage
                                                       onPick:^(IVListOption *o) {
        ws.appLanguage = o.value.length ? o.value : @"";
        [ws.table reloadData];
    }];
    [self.navigationController pushViewController:p animated:YES];
}

- (void)pickRegion {
    NSMutableArray<IVListOption *> *opts = [NSMutableArray new];
    [opts addObject:[IVListOption value:@"" title:IVLL(@"panel.auto", @"Automatique (système)") subtitle:nil]];
    for (NSString *code in [IVLocaleSpoof supportedRegionCodes]) {
        [opts addObject:[IVListOption value:code title:[IVLocaleSpoof displayNameForRegion:code] subtitle:code]];
    }
    __weak typeof(self) ws = self;
    IVListPickerVC *p = [[IVListPickerVC alloc] initWithTitle:IVLL(@"panel.region", @"Pays / région")
                                                      options:opts
                                                selectedValue:self.regionCountry
                                                       onPick:^(IVListOption *o) {
        ws.regionCountry = o.value.length ? o.value : @"";
        [ws.table reloadData];
    }];
    [self.navigationController pushViewController:p animated:YES];
}

- (void)pickModel {
    NSMutableArray<IVListOption *> *opts = [NSMutableArray new];
    for (IVDeviceModel *m in [IVDeviceIdentity modelsForRealChip]) {
        [opts addObject:[IVListOption value:m.identifier title:m.marketingName subtitle:m.identifier]];
    }
    __weak typeof(self) ws = self;
    IVListPickerVC *p = [[IVListPickerVC alloc] initWithTitle:IVLL(@"create.model", @"Modèle d'appareil")
                                                      options:opts
                                                selectedValue:self.chosenModel
                                                       onPick:^(IVListOption *o) {
        ws.chosenModel = o.value;
        [ws.table reloadData];
    }];
    [self.navigationController pushViewController:p animated:YES];
}

- (void)pickIOS {
    NSMutableArray<IVListOption *> *opts = [NSMutableArray new];
    for (NSString *v in [IVDeviceIdentity iosVersions]) {
        NSString *build = [IVDeviceIdentity buildForIOSVersion:v];
        [opts addObject:[IVListOption value:v title:v subtitle:build.length ? [@"build " stringByAppendingString:build] : nil]];
    }
    __weak typeof(self) ws = self;
    IVListPickerVC *p = [[IVListPickerVC alloc] initWithTitle:IVLL(@"create.ios", @"Version iOS")
                                                      options:opts
                                                selectedValue:self.chosenIOS
                                                       onPick:^(IVListOption *o) {
        ws.chosenIOS = o.value;
        [ws.table reloadData];
    }];
    [self.navigationController pushViewController:p animated:YES];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }

@end
