# Badoo — sécurité & forensics du binaire (2026-08-27)

Base analysée : `com.badoo.Badoo` 5.467.0 (CFBundleVersion 5.467.0.31254588),
IPA décrypté `com.badoo.Badoo_5.467.0_und3fined.ipa` (83,5 Mo), MinimumOSVersion 17.0.

## Verdict

**Badoo = classe « lenient » (comme Instagram / Threads).** Aucun verrou
d'intégrité au lancement dans le binaire : le portage 4-redirections de
ThreadsVault s'applique tel quel. La sécurité forte de Badoo est **serveur /
niveau-compte** (anti-fraude, KYC selfie, empreinte device) — elle ne bloque pas
le lancement d'un IPA modifié, mais c'est la surface de **corrélation entre
conteneurs** que l'isolation keychain + MobileGestalt existante doit neutraliser.

## Forensics Mach-O (binaire principal `Badoo`)

- arm64 thin, PIE, ncmds=137.
- **`LC_ENCRYPTION_INFO` absent** → binaire déchiffré (injectable).
- `LC_CODE_SIGNATURE` présent (ré-signé ad-hoc en CI, puis re-signé par Sideloadly à l'install).
- 100 dylibs en `LC_LOAD_DYLIB`, toutes légitimes — **aucune dylib mod injectée**
  (base propre `decrypt.day`, contrairement au base Threads repacké). D'où une
  recette CI *clean* (pas de bloc de tri des mods).
- Scan des gardes d'intégrité au lancement : **App Attest, DeviceCheck, `ptrace`,
  `csops`, `CS_VALID` — tous ABSENTS.** Pas d'anti-debug ni d'auto-vérification de
  signature au démarrage.
- Chaînes de détection JB présentes, mais elles alimentent un champ télémétrie
  souple `isJailbroken` (schéma statsd / profile_chunk) : rapport « propre » sur
  sideload non-jailbreaké, pas de kill au lancement.

## Surface de sécurité serveur / compte (frameworks embarqués)

Non-bloquante au lancement, mais c'est là que se joue la corrélation multi-comptes :

- **ArkoseLabsKit** — FunCaptcha / anti-fraude (défis au signup / actions sensibles).
- **DeviceAuth** (Badoo/Sierra) — empreinte device maison.
- **Veriff** — KYC pièce d'identité + selfie (vérification photo).
- **ProveAuth / ProveBase / ProveMobileAuth** — KYC opérateur (numéro / carrier).
- **FBSDKCoreKit / LoginKit / ShareKit / AEMKit** — SDK Facebook : keypair device
  en keychain + persistance App Group → **vecteur de corrélation device** (le même
  que celui traité par le hook `SecKeyCreateRandomKey` d'InstaVault/ThreadsVault).
- KeychainAccess (Swift), YapDatabase, PINCache — stockage local.
- PlugIns : `BPEPushNotificationService.appex` (extension push — conservée, re-signée par Sideloadly).

## Entitlements clés (archived-expanded-entitlements.xcent)

- `com.apple.security.application-groups = [group.com.badoo.Badoo]` → **redirection
  App Group (#4) nécessaire** : d'où le template ThreadsVault 4-redirections, pas le
  3-redirections d'InstaVault.
- `keychain-access-groups = [KNH8H96PY6.*, com.apple.token]`
- `application-identifier = KNH8H96PY6.com.badoo.Badoo`, team 92BDVV69P5
- Sign in with Apple ; associated-domains (badoo.com, bdo.to, …).

## Conséquence sur l'architecture du port

4 redirections atomiques (tout réussit ou rollback complet), identiques à ThreadsVault :

1. **HOME** (`IVHomeRedirect`) — sandbox par conteneur.
2. **Keychain** (`IVKeychainHook`) — mode HIDE pour le conteneur par défaut ;
   namespaces genp/inet/key ; isolation + wipe du keypair device FBSDK par conteneur
   (le vecteur de re-corrélation derrière la re-vérif selfie).
3. **CFPreferences** (`IVPrefsHook`).
4. **App Group** (`IVAppGroupHook`) — swizzle *dynamique* de
   `containerURLForSecurityApplicationGroupIdentifier:` : s'adapte automatiquement à
   `group.com.badoo.Badoo` sans code en dur (le bundle id n'apparaît que dans un commentaire).

Parité fonctionnelle reprise d'InstaVault build-94..96 / ThreadsVault build-5 :
P1 keychain HIDE, A empreinte device unique par conteneur à la création,
B garde de conteneur périmé au réveil à chaud, C login permanent (re-stamp récursif
`NSFileProtectionCompleteUntilFirstUserAuthentication`), R2 reset déconnecte aussi le
compte principal, P3 spoof MobileGestalt par conteneur.

## Durcissement futur (non inclus au build-1)

Le shield anti-tamper « image-hiding » de TinderVault (fishhook sur
`_dyld_image_count`/`_dyld_get_image_name`/…) reste une option documentée : Badoo lie
les API d'énumération d'images, mais comme il n'a **aucun garde d'intégrité au
lancement**, l'inclure au build-1 n'apporterait qu'un risque de crash sans bénéfice
prouvé. À réserver si une future version de Badoo ajoute une auto-vérification.
