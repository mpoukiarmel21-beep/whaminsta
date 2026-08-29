#import <Foundation/Foundation.h>
#import "IVContainer.h"

/// Redirect #4 — App Group container isolation.
///
/// Instagram is built on Meta's FBSDK stack, which persists part of its session /
/// identity state in the SHARED APP GROUP container
/// (`-[NSFileManager containerURLForSecurityApplicationGroupIdentifier:]`),
/// NOT in the app sandbox that redirect #1 (HOME) covers. Two problems follow
/// for a multi-container tweak on a sideloaded build:
///
///   1. Cross-container leak: every container resolves the SAME app-group
///      container URL, so one container's FBSDK session material bleeds into
///      another — the classic "it reopened on the account I logged in with"
///      bug. HOME/keychain/prefs isolation alone does NOT close this, because
///      the app-group path is resolved by installd, outside CFFIXED_USER_HOME.
///
///   2. Sideload crash: after a personal-cert re-sign the App Group entitlement
///      is remapped/stripped, so the real call can return nil and FBSDK code
///      that force-unwraps the container URL crashes post-login.
///
/// This hook swizzles the (public) NSFileManager selector and, for a NON-default
/// container, returns a container-local path `<containerRoot>/AppGroups/<group>`
/// (skeleton pre-created), giving each container its own private app-group store.
/// Substrate-free: `method_setImplementation`, same technique as IVPrefsHook.
///
/// The DEFAULT container is left on the REAL (Sideloadly-remapped) app-group
/// container — the behaviour proven to work for the Instagram-family base — so
/// an existing primary login survives untouched.
@interface IVAppGroupHook : NSObject

/// Installs the per-container redirect. Returns NO (fail-loud) for a non-default
/// container if the NSFileManager selector is unexpectedly absent, so Bootstrap
/// can roll the whole isolation back to the real sandbox rather than launch
/// half-isolated. No-op returning NO for the default container (caller does not
/// gate on the default path).
+ (BOOL)installForContainer:(IVContainer *)container;

@end
