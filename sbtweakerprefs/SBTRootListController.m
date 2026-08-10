#import <Preferences/PSListController.h>
#import <CoreFoundation/CoreFoundation.h>
#import "../SBTDefaults.h"

#define kPrefsDomain SBTPreferencesDomain
#define kSBTDefaultsVersion SBTDefaultsVersion
#define sbc_default_values SBTDefaultValues

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
