#import <Preferences/PSListController.h>
#import <CoreFoundation/CoreFoundation.h>

static CFStringRef const kPrefsDomain = CFSTR("cz.kolbi.sbtweaker");

// Bump kSBTDefaultsVersion to force every install onto these defaults once
// (e.g. after shipping a bad default). Existing user values are otherwise
// never touched.
static NSInteger const kSBTDefaultsVersion = 3;

static NSDictionary *sbc_default_values(void) {
    static NSDictionary *d = nil;
    if (!d) d = @{
        @"dockIcons":  @5,
        @"hsCols":     @5,
        @"hsRows":     @6,
        @"homeExL":    @20.0,
        @"homeExR":    @20.0,
        @"homeExT":    @40.0,
        @"homeExB":    @180.0,
        @"dockExH":    @30.0,
        @"homeScale":  @0.98,
        @"dockScale":  @0.98,
        @"restoreDockIcons": @YES,
        @"hideAppLibrary":   @YES,
        @"dtlHomeScreen":    @YES,
        @"dtlLockScreen":    @YES,
        @"dragCoefficient":  @0.25,
        @"noWakeAnim":       @YES,
        @"noSleepFade":      @YES,
        @"noIconsFlyIn":     @YES,
    };
    return d;
}

static void sbc_seed_defaults(void) {
    NSDictionary *defs = sbc_default_values();
    CFPreferencesAppSynchronize(kPrefsDomain);

    NSNumber *stored = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("defaultsVersion"), kPrefsDomain));
    BOOL force = !stored || [stored integerValue] < kSBTDefaultsVersion;

    for (NSString *key in defs) {
        CFTypeRef existing = CFPreferencesCopyAppValue((__bridge CFStringRef)key, kPrefsDomain);
        if (force || !existing) {
            CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                     (__bridge CFPropertyListRef)defs[key], kPrefsDomain);
        }
        if (existing) CFRelease(existing);
    }
    if (force) {
        CFPreferencesSetAppValue(CFSTR("defaultsVersion"), (__bridge CFPropertyListRef)@(kSBTDefaultsVersion), kPrefsDomain);
    }
    CFPreferencesAppSynchronize(kPrefsDomain);
}

static void sbc_post_notification(CFStringRef name) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         name, NULL, NULL, YES);
}

@interface SBTRootListController : PSListController
@end

@implementation SBTRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        sbc_seed_defaults();
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

// Posts the apply notification the tweak listens for inside SpringBoard.
// Used by "Reset to Defaults"; regular changes take effect after a respring.
- (void)apply {
    sbc_post_notification(CFSTR("cz.kolbi.sbtweaker/apply"));
}

// The Settings app is not allowed to relaunch SpringBoard on
// rootless/roothide — ask the tweak (which runs inside SpringBoard) to do it.
- (void)respring {
    sbc_post_notification(CFSTR("cz.kolbi.sbtweaker/respring"));
}

- (void)resetDefaults {
    NSDictionary *defs = sbc_default_values();
    for (NSString *key in defs) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)defs[key], kPrefsDomain);
    }
    CFPreferencesSetAppValue(CFSTR("defaultsVersion"), (__bridge CFPropertyListRef)@(kSBTDefaultsVersion), kPrefsDomain);
    CFPreferencesAppSynchronize(kPrefsDomain);
    [self reloadSpecifiers];
    [self apply];
}

@end
