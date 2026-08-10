#import <Foundation/Foundation.h>

static CFStringRef const SBTPreferencesDomain = CFSTR("cz.kolbi.sbtweaker");
static NSInteger const SBTDefaultsVersion = 3;

static inline NSDictionary *SBTDefaultValues(void) {
    static NSDictionary *values = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        values = @{
            @"enabled": @YES,
            @"dockIcons": @5,
            @"hsCols": @5,
            @"hsRows": @6,
            @"hsColsLandscape": @6,
            @"hsRowsLandscape": @5,
            @"homeExLLandscape": @20.0,
            @"homeExRLandscape": @20.0,
            @"homeExTLandscape": @20.0,
            @"homeExBLandscape": @80.0,
            @"homeExL": @20.0,
            @"homeExR": @20.0,
            @"homeExT": @40.0,
            @"homeExB": @180.0,
            @"dockExH": @30.0,
            @"homeScale": @0.98,
            @"homeScaleLandscape": @0.98,
            @"dockScale": @0.98,
            @"restoreDockIcons": @YES,
            @"hideAppLibrary": @YES,
            @"dtlHomeScreen": @YES,
            @"dtlLockScreen": @YES,
            @"dragCoefficient": @0.25,
            @"noWakeAnim": @YES,
            @"noSleepFade": @YES,
            @"noIconsFlyIn": @YES,
            @"fasterCoreAnimation": @YES,
            @"fastCopy": @YES,
        };
    });
    return values;
}
