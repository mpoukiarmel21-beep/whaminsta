# AGENT-HANDOFF — whaminsta

## État actuel

Tweak d'isolation multi-conteneurs pour **Instagram** (`com.burbn.instagram`),
sans jailbreak (dylib injectée + re-sign Sideloadly). Repo public :
`https://github.com/mpoukiarmel21-beep/whaminsta` (branche `master`). Base =
`com.burbn.instagram_442.0.0_und3fined.ipa` (InstaVault release `v1.0-ipa`).

**build-10 a été RETIRÉ** — l'utilisateur a confirmé que **build-8 (29 août,
Claude Code) marchait** à la création de compte, et que c'est la version qui
crachait à la saisie du nom qui est un build plus récent. **Cause racine :
le commit `e88da93` « Fix launch/create crashes + add crash logger »
(modif Bootstrap.m + IVDeviceSpoof.m + IVLocaleSpoof.m) a cassé la création
de compte** — c'est exactement la différence entre build-8 (bon) et mon
build-10 (crash).

## En cours

- **OpenCode — reversion vers le code build-8** (2026-09-01) : les 3 fichiers
  `Bootstrap.m`, `IVDeviceSpoof.m`, `IVLocaleSpoof.m` ont été restaurés depuis
  `6ecb0b2` (= état exact de build-8). Un nouveau build va être relancé pour
  livrer une IPA identique au code qui marchait.

## Prochaine étape

1. **Committer + pousser** le revert, **rebuilder** depuis master (code build-8)
   et livrer le nouveau build (build-11) :
   `gh workflow run "Build whaminsta IPA" --repo mpoukiarmel21-beep/whaminsta --ref master -f "ipa_url=https://github.com/mpoukiarmel21-beep/InstaVault/releases/download/v1.0-ipa/com.burbn.instagram_442.0.0_und3fined.ipa"`.
2. **Test appareil** : la création de compte doit refonctionner comme build-8.
3. Rebuild après toute modif : même commande.

## Blocages / risques

- **Aucun build local** (Windows/PowerShell, pas de Theos/macOS) : builds
  uniquement en CI GitHub Actions (runner `macos-14`, repo **public**).
- **Ne pas réintroduire `e88da93`** (crash logger / NULL-guard device spoof) :
  il est la cause du crash à la création de compte. Garder le code source du
  build-8 (`6ecb0b2`) pour les fichiers Bootstrap/DeviceSpoof/LocaleSpoof.
- L'historique git contient encore `e88da93` (l'état build-8 est restauré via
  commit de revert, pas force-push) — ne pas le rebaser/`cherry-pick`.

## Journal

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
