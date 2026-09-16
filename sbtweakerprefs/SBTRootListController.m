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

    // Each entry copies the old key's value into the new one, but only when the
    // new key has not been written yet, so a deliberate choice is never undone.
    NSMutableDictionary *migrations = [NSMutableDictionary dictionary];
    if (stored && [stored integerValue] < 11) {
        migrations[@"homeGridLandscapeEnabled"] = @"homeGridEnabled";
        migrations[@"homeSpacingLandscapeEnabled"] = @"homeSpacingEnabled";
    }
    if (stored && [stored integerValue] < 14) {
        // Dock spacing split into independent left and right values.
        migrations[@"dockExL"] = @"dockExH";
        migrations[@"dockExR"] = @"dockExH";
    }
    if (migrations.count) {
        for (NSString *newKey in migrations) {
            CFTypeRef newValue = CFPreferencesCopyAppValue((__bridge CFStringRef)newKey, kPrefsDomain);
            if (!newValue) {
                CFTypeRef oldValue = CFPreferencesCopyAppValue(
                    (__bridge CFStringRef)migrations[newKey], kPrefsDomain);
                if (oldValue) {
                    CFPreferencesSetAppValue((__bridge CFStringRef)newKey, oldValue, kPrefsDomain);
                    CFRelease(oldValue);
                }
            }
            if (newValue) CFRelease(newValue);
        }
    }

    for (NSString *key in defs) {
        CFTypeRef existing = CFPreferencesCopyAppValue((__bridge CFStringRef)key, kPrefsDomain);
        BOOL invalidLegacyGridValue = [@[@"dockIcons", @"hsCols", @"hsRows",
                                         @"hsColsLandscape", @"hsRowsLandscape"]
                                       containsObject:key] &&
                                      existing &&
                                      [(__bridge NSNumber *)existing integerValue] <= 0;
        if (!existing || invalidLegacyGridValue) {
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

@interface SBTNotifyingListController : PSListController
- (NSString *)plistName;
@end

@implementation SBTNotifyingListController
- (NSString *)plistName { return @""; }
- (NSArray *)specifiers {
    if (!_specifiers)
        _specifiers = [self loadSpecifiersFromPlistName:[self plistName] target:self];
    return _specifiers;
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    CFPreferencesAppSynchronize(kPrefsDomain);
    sbc_post_notification(CFSTR("cz.kolbi.sbtweaker/apply"));
}
@end

@interface SBTGridSpacingListController : SBTNotifyingListController @end
@implementation SBTGridSpacingListController
- (NSString *)plistName { return @"GridSpacing"; }
@end


@implementation SBTRootListController

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    CFPreferencesAppSynchronize(kPrefsDomain);
    [self apply];
}

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
