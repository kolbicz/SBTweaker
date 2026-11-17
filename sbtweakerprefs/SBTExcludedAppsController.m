#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <CoreFoundation/CoreFoundation.h>
#import "../SBTDefaults.h"

// SBTExcludedAppsController — one switch per installed app. SBTweaker does
// nothing inside an app switched on here. The list is stored as
// an array of bundle identifiers under "excludedApps".

#define kPrefsDomain SBTPreferencesDomain
static NSString *const kSBTBundleIDKey = @"sbtBundleID";

@interface LSApplicationProxy : NSObject
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)applicationType;
- (NSArray *)appTags;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@interface SBTExcludedAppsController : PSListController
@end

@implementation SBTExcludedAppsController

- (NSArray<NSString *> *)excludedApps {
    CFPreferencesAppSynchronize(kPrefsDomain);
    id list = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("excludedApps"), kPrefsDomain));
    return [list isKindOfClass:[NSArray class]] ? list : @[];
}

// Apps with an icon on the Home Screen: everything the user installed, and
// the system apps that are not tagged as hidden.
- (NSArray<NSDictionary *> *)installedApps {
    id workspace = [NSClassFromString(@"LSApplicationWorkspace") defaultWorkspace];
    if (![workspace respondsToSelector:@selector(allInstalledApplications)]) return @[];
    NSMutableArray *apps = [NSMutableArray array];
    for (LSApplicationProxy *proxy in [workspace allInstalledApplications]) {
        if (![proxy respondsToSelector:@selector(applicationIdentifier)]) continue;
        NSString *bundleID = [proxy applicationIdentifier];
        if (!bundleID.length) continue;
        NSString *type = [proxy respondsToSelector:@selector(applicationType)] ? [proxy applicationType] : nil;
        NSArray *tags = [proxy respondsToSelector:@selector(appTags)] ? [proxy appTags] : nil;
        if (![type isEqualToString:@"User"] && [tags containsObject:@"hidden"]) continue;
        NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy localizedName] : nil;
        [apps addObject:@{@"id": bundleID, @"name": name.length ? name : bundleID}];
    }
    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return apps;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specifiers = [NSMutableArray array];
        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        [group setProperty:@"SBTweaker does nothing inside the apps switched on here: Fast Copy, "
                            "Fast Page Transitions and Fast Sheets stay off in them. Switching an app "
                            "on applies right away; after switching one off, reopen that app."
                    forKey:@"footerText"];
        [specifiers addObject:group];
        for (NSDictionary *app in [self installedApps]) {
            PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:app[@"name"]
                                                                    target:self
                                                                       set:@selector(setExcluded:specifier:)
                                                                       get:@selector(excluded:)
                                                                    detail:Nil
                                                                      cell:PSSwitchCell
                                                                      edit:Nil];
            [specifier setProperty:app[@"id"] forKey:kSBTBundleIDKey];
            // Preferences loads the app's icon itself, as its own app list does.
            [specifier setProperty:@YES forKey:@"useLazyIcons"];
            [specifier setProperty:app[@"id"] forKey:@"appIDForLazyIcon"];
            [specifiers addObject:specifier];
        }
        _specifiers = specifiers;
    }
    return _specifiers;
}

- (id)excluded:(PSSpecifier *)specifier {
    return @([[self excludedApps] containsObject:[specifier propertyForKey:kSBTBundleIDKey]]);
}

- (void)setExcluded:(id)value specifier:(PSSpecifier *)specifier {
    NSString *bundleID = [specifier propertyForKey:kSBTBundleIDKey];
    if (!bundleID.length) return;
    NSMutableArray *list = [[self excludedApps] mutableCopy];
    [list removeObject:bundleID];
    if ([value boolValue]) [list addObject:bundleID];
    CFPreferencesSetAppValue(CFSTR("excludedApps"), (__bridge CFPropertyListRef)list, kPrefsDomain);
    CFPreferencesAppSynchronize(kPrefsDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("cz.kolbi.sbtweaker/apply"), NULL, NULL, YES);
}

@end
