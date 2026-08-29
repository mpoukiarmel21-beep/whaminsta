# whaminsta

Multi-container isolation tweak for **Instagram** (`com.burbn.instagram`) on
**non-jailbroken / sideloaded** iOS. Each container behaves like a distinct
phone: its own login, files, keychain, preferences, App Group store, device
fingerprint, locale and GPS. A draggable floating button opens a dark
Liquid-Glass panel to create, switch, and reset containers.

> Personal use only. whaminsta injects into an IPA you already own; it does
> not distribute Instagram. The base IPA is copyrighted — do not redistribute it.

## How it works

whaminsta is a **substrate-free** dylib injected into the Instagram binary and
re-signed by Sideloadly on install. It uses **no CydiaSubstrate** (absent on
sideloaded devices): all hooks are [fishhook](https://github.com/facebook/fishhook)
(C symbol rebinding) + `method_setImplementation` (ObjC). That is why the
Makefile uses `LIBRARY_NAME` (a plain dylib), not `TWEAK_NAME` (which would
auto-link Substrate). See `docs/decisions/001-substrate-free.md`.

### Isolation (atomic, non-default containers only)

For a non-default container, four redirects are applied **all-or-nothing** —
any partial state would leak identity across containers, so a failure rolls the
whole launch back to the real sandbox:

| # | Redirect | What it isolates |
|---|----------|------------------|
| 1 | HOME (`CFFIXED_USER_HOME`/`HOME`/`TMPDIR`) | app sandbox files |
| 2 | Keychain (`IV:<cid>:` namespace on service/server **and the `kSecClassKey` device-key tag**) | credentials / session tokens / **FBSDK device keypair** |
| 3 | CFPreferences (`CFPrefsPlistSource`) | `NSUserDefaults` (device_id / phone_id hints) |
| 4 | **App Group container** (`containerURLForSecurityApplicationGroupIdentifier:`) | FBSDK shared session store |

Redirect #4 is the key reinforcement over the Instagram-era base: Meta's FBSDK
stack keeps session/identity state in the **shared App Group container**, which
lives *outside* `CFFIXED_USER_HOME` — so the HOME redirect alone does not cover
it. Without it, containers share that store (cross-container login leak) and the
call can return `nil` after a personal re-sign (post-login crash). Each
non-default container now gets its own `<containerRoot>/AppGroups/<group>`.

The **default** container keeps the real sandbox / keychain / prefs / App Group
so an existing primary login survives untouched. Device and locale spoofing run
only when isolation is active; location spoofing is always safe (passthrough
when unset).

### Device-fingerprint hardening (redirect #2)

Meta's FBSDK persists a **device keypair** in the keychain as a `kSecClassKey`
item keyed by `kSecAttrApplicationTag` (CFData). It used to be *shared* by every
container (the tag was never namespaced) *and* was not wiped on container delete
(the purge only covered password classes) — so Meta could correlate every login
attempt back to one physical device and trace even already-deleted containers (a
multi-account / selfie verification). Redirect #2 now namespaces that tag per
container as raw bytes and also hooks `SecKeyCreateRandomKey` so the tag is
namespaced *at creation* — its permanent-key store goes through Security's
internal `SecItemAdd`, invisible to fishhook, so namespacing only the read would
desync write vs. read and regenerate-loop the key (login regression). Purge/count
now cover `kSecClassKey`, so a deleted or reset container's device key is wiped
and verified. It is a no-op passthrough for apps that store no tagged keys, and
the default container is untouched.

> Residual hard wall: **DeviceCheck / App Attest** are hardware-attested (Secure
> Enclave) and cannot be spoofed from unprivileged userland. They are likely
> already broken by a personal re-sign (so Meta falls back to the soft signals we
> spoof), but no userland hook can forge a valid attestation if Meta demands one.

## Build (CI only)

There is no local macOS toolchain in this project — builds run on GitHub Actions
(`.github/workflows/build.yml`, `macos-14`): Theos compiles the dylib,
`insert_dylib` injects it, the workflow keeps the base IPA's load-commanded
repacker dylibs (they are live in this repacked sideload base) and drops only
dead ones, ad-hoc `codesign`s, and publishes `whaminsta.ipa` as a release
asset. Sideloadly re-signs on install.

The repo is **public** because GitHub's macOS runners are free only on public
repos; on a private repo the build job never starts.

```bash
# 1. Host the decrypted Instagram IPA as a release asset (tag e.g. v1.0-ipa)
# 2. Trigger the build against that tag:
gh workflow run build.yml -f ipa_url=v1.0-ipa
# 3. Download whaminsta.ipa from the build-N release, install via Sideloadly.
```

## Repo layout

```
Tweak/Source/        substrate-free tweak (Bootstrap + Core/Isolation/Spoof/UI/Util)
Tweak/Makefile       LIBRARY_NAME = whaminsta
.github/workflows/   CI build (compile + inject + clean-base strip + sign + release)
Scripts/             local manual inject fallback (CI is canonical)
Entitlements/        empty threads.entitlements (CI ad-hoc signs; kept harmless)
docs/                plan, audits, decisions (ADRs)
AGENT-HANDOFF.md     multi-agent handoff (state / next step / journal)
```
