# AGENT-HANDOFF — whaminsta

## État actuel

Tweak d'isolation multi-conteneurs pour **Instagram** (`com.burbn.instagram`),
sans jailbreak (dylib injectée + re-sign Sideloadly). Repo public :
`https://github.com/mpoukiarmel21-beep/whaminsta` (branche `master`). Base =
`com.burbn.instagram_442.0.0_und3fined.ipa` (InstaVault release `v1.0-ipa`,
asset inchangé depuis le 2026-08-20 — vérifié).

**build-14 livré** (run `33619495886` SUCCESS) :
`https://github.com/mpoukiarmel21-beep/whaminsta/releases/download/build-14/whaminsta.ipa`
= build-13 + **2 correctifs du crash « saisie du nom au signup »** + logger
amélioré. (1) `IVLocationSpoof` : anti-boucles — `IVDeliverFake` limité à 1
livraison/0,5 s par manager (un delegate qui redémarre les updates à chaque fix
ne peut plus affamer la main queue → kill watchdog), et `IVNotifyAuthorized` ne
tire plus le callback d'autorisation qu'UNE fois par manager (sémantique réelle
CLLocationManager : un re-request dans le callback ne reboucle plus). La fausse
localisation continue de couler via le timer 1 s — **feature inchangée**.
(2) `Bootstrap` : `sigaltstack` + `SA_ONSTACK` → le handler s'exécute même sur
un stack overflow (classe exacte du crash trouvé par le projet INSTA au même
étape) ; `si_addr` consigné. L'alerte in-app peut désormais remonter ce qui
était invisible.

## En cours

- **OpenCode — build-14 en test utilisateur** (2026-09-02). Si le crash
  persiste, l'alerte « Crash détecté » affichera ENFIN la stack (même pour un
  stack overflow) → la coller ici pour le fix certain.

## Prochaine étape

1. **User : installer build-14**, reproduire (Instagram → Créer un compte →
   nom). Soit ça ne crashe plus (cause = boucle location), soit l'alerte au
   relancement donne la stack → la coller ici.
2. Si la stack montre des frames Instagram sans `whaminsta.dylib` → crash dans
   le base IPA cracké → changer de base (seule issue restante).
3. Builds suivants : `gh workflow run build.yml --repo mpoukiarmel21-beep/whaminsta
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
