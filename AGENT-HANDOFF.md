# AGENT-HANDOFF — whaminsta

## État actuel

Tweak d'isolation multi-conteneurs pour **Instagram** (`com.burbn.instagram`),
sans jailbreak (dylib injectée + re-sign Sideloadly). Repo public :
`https://github.com/mpoukiarmel21-beep/whaminsta` (branche `master`). Base =
`com.burbn.instagram_442.0.0_und3fined.ipa` (InstaVault release `v1.0-ipa`,
asset inchangé depuis le 2026-08-20 — vérifié).

**build-12 livré** (run `33500258218` SUCCESS) :
`https://github.com/mpoukiarmel21-beep/whaminsta/releases/download/build-12/whaminsta.ipa`
= **code source exact de build-8** (celui que l'utilisateur dit fonctionner)
+ **crash logger** (le seul ajout, compilé correctement). Le crash logger
ouvre `<realHome>/Documents/whaminsta/logs/crash.log` et capte **exceptions
ObjC + signaux fatals** (backtrace via `backtrace_symbols_fd`). Le logger ne
change AUCUN comportement applicatif.

## En cours

- **OpenCode — collecte de la stack du crash création de compte** (2026-09-01).
  Avertissement de contradiction : build-8 et build-11 ont le **même code + la
  même base IPA**, or l'utilisateur dit build-8 OK mais build-11 crash à la
  création de compte. Conclusion probable : le crash à la création de compte
  **existait déjà dans build-8** mais n'a jamais été déclenché/testé à ce moment-là,
  ou il est intermittent. Pas de stack = pas de diagnostic exact → build-12
  embarque le crash logger pour enfin capturer la vraie cause.

## Prochaine étape

1. **User : installer build-12, reproduire le crash** (Instagram → Créer un
   compte → taper le nom → crash).
2. **Récupérer `crash.log`** : dossier `<iPhone>/On My iPhone/Instagram/Documents/
   whaminsta/logs/crash.log` (via l'app Fichiers → sur cet iPhone → Instagram →
   Documents → whaminsta → logs), ou demander à Sideloadly d'exposer le conteneur.
   Fournir le contenu du fichier (même partiellement) pour lire la stack.
3. L'analyse de la stack déterminera : (a) crash dans le base IPA Instagram
   lui-même (→ hors de notre portée, besoin d'une autre version d'IPA), ou
   (b) crash dans `whaminsta.dylib` (→ hook fautif à corriger).

## Blocages / risques

- **Contradiction build-8 vs build-11** (même binaire, résultats opposés) —
  non résolue : soit le crash est dans le base IPA, soit il est intermittent,
  soit l'utilisateur a confondu. Le logger doit trancher.
- **Aucun build local** (Windows/PowerShell, pas de Theos/macOS) : builds
  uniquement en CI GitHub Actions (runner `macos-14`, repo **public**).
- Base IPA `..._und3fined.ipa` = IPA cracké/patched : si le crash est à
  l'intérieur du binaire Instagram (pas du dylib), changer de base
  (ex. InstaVault plus récent ou sauce alternative) est la seule issue.

## Journal

- **2026-09-01 (OpenCode)** — build-12 (code build-8 + crash logger). Suite à
  « ça crash toujours » sur build-11 (== build-8 exactement), retour d'expérience :
  le crash création de compte n'a jamais été capturé. Réintroduit le crash logger
  (commit `c71d04c`) : C function `IVExceptionCrashHandler` (pointeur, pas block),
  `IVSignalCrashHandler` (sigaction SA_SIGINFO/SA_RESETHAND), fd ouvert dans
  `<realHome>/Documents/whaminsta/logs/crash.log`. Build `33500258218` SUCCESS →
  `build-12`. Prochaine action : user reproduit le crash et renvoie `crash.log`.

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
