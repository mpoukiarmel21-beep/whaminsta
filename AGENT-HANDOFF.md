# AGENT-HANDOFF — whaminsta

## État actuel

Tweak d'isolation multi-conteneurs pour **Instagram** (`com.burbn.instagram`),
sans jailbreak (dylib injectée + re-sign Sideloadly). Repo public :
`https://github.com/mpoukiarmel21-beep/whaminsta` (branche `master`). Base =
`com.burbn.instagram_442.0.0_und3fined.ipa` (InstaVault release `v1.0-ipa`,
asset inchangé depuis le 2026-08-20 — vérifié).

**build-13 livré** (run `33501750458` SUCCESS) :
`https://github.com/mpoukiarmel21-beep/whaminsta/releases/download/build-13/whaminsta.ipa`
= code build-8 + **crash logger + alerte in-app**. Au lancement suivant un
crash, Instagram affiche une alerte « Crash détecté » avec la stack et un
bouton « Copier la stack » (plus besoin d'aller dans l'app Fichiers). Le
logger capte exceptions ObjC **et** signaux fatals, les deux dans
`<realHome>/Documents/whaminsta/logs/crash.log` (fd pré-ouvert, offset "déjà
vu" persisté dans `crash.seen`).

## En cours

- **OpenCode — collecte de la stack via alerte in-app** (2026-09-01).
  Avertissement : build-8 et build-11 ont le **même code + la même base IPA**
  (base InstaVault `v1.0-ipa` inchangée depuis le 20/08 — vérifié), or
  l'utilisateur dit build-8 OK mais build-11/12 crash. Le crash à la création
  de compte existait donc probablement déjà dans build-8. L'utilisateur a
  **refusé de naviguer dans Fichiers** → nouveau mécanisme : alerte auto dans
  l'app au prochain lancement + bouton copier. En attente de la stack.

## Prochaine étape

1. **User : installer build-13**, reproduire le crash (Instagram → Créer un
   compte → nom → crash), **relancer Instagram**, attendre ~3 s, copier la
   stack via l'alerte « Crash détecté » et la coller ici.
2. L'analyse de la stack déterminera : (a) crash dans le base IPA Instagram
   lui-même (→ hors de notre portée, changer de base/e d'IPA), ou
   (b) crash dans `whaminsta.dylib` (→ hook fautif à corriger).
3. Si l'alerte ne s'affiche pas : vérifier que build-13 est bien installé
   (et non build-12), puis que `<realHome>/Documents/whaminsta/logs/crash.log`
   existe (sinon = pas de capture = crash avant l'installation du logger).

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
