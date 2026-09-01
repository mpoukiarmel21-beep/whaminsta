# AGENT-HANDOFF — whaminsta

## État actuel

Tweak d'isolation multi-conteneurs pour **Instagram** (`com.burbn.instagram`),
sans jailbreak (dylib injectée + re-sign Sideloadly). Repo public :
`https://github.com/mpoukiarmel21-beep/whaminsta` (branche `master`). Base =
`com.burbn.instagram_442.0.0_und3fined.ipa` (InstaVault release `v1.0-ipa`).

**build-10 livré** (run `33495314774` SUCCESS) :
`https://github.com/mpoukiarmel21-beep/whaminsta/releases/download/build-10/whaminsta.ipa`
— inclut les correctifs de crash à la création de compte (voir Journal).

## En cours

- **OpenCode — build-10 livré** (2026-09-01) : fix crash « création de compte »
  enfin compilé et livré. À faire valider sur appareil par l'utilisateur ; si le
  crash persiste, le **crash logger** intégré dump la stack dans
  `<Documents>/whaminsta/logs/crash.log` (lisible via l'app Fichiers) → on aura
  une stack précise.

## Prochaine étape

1. **Test appareil de build-10** : ouvrir un conteneur (non-défaut), aller dans
   la création de compte Instagram, taper le nom. Retour sur le comportement.
2. **Si encore un crash** : récupérer
   `<iPhone>/Documents/whaminsta/logs/crash.log` (via Fichiers/partage) et le
   fournir — c'est exactement pour ça que le logger a été ajouté.
3. Rebuild après toute modif :
   `gh workflow run "Build whaminsta IPA" --repo mpoukiarmel21-beep/whaminsta --ref master -f "ipa_url=https://github.com/mpoukiarmel21-beep/InstaVault/releases/download/v1.0-ipa/com.burbn.instagram_442.0.0_und3fined.ipa"`.

## Blocages / risques

- **Aucun build local** (Windows/PowerShell, pas de Theos/macOS) : builds
  uniquement en CI GitHub Actions (runner `macos-14`, repo **public**).
- Le crash logger a d'abord fait **échouer la compilation** : le handler
  `NSUncaughtExceptionHandler` prend un **pointeur de fonction C**, pas un
  block ObjC (erreur `incompatible type` sur SDK moderne) — corrigé.
- Si un nouveau crash apparaît après build-10, la stack dans `crash.log`
  est le chemin le plus rapide.

## Journal

- **2026-09-01 (OpenCode)** — build-10 livré. Problème : user rapportait un
  crash à la **création de compte** dès la saisie du nom. Diagnostic : le
  correctif `e88da93` (crash Logger NULL-guard `IVDeviceSpoof` sysctl/uname +
  idempotence `IVSwizzleUDReader` + captureur de stack) était **commité mais
  jamais buildé** — le dernier IPA livré (build-8, hash `6ecb0b2`) datait du
  29-08 et ne l'incluait pas. Deux runs CI : (1) `33494867336` **échec** =
  `Bootstrap.m:160` block ObjC passé à `NSSetUncaughtExceptionHandler`
  (pointeur de fonction) → extrait un handler C `IVExceptionCrashHandler` +
  `IVPriorExceptionHandler` statique (commit `6cfcf67`) ; (2) `33495314774`
  **SUCCESS** → release **build-10**, `whaminsta.ipa` HTTP 200. Base IPA
  `v1.0-ipa`/`com.burbn.instagram_442.0.0_und3fined.ipa` (même que build-8).
