#import <UIKit/UIKit.h>

static CFStringRef const SBTPreferencesDomain = CFSTR("cz.kolbi.sbtweaker");
static NSInteger const SBTDefaultsVersion = 12;

static inline NSDictionary *SBTDefaultValues(void) {
    static NSDictionary *values = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        BOOL iPad = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad;
        values = @{
            @"enabled": @NO,
            @"dockLayoutEnabled": @NO,
            @"dockIcons": @4,
            @"homeGridEnabled": @NO,
            @"homeGridLandscapeEnabled": @NO,
            @"hsCols": iPad ? @5 : @4,
            @"hsRows": @6,
            @"hsColsLandscape": iPad ? @6 : @4,
            @"hsRowsLandscape": iPad ? @5 : @6,
            @"homeSpacingEnabled": @NO,
            @"homeSpacingLandscapeEnabled": @NO,
            @"homeExL": @0.0,
            @"homeExR": @0.0,
            @"homeExT": @0.0,
            @"homeExB": @0.0,
            @"homeExLLandscape": @0.0,
            @"homeExRLandscape": @0.0,
            @"homeExTLandscape": @0.0,
            @"homeExBLandscape": @0.0,
            @"pageIndicatorPositionEnabled": @NO,
            @"pageIndicatorX": @0.0,
            @"pageIndicatorY": @0.0,
            @"pageIndicatorXLandscape": @0.0,
            @"pageIndicatorYLandscape": @0.0,
            @"dockSpacingEnabled": @NO,
            @"dockExH": @0.0,
            @"homeScaleEnabled": @NO,
            @"homeScale": @1.0,
            @"dockScaleEnabled": @NO,
            @"dockScale": @1.0,
            @"iconLayoutBackupEnabled": @NO,
            @"hideAppLibrary": @NO,
            @"dtlHomeScreen": @NO,
            @"dtlLockScreen": @NO,
            @"dragCoefficientEnabled": @NO,
            @"dragCoefficient": @1.0,
            @"noWakeAnim": @NO,
            @"noSleepFade": @NO,
            @"noIconsFlyIn": @NO,
            @"fasterCoreAnimation": @NO,
            @"fastCopy": @NO,
        };
    });
    return values;
}
