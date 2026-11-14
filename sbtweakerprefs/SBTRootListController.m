#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
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
    if (stored && [stored integerValue] < 18) {
        // Fast Sheets got its own duration; it used to share this one.
        migrations[@"fastSheetsDuration"] = @"noSlideDuration";
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
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specifiers = [[super specifiers] mutableCopy];
        // Free Icon Placement turns on iOS 17's snap to grid; iOS 18 places
        // icons freely by itself, and iOS 16 and earlier do not have it.
        if ([NSProcessInfo processInfo].operatingSystemVersion.majorVersion != 17) {
            NSIndexSet *hidden = [specifiers indexesOfObjectsPassingTest:^BOOL(PSSpecifier *spec, NSUInteger idx, BOOL *stop) {
                return [@[@"freeIconPlacementGroup", @"freeIconPlacement"] containsObject:spec.identifier];
            }];
            [specifiers removeObjectsAtIndexes:hidden];
        }
        _specifiers = specifiers;
    }
    return _specifiers;
}
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

// Posts the apply notification the tweak listens for inside SpringBoard,
// after every change and after "Reset to Defaults". Most switches apply
// right away; the few that only take effect at launch say so in the pane.
- (void)apply {
    sbc_post_notification(CFSTR("cz.kolbi.sbtweaker/apply"));
}

// The Settings app is not allowed to relaunch SpringBoard on
// rootless/roothide — ask the tweak (which runs inside SpringBoard) to do it.
// Any process can post the notification, so the tweak only honours it when
// this fresh request timestamp is in the preferences domain, which sandboxed
// apps cannot write.
- (void)respring {
    CFPreferencesSetAppValue(CFSTR("respringRequest"),
                             (__bridge CFPropertyListRef)@(CFAbsoluteTimeGetCurrent()), kPrefsDomain);
    CFPreferencesAppSynchronize(kPrefsDomain);
    sbc_post_notification(CFSTR("cz.kolbi.sbtweaker/respring"));
}

#ifndef SBT_VERSION
#define SBT_VERSION "unknown"
#endif

- (NSString *)version:(PSSpecifier *)specifier {
    return @SBT_VERSION;
}

- (void)openURLString:(NSString *)string {
    NSURL *url = [NSURL URLWithString:string];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)openTwitter {
    [self openURLString:@"https://x.com/_kolbicz"];
}

- (void)openGitHub {
    [self openURLString:@"https://github.com/kolbicz/SBTweaker"];
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
