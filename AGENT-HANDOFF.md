# AGENT-HANDOFF — whaminsta

## État actuel

Tweak d'isolation multi-conteneurs pour **Instagram** (`com.burbn.instagram`),
sans jailbreak (dylib injectée + re-sign Sideloadly). Repo public :
`https://github.com/mpoukiarmel21-beep/whaminsta` (branche `master`). Base =
`com.burbn.instagram_442.0.0_und3fined.ipa` (InstaVault release `v1.0-ipa`,
asset inchangé depuis le 2026-08-20 — vérifié).

**build-16 livré** (run `37091882755` SUCCESS) :
`https://github.com/mpoukiarmel21-beep/whaminsta/releases/download/build-16/whaminsta.ipa`
= build-15 **+ correction du hang à l'étape nom** + isolation du nom d'appareil.
Build-15 (run `33627557672` SUCCESS) =
`https://github.com/mpoukiarmel21-beep/whaminsta/releases/download/build-15/whaminsta.ipa`
= **alignement complet sur InstaVault** (projet sœur où la création de compte
fonctionne) : whaminsta hookait des surfaces qu'InstaVault n'a jamais eues (ou a
retirées « for stability » — commentaire documenté dans son IVHardwareHook), et
ce sont exactement celles qu'active le fingerprinting d'Instagram à l'étape nom
du signup.

**Retour utilisateur build-15 : le crash était devenu un HANG** — spinner
infini au champ nom. Cause identifiée et corrigée en build-16 (voir Journal,
2026-10-03) : le rate-limit 0,5 s ajouté en build-14 **jetait le callback** de
`-requestLocation`, donc Instagram attendait une réponse qui n'arrivait jamais.

## En cours

- **User — test build-16** (2026-10-03). Déposée aussi dans
  `D:\IPA APP\NEW INSTA.ipa`. À vérifier : Instagram → Créer un compte →
  nom doit passer, la localisation fake doit s'appliquer.

## Prochaine étape

1. **User : installer build-16** et reproduire (Instagram → Créer un compte →
   nom). Le spinner doit passer.
2. Si le hang persiste : extraire `tweak.log` (`<HOME real>/Documents/whaminsta/logs/`)
   — ce serait alors un comportement réseau/Instagram, plus un callback non
   délivré par nous.
3. Si crash (peu probable) : l'alerte « Crash détecté » capture les
   stack-overflow (sigaltstack, build-14) → coller la stack ici.
4. Builds suivants : `gh workflow run build.yml --repo mpoukiarmel21-beep/whaminsta
   --ref master -f ipa_url=https://github.com/mpoukiarmel21-beep/InstaVault/releases/download/v1.0-ipa/com.burbn.instagram_442.0.0_und3fined.ipa`

## Blocages / risques

- **Contradiction build-8 vs build-11/12** (même binaire, résultats opposés)
  — non résolue : soit le crash est dans le base IPA, soit intermittent, soit
  l'utilisateur a confondu les builds. Le logger/alerte doit trancher.
- **Aucun build local** (Windows/PowerShell, pas de Theos/macOS) : builds
  uniquement en CI GitHub Actions (runner `macos-14`, repo **public**).
- Base IPA `..._und3fined.ipa` = IPA cracké/patched : si la stack montre des
  frames Instagram sans aucun `whaminsta.dylib`, changer de base est la seule
  issue.

## Journal

- **2026-10-03 (OpenCode) — hang « étape nom » : le rate-limit jetait le
  callback**. Après build-15 le symptom n'est plus un crash mais un spinner
  infini au champ nom. Revue de IVLocationSpoof.m : `IVDeliverFakeOnce` avait
  un rate-limit 0,5 s (`kIVLastFakeDeliverKey`) hérité du build-14. Instagram
  appelle `-startUpdatingLocation` puis `-requestLocation` de suite pendant la
  validation du nom → la **deuxième** demande tombait dans la fenêtre et son
  callback était **supprimé sans explication** → l'app attend une réponse qui
  n'arrivera jamais. C'est le même chemin location que l'ancien crash, avec un
  symptôme différent : build-14 a remplacé la boucle par un abandon. Fix : le
  rate-limit (temporel, jette des demandes légitimes) est remplacé par une
  **garde de récursion** `gInDelivery` (booléen, ne bloque que la ré-entrance
  depuis l'intérieur de notre propre livraison — la seule forme qui peut
  réellement boucler), livraison **synchrone sur main** (plus de `dispatch_async`
  qui rendait les deux demandes inséparables), et fallback
  `locationManager:didFailWithError:`/`kCLErrorLocationUnknown` quand aucun
  délégué ne sait recevoir un fix — jamais de repli sur le vrai
  `-startUpdatingLocation` (sinon fuite de la vraie position). Résultat :
  **chaque demande reçoit une réponse**, et le GPS réel n'est jamais démarré.
  + audit isolation : surfaces déjà colmatées (prefs, app-group, files, IDFV/
  IDFA, locale/heure, DeviceCheck/Attest, AutoFill, keychain y compris la clé
  device Meta via tag `kSecClassKey` namespacé). **Restait `UIDevice.name`** —
  même nom d'appareil dans tous les conteneurs, seule surface restante sans
  contre-vérification (modèle et version iOS restent réels volontairement pour
  rester cohérents avec sysctl/NSProcessInfo). Ajout d'un nom déterministe par
  cid. + `IVDeviceSpoof.h` remis en phase : il documentait encore sysctl/uname/
  MGCopyAnswer et le spoof de version iOS, tous retirés en build-15. Commit
  `e8b69f3`, run `37091882755` SUCCESS → release **build-16**, également
  déposée dans `D:\IPA APP\NEW INSTA.ipa` (l'IPA précédente de ce chemin,
  321 993 299 o, était un build **Regram** sans `whaminsta.dylib` —
  sauvegardée en `D:\IPA APP\NEW INSTA (avant 2026-10-03).ipa`).

- **2026-09-02 (OpenCode) — build-15 : alignement InstaVault (la vraie cause)**.
  Utilisateur : « avec InstaVault j'arrive à bien créer le compte » → diff
  systématique des deux projets. IVLocaleSpoof/IVPrefsHook/IVHardening :
  identiques. Les différences sont DANS IVDeviceSpoof et IVLocationSpoof :
  whaminsta seul hookait sysctl/sysctlbyname/uname/MGCopyAnswer/dlsym +
  UIDevice.systemVersion + NSProcessInfo.operatingSystemVersion(+String)/
  systemUptime + kern.boottime, et côté location l'authorizationStatus,
  requestWhenInUse/Always, CLLocationUpdate, stopUpdatingLocation + timer 1 s.
  InstaVault ne hook QUE IDFV/IDFA et location/start/request (one-shot) — et
  son IVHardwareHook documente le retrait du hook MobileGestalt « for
  stability ». Toutes ces surfaces s'activent au fingerprinting d'Instagram à
  l'étape nom du signup. Réécrit les deux fichiers à l'ensemble minimal éprouvé
  d'InstaVault (−548 lignes de surface), garanties conservées (choix
  modèle/iOS visibles dans le panneau via IVDeviceIdentity ; GPS jamais
  démarré en mode fake → aucune fuite de vraie position ; rate-limit 0,5 s du
  build-14 conservé par sécurité). Run `33627557672` SUCCESS → release
  **build-15**.

- **2026-09-02 (OpenCode)** — **build-14 : correctif du crash « saisie du nom
  au signup »**. Revue complète de TOUS les hooks (location, keychain, device,
  locale, prefs, app-group, hardening, camera, container) : aucun bug
  déterministe évident — d'où l'échec du fix aveugle `e88da93` (reverti).
  Cause la plus probable identifiée par comparaison avec le projet INSTA sœur
  (même symptôme, racine = récursion location au signup) : **boucle infinie
  dans le chemin location synthétique** quand Instagram interroge le GPS à
  l'étape nom — soit `deliver→start→deliver`, soit `notify→request→notify`
  (starvation main queue = kill watchdog, invisible pour l'ancien logger).
  Fix chirurgical : anti-boucles par manager (flag associé + rate-limit 0,5 s),
  sémantique calquée sur CLLocationManager réel, **localisation inchangée**
  (fixes livrés par le timer 1 s). + `sigaltstack`/`SA_ONSTACK`/`si_addr` pour
  que l'alerte in-app capture ENFIN les stack-overflow. Run `33619495886`
  SUCCESS → release **build-14**. IVHardening (completion DeviceCheck sur file
  background) = piste n°2 volontairement NON touchée (risque de deadlock si
  Instagram attend de façon synchrone) — à activer seulement si la stack
  l'indique.

- **2026-09-01 (OpenCode)** — build-13 (alerte in-app « Copier la stack »).
  Suite au refus de l'utilisateur d'ouvrir Fichiers, implémenté
  `IVFloatingButton presentPendingCrashReport` : lit `crash.log`, offset
  `crash.seen`, alerte `UIAlertController` + `UIPasteboard`. Exception handler
  appende désormais aussi dans `crash.log` (fd partagé avec la couche signal),
  donc les deux types de crash remontent. Alerte tirée une fois sur le
  fallback de lancement à froid (jamais sur DidBecomeActive). Commit
  `e5846e3`, run `33501750458` SUCCESS.

- **2026-09-01 (OpenCode)** — build-12 (code build-8 + crash logger). Suite à
  « ça crash toujours » sur build-11 (== build-8 exactement), retour
  d'expérience : le crash création de compte n'a jamais été capturé. Réintroduit
  le crash logger (commit `c71d04c`) : C function `IVExceptionCrashHandler`
  (pointeur, pas block), `IVSignalCrashHandler` (sigaction SA_SIGINFO/SA_RESETHAND),
  fd ouvert dans `<realHome>/Documents/whaminsta/logs/crash.log`. Build
  `33500258218` SUCCESS → `build-12`.

- **2026-09-01 (OpenCode)** — reversion code build-8 suite à confirmation user.
  L'utilisateur : « ça marchait bien avec la version de claude code ». build-10
  (runs `33494867336`/`33495314774`) était construit depuis `e88da93` qui a
  **introduit le crash à la création de compte**. Restauré les 3 fichiers
  sources depuis `6ecb0b2` (état build-8) et livré un nouveau build.

- **2026-09-01 (OpenCode)** — build-10 livré PUIS RETIRÉ. Run `33494867336`
  **échec** = `Bootstrap.m:160` block ObjC passé à `NSSetUncaughtExceptionHandler`
  (pointeur de fonction) → handler C `IVExceptionCrashHandler` (commit
  `6cfcf67`), run `33495314774` **SUCCESS** → release **build-10**. Avec le
  recul, `e88da93` était la cause du crash — d'où le retour à build-8.
