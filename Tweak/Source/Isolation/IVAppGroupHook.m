#import "IVAppGroupHook.h"
#import "IVPaths.h"
#import "IVDiagnostics.h"
#import <objc/runtime.h>

// The active container's private App Groups base dir
// (<containerRoot>/AppGroups). nil == hook not installed (default container /
// install failed) => real app-group container passthrough.
static NSString *gGroupBase = nil;

// Original -[NSFileManager containerURLForSecurityApplicationGroupIdentifier:].
typedef NSURL *(*IVGroupURLFn)(id self, SEL _cmd, NSString *groupIdentifier);
static IVGroupURLFn gOrigGroupURL = NULL;

// A group identifier ("group.com.burbn.instagram") is normally a safe path
// component, but sanitise defensively so a hostile/odd identifier can never
// escape the container root via "/" or "..".
static NSString *IVSafeGroupComponent(NSString *groupId) {
    if (![groupId isKindOfClass:[NSString class]] || groupId.length == 0) {
        return @"_default";
    }
    NSCharacterSet *bad = [NSCharacterSet characterSetWithCharactersInString:@"/\\:\0"];
    NSString *clean = [[groupId componentsSeparatedByCharactersInSet:bad]
                          componentsJoinedByString:@"_"];
    return clean.length ? clean : @"_default";
}

// Replacement: hand back a container-local directory for every requested app
// group, so each container has its own isolated FBSDK app-group store. Creates
// the standard skeleton (Library, Library/Caches, Documents) the way iOS would,
// since FBSDK expects those subdirs to exist.
static NSURL *iv_containerURLForAppGroup(id selfObj, SEL _cmd, NSString *groupIdentifier) {
    if (gGroupBase.length == 0) {
        return gOrigGroupURL ? gOrigGroupURL(selfObj, _cmd, groupIdentifier) : nil;
    }
    NSString *dir = [gGroupBase stringByAppendingPathComponent:IVSafeGroupComponent(groupIdentifier)];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sub in @[ @"Library", @"Library/Caches", @"Documents" ]) {
        NSString *p = [dir stringByAppendingPathComponent:sub];
        if (![fm fileExistsAtPath:p]) {
            NSError *err = nil;
            if (![fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:&err]) {
                IVErr(@"AppGroup: skeleton create failed at %@: %@", p, err);
            }
        }
    }
    return [NSURL fileURLWithPath:dir isDirectory:YES];
}

@implementation IVAppGroupHook

+ (BOOL)installForContainer:(IVContainer *)container {
    if (!container || container.isDefault) {
        IVLog(@"AppGroup: default container — real app-group container passthrough (no hook)");
        return NO;   // no-op for default; caller never gates on the default path
    }
    if (gGroupBase) {
        IVLog(@"AppGroup: already installed (base=%@)", gGroupBase);
        return YES;
    }

    Class cls = [NSFileManager class];
    SEL sel = @selector(containerURLForSecurityApplicationGroupIdentifier:);
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) {
        // Fail-loud: the public selector is unexpectedly gone. Return NO so
        // Bootstrap reverts the whole isolation to the real sandbox rather than
        // launch with the app-group store shared across containers (a leak).
        IVErr(@"AppGroup: containerURLForSecurityApplicationGroupIdentifier: ABSENT — cannot isolate app group");
        return NO;
    }

    NSString *base = [[IVPaths containerRootForCID:container.cid]
                         stringByAppendingPathComponent:@"AppGroups"];
    gGroupBase = [base copy];

    gOrigGroupURL = (IVGroupURLFn)method_setImplementation(m, (IMP)iv_containerURLForAppGroup);
    if (!gOrigGroupURL) {
        IVErr(@"AppGroup: method_setImplementation returned NULL original — aborting");
        gGroupBase = nil;
        return NO;
    }
    IVLog(@"AppGroup: app-group container redirected -> %@", gGroupBase);
    return YES;
}

@end
