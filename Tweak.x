#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>
#import <stdint.h>
#import <stdbool.h>
#import <math.h>
#import <notify.h>
#import <QuartzCore/QuartzCore.h>
#import "SBTDefaults.h"
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#endif

// SBTweaker — injection-tweak conversions of cyanide tweaks, all running
// inside SpringBoard on the main thread (no RemoteCall plumbing):
//  - sbcustomizer.m: home grid / dock size / labels
//  - darksword_layout.m: spacing & icon scaling
//  - darksword disable_app_library(): hide App Library
//  - darksword_tweaks.m double-tap-to-lock: home & lock screen gestures
//  - Fast Copy callout (also loads into UIKit application processes)
//  - Fast Page Transitions: navigation slide inside apps (app processes only)
//
// Icon arrangement and add-to-dock from the original sbcustomizer.m were
// dropped.

// SBIconListGridSize raw layout (low 16 bits = columns, high 16 = rows),
// matching the packing used by the original sbcustomizer.m.
typedef struct { unsigned short columns; unsigned short rows; } SBCGridSize;

// SBIconImageInfo from SpringBoard's SBIconImageInfo.h
typedef struct {
    CGSize size;
    CGFloat scale;
    CGFloat continuousCornerRadius;
} SBIconImageInfo;

// Duck-typed declarations for the SpringBoard classes we touch
// (SBIconController, SBHIconManager, SBRootFolderController, SBIconListView,
// SBIconListModel, SBIconView, layout configuration objects).
@interface NSObject (SBCustomizer)
- (id)iconManager;
- (id)dockListView;
- (id)rootFolderController;
- (id)rootFolderView;
- (id)model;
- (id)iconListModel;
- (id)displayedModel;
- (id)listLayoutProvider;
- (id)layoutForIconLocation:(id)location;
- (id)layout;
- (id)layoutConfiguration;
- (NSString *)iconLocation;
- (id)icons;
- (BOOL)importState:(id)state;
- (void)noteIconStateChangedExternally;
- (id)icon;
- (BOOL)isDock;
- (BOOL)automaticallyAdjustsLayoutMetricsToFit;
- (void)setAutomaticallyAdjustsLayoutMetricsToFit:(BOOL)value;
- (NSUInteger)numberOfPortraitColumns;
- (NSUInteger)numberOfPortraitRows;
- (NSUInteger)numberOfLandscapeColumns;
- (NSUInteger)numberOfLandscapeRows;
- (UIEdgeInsets)portraitLayoutInsets;
- (SBCGridSize)gridSize;
- (void)setGridSize:(SBCGridSize)grid;
- (void)changeGridSize:(SBCGridSize)grid options:(NSUInteger)options;
- (void)setNumberOfPortraitColumns:(NSUInteger)value;
- (void)setNumberOfPortraitRows:(NSUInteger)value;
- (void)setNumberOfLandscapeColumns:(NSUInteger)value;
- (void)setNumberOfLandscapeRows:(NSUInteger)value;
- (NSUInteger)iconListViewCount;
- (id)iconListViewAtIndex:(NSUInteger)index;
// darksword_layout.m additions
- (void)setPortraitLayoutInsets:(UIEdgeInsets)insets;
- (SBIconImageInfo)iconImageInfo;
- (void)setIconImageInfo:(SBIconImageInfo)info;
- (void)setNeedsRelayout:(BOOL)value;
- (void)relayout;
- (void)layoutIconListsWithAnimationType:(NSInteger)type forceRelayout:(BOOL)force;
- (void)_updateAfterManualIconImageInfoChangeInvalidatingLayout:(BOOL)invalidate;
// Spotlight dismissal (SBHIconManager / SBRootFolderController / SBIconController)
- (void)dismissSpotlightAnimated:(BOOL)animated completionHandler:(id)handler;
- (BOOL)isShowingSpotlightOrLeadingCustomView;
- (BOOL)isAnySearchVisibleOrTransitioning;
- (void)dismissSearchView;
// Spotlight UI process (SPUISearchViewController)
- (void)clearTimerExpired;
@end

@interface SpringBoard : UIApplication
- (void)_simulateLockButtonPress;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
@end

@interface SBDefaultIconModelStore : NSObject
+ (instancetype)sharedInstance;
- (NSURL *)currentIconStateURL;
@end

@interface SBIconModelPropertyListFileStore : NSObject
- (NSURL *)currentIconStateURL;
- (BOOL)saveCurrentIconState:(id)state error:(NSError **)error;
- (BOOL)_save:(id)state url:(NSURL *)url error:(NSError **)error;
@end

#define kPrefsDomain SBTPreferencesDomain
static CFStringRef const kApplyNotification = CFSTR("cz.kolbi.sbtweaker/apply");
static BOOL sbc_pref_bool_live(CFStringRef key);

// Wake/sleep tracing for test builds (make SBT_TRACE=1). Times are
// CACurrentMediaTime() in seconds, so lines from one wake line up.
//
// Every line also goes to a file on the device. It lives in the media
// folder, which a paired computer reads over USB (afcclient, Finder's file
// sharing) without going through the device's own share sheet. It starts
// over past 2 MB, keeping the previous file as .old.
#if SBT_WAKE_TRACE
static NSString *const kSBTTraceLogPath = @"/var/mobile/Media/SBTweaker/wake-trace.log";
static const unsigned long long kSBTTraceLogLimit = 2 * 1024 * 1024;

static void sbt_trace_write(NSString *line) {
    NSLog(@"[SBT:WAKE] %@", line);
    static dispatch_queue_t queue;
    static NSDateFormatter *formatter;
    static NSFileHandle *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("cz.kolbi.sbtweaker.trace", DISPATCH_QUEUE_SERIAL);
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });
    NSDate *now = [NSDate date];
    dispatch_async(queue, ^{
        @try {
            if (!handle) {
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm createDirectoryAtPath:[kSBTTraceLogPath stringByDeletingLastPathComponent]
              withIntermediateDirectories:YES attributes:nil error:NULL];
                if ([[fm attributesOfItemAtPath:kSBTTraceLogPath error:NULL] fileSize] > kSBTTraceLogLimit) {
                    NSString *old = [kSBTTraceLogPath stringByAppendingString:@".old"];
                    [fm removeItemAtPath:old error:NULL];
                    [fm moveItemAtPath:kSBTTraceLogPath toPath:old error:NULL];
                }
                if (![fm fileExistsAtPath:kSBTTraceLogPath])
                    [fm createFileAtPath:kSBTTraceLogPath contents:nil attributes:nil];
                handle = [NSFileHandle fileHandleForWritingAtPath:kSBTTraceLogPath];
                [handle seekToEndOfFile];
            }
            NSString *entry = [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:now], line];
            [handle writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
            // Past the limit: close it, so the next line starts a new file.
            if (handle.offsetInFile > kSBTTraceLogLimit) {
                [handle closeFile];
                handle = nil;
            }
        } @catch (__unused NSException *e) {
            handle = nil;
        }
    });
}

static void sbt_trace_schedule_snapshots(void);
#define SBT_TRACE(fmt, ...) sbt_trace_write([NSString stringWithFormat:@"%.3f " fmt, \
                                                CACurrentMediaTime(), ##__VA_ARGS__])
#else
#define SBT_TRACE(...) do {} while (0)
#endif

static int clampi(int v, int lo, int hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// Missing keys fall back to SBTDefaults.h, the same table the Settings pane
// seeds from, so the tweak and the pane can never disagree about a default.
static id prefValue(NSDictionary *p, NSString *key) {
    return p[key] ?: SBTDefaultValues()[key];
}

static NSInteger prefInt(NSDictionary *p, NSString *key) {
    return [prefValue(p, key) integerValue];
}

static double prefDouble(NSDictionary *p, NSString *key) {
    return [prefValue(p, key) doubleValue];
}

static BOOL prefBool(NSDictionary *p, NSString *key) {
    return [prefValue(p, key) boolValue];
}

// ------------------------------------------------------------- common lookups

static id list_view_model(id listView) {
    id model = nil;
    if ([listView respondsToSelector:@selector(model)]) model = [listView model];
    if (!model && [listView respondsToSelector:@selector(iconListModel)]) model = [listView iconListModel];
    if (!model && [listView respondsToSelector:@selector(displayedModel)]) model = [listView displayedModel];
    return model;
}

static id dock_list_view(id ctrl, id mgr) {
    id dock = nil;
    if ([mgr respondsToSelector:@selector(dockListView)]) dock = [mgr dockListView];
    if (!dock && [ctrl respondsToSelector:@selector(dockListView)]) dock = [ctrl dockListView];
    return dock;
}

// Provider lives on the icon manager on iOS 17 (the controller fallback is
// the iOS 26 path from the original; harmless to keep).
static id root_layout_config(id ctrl, id mgr) {
    id provider = nil;
    if ([mgr respondsToSelector:@selector(listLayoutProvider)]) provider = [mgr listLayoutProvider];
    if (!provider && [ctrl respondsToSelector:@selector(listLayoutProvider)]) provider = [ctrl listLayoutProvider];
    if (![provider respondsToSelector:@selector(layoutForIconLocation:)]) return nil;
    id layout = [provider layoutForIconLocation:@"SBIconLocationRoot"];
    return [layout respondsToSelector:@selector(layoutConfiguration)] ? [layout layoutConfiguration] : nil;
}

static id dock_layout_config(id dock) {
    id layout = [dock respondsToSelector:@selector(layout)] ? [dock layout] : nil;
    return [layout respondsToSelector:@selector(layoutConfiguration)] ? [layout layoutConfiguration] : nil;
}

static void force_manager_relayout(id mgr) {
    if ([mgr respondsToSelector:@selector(setNeedsRelayout:)])
        [mgr setNeedsRelayout:YES];
    if ([mgr respondsToSelector:@selector(relayout)])
        [mgr relayout];
    if ([mgr respondsToSelector:@selector(layoutIconListsWithAnimationType:forceRelayout:)])
        [mgr layoutIconListsWithAnimationType:0 forceRelayout:YES];
}

// ------------------------------------------------------ icon layout backup

static NSString *sbt_icon_layout_backup_path(void) {
#ifdef THEOS_PACKAGE_SCHEME_ROOTHIDE
    // Keep the snapshot inside roothide's randomized jailbreak root. Writing
    // the literal rootfs path leaks the file into the shared mobile container,
    // where sandboxed and non-roothide applications can see it.
    return jbroot(@"/var/mobile/Library/Preferences/cz.kolbi.sbtweaker.iconlayout.plist");
#else
    return @"/var/mobile/Library/Preferences/cz.kolbi.sbtweaker.iconlayout.plist";
#endif
}

static BOOL sbt_icon_restore_guard = NO;

// A snapshot that could not be refreshed is removed rather than kept: the
// next launch would otherwise restore it over every change made since.
//
// The state is serialized right away, since SpringBoard may go on mutating
// it, but written on a serial background queue so a save never waits on the
// disk. Order is kept, so the newest save always lands last.
static void sbt_write_icon_layout_snapshot(id state) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("cz.kolbi.sbtweaker.iconbackup", DISPATCH_QUEUE_SERIAL);
    });
    NSData *data = [NSPropertyListSerialization propertyList:state
                                            isValidForFormat:NSPropertyListBinaryFormat_v1_0]
        ? [NSPropertyListSerialization dataWithPropertyList:state
                                                     format:NSPropertyListXMLFormat_v1_0
                                                    options:0 error:NULL]
        : nil;
    NSString *path = sbt_icon_layout_backup_path();
    dispatch_async(queue, ^{
        if ([data writeToFile:path atomically:YES]) return;
        NSLog(@"[SBT:ICONS] snapshot not refreshed, removing the outdated one");
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    });
}

static BOOL sbt_restore_icon_layout(void) {
    if (!sbc_pref_bool_live(CFSTR("iconLayoutBackupEnabled"))) return NO;
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:sbt_icon_layout_backup_path()];
    if (!state.count) return NO;

    id controller = [%c(SBIconController) sharedInstance];
    id model = [controller respondsToSelector:@selector(model)] ? [controller model] : nil;
    BOOL restored = NO;
    @try {
        id store = [%c(SBDefaultIconModelStore) sharedInstance];
        NSURL *url = [store respondsToSelector:@selector(currentIconStateURL)]
            ? [store currentIconStateURL] : nil;
        // Nothing to do when SpringBoard loaded the very layout we kept.
        if (url.path.length &&
            [[NSDictionary dictionaryWithContentsOfFile:url.path] isEqualToDictionary:state]) {
            NSLog(@"[SBT:ICONS] layout matches the snapshot, no restore needed");
            return NO;
        }
        if (url.path.length)
            restored = [state writeToFile:url.path atomically:YES];
        if ([model respondsToSelector:@selector(importState:)])
            restored = [model importState:state] || restored;
        if (restored && [controller respondsToSelector:@selector(noteIconStateChangedExternally)])
            [controller noteIconStateChangedExternally];
    } @catch (NSException *exception) {
        NSLog(@"[SBT:ICONS] restore exception: %@", exception);
        restored = NO;
    }
    NSLog(@"[SBT:ICONS] layout restore %@", restored ? @"requested" : @"failed");
    return restored;
}

%group SpringBoard
%hook SBIconModelPropertyListFileStore
- (BOOL)saveCurrentIconState:(id)state error:(NSError **)error {
    if (sbt_icon_restore_guard) return YES;
    BOOL result = %orig;
    if (result && sbc_pref_bool_live(CFSTR("iconLayoutBackupEnabled")))
        sbt_write_icon_layout_snapshot(state);
    return result;
}

- (BOOL)_save:(id)state url:(NSURL *)url error:(NSError **)error {
    if (sbt_icon_restore_guard) return YES;
    BOOL result = %orig;
    if (result && sbc_pref_bool_live(CFSTR("iconLayoutBackupEnabled"))) {
        NSURL *currentURL = nil;
        if ([self respondsToSelector:@selector(currentIconStateURL)])
            currentURL = [(id)self currentIconStateURL];
        if (!currentURL || [url.path isEqualToString:currentURL.path])
            sbt_write_icon_layout_snapshot(state);
    }
    return result;
}
%end
%end

// ------------------------------------------------------- native layout values
//
// The patches below write custom values into SpringBoard's layout objects.
// The getter hooks only override while a feature is on; once it is switched
// off they answer with the stored value, which was still ours, so switching a
// feature off used to take a respring. The value each object held before our
// first write is therefore kept alongside it, replaced whenever SpringBoard
// itself sets a new one, and written back when the feature is switched off.
static char sbc_native_layout_key;
static BOOL sbc_writing_layout = NO;  // our own write, not a new native value
static BOOL sbc_reading_native = NO;  // getter hooks answer the stored value

static NSMutableDictionary *sbc_native_layout(id obj, BOOL create) {
    if (!obj) return nil;
    NSMutableDictionary *values = objc_getAssociatedObject(obj, &sbc_native_layout_key);
    if (!values && create) {
        values = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(obj, &sbc_native_layout_key, values,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return values;
}

static void sbc_record_native(id obj, NSString *key, NSValue *(^read)(void)) {
    NSMutableDictionary *values = sbc_native_layout(obj, YES);
    if (!values || values[key]) return;
    sbc_reading_native = YES;
    NSValue *value = read();
    sbc_reading_native = NO;
    if (value) values[key] = value;
}

// SpringBoard set a value itself: that is the native one from now on.
static void sbc_note_native(id obj, NSString *key, NSValue *value) {
    if (sbc_writing_layout) return;
    NSMutableDictionary *values = sbc_native_layout(obj, NO);
    if (values[key]) values[key] = value;
}

static void sbc_write_columns(id obj, NSUInteger columns) {
    if (![obj respondsToSelector:@selector(setNumberOfPortraitColumns:)]) return;
    if ([obj respondsToSelector:@selector(numberOfPortraitColumns)])
        sbc_record_native(obj, @"columns", ^NSValue *{ return @([obj numberOfPortraitColumns]); });
    sbc_writing_layout = YES;
    [obj setNumberOfPortraitColumns:columns];
    sbc_writing_layout = NO;
}

static void sbc_write_rows(id obj, NSUInteger rows) {
    if (![obj respondsToSelector:@selector(setNumberOfPortraitRows:)]) return;
    if ([obj respondsToSelector:@selector(numberOfPortraitRows)])
        sbc_record_native(obj, @"rows", ^NSValue *{ return @([obj numberOfPortraitRows]); });
    sbc_writing_layout = YES;
    [obj setNumberOfPortraitRows:rows];
    sbc_writing_layout = NO;
}

static void sbc_write_insets(id obj, UIEdgeInsets insets) {
    if (![obj respondsToSelector:@selector(setPortraitLayoutInsets:)]) return;
    if ([obj respondsToSelector:@selector(portraitLayoutInsets)])
        sbc_record_native(obj, @"insets", ^NSValue *{
            return [NSValue valueWithUIEdgeInsets:[obj portraitLayoutInsets]];
        });
    sbc_writing_layout = YES;
    [obj setPortraitLayoutInsets:insets];
    sbc_writing_layout = NO;
}

static void sbc_write_grid_size(id obj, SBCGridSize grid) {
    if (![obj respondsToSelector:@selector(setGridSize:)]) return;
    if ([obj respondsToSelector:@selector(gridSize)])
        sbc_record_native(obj, @"gridSize", ^NSValue *{
            SBCGridSize native = [obj gridSize];
            return [NSValue valueWithBytes:&native objCType:@encode(SBCGridSize)];
        });
    sbc_writing_layout = YES;
    [obj setGridSize:grid];
    sbc_writing_layout = NO;
}

static void sbc_write_autofit(id obj, BOOL autofit) {
    if (![obj respondsToSelector:@selector(setAutomaticallyAdjustsLayoutMetricsToFit:)]) return;
    if ([obj respondsToSelector:@selector(automaticallyAdjustsLayoutMetricsToFit)])
        sbc_record_native(obj, @"autofit", ^NSValue *{
            return @([obj automaticallyAdjustsLayoutMetricsToFit]);
        });
    sbc_writing_layout = YES;
    [obj setAutomaticallyAdjustsLayoutMetricsToFit:autofit];
    sbc_writing_layout = NO;
}

// Writes the native value back and forgets it. NO when there was none, i.e.
// the value was never changed.
static BOOL sbc_restore_native(id obj, NSString *key) {
    NSMutableDictionary *values = sbc_native_layout(obj, NO);
    NSValue *value = values[key];
    if (!value) return NO;
    [values removeObjectForKey:key];
    sbc_writing_layout = YES;
    if ([key isEqualToString:@"columns"]) {
        [obj setNumberOfPortraitColumns:[(NSNumber *)value unsignedIntegerValue]];
    } else if ([key isEqualToString:@"rows"]) {
        [obj setNumberOfPortraitRows:[(NSNumber *)value unsignedIntegerValue]];
    } else if ([key isEqualToString:@"insets"]) {
        [obj setPortraitLayoutInsets:value.UIEdgeInsetsValue];
    } else if ([key isEqualToString:@"gridSize"]) {
        SBCGridSize grid;
        [value getValue:&grid size:sizeof grid];
        [obj setGridSize:grid];
    } else if ([key isEqualToString:@"autofit"]) {
        [obj setAutomaticallyAdjustsLayoutMetricsToFit:[(NSNumber *)value boolValue]];
    }
    sbc_writing_layout = NO;
    return YES;
}

// ---------------------------------------------------------------- grid patches

static void disable_list_autofit(id listView, NSString *tag) {
    if ([listView respondsToSelector:@selector(setAutomaticallyAdjustsLayoutMetricsToFit:)]) {
        sbc_write_autofit(listView, NO);
        NSLog(@"[SBC] %@ autoFit=NO", tag);
    }
}

static NSArray *sbc_root_list_views(id mgr) {
    NSMutableArray *lists = [NSMutableArray array];
    id rootFolder = [mgr respondsToSelector:@selector(rootFolderController)] ? [mgr rootFolderController] : nil;
    if (![rootFolder respondsToSelector:@selector(iconListViewCount)] ||
        ![rootFolder respondsToSelector:@selector(iconListViewAtIndex:)])
        return lists;
    NSUInteger count = MIN([rootFolder iconListViewCount], 64);
    for (NSUInteger i = 0; i < count; i++) {
        id listView = [rootFolder iconListViewAtIndex:i];
        if (listView) [lists addObject:listView];
    }
    return lists;
}

static void patch_dock(id dock, int dockIcons) {
    if (!dock) { NSLog(@"[SBC] dock: nil dockListView"); return; }
    disable_list_autofit(dock, @"dockListView");

    id model = list_view_model(dock);
    if (model && [model respondsToSelector:@selector(gridSize)] &&
        [model respondsToSelector:@selector(setGridSize:)]) {
        SBCGridSize old = [model gridSize];
        SBCGridSize grid = { (unsigned short)dockIcons, old.rows };
        sbc_write_grid_size(model, grid);
        NSLog(@"[SBC] dock gridSize -> %dx%d", dockIcons, old.rows);
    }

    id cfg = dock_layout_config(dock);
    if ([cfg respondsToSelector:@selector(setNumberOfPortraitColumns:)]) {
        sbc_write_columns(cfg, (NSUInteger)dockIcons);
        NSLog(@"[SBC] dock portraitColumns -> %d", dockIcons);
    }
    [dock setNeedsLayout];
}

static void restore_dock(id dock) {
    BOOL restored = sbc_restore_native(list_view_model(dock), @"gridSize");
    restored = sbc_restore_native(dock_layout_config(dock), @"columns") || restored;
    restored = sbc_restore_native(dock, @"autofit") || restored;
    if (!restored) return;
    NSLog(@"[SBC] dock count restored");
    [dock setNeedsLayout];
}

static void patch_homescreen_grid(id mgr, id cfg, int cols, int rows) {
    if ([cfg respondsToSelector:@selector(setNumberOfPortraitColumns:)]) {
        sbc_write_columns(cfg, (NSUInteger)cols);
        sbc_write_rows(cfg, (NSUInteger)rows);
        NSLog(@"[SBC] hs provider cols=%d rows=%d", cols, rows);
    }

    NSArray *lists = sbc_root_list_views(mgr);
    for (NSUInteger i = 0; i < lists.count; i++) {
        id listView = lists[i];
        NSString *tag = [NSString stringWithFormat:@"page[%lu]", (unsigned long)i];
        disable_list_autofit(listView, tag);
        // Never rewrite a Home Screen model's grid. On iOS 15 this can
        // invalidate and remove widgets during icon-state restoration.
        // Configuration and SBIconListView metric hooks provide the
        // custom capacity/layout without modifying the saved icon state.
        [listView setNeedsLayout];
    }
}

// ---------------------------------------------------- spacing (darksword_layout)

// The extras are added to the configuration's own native insets, the way the
// landscape ones always were. Fixed bases ({60, 27, 100, 27} for the Home
// Screen, 16 at the dock's sides, from the original) only matched some
// iPhones: elsewhere switching spacing on with no extras already moved the
// icons. Until we first write, the stored value is the native one.
static UIEdgeInsets sbc_base_insets(id cfg, UIEdgeInsets stored) {
    NSValue *native = sbc_native_layout(cfg, NO)[@"insets"];
    return native ? native.UIEdgeInsetsValue : stored;
}

static UIEdgeInsets sbc_stored_insets(id cfg) {
    if (![cfg respondsToSelector:@selector(portraitLayoutInsets)]) return UIEdgeInsetsZero;
    sbc_reading_native = YES;
    UIEdgeInsets stored = [cfg portraitLayoutInsets];
    sbc_reading_native = NO;
    return stored;
}

static UIEdgeInsets sbc_home_insets(NSDictionary *p, UIEdgeInsets base) {
    base.top += prefDouble(p, @"homeExT");
    base.left += prefDouble(p, @"homeExL");
    base.bottom += prefDouble(p, @"homeExB");
    base.right += prefDouble(p, @"homeExR");
    return base;
}

static UIEdgeInsets sbc_dock_insets(NSDictionary *p, UIEdgeInsets base) {
    base.left += prefDouble(p, @"dockExL");
    base.right += prefDouble(p, @"dockExR");
    return base;
}

static void apply_home_spacing(id cfg, NSDictionary *p) {
    if (![cfg respondsToSelector:@selector(setPortraitLayoutInsets:)]) {
        NSLog(@"[SBC:SPACE] layoutConfiguration lacks setPortraitLayoutInsets:");
        return;
    }
    UIEdgeInsets insets = sbc_home_insets(p, sbc_base_insets(cfg, sbc_stored_insets(cfg)));
    sbc_write_insets(cfg, insets);
    NSLog(@"[SBC:SPACE] home insets %@", NSStringFromUIEdgeInsets(insets));
}

static void apply_dock_spacing(id dockCfg, NSDictionary *p) {
    if (![dockCfg respondsToSelector:@selector(setPortraitLayoutInsets:)]) {
        NSLog(@"[SBC:SPACE] dock layoutConfiguration lacks setPortraitLayoutInsets:");
        return;
    }
    UIEdgeInsets insets = sbc_dock_insets(p, sbc_base_insets(dockCfg, sbc_stored_insets(dockCfg)));
    sbc_write_insets(dockCfg, insets);
    NSLog(@"[SBC:SPACE] dock insets %@", NSStringFromUIEdgeInsets(insets));
}

// ----------------------------------------------------- scaling (darksword_layout)

// Icon geometry differs per device and per layout (e.g. 60 pt at 2x, 64 pt
// at 3x; iPad pages with widgets use smaller icons), so the scaled value is
// derived from each configuration's own native icon image info. Once
// scaling is on, a configuration is written with the scaled value, so its
// native one is kept alongside it: recorded from the first read, replaced
// whenever SpringBoard itself sets a new value, and handed on to copies.
// Scaling that absolute value keeps repeated layout passes idempotent (no
// compounding).
static char sbc_native_icon_info_key;
static BOOL sbc_writing_icon_info = NO;

static BOOL sbc_icon_info_valid(SBIconImageInfo info) {
    return info.size.width > 0.0 && info.size.height > 0.0 && info.scale > 0.0;
}

static void sbc_set_native_icon_info(id cfg, SBIconImageInfo info) {
    if (!sbc_icon_info_valid(info)) return;
    objc_setAssociatedObject(cfg, &sbc_native_icon_info_key,
                             [NSValue valueWithBytes:&info objCType:@encode(SBIconImageInfo)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL sbc_get_native_icon_info(id cfg, SBIconImageInfo *info) {
    NSValue *stored = objc_getAssociatedObject(cfg, &sbc_native_icon_info_key);
    if (!stored) return NO;
    [stored getValue:info size:sizeof *info];
    return YES;
}

static SBIconImageInfo configured_icon_image_info(SBIconImageInfo native, double scale) {
    SBIconImageInfo info = native;
    info.size = CGSizeMake(native.size.width * scale, native.size.height * scale);
    info.continuousCornerRadius = native.continuousCornerRadius * scale;
    return info;
}

static UIEdgeInsets constrained_grid_insets(UIEdgeInsets insets, int columns,
                                             int rows, double iconScale,
                                             BOOL landscape) {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGFloat width = landscape ? MAX(screen.width, screen.height) : MIN(screen.width, screen.height);
    CGFloat height = landscape ? MIN(screen.width, screen.height) : MAX(screen.width, screen.height);
    CGFloat minimumCell = 36.0 * MAX(0.5, MIN(iconScale, 1.5));
    CGFloat horizontalBudget = MAX(0.0, width - columns * minimumCell);
    CGFloat verticalBudget = MAX(0.0, height - rows * minimumCell);

    CGFloat excess = insets.left + insets.right - horizontalBudget;
    if (excess > 0.0) {
        insets.left -= excess / 2.0;
        insets.right -= excess / 2.0;
    }
    excess = insets.top + insets.bottom - verticalBudget;
    if (excess > 0.0) {
        insets.top -= excess / 2.0;
        insets.bottom -= excess / 2.0;
    }
    return insets;
}

static double sbc_effective_home_scale(NSDictionary *p) {
    if (!prefBool(p, @"homeScaleEnabled")) return 1.0;
    double scale = prefDouble(p, @"homeScale");
    return scale > 0.0 && scale <= 2.0 ? scale : 1.0;
}

// SBApplicationIcon only — widgets/folders assert on a forced app icon size.
static void refresh_list_view_icons(id listView, SBIconImageInfo info) {
    Class iconViewClass = %c(SBIconView);
    Class appIconClass = %c(SBApplicationIcon);
    if (!iconViewClass || !appIconClass) return;

    for (id v in [listView subviews]) {
        if (![v isKindOfClass:iconViewClass]) continue;
        id icon = [v respondsToSelector:@selector(icon)] ? [v icon] : nil;
        if (![icon isKindOfClass:appIconClass]) continue;
        if ([v respondsToSelector:@selector(setIconImageInfo:)])
            [v setIconImageInfo:info];
        if ([v respondsToSelector:@selector(_updateAfterManualIconImageInfoChangeInvalidatingLayout:)])
            [v _updateAfterManualIconImageInfoChangeInvalidatingLayout:YES];
    }
}

static void refresh_home_icons(id mgr, SBIconImageInfo info) {
    for (id listView in sbc_root_list_views(mgr)) {
        if ([listView respondsToSelector:@selector(isDock)] && [listView isDock]) continue;
        refresh_list_view_icons(listView, info);
    }
}

// Scaling switched off: hand the configuration its native icon geometry back.
// NO when it was never scaled.
static BOOL restore_icon_scale(id cfg) {
    SBIconImageInfo native;
    if (!cfg || !sbc_get_native_icon_info(cfg, &native)) return NO;
    objc_setAssociatedObject(cfg, &sbc_native_icon_info_key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([cfg respondsToSelector:@selector(setIconImageInfo:)]) {
        sbc_writing_icon_info = YES;
        [cfg setIconImageInfo:native];
        sbc_writing_icon_info = NO;
    }
    return YES;
}

static void apply_home_scale(id mgr, id cfg, double scale) {
    if (scale <= 0.0 || scale > 2.0 || ![cfg respondsToSelector:@selector(iconImageInfo)]) return;
    // The getter hook already returns the stock geometry scaled once.
    refresh_home_icons(mgr, [cfg iconImageInfo]);
    NSLog(@"[SBC:SCALE] home scale=%.2f", scale);
}

static void apply_dock_scale(id dock, id dockCfg, double scale) {
    if (scale <= 0.0 || scale > 2.0 || !dock ||
        ![dockCfg respondsToSelector:@selector(iconImageInfo)]) return;
    SBIconImageInfo info = [dockCfg iconImageInfo];
    refresh_list_view_icons(dock, info);
    NSLog(@"[SBC:SCALE] dock scale=%.2f", scale);
}

// ---------------------------------------- capacity correct at state-load time
//
// IconOrder can only replay the state SpringBoard last saved. With a >4-icon
// dock, SpringBoard validates the loaded icon state against the dock's
// capacity *before* our delayed patches run: capacity is still 4, the extra
// icon is evicted, and the reduced layout is what gets saved — which IconOrder
// then faithfully preserves. Hooking the configuration getters makes dock and
// home values correct from the very first query, whenever SpringBoard creates
// these objects. Dock = single row; folders (stock 3x3) are left untouched.

@interface SBIconListGridLayoutConfiguration : NSObject
- (NSUInteger)numberOfPortraitRows;
- (NSUInteger)numberOfPortraitColumns;
- (UIEdgeInsets)portraitLayoutInsets;
- (SBIconImageInfo)iconImageInfo;
@end

@interface SBIconListView : UIView
- (NSString *)iconLocation;
- (id)layout;
- (NSUInteger)iconRowsForCurrentOrientation;
- (NSUInteger)iconColumnsForCurrentOrientation;
- (NSUInteger)iconRowsForSpacingCalculation;
- (NSUInteger)iconsInRowForSpacingCalculation;
@end

@interface SBRootFolderView : UIView
- (id)pageControl;
- (id)scrollAccessoryView;
@end

@interface SBDockIconListModel : NSObject
- (SBCGridSize)gridSize;
@end

static NSDictionary *sbc_cachedPrefs = nil;
static CFAbsoluteTime sbc_prefs_loaded_at = 0;

// iOS 15 gives pages containing widgets their own icon location. They are
// still ordinary Home Screen root pages and must use the same custom metrics.
static BOOL sbc_is_root_icon_location(NSString *location) {
    return [location isEqualToString:@"SBIconLocationRoot"] ||
           [location isEqualToString:@"SBIconLocationRootWithWidgets"];
}

// Preferences go through CFPreferences/cfprefsd — the same channel the
// Settings pane writes through. Reading the plist file directly could serve
// stale values when a toggle was followed quickly by a respring (cfprefsd
// hadn't flushed yet); cfprefsd survives the respring and always has the
// current values.
static NSDictionary *sbc_reload_prefs(void) {
    CFDictionaryRef d = CFPreferencesCopyMultiple(NULL, kPrefsDomain,
                                                  kCFPreferencesCurrentUser,
                                                  kCFPreferencesAnyHost);
    sbc_cachedPrefs = CFBridgingRelease(d);
    sbc_prefs_loaded_at = CFAbsoluteTimeGetCurrent();
    return sbc_cachedPrefs;
}

static NSDictionary *sbc_prefs(void) {
    // Hot hooks must not make a cfprefsd round-trip on every call. The
    // Settings pane posts the apply notification after every change, and
    // sbc_apply() reloads right away, so the cache only needs refreshing for
    // writes that did not come through the pane, or a read so early in boot
    // that cfprefsd had nothing yet. Ten seconds covers those.
    if (!sbc_cachedPrefs || CFAbsoluteTimeGetCurrent() - sbc_prefs_loaded_at >= 10.0)
        sbc_reload_prefs();
    return sbc_cachedPrefs;
}

// ------------------------------------------------------ config identification
//
// These getter hooks used to guess the target from the stock geometry
// (1 row = dock, 3 columns = folders, everything else = home). That also
// matched the App Library pod configs, which are neither — so App Library
// got the home grid/spacing/scale and looked broken. Now we only touch the
// two config instances SpringBoard actually uses for the root (home) and
// dock locations, identified by object identity.

static __weak id sbc_root_cfg = nil;
static __weak id sbc_dock_cfg = nil;
static NSHashTable *sbc_root_cfg_instances = nil;

static NSHashTable *sbc_root_configs(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sbc_root_cfg_instances = [NSHashTable weakObjectsHashTable];
    });
    return sbc_root_cfg_instances;
}

// Configurations already identified as neither root nor dock (App Library
// pods, folders). The getters below run many times per layout pass; without
// this every call for such a config re-queried the layout provider.
static NSHashTable *sbc_other_configs(void) {
    static NSHashTable *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSHashTable weakObjectsHashTable]; });
    return set;
}

static void sbc_register_root_config(id cfg) {
    if (!cfg) return;
    [sbc_other_configs() removeObject:cfg];
    [sbc_root_configs() addObject:cfg];
    sbc_root_cfg = cfg;
}

static void sbc_set_dock_config(id cfg) {
    if (!cfg) return;
    [sbc_other_configs() removeObject:cfg];
    sbc_dock_cfg = cfg;
}

#define SBC_CFG_UNKNOWN 0
#define SBC_CFG_ROOT    1
#define SBC_CFG_DOCK    2

static int sbc_config_kind(id cfg) {
    if (!cfg) return SBC_CFG_UNKNOWN;
    if (sbc_root_cfg && cfg == sbc_root_cfg) return SBC_CFG_ROOT;
    if ([sbc_root_configs() containsObject:cfg]) return SBC_CFG_ROOT;
    if (sbc_dock_cfg && cfg == sbc_dock_cfg) return SBC_CFG_DOCK;
    if ([sbc_other_configs() containsObject:cfg]) return SBC_CFG_UNKNOWN;

    // Refresh identities from the live layout provider.
    id iconCtrl = [%c(SBIconController) sharedInstance];
    id mgr = [iconCtrl respondsToSelector:@selector(iconManager)] ? [iconCtrl iconManager] : nil;
    id provider = [mgr respondsToSelector:@selector(listLayoutProvider)] ? [mgr listLayoutProvider] : nil;
    if ([provider respondsToSelector:@selector(layoutForIconLocation:)]) {
        id rl = [provider layoutForIconLocation:@"SBIconLocationRoot"];
        sbc_root_cfg = [rl respondsToSelector:@selector(layoutConfiguration)] ? [rl layoutConfiguration] : nil;
        sbc_register_root_config(sbc_root_cfg);
        id dl = [provider layoutForIconLocation:@"SBIconLocationDock"];
        sbc_set_dock_config([dl respondsToSelector:@selector(layoutConfiguration)] ? [dl layoutConfiguration] : nil);
    }
    if (cfg == sbc_root_cfg) return SBC_CFG_ROOT;
    if (cfg == sbc_dock_cfg) return SBC_CFG_DOCK;
    // Only cache a negative answer once both identities are known; during
    // boot the provider chain may not be up yet.
    if (sbc_root_cfg && sbc_dock_cfg) [sbc_other_configs() addObject:cfg];
    return SBC_CFG_UNKNOWN;
}

%group SpringBoard
%hook SBIconListGridLayoutConfiguration
- (id)copyWithZone:(NSZone *)zone {
    id copy = %orig;
    if ([sbc_root_configs() containsObject:self])
        sbc_register_root_config(copy);
    SBIconImageInfo native;
    if (copy && sbc_get_native_icon_info(self, &native))
        sbc_set_native_icon_info(copy, native);
    NSDictionary *layout = sbc_native_layout(self, NO);
    if (copy && layout.count)
        objc_setAssociatedObject(copy, &sbc_native_layout_key, [layout mutableCopy],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return copy;
}

- (void)setNumberOfPortraitColumns:(NSUInteger)value {
    sbc_note_native(self, @"columns", @(value));
    %orig;
}

- (void)setNumberOfPortraitRows:(NSUInteger)value {
    sbc_note_native(self, @"rows", @(value));
    %orig;
}

- (void)setPortraitLayoutInsets:(UIEdgeInsets)insets {
    sbc_note_native(self, @"insets", [NSValue valueWithUIEdgeInsets:insets]);
    %orig;
}

- (NSUInteger)numberOfPortraitRows {
    NSUInteger orig = %orig;
    if (sbc_reading_native) return orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return orig;
    if (sbc_config_kind(self) != SBC_CFG_ROOT) return orig;
    if (!prefBool(p, @"homeGridEnabled")) return orig;
    return (NSUInteger)clampi((int)prefInt(p, @"hsRows"), 1, 10);
}

- (NSUInteger)numberOfPortraitColumns {
    NSUInteger orig = %orig;
    if (sbc_reading_native) return orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return orig;
    int kind = sbc_config_kind(self);
    // Fallback for the dock only: identity lookup can fail during boot (the
    // provider chain may not be up when icon-state validation first asks),
    // which used to cost us the 5th dock icon. A single-row, 4-wide grid is
    // unambiguous enough — the App Library breakage came from the *home*
    // branch matching everything, and that branch stays identity-only.
    // The dock-count switch owns both its geometry and capacity. This
    // fallback keeps the configured slot count available during boot-time
    // icon-state validation before object identity has been established.
    if (kind == SBC_CFG_UNKNOWN && prefBool(p, @"dockLayoutEnabled") &&
        orig == 4 && [self numberOfPortraitRows] == 1) {
        static BOOL logged = NO;
        if (!logged) { logged = YES; NSLog(@"[SBC] dock config identified by 1-row fallback"); }
        kind = SBC_CFG_DOCK;
    }
    if (kind == SBC_CFG_DOCK && prefBool(p, @"dockLayoutEnabled"))
        return (NSUInteger)clampi((int)prefInt(p, @"dockIcons"), 1, 8);
    if (kind == SBC_CFG_ROOT && prefBool(p, @"homeGridEnabled"))
        return (NSUInteger)clampi((int)prefInt(p, @"hsCols"), 1, 10);
    return orig;
}

- (UIEdgeInsets)portraitLayoutInsets {
    UIEdgeInsets orig = %orig;
    if (sbc_reading_native) return orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return orig;
    int kind = sbc_config_kind(self);
    if (kind == SBC_CFG_DOCK) {
        if (!prefBool(p, @"dockSpacingEnabled")) return orig;
        return sbc_dock_insets(p, sbc_base_insets(self, orig));
    }
    if (kind == SBC_CFG_ROOT) {
        if (!prefBool(p, @"homeSpacingEnabled")) return orig;
        UIEdgeInsets insets = sbc_home_insets(p, sbc_base_insets(self, orig));
        // The grid and icon size actually in use, not settings that are off.
        return constrained_grid_insets(insets,
            clampi((int)[(id)self numberOfPortraitColumns], 1, 10),
            clampi((int)[(id)self numberOfPortraitRows], 1, 10),
            sbc_effective_home_scale(p), NO);
    }
    return orig;
}

- (SBIconImageInfo)iconImageInfo {
    SBIconImageInfo orig = %orig;
    SBIconImageInfo native;
    BOOL known = sbc_get_native_icon_info(self, &native);
    NSDictionary *p = sbc_prefs();
    BOOL home = prefBool(p, @"enabled") && prefBool(p, @"homeScaleEnabled");
    BOOL dock = prefBool(p, @"enabled") && prefBool(p, @"dockScaleEnabled");
    // Scaling off: SpringBoard's value, or the native one if it was scaled.
    if (!home && !dock) return known ? native : orig;
    int kind = sbc_config_kind(self);
    BOOL scaled = (kind == SBC_CFG_ROOT && home) || (kind == SBC_CFG_DOCK && dock);
    if (!scaled) return known ? native : orig;
    if (!known) {
        if (!sbc_icon_info_valid(orig)) return orig;
        native = orig;
        sbc_set_native_icon_info(self, native);
    }
    double scale = kind == SBC_CFG_DOCK ? prefDouble(p, @"dockScale")
                                        : prefDouble(p, @"homeScale");
    if (scale <= 0.0 || scale > 2.0) return native;
    return configured_icon_image_info(native, scale);
}

- (void)setIconImageInfo:(SBIconImageInfo)info {
    // A value SpringBoard sets is the new native one; ours is the scaled one.
    if (!sbc_writing_icon_info && objc_getAssociatedObject(self, &sbc_native_icon_info_key))
        sbc_set_native_icon_info(self, info);
    %orig;
}
%end
%end

// Widget-bearing Home Screen pages use page-specific (and sometimes copied)
// grid configurations instead of the provider's canonical root instance.
// Register only list views explicitly belonging to a root-page location so
// the App Library, folders and dock remain untouched.
%group SpringBoard
%hook SBIconListView
static BOOL sbc_root_list_uses_landscape_metrics(SBIconListView *listView) {
    return CGRectGetWidth(listView.bounds) > CGRectGetHeight(listView.bounds);
}

static NSUInteger sbc_root_list_dimension(SBIconListView *listView,
                                          NSUInteger original, BOOL rows) {
    NSString *location = [listView respondsToSelector:@selector(iconLocation)]
        ? [(id)listView iconLocation] : nil;
    if (!sbc_is_root_icon_location(location)) return original;

    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return original;

    BOOL landscape = sbc_root_list_uses_landscape_metrics(listView);
    NSString *enabledKey = landscape ? @"homeGridLandscapeEnabled" : @"homeGridEnabled";
    if (!prefBool(p, enabledKey)) return original;

    NSString *key = rows ? (landscape ? @"hsRowsLandscape" : @"hsRows")
                         : (landscape ? @"hsColsLandscape" : @"hsCols");
    return (NSUInteger)clampi((int)prefInt(p, key), 1, 10);
}

- (NSUInteger)iconRowsForCurrentOrientation {
    NSUInteger original = %orig;
    return sbc_root_list_dimension(self, original, YES);
}

- (NSUInteger)iconColumnsForCurrentOrientation {
    NSUInteger original = %orig;
    return sbc_root_list_dimension(self, original, NO);
}

- (NSUInteger)iconRowsForSpacingCalculation {
    NSUInteger original = %orig;
    return sbc_root_list_dimension(self, original, YES);
}

- (NSUInteger)iconsInRowForSpacingCalculation {
    NSUInteger original = %orig;
    return sbc_root_list_dimension(self, original, NO);
}

- (void)layoutSubviews {
    NSString *location = [self respondsToSelector:@selector(iconLocation)]
        ? [(id)self iconLocation] : nil;
    if (sbc_is_root_icon_location(location)) {
        id layout = [self respondsToSelector:@selector(layout)] ? [(id)self layout] : nil;
        id cfg = [layout respondsToSelector:@selector(layoutConfiguration)]
            ? [layout layoutConfiguration] : nil;
        sbc_register_root_config(cfg);
    }
    %orig;
}
%end
%end

// Landscape accessors vary between SpringBoard releases and device types.
// Install these hooks manually only when the runtime has a real method and
// Substrate gives us a valid original implementation. This keeps independent
// portrait/landscape counts without calling a missing %orig on iOS 16/17.
static NSUInteger (*sbc_orig_landscape_rows)(id, SEL) = NULL;
static NSUInteger (*sbc_orig_landscape_columns)(id, SEL) = NULL;
static UIEdgeInsets (*sbc_orig_landscape_insets)(id, SEL) = NULL;
static SBIconImageInfo (*sbc_orig_landscape_icon_info)(id, SEL) = NULL;

static NSUInteger sbc_landscape_rows(id self, SEL _cmd) {
    NSUInteger orig = sbc_orig_landscape_rows
        ? sbc_orig_landscape_rows(self, _cmd) : 0;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return orig;
    if (sbc_config_kind(self) != SBC_CFG_ROOT) return orig;
    if (!prefBool(p, @"homeGridLandscapeEnabled")) return orig;
    return (NSUInteger)clampi((int)prefInt(p, @"hsRowsLandscape"), 1, 10);
}

static NSUInteger sbc_landscape_columns(id self, SEL _cmd) {
    NSUInteger orig = sbc_orig_landscape_columns
        ? sbc_orig_landscape_columns(self, _cmd) : 0;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return orig;
    if (sbc_config_kind(self) != SBC_CFG_ROOT) return orig;
    if (!prefBool(p, @"homeGridLandscapeEnabled")) return orig;
    return (NSUInteger)clampi((int)prefInt(p, @"hsColsLandscape"), 1, 10);
}

static UIEdgeInsets sbc_landscape_insets(id self, SEL _cmd) {
    UIEdgeInsets orig = sbc_orig_landscape_insets
        ? sbc_orig_landscape_insets(self, _cmd) : UIEdgeInsetsZero;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled") ||
        !prefBool(p, @"homeSpacingLandscapeEnabled") ||
        sbc_config_kind(self) != SBC_CFG_ROOT)
        return orig;
    UIEdgeInsets insets = UIEdgeInsetsMake(orig.top + prefDouble(p, @"homeExTLandscape"),
                                           orig.left + prefDouble(p, @"homeExLLandscape"),
                                           orig.bottom + prefDouble(p, @"homeExBLandscape"),
                                           orig.right + prefDouble(p, @"homeExRLandscape"));
    // The grid and icon size actually in use, not settings that are off.
    int columns = [self respondsToSelector:@selector(numberOfLandscapeColumns)]
        ? (int)[self numberOfLandscapeColumns] : (int)prefInt(p, @"hsColsLandscape");
    int rows = [self respondsToSelector:@selector(numberOfLandscapeRows)]
        ? (int)[self numberOfLandscapeRows] : (int)prefInt(p, @"hsRowsLandscape");
    return constrained_grid_insets(insets, clampi(columns, 1, 10), clampi(rows, 1, 10),
                                   sbc_effective_home_scale(p), YES);
}

static SBIconImageInfo sbc_landscape_icon_info(id self, SEL _cmd) {
    SBIconImageInfo orig = sbc_orig_landscape_icon_info
        ? sbc_orig_landscape_icon_info(self, _cmd) : (SBIconImageInfo){0};
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled") ||
        !prefBool(p, @"homeScaleEnabled") ||
        sbc_config_kind(self) != SBC_CFG_ROOT)
        return orig;
    double scale = prefDouble(p, @"homeScale");
    // Nothing writes the landscape value, so the original is the native one.
    if (!sbc_icon_info_valid(orig) || scale <= 0.0 || scale > 2.0) return orig;
    return configured_icon_image_info(orig, scale);
}

static void sbc_install_landscape_hooks(void) {
    Class cls = objc_getClass("SBIconListGridLayoutConfiguration");
    if (!cls) return;

    SEL rows = @selector(numberOfLandscapeRows);
    if (class_getInstanceMethod(cls, rows)) {
        MSHookMessageEx(cls, rows, (IMP)sbc_landscape_rows,
                        (IMP *)&sbc_orig_landscape_rows);
    }

    SEL columns = @selector(numberOfLandscapeColumns);
    if (class_getInstanceMethod(cls, columns)) {
        MSHookMessageEx(cls, columns, (IMP)sbc_landscape_columns,
                        (IMP *)&sbc_orig_landscape_columns);
    }

    SEL insets = NSSelectorFromString(@"landscapeLayoutInsets");
    if (class_getInstanceMethod(cls, insets)) {
        MSHookMessageEx(cls, insets, (IMP)sbc_landscape_insets,
                        (IMP *)&sbc_orig_landscape_insets);
    }

    SEL iconInfo = NSSelectorFromString(@"landscapeIconImageInfo");
    if (class_getInstanceMethod(cls, iconInfo)) {
        MSHookMessageEx(cls, iconInfo, (IMP)sbc_landscape_icon_info,
                        (IMP *)&sbc_orig_landscape_icon_info);
    }
}

%group SpringBoard
%hook SBDockIconListModel
- (SBCGridSize)gridSize {
    SBCGridSize grid = %orig;
    if (sbc_reading_native) return grid;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return grid;
    if (!prefBool(p, @"dockLayoutEnabled")) return grid;
    int dockIcons = clampi((int)prefInt(p, @"dockIcons"), 1, 8);
    if (grid.columns < dockIcons) grid.columns = (unsigned short)dockIcons;
    return grid;
}

- (void)setGridSize:(SBCGridSize)grid {
    sbc_note_native(self, @"gridSize", [NSValue valueWithBytes:&grid objCType:@encode(SBCGridSize)]);
    %orig;
}
%end
%end

// ---------------------------------------- iOS 18: Home Screen page capacity
//
// SBTweaker's view hooks show the custom rows/columns, but each Home Screen
// page's list model keeps the grid it was created with — stock 4x6. iOS 17's
// and 18's
// free placement and the page capacity work against that model grid, so a
// page counted as full at 24 cells: icons could not be dropped into the
// visible extra rows, and a widget could not move down into an empty row.
//
// SpringBoard asks the icon manager (and the icon model, while unarchiving
// the icon state) for the list grid size when it builds a folder's pages.
// Answering with the custom grid for the root folder makes the pages be
// created with it, so capacity, gaps and widget placement all agree with
// what is shown. Pages are built at launch, so this takes a respring.
// Overriding the model's gridSize getter afterwards (the earlier widget test
// builds) is not enough: the model keeps its stored grid.

// Both are asked from hooks that run many times per layout pass.
static NSInteger sbc_os_major(void) {
    static NSInteger major;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        major = [NSProcessInfo processInfo].operatingSystemVersion.majorVersion;
    });
    return major;
}

static BOOL sbc_is_ios17_or_newer(void) {
    return sbc_os_major() >= 17;
}

// Cached once found; until SpringBoardHome has registered it, nil is not kept.
static Class sbc_root_folder_class(void) {
    static Class cls = Nil;
    if (!cls) cls = objc_getClass("SBRootFolder");
    return cls;
}

static SBCGridSize sbc_root_list_grid(Class folderClass, SBCGridSize original, const char *source) {
    if (!sbc_is_ios17_or_newer() || !folderClass) return original;
    // Empty means "no special grid" (e.g. the widget-page variant on iPhone);
    // keep it empty so SpringBoard's early-outs stay intact.
    if (!original.columns || !original.rows) return original;
    Class rootFolderClass = sbc_root_folder_class();
    if (!rootFolderClass || ![folderClass isSubclassOfClass:rootFolderClass]) return original;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled") || !prefBool(p, @"homeGridEnabled")) return original;
    SBCGridSize grid = {
        (unsigned short)clampi((int)prefInt(p, @"hsCols"), 1, 10),
        (unsigned short)clampi((int)prefInt(p, @"hsRows"), 1, 10)
    };
    static uint32_t lastLogged = 0;
    uint32_t sig = ((uint32_t)grid.columns << 16) | grid.rows;
    if (sig != lastLogged) {
        lastLogged = sig;
        NSLog(@"[SBC:I18] %s root list grid %ux%u (stock %ux%u)", source,
              grid.columns, grid.rows, original.columns, original.rows);
    }
    return grid;
}

// Installed manually: only where the method exists and returns the
// two-unsigned-short grid struct, so a differently shaped SpringBoard is left
// alone instead of crashing.
static SBCGridSize (*sbc_orig_mgr_list_grid)(id, SEL, Class) = NULL;
static SBCGridSize (*sbc_orig_mgr_widget_list_grid)(id, SEL, Class) = NULL;
static SBCGridSize (*sbc_orig_model_list_grid)(id, SEL, Class) = NULL;

static SBCGridSize sbc_mgr_list_grid(id self, SEL _cmd, Class folderClass) {
    return sbc_root_list_grid(folderClass, sbc_orig_mgr_list_grid(self, _cmd, folderClass), "manager");
}
static SBCGridSize sbc_mgr_widget_list_grid(id self, SEL _cmd, Class folderClass) {
    return sbc_root_list_grid(folderClass, sbc_orig_mgr_widget_list_grid(self, _cmd, folderClass), "manager-widgets");
}
static SBCGridSize sbc_model_list_grid(id self, SEL _cmd, Class folderClass) {
    return sbc_root_list_grid(folderClass, sbc_orig_model_list_grid(self, _cmd, folderClass), "model");
}

static void sbc_hook_grid_getter(const char *className, const char *selName, IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    SEL sel = sel_registerName(selName);
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) { NSLog(@"[SBC:I18] -[%s %s] missing", className, selName); return; }
    char ret[64] = {0}, arg[16] = {0};
    method_getReturnType(m, ret, sizeof ret);
    method_getArgumentType(m, 2, arg, sizeof arg);
    if (!strstr(ret, "=SS}") || arg[0] != '#' || method_getNumberOfArguments(m) != 3) {
        NSLog(@"[SBC:I18] -[%s %s] unexpected signature %s", className, selName, method_getTypeEncoding(m));
        return;
    }
    MSHookMessageEx(cls, sel, replacement, original);
}

// ------------------------------------------ iOS 18: widget placement
//
// On iPhone, SpringBoardHome keeps widgets on 2x2 blocks ("quads"): a widget
// may only start on an even row and on a block column or the right edge. That
// matches the stock 4-column grid, but on a custom grid it leaves out rows and
// columns (with 5 columns a 2x2 widget could start at columns 1, 3 and 4 only).
// SpringBoardHome already has the iPad behaviour that places widgets freely;
// the hooks below turn it on for the Home Screen pages.

static BOOL sbc_list_is_root(id model) {
    if (![model respondsToSelector:@selector(folder)]) return NO;
    id folder = [model performSelector:@selector(folder)];
    Class rootFolderClass = sbc_root_folder_class();
    return folder && rootFolderClass && [folder isKindOfClass:rootFolderClass];
}

// The size class of the icons in a drag (the placeholder's), or nil.
static id sbc_drag_size_class(id dragManager, id dragID) {
    if (!dragID || ![dragManager respondsToSelector:@selector(iconDragContextForDragWithIdentifier:)]) return nil;
    id context = [dragManager performSelector:@selector(iconDragContextForDragWithIdentifier:) withObject:dragID];
    for (NSString *name in @[@"dragPlaceholderGridSizeClass", @"draggedIconGridSizeClass"]) {
        SEL sel = NSSelectorFromString(name);
        if (![context respondsToSelector:sel]) continue;
        id sizeClass = ((id (*)(id, SEL))objc_msgSend)(context, sel);
        if (sizeClass) return sizeClass;
    }
    return nil;
}

// Laying out a list, a saved widget position off the 2x2 blocks is discarded
// and the widget moved, unless the list's "icon layout behavior" has
// allowedOnAnyRow (1) and allowedOnAnyColumn (2). The root lists get both
// when the custom grid is on.
#define SBC_LAYOUT_ANY_ROW_AND_COLUMN 0x3ULL

// iOS 17's free icon placement ("Free Icon Placement" in the settings),
// independent of the custom grid. iOS 18 places icons freely by itself.
static BOOL sbc_free_icon_placement_enabled(void) {
    NSDictionary *p = sbc_prefs();
    return prefBool(p, @"enabled") && prefBool(p, @"freeIconPlacement");
}

// Widgets on any row and column of a custom grid. On iOS 17 this belongs to
// free icon placement, which it was tested with.
static BOOL sbc_free_widget_layout_enabled(void) {
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled") || !prefBool(p, @"homeGridEnabled")) return NO;
    return sbc_os_major() >= 18 ||
           prefBool(p, @"freeIconPlacement");
}

static unsigned long long (*sbc_orig_model_layout_behavior)(id, SEL, Class) = NULL;
static unsigned long long sbc_model_layout_behavior(id self, SEL _cmd, Class folderClass) {
    unsigned long long r = sbc_orig_model_layout_behavior(self, _cmd, folderClass);
    Class rootFolderClass = sbc_root_folder_class();
    if (folderClass && rootFolderClass && [folderClass isSubclassOfClass:rootFolderClass] &&
        sbc_free_widget_layout_enabled())
        r |= SBC_LAYOUT_ANY_ROW_AND_COLUMN;
    return r;
}

static unsigned long long (*sbc_orig_folder_layout_behavior)(id, SEL) = NULL;
static unsigned long long sbc_folder_layout_behavior(id self, SEL _cmd) {
    unsigned long long r = sbc_orig_folder_layout_behavior(self, _cmd);
    Class rootFolderClass = sbc_root_folder_class();
    if (rootFolderClass && [self isKindOfClass:rootFolderClass] && sbc_free_widget_layout_enabled())
        r |= SBC_LAYOUT_ANY_ROW_AND_COLUMN;
    return r;
}

static unsigned long long (*sbc_orig_list_layout_behavior)(id, SEL) = NULL;
static unsigned long long sbc_list_layout_behavior(id self, SEL _cmd) {
    unsigned long long r = sbc_orig_list_layout_behavior(self, _cmd);
    if (sbc_free_widget_layout_enabled() && sbc_list_is_root(self))
        r |= SBC_LAYOUT_ANY_ROW_AND_COLUMN;
    return r;
}

static void sbc_hook_layout_behavior(const char *className, const char *selName, unsigned int args,
                                     IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    SEL sel = sel_registerName(selName);
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    if (!enc || (enc[0] != 'Q' && enc[0] != 'q') || method_getNumberOfArguments(m) != args) {
        NSLog(@"[SBC:I18] -[%s %s] missing or unexpected (%s)", className, selName, enc);
        return;
    }
    MSHookMessageEx(cls, sel, replacement, original);
}

// While a widget is dragged, the drag manager turns the drag point into a
// placement in one of two ways. The iPhone way takes the cell under the
// widget's centre as its top-left cell, so with free rows and columns the
// widget hangs down and to the right of the finger. With
// prioritizesDirectIconPlacement (the iPad way) it places the widget's block
// of cells centred on the drag point instead. It is only turned on while a
// widget is dragged over a Home Screen page.
static __thread BOOL sbc_direct_placement = NO;

static BOOL sbc_widget_drag_on_root(id dragManager, id dragID, id listView) {
    if (!sbc_free_widget_layout_enabled() || !dragID) return NO;
    if (![listView respondsToSelector:@selector(iconLocation)]) return NO;
    NSString *location = [listView performSelector:@selector(iconLocation)];
    if (![location isKindOfClass:[NSString class]] || ![location hasPrefix:@"SBIconLocationRoot"]) return NO;
    id sizeClass = sbc_drag_size_class(dragManager, dragID);
    return sizeClass && ![[sizeClass description] containsString:@"Default"];
}

static BOOL (*sbc_orig_prioritizes_direct)(id, SEL) = NULL;
static BOOL sbc_prioritizes_direct(id self, SEL _cmd) {
    return sbc_orig_prioritizes_direct(self, _cmd) || sbc_direct_placement;
}

static void (*sbc_orig_update_placeholder)(id, SEL, id, id) = NULL;
static void sbc_update_placeholder(id self, SEL _cmd, id session, id listView) {
    id dragID = [self respondsToSelector:@selector(uniqueIdentifierForIconDropSession:)]
        ? [self performSelector:@selector(uniqueIdentifierForIconDropSession:) withObject:session] : nil;
    BOOL previous = sbc_direct_placement;
    sbc_direct_placement = sbc_widget_drag_on_root(self, dragID, listView);
    sbc_orig_update_placeholder(self, _cmd, session, listView);
    sbc_direct_placement = previous;
}

static BOOL (*sbc_orig_move_placeholder)(id, SEL, id, unsigned long long, id, id) = NULL;
static BOOL sbc_move_placeholder(id self, SEL _cmd, id icons, unsigned long long cell, id listView, id dragID) {
    BOOL previous = sbc_direct_placement;
    sbc_direct_placement = sbc_widget_drag_on_root(self, dragID, listView);
    BOOL r = sbc_orig_move_placeholder(self, _cmd, icons, cell, listView, dragID);
    sbc_direct_placement = previous;
    return r;
}

static void sbc_hook_checked(const char *className, const char *selName, const char *encoding,
                             IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    SEL sel = sel_registerName(selName);
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    const char *enc = m ? method_getTypeEncoding(m) : NULL;
    if (!enc || strcmp(enc, encoding) != 0) {
        NSLog(@"[SBC:I18] -[%s %s] missing or unexpected (%s)", className, selName, enc);
        return;
    }
    MSHookMessageEx(cls, sel, replacement, original);
}

static void sbc_install_direct_placement_hooks(void) {
    // All three or none: the getter alone would change every drag.
    if (!objc_getClass("SBIconDragManager")) return;
    Class cls = objc_getClass("SBIconDragManager");
    const char *updSel = "updatePlaceholderPositionForDropSession:inIconListView:";
    const char *movSel = "movePlaceholderForDraggedIcons:toGridCellIndex:inListView:forDragWithIdentifier:";
    Method upd = class_getInstanceMethod(cls, sel_registerName(updSel));
    Method mov = class_getInstanceMethod(cls, sel_registerName(movSel));
    Method get = class_getInstanceMethod(cls, sel_registerName("prioritizesDirectIconPlacement"));
    if (!upd || !mov || !get ||
        strcmp(method_getTypeEncoding(upd), "v32@0:8@16@24") != 0 ||
        strcmp(method_getTypeEncoding(mov), "B48@0:8@16Q24@32@40") != 0 ||
        strcmp(method_getTypeEncoding(get), "B16@0:8") != 0 ||
        ![cls instancesRespondToSelector:@selector(uniqueIdentifierForIconDropSession:)] ||
        ![cls instancesRespondToSelector:@selector(iconDragContextForDragWithIdentifier:)]) {
        NSLog(@"[SBC:I18] direct widget placement unavailable");
        return;
    }
    sbc_hook_checked("SBIconDragManager", "prioritizesDirectIconPlacement", "B16@0:8",
                     (IMP)sbc_prioritizes_direct, (IMP *)&sbc_orig_prioritizes_direct);
    sbc_hook_checked("SBIconDragManager", updSel, "v32@0:8@16@24",
                     (IMP)sbc_update_placeholder, (IMP *)&sbc_orig_update_placeholder);
    sbc_hook_checked("SBIconDragManager", movSel, "B48@0:8@16Q24@32@40",
                     (IMP)sbc_move_placeholder, (IMP *)&sbc_orig_move_placeholder);
}

// iOS 17 already contains the Home Screen "snap to grid" of iOS 18 (icons
// keep the cell they are dropped on, gaps allowed), switched off on iPhone:
// the drag manager asks its delegate whether snapping is allowed and whether
// a location can snap, and a drop only keeps its cell when the list's fixed
// icon location behavior says so. In iOS 17 that is 1 (keep the cell for
// snap-to-grid insertions; 2 always, 3 widgets only, and these two also
// require fixed positions). iOS 18 renumbered these and uses 4.
#define SBC_FIXED_LOCATIONS_ON_SNAP 1LL
#define SBC_FIXED_LOCATIONS_ALWAYS 2LL
#define SBC_FIXED_LOCATIONS_WIDGETS 3LL

// iPhone root lists have no fixed positions (0) and get 1. iPad root lists
// already keep fixed positions for widgets, required for rotation (3); they
// get 2, which keeps them for every icon and still requires them.
static long long sbc_free_fixed_behavior(long long behavior) {
    if (behavior == 0) return SBC_FIXED_LOCATIONS_ON_SNAP;
    if (behavior == SBC_FIXED_LOCATIONS_WIDGETS) return SBC_FIXED_LOCATIONS_ALWAYS;
    return behavior;
}

static long long (*sbc_orig_model_fixed_behavior)(id, SEL, Class) = NULL;
static long long sbc_model_fixed_behavior(id self, SEL _cmd, Class folderClass) {
    long long r = sbc_orig_model_fixed_behavior(self, _cmd, folderClass);
    Class rootFolderClass = sbc_root_folder_class();
    if (folderClass && rootFolderClass && [folderClass isSubclassOfClass:rootFolderClass] &&
        sbc_free_icon_placement_enabled())
        r = sbc_free_fixed_behavior(r);
    return r;
}

static long long (*sbc_orig_folder_fixed_behavior)(id, SEL) = NULL;
static long long sbc_folder_fixed_behavior(id self, SEL _cmd) {
    long long r = sbc_orig_folder_fixed_behavior(self, _cmd);
    Class rootFolderClass = sbc_root_folder_class();
    if (rootFolderClass && [self isKindOfClass:rootFolderClass] && sbc_free_icon_placement_enabled())
        r = sbc_free_fixed_behavior(r);
    return r;
}

static long long (*sbc_orig_list_fixed_behavior)(id, SEL) = NULL;
static long long sbc_list_fixed_behavior(id self, SEL _cmd) {
    long long r = sbc_orig_list_fixed_behavior(self, _cmd);
    if (sbc_free_icon_placement_enabled() && sbc_list_is_root(self))
        r = sbc_free_fixed_behavior(r);
    return r;
}

static BOOL (*sbc_orig_snap_allowed)(id, SEL) = NULL;
static BOOL sbc_snap_allowed(id self, SEL _cmd) {
    return sbc_orig_snap_allowed(self, _cmd) || sbc_free_icon_placement_enabled();
}

static BOOL (*sbc_orig_can_snap_in_location)(id, SEL, id) = NULL;
static BOOL sbc_can_snap_in_location(id self, SEL _cmd, id location) {
    if (sbc_orig_can_snap_in_location(self, _cmd, location)) return YES;
    return [location isKindOfClass:[NSString class]] && [location hasPrefix:@"SBIconLocationRoot"] &&
           sbc_free_icon_placement_enabled();
}

// iOS 17 only adds the snap-to-grid placeholder options (2: insert at a fixed
// cell, 4) when the dragged item has a non-default size class, i.e. for
// widgets; app icons are still placed by order. The placeholder's options
// get them for every drag on a Home Screen page.
#define SBC_PLACEHOLDER_SNAP_OPTIONS 0x6ULL

static unsigned long long (*sbc_orig_placeholder_options)(id, SEL) = NULL;
static unsigned long long sbc_placeholder_options(id self, SEL _cmd) {
    unsigned long long r = sbc_orig_placeholder_options(self, _cmd);
    if ((r & SBC_PLACEHOLDER_SNAP_OPTIONS) == SBC_PLACEHOLDER_SNAP_OPTIONS || !sbc_free_icon_placement_enabled())
        return r;
    id listView = [self respondsToSelector:@selector(listView)] ? [self performSelector:@selector(listView)] : nil;
    if (![listView respondsToSelector:@selector(iconLocation)]) return r;
    NSString *location = [listView performSelector:@selector(iconLocation)];
    if ([location isKindOfClass:[NSString class]] && [location hasPrefix:@"SBIconLocationRoot"])
        r |= SBC_PLACEHOLDER_SNAP_OPTIONS;
    return r;
}

static BOOL (*sbc_orig_context_snap_allowed)(id, SEL) = NULL;
static BOOL sbc_context_snap_allowed(id self, SEL _cmd) {
    return sbc_orig_context_snap_allowed(self, _cmd) || sbc_free_icon_placement_enabled();
}

// The drop, too, passes its snap-to-grid insertion options only for items
// with a non-default size class; an app icon is inserted with none and the
// page closes the gap again. While a drop onto a Home Screen page runs, the
// root folder insertion gets the options a snapped widget would.
#define SBC_SNAP_DROP_OPTIONS 0x302ULL
static __thread BOOL sbc_snap_drop = NO;

static void (*sbc_orig_snap_perform_drop)(id, SEL, id, id, id, id) = NULL;
static void sbc_snap_perform_drop(id self, SEL _cmd, id drop, id identifier, id iconIdentifiers, id listView) {
    BOOL previous = sbc_snap_drop;
    NSString *location = [listView respondsToSelector:@selector(iconLocation)]
        ? [listView performSelector:@selector(iconLocation)] : nil;
    sbc_snap_drop = [location isKindOfClass:[NSString class]] && [location hasPrefix:@"SBIconLocationRoot"] &&
                    sbc_free_icon_placement_enabled();
    sbc_orig_snap_perform_drop(self, _cmd, drop, identifier, iconIdentifiers, listView);
    sbc_snap_drop = previous;
}

static id (*sbc_orig_folder_insert_at_path)(id, SEL, id, id, unsigned long long) = NULL;
static id sbc_folder_insert_at_path(id self, SEL _cmd, id icon, id gridPath, unsigned long long options) {
    Class rootFolderClass = sbc_root_folder_class();
    if (sbc_snap_drop && rootFolderClass && [self isKindOfClass:rootFolderClass])
        options |= SBC_SNAP_DROP_OPTIONS;
    return sbc_orig_folder_insert_at_path(self, _cmd, icon, gridPath, options);
}

// With icons at fixed positions, moving an item makes the list relocate the
// fixed icons in the target range, looked up in the grid for the given
// options. On iOS 17 with a custom grid that grid can differ from the one the
// range was computed in, and SpringBoardHome then aborts on an assertion.
// Such a relocation is skipped instead.
typedef struct { unsigned long long start; SBCGridSize size; } SBCGridRange;
static id (*sbc_orig_relocate_fixed)(id, SEL, SBCGridRange, unsigned long long) = NULL;
static id sbc_relocate_fixed(id self, SEL _cmd, SBCGridRange range, unsigned long long options) {
    if (sbc_free_icon_placement_enabled() && [self respondsToSelector:@selector(gridCellInfoWithOptions:)]) {
        id info = ((id (*)(id, SEL, unsigned long long))objc_msgSend)(self, @selector(gridCellInfoWithOptions:), options);
        SBCGridSize grid = [info respondsToSelector:@selector(gridSize)]
            ? ((SBCGridSize (*)(id, SEL))objc_msgSend)(info, @selector(gridSize)) : (SBCGridSize){0, 0};
        BOOL fits = grid.columns && grid.rows && range.start < (unsigned long long)grid.columns * grid.rows &&
                    range.start % grid.columns + range.size.columns <= grid.columns &&
                    range.start / grid.columns + range.size.rows <= grid.rows;
        if (!fits) {
            NSLog(@"[SBC:I17] skipping fixed icon relocation for range %llu %ux%u in %ux%u grid",
                  range.start, range.size.columns, range.size.rows, grid.columns, grid.rows);
            return nil;
        }
    }
    return sbc_orig_relocate_fixed(self, _cmd, range, options);
}

static void sbc_install_ios17_snap_hooks(void) {
    Class cls = objc_getClass("SBIconDragManager");
    Method allowed = cls ? class_getInstanceMethod(cls, sel_registerName("isSnapToGridAllowed")) : NULL;
    Method inLocation = cls ? class_getInstanceMethod(cls, sel_registerName("canSnapToGridInIconLocation:")) : NULL;
    if (!allowed || !inLocation || strcmp(method_getTypeEncoding(allowed), "B16@0:8") != 0 ||
        strcmp(method_getTypeEncoding(inLocation), "B24@0:8@16") != 0) {
        NSLog(@"[SBC:I17] snap to grid unavailable");
        return;
    }
    sbc_hook_layout_behavior("SBHIconModel", "listsFixedIconLocationBehaviorForFolderClass:", 3,
                             (IMP)sbc_model_fixed_behavior, (IMP *)&sbc_orig_model_fixed_behavior);
    sbc_hook_layout_behavior("SBFolder", "listsFixedIconLocationBehavior", 2,
                             (IMP)sbc_folder_fixed_behavior, (IMP *)&sbc_orig_folder_fixed_behavior);
    sbc_hook_layout_behavior("SBIconListModel", "fixedIconLocationBehavior", 2,
                             (IMP)sbc_list_fixed_behavior, (IMP *)&sbc_orig_list_fixed_behavior);
    MSHookMessageEx(cls, sel_registerName("isSnapToGridAllowed"),
                    (IMP)sbc_snap_allowed, (IMP *)&sbc_orig_snap_allowed);
    MSHookMessageEx(cls, sel_registerName("canSnapToGridInIconLocation:"),
                    (IMP)sbc_can_snap_in_location, (IMP *)&sbc_orig_can_snap_in_location);
    sbc_hook_layout_behavior("SBIconListViewPlaceholderAssertion", "options", 2,
                             (IMP)sbc_placeholder_options, (IMP *)&sbc_orig_placeholder_options);
    // The drop asks the drag context, which keeps its own copy.
    Class contextCls = objc_getClass("SBIconDragContext");
    Method contextAllowed = contextCls ? class_getInstanceMethod(contextCls, sel_registerName("isSnapToGridAllowed")) : NULL;
    if (contextAllowed && strcmp(method_getTypeEncoding(contextAllowed), "B16@0:8") == 0)
        MSHookMessageEx(contextCls, sel_registerName("isSnapToGridAllowed"),
                        (IMP)sbc_context_snap_allowed, (IMP *)&sbc_orig_context_snap_allowed);
    else
        NSLog(@"[SBC:I17] drag context snap to grid unavailable");

    sbc_hook_checked("SBIconDragManager",
                     "predictable_performIconDrop:identifier:draggedIconIdentifiers:inIconListView:",
                     "v48@0:8@16@24@32@40",
                     (IMP)sbc_snap_perform_drop, (IMP *)&sbc_orig_snap_perform_drop);
    Class folderCls = objc_getClass("SBFolder");
    SEL insertSel = sel_registerName("insertIcon:atGridPath:options:");
    Method insert = folderCls ? class_getInstanceMethod(folderCls, insertSel) : NULL;
    char optionsType[8] = {0};
    if (insert) method_getArgumentType(insert, 4, optionsType, sizeof optionsType);
    if (insert && method_getTypeEncoding(insert)[0] == '@' && method_getNumberOfArguments(insert) == 5 &&
        (optionsType[0] == 'Q' || optionsType[0] == 'q'))
        MSHookMessageEx(folderCls, insertSel, (IMP)sbc_folder_insert_at_path, (IMP *)&sbc_orig_folder_insert_at_path);
    else
        NSLog(@"[SBC:I17] folder grid path insertion unavailable");

    sbc_hook_checked("SBIconListModel", "relocateFixedIconsInGridRange:gridCellInfoOptions:",
                     "@40@0:8{SBHIconGridRange=Q{SBHIconGridSize=SS}}16Q32",
                     (IMP)sbc_relocate_fixed, (IMP *)&sbc_orig_relocate_fixed);
}

static void sbc_install_home_layout_hooks(void) {
    NSInteger major = sbc_os_major();
    if (major < 17) return;
    // Free widget placement: iOS 17 and later.
    sbc_hook_layout_behavior("SBHIconModel", "listsIconLayoutBehaviorForFolderClass:", 3,
                             (IMP)sbc_model_layout_behavior, (IMP *)&sbc_orig_model_layout_behavior);
    sbc_hook_layout_behavior("SBFolder", "listsIconLayoutBehavior", 2,
                             (IMP)sbc_folder_layout_behavior, (IMP *)&sbc_orig_folder_layout_behavior);
    sbc_hook_layout_behavior("SBIconListModel", "iconLayoutBehavior", 2,
                             (IMP)sbc_list_layout_behavior, (IMP *)&sbc_orig_list_layout_behavior);
    if (major < 18)
        sbc_install_ios17_snap_hooks();
    else
        sbc_install_direct_placement_hooks();
    sbc_hook_grid_getter("SBHIconManager", "listGridSizeForFolderClass:",
                         (IMP)sbc_mgr_list_grid, (IMP *)&sbc_orig_mgr_list_grid);
    sbc_hook_grid_getter("SBHIconManager", "listWithNonDefaultSizedIconsGridSizeForFolderClass:",
                         (IMP)sbc_mgr_widget_list_grid, (IMP *)&sbc_orig_mgr_widget_list_grid);
    sbc_hook_grid_getter("SBHIconModel", "listGridSizeForFolderClass:",
                         (IMP)sbc_model_list_grid, (IMP *)&sbc_orig_model_list_grid);
}

// --------------------------------------------------- launch-time instant apply
//
// sbc_apply() runs a few seconds after launch (it needs the icon list views
// to exist for model grid patching), which is why the stock layout used to
// flash briefly after a respring. These hooks instead patch the layout
// configurations the moment SpringBoard first asks for them, so the very
// first layout pass already uses our values. Runtime changes still go
// through sbc_apply() via "Apply Now".

@interface SBHIconManager : NSObject
- (id)listLayoutProvider;
@end

@interface SBDockIconListView : UIView
@end

// Weak: remembers which configs/dock views were patched without keeping
// them alive after SpringBoard discards them.
static NSHashTable *sbc_patched_set(void) {
    static NSHashTable *set = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSHashTable weakObjectsHashTable]; });
    return set;
}

static void sbc_patch_root_config(id cfg) {
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return;

    int hsCols       = clampi((int)prefInt(p, @"hsCols"), 1, 10);
    int hsRows       = clampi((int)prefInt(p, @"hsRows"), 1, 10);
    double homeScale = prefDouble(p, @"homeScale");

    if (prefBool(p, @"homeGridEnabled") &&
        [cfg respondsToSelector:@selector(setNumberOfPortraitColumns:)]) {
        sbc_write_columns(cfg, (NSUInteger)hsCols);
        sbc_write_rows(cfg, (NSUInteger)hsRows);
    }
    if (prefBool(p, @"homeSpacingEnabled"))
        sbc_write_insets(cfg, sbc_home_insets(p, sbc_base_insets(cfg, sbc_stored_insets(cfg))));
    if (prefBool(p, @"homeScaleEnabled") &&
        homeScale > 0.0 && homeScale <= 2.0 &&
        [cfg respondsToSelector:@selector(setIconImageInfo:)] &&
        [cfg respondsToSelector:@selector(iconImageInfo)]) {
        // The getter hook records the native value before it is overwritten
        // and already returns it scaled.
        SBIconImageInfo info = [cfg iconImageInfo];
        sbc_writing_icon_info = YES;
        [cfg setIconImageInfo:info];
        sbc_writing_icon_info = NO;
    }
}

static void sbc_patch_dock_config(id dock) {
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return;

    int dockIcons    = clampi((int)prefInt(p, @"dockIcons"), 1, 8);
    double dockScale = prefDouble(p, @"dockScale");

    id cfg = dock_layout_config(dock);
    if (prefBool(p, @"dockLayoutEnabled"))
        sbc_write_columns(cfg, (NSUInteger)dockIcons);
    if (prefBool(p, @"dockSpacingEnabled"))
        sbc_write_insets(cfg, sbc_dock_insets(p, sbc_base_insets(cfg, sbc_stored_insets(cfg))));
    if (prefBool(p, @"dockScaleEnabled") &&
        dockScale > 0.0 && dockScale <= 2.0 &&
        [cfg respondsToSelector:@selector(setIconImageInfo:)] &&
        [cfg respondsToSelector:@selector(iconImageInfo)]) {
        SBIconImageInfo info = [cfg iconImageInfo];
        sbc_writing_icon_info = YES;
        [cfg setIconImageInfo:info];
        sbc_writing_icon_info = NO;
    }
    [dock setNeedsLayout];
}

%group SpringBoard
%hook SBHIconManager
- (id)listLayoutProvider {
    id provider = %orig;
    id layout = [provider respondsToSelector:@selector(layoutForIconLocation:)]
                ? [provider layoutForIconLocation:@"SBIconLocationRoot"] : nil;
    id cfg = [layout respondsToSelector:@selector(layoutConfiguration)] ? [layout layoutConfiguration] : nil;
    // Establish object identity before any setter/getter can trigger the
    // first layout pass. Previously this happened lazily from inside the
    // getters, so the first pass used stock spacing and icon geometry.
    if (cfg) sbc_root_cfg = cfg;
    id dockLayout = [provider respondsToSelector:@selector(layoutForIconLocation:)]
                    ? [provider layoutForIconLocation:@"SBIconLocationDock"] : nil;
    id dockCfg = [dockLayout respondsToSelector:@selector(layoutConfiguration)]
                 ? [dockLayout layoutConfiguration] : nil;
    if (dockCfg) sbc_set_dock_config(dockCfg);
    if (cfg && ![sbc_patched_set() containsObject:cfg]) {
        [sbc_patched_set() addObject:cfg];
        sbc_patch_root_config(cfg);
    }
    return provider;
}
%end
%end

%group SpringBoard
%hook SBDockIconListView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    id cfg = dock_layout_config(self);
    if (cfg) sbc_set_dock_config(cfg);
    if ([sbc_patched_set() containsObject:self]) return;
    [sbc_patched_set() addObject:self];
    sbc_patch_dock_config(self);
}
%end
%end

// ------------------------------------------------------------ App Library
//
// Integrated from the standalone NoAppLibrary tweak (itself a conversion of
// cyanide's darksword disable_app_library()). The App Library lives in the
// root folder controller's trailingCustomViewControllers; hooking the getter
// persistently beats the one-shot remote poke, which raced with SpringBoard
// repopulating the list on iOS 17.
//
// The *_live readers share sbc_prefs()'s cache, which the apply notification
// reloads after every change in the Settings pane, so a switch still applies
// without a respring. Every feature switch is gated by the master "enabled"
// switch; "enabled" itself is not.

static BOOL sbc_pref_bool_live(CFStringRef key) {
    NSDictionary *prefs = sbc_prefs();
    if (key != CFSTR("enabled") && !prefBool(prefs, @"enabled")) return NO;
    return prefBool(prefs, (__bridge NSString *)key);
}

static double sbc_pref_double_live(CFStringRef key) {
    return prefDouble(sbc_prefs(), (__bridge NSString *)key);
}

static BOOL sbc_hide_app_library(void) {
    BOOL hide = sbc_pref_bool_live(CFSTR("hideAppLibrary"));
    static BOOL logged = NO;
    if (!logged) { logged = YES; NSLog(@"[SBC:APPLIB] hideAppLibrary=%d", hide); }
    return hide;
}

// iOS 17.4+/18 back the App Library page with a PLURAL
// trailingCustomViewControllers array; iOS 15–17.3 use the SINGULAR
// trailingCustomViewController (and trailingCustomView on the view side).
// Hook both shapes — a hook on an absent class/method simply never fires.
// (SBHRootFolderController/SBHRootFolderView never existed; those class
// names were a wrong guess and are gone now.)
%group SpringBoard
%hook SBRootFolderController
- (NSArray *)trailingCustomViewControllers {
    return sbc_hide_app_library() ? @[] : %orig;
}
- (id)trailingCustomViewController {
    return sbc_hide_app_library() ? nil : %orig;
}
%end
%end

// Move the root Home Screen's combined page-dots/Search control without
// changing its layout-owned center. SpringBoard rewrites that center whenever
// the active page changes; a view transform survives those frame/center
// updates and also keeps the accessory's hit-testing in the visible position.
static char sbc_indicator_base_transform_key;
static char sbc_indicator_last_transform_key;
static char sbc_indicator_last_offset_key;

static void sbc_set_indicator_offset(UIView *indicator, CGPoint offset) {
    if (!indicator) return;
    CGAffineTransform current = indicator.transform;
    NSValue *baseValue = objc_getAssociatedObject(indicator,
                                                  &sbc_indicator_base_transform_key);
    NSValue *lastTransformValue = objc_getAssociatedObject(indicator,
                                                           &sbc_indicator_last_transform_key);
    NSValue *lastOffsetValue = objc_getAssociatedObject(indicator,
                                                        &sbc_indicator_last_offset_key);
    // Never moved and nothing to move: leave the view alone.
    if (!lastTransformValue && CGPointEqualToPoint(offset, CGPointZero)) return;

    BOOL replaced = lastTransformValue &&
        !CGAffineTransformEqualToTransform(current, [lastTransformValue CGAffineTransformValue]);
    // Both layout passes call this; when nothing changed since the last one
    // there is nothing to write.
    if (!replaced && lastOffsetValue &&
        CGPointEqualToPoint([lastOffsetValue CGPointValue], offset))
        return;

    CGAffineTransform base = baseValue ? [baseValue CGAffineTransformValue] : current;

    // If SpringBoard legitimately replaced the transform (rather than merely
    // laying out the center again), adopt that as the new stock transform.
    if (replaced) base = current;

    CGAffineTransform applied = CGAffineTransformTranslate(base, offset.x, offset.y);
    indicator.transform = applied;
    objc_setAssociatedObject(indicator, &sbc_indicator_base_transform_key,
                             [NSValue valueWithCGAffineTransform:base],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(indicator, &sbc_indicator_last_transform_key,
                             [NSValue valueWithCGAffineTransform:applied],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(indicator, &sbc_indicator_last_offset_key,
                             [NSValue valueWithCGPoint:offset],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void sbc_apply_root_indicator_offset(SBRootFolderView *rootView) {
    // On iOS 18 the Search pill and page dots live inside this accessory
    // container. Moving the inherited pageControl alone leaves the visible
    // pill and its hit target at the stock position, so prefer the accessory
    // and fall back to pageControl on versions that lack it.
    UIView *indicator = [rootView respondsToSelector:@selector(scrollAccessoryView)]
        ? (UIView *)[(id)rootView scrollAccessoryView] : nil;
    if (!indicator && [rootView respondsToSelector:@selector(pageControl)])
        indicator = (UIView *)[(id)rootView pageControl];
    if (!indicator) return;

    NSDictionary *p = sbc_prefs();
    CGPoint offset = CGPointZero;
    if (prefBool(p, @"enabled") &&
        prefBool(p, @"pageIndicatorPositionEnabled")) {
        BOOL landscape = CGRectGetWidth(rootView.bounds) > CGRectGetHeight(rootView.bounds);
        offset.x = prefDouble(p, landscape ? @"pageIndicatorXLandscape" : @"pageIndicatorX");
        offset.y = prefDouble(p, landscape ? @"pageIndicatorYLandscape" : @"pageIndicatorY");
    }
    sbc_set_indicator_offset(indicator, offset);
}

%group SpringBoard
%hook SBRootFolderView
- (NSArray *)trailingCustomViewControllers {
    return sbc_hide_app_library() ? @[] : %orig;
}
- (id)trailingCustomView {
    return sbc_hide_app_library() ? nil : %orig;
}
// Belt and braces: force the page count even if a trailing VC was already
// installed before the hooks were loaded (iOS 15/16).
- (NSUInteger)_trailingCustomPageCount {
    return sbc_hide_app_library() ? 0 : %orig;
}
- (void)layoutSubviews {
    %orig;
    sbc_apply_root_indicator_offset(self);
}
- (void)_layoutSubviews {
    %orig;
    sbc_apply_root_indicator_offset(self);
}
%end
%end

// Absent on some versions — the hook then simply never fires.
%group SpringBoard
%hook SBIconController
- (BOOL)isAppLibrarySupported {
    return sbc_hide_app_library() ? NO : %orig;
}
- (BOOL)isAppLibraryAllowed {
    return sbc_hide_app_library() ? NO : %orig;
}
- (NSUInteger)maxIconCountForDock {
    NSUInteger original = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled") ||
        !prefBool(p, @"dockLayoutEnabled"))
        return original;
    // Return the configured count rather than MAX(original, configured). The
    // range now goes below the stock four, and a floor of four would let the
    // dock hold more icons than the grid has slots for.
    return (NSUInteger)clampi((int)prefInt(p, @"dockIcons"), 1, 8);
}
%end
%end

// iPad: also remove the App Library button from the floating dock.
%group SpringBoard
%hook SBFloatingDockDefaults
- (BOOL)appLibraryEnabled {
    return sbc_hide_app_library() ? NO : %orig;
}
%end
%end

// Belt and braces for state captured before the hooks were installed: clear
// the ivars directly, like the original disable_app_library() did. Plural on
// iOS 17.4+/18, singular on iOS 15–17.3.
static void sbc_poke_trailing(id obj) {
    if (!obj) return;
    Ivar iv = class_getInstanceVariable([obj class], "_trailingCustomViewControllers");
    if (iv) {
        object_setIvar(obj, iv, [NSArray array]);
        NSLog(@"[SBC:APPLIB] cleared _trailingCustomViewControllers on %@", object_getClass(obj));
    }
    Ivar ivSingular = class_getInstanceVariable([obj class], "_trailingCustomViewController");
    if (ivSingular) {
        object_setIvar(obj, ivSingular, nil);
        NSLog(@"[SBC:APPLIB] cleared _trailingCustomViewController on %@", object_getClass(obj));
    }
}

// -------------------------------------------------------- Double-tap to lock
//
// Integrated from the standalone DoubleTapLock tweak (itself a conversion of
// darksword_tweak_double_tap_to_lock_in_session() from cyanide). The two
// behavioral details are kept:
//  1. Home screen: a recognizer on the full root-folder view. A gesture
//     delegate rejects touches on icons, folders, the dock and controls.
//  2. Lock screen: recognizer on the cover sheet root view (the full-screen
//     container), not on CSMainPageContentViewController's view — on iPad the
//     main page content is a centered column, so edge taps never reached a
//     recognizer attached there and double-tap only worked mid-screen.
// Each area has its own switch (dtlHomeScreen / dtlLockScreen), read live.
// Recognizers are installed when the views appear, so switching one on takes
// a respring; switching it off applies at once, because the delegate then
// refuses to let the gesture begin.

@interface CSCoverSheetViewController : UIViewController
@end

static char kDTLockGestureKey;
static char kDTHomeGestureKey;

static UITapGestureRecognizer *dtl_makeRecognizer(void) {
    UITapGestureRecognizer *gr = [[UITapGestureRecognizer alloc]
        initWithTarget:[%c(SpringBoard) sharedApplication]
                action:@selector(_simulateLockButtonPress)];
    gr.numberOfTapsRequired = 2;
    gr.cancelsTouchesInView = NO;
    gr.delaysTouchesBegan = NO;
    return gr;
}

@interface SBTHomeDoubleTapDelegate : NSObject <UIGestureRecognizerDelegate>
@end

@interface SBTLockDoubleTapDelegate : NSObject <UIGestureRecognizerDelegate>
@end

static BOOL sbt_view_contains_visible_passcode_ui(UIView *view) {
    if (!view || view.hidden || view.alpha < 0.01) return NO;
    NSString *name = NSStringFromClass([view class]);
    if ([name localizedCaseInsensitiveContainsString:@"Passcode"] ||
        [name localizedCaseInsensitiveContainsString:@"NumberPad"] ||
        [name localizedCaseInsensitiveContainsString:@"Keypad"])
        return YES;
    for (UIView *subview in view.subviews) {
        if (sbt_view_contains_visible_passcode_ui(subview)) return YES;
    }
    return NO;
}

@implementation SBTLockDoubleTapDelegate
// Reject the gesture everywhere while passcode authentication is on screen,
// including empty areas outside the keypad itself. This walks the whole
// window, so it runs once per recognized double-tap rather than per touch.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (!sbc_pref_bool_live(CFSTR("dtlLockScreen"))) return NO;
    UIView *root = gestureRecognizer.view;
    return !sbt_view_contains_visible_passcode_ui(root.window ?: root);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    UIView *root = gestureRecognizer.view;
    for (UIView *view = touch.view; view && view != root; view = view.superview) {
        if ([view isKindOfClass:[UIControl class]]) return NO;
        NSString *name = NSStringFromClass([view class]);
        if ([name localizedCaseInsensitiveContainsString:@"Passcode"] ||
            [name localizedCaseInsensitiveContainsString:@"NumberPad"] ||
            [name localizedCaseInsensitiveContainsString:@"Keypad"])
            return NO;
    }
    return YES;
}
@end

@implementation SBTHomeDoubleTapDelegate
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    return sbc_pref_bool_live(CFSTR("dtlHomeScreen"));
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    Class iconViewClass = %c(SBIconView);
    Class dockViewClass = %c(SBDockIconListView);
    UIView *root = gestureRecognizer.view;

    for (UIView *view = touch.view; view && view != root; view = view.superview) {
        if ([view isKindOfClass:[UIControl class]]) return NO;
        if (iconViewClass && [view isKindOfClass:iconViewClass]) return NO;
        if (dockViewClass && [view isKindOfClass:dockViewClass]) return NO;

        NSString *name = NSStringFromClass([view class]);
        if ([name containsString:@"Dock"] || [name containsString:@"FolderIcon"])
            return NO;
    }
    return YES;
}
@end

static SBTHomeDoubleTapDelegate *sbt_home_double_tap_delegate(void) {
    static SBTHomeDoubleTapDelegate *delegate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        delegate = [SBTHomeDoubleTapDelegate new];
    });
    return delegate;
}

static SBTLockDoubleTapDelegate *sbt_lock_double_tap_delegate(void) {
    static SBTLockDoubleTapDelegate *delegate = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        delegate = [SBTLockDoubleTapDelegate new];
    });
    return delegate;
}

static void (*sbt_orig_root_did_move_to_window)(id, SEL) = NULL;

static void sbt_root_did_move_to_window(id self, SEL _cmd) {
    if (sbt_orig_root_did_move_to_window)
        sbt_orig_root_did_move_to_window(self, _cmd);
    if (![self window]) return;
    // Apply once when the real root view enters a window; persistent getter
    // hooks handle subsequent App Library queries without timer retries.
    if (sbc_hide_app_library()) sbc_poke_trailing(self);
    if (!sbc_pref_bool_live(CFSTR("dtlHomeScreen"))) return;
    if (objc_getAssociatedObject(self, &kDTHomeGestureKey)) return;

    UITapGestureRecognizer *recognizer = dtl_makeRecognizer();
    recognizer.delegate = sbt_home_double_tap_delegate();
    [self addGestureRecognizer:recognizer];
    objc_setAssociatedObject(self, &kDTHomeGestureKey, recognizer,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void sbt_install_home_double_tap_hook(void) {
    Class cls = objc_getClass("SBRootFolderView");
    SEL selector = @selector(didMoveToWindow);
    if (!cls || !class_getInstanceMethod(cls, selector)) return;
    MSHookMessageEx(cls, selector, (IMP)sbt_root_did_move_to_window,
                    (IMP *)&sbt_orig_root_did_move_to_window);
}

%group SpringBoard
%hook CSCoverSheetViewController
- (void)viewDidLoad {
    %orig;
    // Guard against the Logos superclass pitfall: if CSCoverSheetViewController
    // does not override viewDidLoad itself, Substrate hooks UIViewController's
    // implementation and this would run for every view controller in
    // SpringBoard (attaching a lock recognizer to each view — a likely
    // watchdog/hang source). Only proceed for actual cover sheet instances.
    if (![self isKindOfClass:%c(CSCoverSheetViewController)]) return;
    if (!sbc_pref_bool_live(CFSTR("dtlLockScreen"))) return;
    UIView *v = self.view;
    if (!v) return;
    if (objc_getAssociatedObject(v, &kDTLockGestureKey)) return;

    UITapGestureRecognizer *gr = dtl_makeRecognizer();
    gr.delegate = sbt_lock_double_tap_delegate();
    [v addGestureRecognizer:gr];
    objc_setAssociatedObject(v, &kDTLockGestureKey, gr, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end
%end

// --------------------------------------------------- UIAnimationDragCoefficient
//
// Ported from the standalone FastAnimations tweak (itself converted from the
// darksword remote-write PoC): in-process, remote_read/remote_write become
// direct memory access. iOS 17: SetUIAnimationDragCoefficient is ungated — it
// just stores a float into a UIKitCore global; we disassemble the function to
// locate that global and write the coefficient directly. A stock value (1.0)
// is never written, so this cannot clobber another tweak's override unless a
// non-stock value is configured here.

typedef struct {
    uint64_t g, revVar, revOnce;
    uint32_t valOff, revOff;
    bool gated, isFloat;
} drag_t;

static uint64_t strip_fp(void *p)
{
    uint64_t v = (uint64_t)p;
#if defined(__arm64e__)
    // PAC only exists on arm64e; plain arm64 pointers are never signed.
    if (v >> 47) {
#if defined(__has_builtin) && __has_builtin(__builtin_ptrauth_strip)
        v = (uint64_t)__builtin_ptrauth_strip((void *)v, 0);
#else
        __asm__ volatile("xpaci %0" : "+r"(v));
#endif
    }
#endif
    return v;
}

static bool find_drag(drag_t *o)
{
    void *fp = dlsym(RTLD_DEFAULT, "_SetUIAnimationDragCoefficient");
    if (!fp) {
        void *h = dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_LAZY);
        if (h) fp = dlsym(h, "_SetUIAnimationDragCoefficient");
        if (!fp) { NSLog(@"[SBT:DRAG] dlsym failed"); return false; }
    }
    uint64_t pc = strip_fp(fp);
    const uint32_t *c = (const uint32_t *)pc;
    for (int i = 0; i < 4; i++)
        if ((c[i] & 0xfc000000) == 0x14000000) {
            pc += (uint64_t)i*4 + (int64_t)((int32_t)(c[i]<<6)>>4);
            c = (const uint32_t *)pc; break;
        }

    uint64_t pg[32]={0}, pv[32]={0}, g=0, rV=0, rO=0;
    uint32_t vOff=0, rOff=0;
    bool isFloat = false;

    for (int i = 0; i < 80; i++) {
        uint32_t in=c[i]; int rd=in&31, rn=(in>>5)&31;
        uint64_t ipc=pc+(uint64_t)i*4;
        if (in==0xd65f03c0 || in==0xd65f0bff || in==0xd65f0fff) break;

        if ((in&0x9f000000)==0x90000000) {                          // ADRP
            int64_t lo=(in>>29)&3, hi=(in>>5)&0x7ffff;
            int64_t off=((hi<<2)|lo)<<12; off=(off<<31)>>31;
            pg[rd]=(ipc&~0xfffULL)+off; pv[rd]=0;
        } else if ((in&0xff800000)==0x91000000 && pg[rn]) {         // ADD imm
            pv[rd]=pg[rn]+((in>>10)&0xfff);
        } else if ((in&0xffc00000)==0xf9400000 && pg[rn] && !rO) {
            rO = pg[rn] + (((in>>10)&0xfff)<<3);
        } else if ((in&0xffc00000)==0xb9400000 && pg[rn] && !rV) {
            rV = pg[rn] + (((in>>10)&0xfff)<<2);
        } else if ((in&0xff800000)==0xfd000000 && !g) {              // STR Dt -> double (iOS 18+)
            uint64_t base = pv[rn] ? pv[rn] : pg[rn];
            if (base) {
                g=base; vOff=((in>>10)&0xfff)<<3; isFloat=false;
            }
        } else if ((in&0xffc00000)==0xbd000000 && !g) {              // STR St -> float (iOS 17)
            uint64_t base = pv[rn] ? pv[rn] : pg[rn];
            if (base) {
                g=base; vOff=((in>>10)&0xfff)<<2; isFloat=true;
            }
        } else if ((in&0xff800000)==0xb9000000 && g && pv[rn]==g) {
            rOff = ((in>>10)&0xfff)<<2;
            break;
        }
    }

    if (!g) { NSLog(@"[SBT:DRAG] FAIL: no STR Dt/St matched"); return false; }
    bool gated = (rV && rO && (rO == rV + 8 || rV == rO + 8));
    o->g=g; o->revVar=rV; o->revOnce=rO;
    o->valOff = (gated && !vOff) ? 8 : vOff;
    o->revOff = rOff; o->gated = gated; o->isFloat = isFloat;
    NSLog(@"[SBT:DRAG] find_drag: g=0x%llx vOff=0x%x gated=%d isFloat=%d",
          (unsigned long long)g, o->valOff, gated, isFloat);
    return true;
}

static void override_drag_coefficient(double v)
{
    // The location never moves within a process, so the disassembly runs once.
    static drag_t d;
    static bool found = false;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ found = find_drag(&d); });
    if (!found) { NSLog(@"[SBT:DRAG] find_drag failed"); return; }

    if (d.gated) {                                  // iOS 18+/26: rev + sentinel + double
        uint32_t *revVar = (uint32_t *)d.revVar;
        if ((int)*revVar < 1) *revVar = 1;
        *(uint32_t *)(d.g + d.revOff) = 0x7fffffff;
        *(double *)(d.g + d.valOff) = v;
        NSLog(@"[SBT:DRAG] gated g=0x%llx value=%.4f",
              (unsigned long long)d.g, *(double *)(d.g + d.valOff));
    } else if (d.isFloat) {                         // iOS 17: 32-bit float, no gating
        *(float *)(d.g + d.valOff) = (float)v;
        NSLog(@"[SBT:DRAG] f32 g=0x%llx+0x%x value=%.4f",
              (unsigned long long)d.g, d.valOff,
              (double)*(float *)(d.g + d.valOff));
    } else {                                        // ungated double (theoretical)
        *(double *)(d.g + d.valOff) = v;
        NSLog(@"[SBT:DRAG] f64 g=0x%llx+0x%x value=%.4f",
              (unsigned long long)d.g, d.valOff,
              *(double *)(d.g + d.valOff));
    }
}

// Whether the global currently holds a value written here. Switching the
// option off (or back to 1.0) then writes the stock value back once; a
// global this tweak never touched is still left alone.
static BOOL sbc_drag_overridden = NO;

static void sbc_apply_drag_coefficient(void) {
    NSDictionary *p = sbc_prefs();
    double v = sbc_pref_double_live(CFSTR("dragCoefficient"));
    BOOL custom = prefBool(p, @"enabled") && prefBool(p, @"dragCoefficientEnabled") &&
                  v >= 0.01 && v <= 2.0 && fabs(v - 1.0) >= 1e-9;
    if (custom) {
        override_drag_coefficient(v);
        sbc_drag_overridden = YES;
    } else if (sbc_drag_overridden) {
        override_drag_coefficient(1.0);
        sbc_drag_overridden = NO;
    }
}

// Adding a widget runs SpringBoard animations that UIKit's coefficient scales
// alongside steps with their own timing; with a small coefficient they get out
// of step and the page's icons stay invisible for seconds. Switching back to
// the configured coefficient while that flow still runs (2-3 s, well past the
// widget sheet's disappearance) does the same, and there is no callback for
// its end, and switching back while an app is in front breaks it just the
// same (the Home Screen comes back with only the new widget). So the stock
// coefficient is restored when a widget is chosen and the configured one
// re-applied once the flow is over (3 s) and the Home Screen has left edit
// mode or an app is in front, and after 60 s at the latest.
static BOOL sbc_drag_suspended = NO;
static CFAbsoluteTime sbc_drag_suspended_at = 0;
static dispatch_source_t sbc_drag_poll = NULL;

static void sbc_end_drag_suspension(void) {
    if (!sbc_drag_suspended) return;
    sbc_drag_suspended = NO;
    if (sbc_drag_poll) { dispatch_source_cancel(sbc_drag_poll); sbc_drag_poll = NULL; }
    sbc_apply_drag_coefficient();
}

static BOOL sbc_app_in_foreground(void) {
    id app = [UIApplication sharedApplication];
    SEL sel = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    return [app respondsToSelector:sel] && ((id (*)(id, SEL))objc_msgSend)(app, sel) != nil;
}

static BOOL sbc_home_screen_editing(void) {
    id iconCtrl = [%c(SBIconController) sharedInstance];
    id mgr = [iconCtrl respondsToSelector:@selector(iconManager)] ? [iconCtrl iconManager] : nil;
    return [mgr respondsToSelector:@selector(isEditing)] && ((BOOL (*)(id, SEL))objc_msgSend)(mgr, @selector(isEditing));
}

static void sbc_check_drag_suspension(void) {
    if (!sbc_drag_suspended) return;
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - sbc_drag_suspended_at;
    if (elapsed >= 60.0 || (elapsed >= 3.0 && (sbc_app_in_foreground() || !sbc_home_screen_editing())))
        sbc_end_drag_suspension();
}

static void sbc_suspend_drag_coefficient(void) {
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled") || !prefBool(p, @"dragCoefficientEnabled")) return;
    double v = sbc_pref_double_live(CFSTR("dragCoefficient"));
    if (v < 0.01 || v > 2.0 || fabs(v - 1.0) < 1e-9) return;
    sbc_drag_suspended = YES;
    sbc_drag_suspended_at = CFAbsoluteTimeGetCurrent();
    override_drag_coefficient(1.0);
    if (!sbc_drag_poll) {
        sbc_drag_poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(sbc_drag_poll, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                                  250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(sbc_drag_poll, ^{ sbc_check_drag_suspension(); });
        dispatch_resume(sbc_drag_poll);
    }
}

static void (*sbc_orig_root_add_widget)(id, SEL, id, id) = NULL;
static void sbc_root_add_widget(id self, SEL _cmd, id sheet, id iconView) {
    sbc_suspend_drag_coefficient();
    sbc_orig_root_add_widget(self, _cmd, sheet, iconView);
}

static void (*sbc_orig_pad_add_widget)(id, SEL, id, id) = NULL;
static void sbc_pad_add_widget(id self, SEL _cmd, id sheet, id iconView) {
    sbc_suspend_drag_coefficient();
    sbc_orig_pad_add_widget(self, _cmd, sheet, iconView);
}

// Hooks a class's own implementation only, so a subclass is not hooked twice.
static void sbc_hook_own(const char *className, const char *selName, const char *encoding,
                         IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    SEL sel = sel_registerName(selName);
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m || strcmp(method_getTypeEncoding(m), encoding) != 0) return;
    BOOL own = NO;
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    for (unsigned int j = 0; j < count; j++) if (list[j] == m) own = YES;
    free(list);
    if (own) MSHookMessageEx(cls, sel, replacement, original);
}

static void sbc_install_add_widget_hooks(void) {
    const char *chosen = "addWidgetSheetViewController:didSelectWidgetIconView:";
    sbc_hook_own("SBRootFolderController", chosen, "v32@0:8@16@24",
                 (IMP)sbc_root_add_widget, (IMP *)&sbc_orig_root_add_widget);
    sbc_hook_own("SBHPadAddSheetViewController", chosen, "v32@0:8@16@24",
                 (IMP)sbc_pad_add_widget, (IMP *)&sbc_orig_pad_add_widget);
}

// ------------------------------------------------ wake/sleep & icon fly-in
//
// Simplified after Speedster (github.com/Hoangdus/Speedster): plain getter
// hooks instead of poking the settings object's ivars.
//
// iOS 17 reality (confirmed on-device):
//   sleep (screen off) is governed by the backlight fade duration alone.
//   wake  (screen on)  is gated by the fade duration AND the animation
//   speed — the speed alone does nothing while the fade ramp is non-zero.
// The fade duration is one setting shared by both transitions, so each
// switch has to know which transition is running:
//   wake:  fade 0 + speed kSBTWakeSpeed   iff noWakeAnim
//   sleep: fade 0                         iff noSleepFade
// WakeExact hooks the class methods that are handed isWake; WakeLegacy, for
// versions without them, remembers the flag from the last settings fetch.
// Read live, so the toggles are instant.

static BOOL sbt_transition_is_wake = YES;
static const double kSBTWakeSpeed = 10.0;

// Preferred path: both of these class methods are handed isWake directly, so
// which transition is in flight is never in doubt.
//
// +backlightFadeDurationForSource:isWake: is the only consumer of
// backlightFadeDuration in SpringBoard. It computes
//     [rootSettings backlightFadeDuration] / _animationSpeedFor...
// reading the settings getter itself rather than going through
// -_animationSettingsForBacklightChangeSource:isWake:. That is why the shared
// sbt_transition_is_wake flag below is unreliable: on a wake the fade can be
// asked for before the settings call has flipped the flag, so the getter
// answers from the sleep branch and hands back the stock fade instead of 0.
// Ordering decides it, which makes the fault intermittent.
%group WakeExact
%hook SBScreenWakeAnimationController
+ (double)backlightFadeDurationForSource:(long long)source isWake:(BOOL)wake {
    BOOL off = sbc_pref_bool_live(wake ? CFSTR("noWakeAnim") : CFSTR("noSleepFade"));
#if SBT_WAKE_TRACE
    double stock = %orig;
    SBT_TRACE("+fade %s src=%lld stock=%.3f -> %.3f", wake ? "wake" : "sleep", source,
              stock, off ? 0.0 : stock);
    return off ? 0 : stock;
#else
    if (off) return 0;
    return %orig;
#endif
}

+ (double)_animationSpeedForBacklightChangeSource:(long long)source isWake:(BOOL)wake {
    // One value instead of two multiplied together. See kSBTWakeSpeed.
    BOOL fast = wake && sbc_pref_bool_live(CFSTR("noWakeAnim"));
#if SBT_WAKE_TRACE
    double stock = %orig;
    SBT_TRACE("+speed %s src=%lld stock=%.3f -> %.3f", wake ? "wake" : "sleep", source,
              stock, fast ? kSBTWakeSpeed : stock);
    return fast ? kSBTWakeSpeed : stock;
#else
    if (fast) return kSBTWakeSpeed;
    return %orig;
#endif
}
%end
%end


// Fallback for versions without those class methods: the instance getter plus
// a flag remembered from the last transition.
%group WakeLegacy
%hook SBScreenWakeAnimationController
- (id)_animationSettingsForBacklightChangeSource:(long long)source isWake:(BOOL)wake {
    SBT_TRACE("-settings %s src=%lld (legacy flag was %s)", wake ? "wake" : "sleep", source,
              sbt_transition_is_wake ? "wake" : "sleep");
#if SBT_WAKE_TRACE
    if (wake) sbt_trace_schedule_snapshots();
#endif
    sbt_transition_is_wake = wake;
    return %orig(source, wake);
}

- (double)backlightFadeDuration {
    SBT_TRACE("-controller fade, flag=%s", sbt_transition_is_wake ? "wake" : "sleep");
    if (sbt_transition_is_wake)
        return sbc_pref_bool_live(CFSTR("noWakeAnim")) ? 0 : %orig;
    return sbc_pref_bool_live(CFSTR("noSleepFade")) ? 0 : %orig;
}
%end
%end

%group WakeLegacy
%hook SBFWakeAnimationSettings
- (double)backlightFadeDuration {
    SBT_TRACE("-settings fade, flag=%s", sbt_transition_is_wake ? "wake" : "sleep");
    if (sbt_transition_is_wake)
        return sbc_pref_bool_live(CFSTR("noWakeAnim")) ? 0 : %orig;
    return sbc_pref_bool_live(CFSTR("noSleepFade")) ? 0 : %orig;
}
// +[SBScreenWakeAnimationController _animationSpeedForBacklightChangeSource:
// isWake:] takes speedMultiplierForLiftToWake for a lift-to-wake source and
// then MULTIPLIES it by speedMultiplierForWake. Returning a large value from
// both therefore compounded: 1000 x 1000 = 1000000.
//
// That matters because the wake sequence hides the Lock Screen views
// (_setRelevantLockScreenViewsHidden:) and unhides them from the animation's
// completion. At an absurd speed the completion is mishandled and the clock
// stays hidden for seconds -- seen on iPadOS 15. A modest speed still makes a
// ~0.5s animation imperceptible (0.05s) while staying inside the range
// SpringBoard is written for, and the lift multiplier is left neutral so the
// two can no longer compound.
- (double)speedMultiplierForWake {
    SBT_TRACE("-speedMultiplierForWake");
    return sbc_pref_bool_live(CFSTR("noWakeAnim")) ? kSBTWakeSpeed : %orig;
}
- (double)speedMultiplierForLiftToWake {
    SBT_TRACE("-speedMultiplierForLiftToWake");
    return sbc_pref_bool_live(CFSTR("noWakeAnim")) ? 1.0 : %orig;
}
%end
%end

#if SBT_WAKE_TRACE
// The Lock Screen views (clock, date) are hidden while the screen wakes and
// shown again from the animation's completion. Which class does that, and
// under which name, differs between versions, so the trace build looks in
// SpringBoard's, CoverSheet's and SpringBoardFoundation's own classes for
// one-BOOL methods that hide or show Lock Screen, date or clock views, and
// logs every call.
//
// The clock view itself (any UIView class with "DateView" in its name, e.g.
// SBFLockScreenDateView) additionally logs being hidden, faded, put into a
// window and removed. After every wake its effective visibility is sampled
// for a few seconds, naming the view or ancestor that hides it, if any.
static NSMutableArray<Class> *sbt_trace_date_view_classes;

static NSHashTable *sbt_trace_date_views(void) {
    static NSHashTable *views;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ views = [NSHashTable weakObjectsHashTable]; });
    return views;
}

static BOOL sbt_trace_selector_matches(const char *name) {
    if (!strstr(name, "Hidden") && !strstr(name, "Visible")) return NO;
    return strstr(name, "LockScreen") || strstr(name, "DateView") || strstr(name, "Clock");
}

static Method sbt_trace_own_method(Class cls, SEL sel) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method found = NULL;
    for (unsigned int i = 0; i < count && !found; i++)
        if (method_getName(methods[i]) == sel) found = methods[i];
    free(methods);
    return found;
}

// Wraps `sel` on `cls` itself: its own implementation, or an added override
// calling the superclass's when the method is only inherited.
static void sbt_trace_wrap(Class cls, SEL sel, const char *types, id (^make)(IMP (^next)(void))) {
    Method own = sbt_trace_own_method(cls, sel);
    if (own) {
        IMP orig = method_getImplementation(own);
        method_setImplementation(own, imp_implementationWithBlock(make(^IMP { return orig; })));
    } else {
        Class superclass = class_getSuperclass(cls);
        class_addMethod(cls, sel, imp_implementationWithBlock(make(^IMP {
            return class_getMethodImplementation(superclass, sel);
        })), types);
    }
}

static void sbt_trace_date_view_class(Class cls) {
    NSString *name = NSStringFromClass(cls);
    sbt_trace_wrap(cls, @selector(setHidden:), "v20@0:8B16", ^id(IMP (^next)(void)) {
        return ^(UIView *me, BOOL value) {
            [sbt_trace_date_views() addObject:me];
            if (value != me.hidden) SBT_TRACE("%@ %p setHidden:%d", name, me, value);
            ((void (*)(id, SEL, BOOL))next())(me, @selector(setHidden:), value);
        };
    });
    sbt_trace_wrap(cls, @selector(setAlpha:), "v24@0:8d16", ^id(IMP (^next)(void)) {
        return ^(UIView *me, CGFloat value) {
            [sbt_trace_date_views() addObject:me];
            if (fabs(value - me.alpha) > 0.001)
                SBT_TRACE("%@ %p setAlpha:%.2f (was %.2f)", name, me, value, me.alpha);
            ((void (*)(id, SEL, CGFloat))next())(me, @selector(setAlpha:), value);
        };
    });
    sbt_trace_wrap(cls, @selector(didMoveToWindow), "v16@0:8", ^id(IMP (^next)(void)) {
        return ^(UIView *me) {
            [sbt_trace_date_views() addObject:me];
            ((void (*)(id, SEL))next())(me, @selector(didMoveToWindow));
            SBT_TRACE("%@ %p %s window", name, me, me.window ? "entered" : "left");
        };
    });
    sbt_trace_wrap(cls, @selector(removeFromSuperview), "v16@0:8", ^id(IMP (^next)(void)) {
        return ^(UIView *me) {
            SBT_TRACE("%@ %p removeFromSuperview", name, me);
            ((void (*)(id, SEL))next())(me, @selector(removeFromSuperview));
        };
    });
    SBT_TRACE("tracing clock view class %@", name);
}

static void sbt_trace_scan_image(const char *image, NSMutableArray<Class> *dateViewClasses) {
    unsigned int classCount = 0;
    const char **names = objc_copyClassNamesForImage(image, &classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = objc_getClass(names[i]);
        if (!cls) continue;
        if (strstr(names[i], "DateView") && [cls isSubclassOfClass:[UIView class]])
            [dateViewClasses addObject:cls];
        for (int meta = 0; meta < 2; meta++) {
            Class target = meta ? object_getClass(cls) : cls;
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(target, &methodCount);
            for (unsigned int j = 0; j < methodCount; j++) {
                SEL sel = method_getName(methods[j]);
                const char *selName = sel_getName(sel);
                // UIView's own setters are traced per clock view class instead.
                if (sel == @selector(setHidden:) || !sbt_trace_selector_matches(selName)) continue;
                const char *enc = method_getTypeEncoding(methods[j]);
                NSString *label = [NSString stringWithFormat:@"%c[%s %s]",
                                   meta ? '+' : '-', names[i], selName];
                if (!enc || (strcmp(enc, "v20@0:8B16") != 0 && strcmp(enc, "v20@0:8c16") != 0)) {
                    SBT_TRACE("seen %@ (%s), not traced", label, enc ?: "?");
                    continue;
                }
                IMP orig = method_getImplementation(methods[j]);
                method_setImplementation(methods[j], imp_implementationWithBlock(^(id me, BOOL value) {
                    SBT_TRACE("%@ %s", label, value ? "YES" : "NO");
                    ((void (*)(id, SEL, BOOL))orig)(me, sel, value);
                }));
                SBT_TRACE("tracing %@", label);
            }
            free(methods);
        }
    }
    free(names);
}

static void sbt_trace_collect_date_views(UIView *view, NSMutableSet *found) {
    for (Class cls in sbt_trace_date_view_classes)
        if ([view isKindOfClass:cls]) { [found addObject:view]; break; }
    for (UIView *subview in view.subviews) sbt_trace_collect_date_views(subview, found);
}

// Hidden, transparent, or shown transparent by a running animation: the
// view itself or the first ancestor that keeps it from being seen.
static NSString *sbt_trace_view_state(UIView *view) {
    NSString *blocker = nil;
    for (UIView *v = view; v && !blocker; v = v.superview) {
        CALayer *shown = v.layer.presentationLayer ?: v.layer;
        if (v.hidden) blocker = @"hidden";
        else if (v.alpha < 0.01) blocker = @"alpha 0";
        else if (shown.opacity < 0.01) blocker = @"animating at opacity 0";
        if (blocker) blocker = [NSString stringWithFormat:@"%@ %p %@", NSStringFromClass([v class]), v, blocker];
    }
    CALayer *shown = view.layer.presentationLayer ?: view.layer;
    return [NSString stringWithFormat:@"%@ %p hidden=%d alpha=%.2f shown=%.2f window=%d -> %@",
            NSStringFromClass([view class]), view, view.hidden, view.alpha, shown.opacity,
            view.window != nil, blocker ? [@"blocked by " stringByAppendingString:blocker] : @"visible"];
}

static void sbt_trace_snapshot(NSString *when) {
    NSMutableSet *views = [NSMutableSet setWithArray:sbt_trace_date_views().allObjects];
    // Every window, SpringBoard's internal ones included; scene windows as a
    // fallback where the private class method is missing.
    NSArray *windows = nil;
    SEL all = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
    if ([UIWindow respondsToSelector:all])
        windows = ((NSArray *(*)(id, SEL, BOOL, BOOL))objc_msgSend)([UIWindow class], all, YES, NO);
    if (!windows) {
        NSMutableArray *sceneWindows = [NSMutableArray array];
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes)
            if ([scene isKindOfClass:[UIWindowScene class]])
                [sceneWindows addObjectsFromArray:((UIWindowScene *)scene).windows];
        windows = sceneWindows;
    }
    for (UIWindow *window in windows) sbt_trace_collect_date_views(window, views);
    if (!views.count) { SBT_TRACE("clock %@: no clock view found", when); return; }
    for (UIView *view in views) {
        if (!view.window) continue;
        SBT_TRACE("clock %@: %@", when, sbt_trace_view_state(view));
    }
}

static void sbt_trace_schedule_snapshots(void) {
    for (NSNumber *delay in @[@0.1, @0.3, @0.6, @1, @2, @3, @5, @8]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sbt_trace_snapshot([NSString stringWithFormat:@"+%.1fs", delay.doubleValue]);
        });
    }
}

// Which transition SpringBoard sets up, alongside the exact hooks (the
// legacy group hooks this method itself).
static id (*sbt_trace_orig_settings)(id, SEL, long long, BOOL) = NULL;
static id sbt_trace_settings(id self, SEL _cmd, long long source, BOOL wake) {
    SBT_TRACE("-settings %s src=%lld", wake ? "wake" : "sleep", source);
    if (wake) sbt_trace_schedule_snapshots();
    return sbt_trace_orig_settings(self, _cmd, source, wake);
}

static void sbt_trace_install_settings_hook(void) {
    Class cls = objc_getClass("SBScreenWakeAnimationController");
    SEL sel = @selector(_animationSettingsForBacklightChangeSource:isWake:);
    if (cls && class_getInstanceMethod(cls, sel))
        MSHookMessageEx(cls, sel, (IMP)sbt_trace_settings, (IMP *)&sbt_trace_orig_settings);
}

static void sbt_trace_install_view_hooks(void) {
    NSMutableSet *images = [NSMutableSet set];
    for (NSString *name in @[@"SBScreenWakeAnimationController", @"CSCoverSheetViewController",
                             @"SBFLockScreenDateView", @"SBFWakeAnimationSettings"]) {
        Class cls = NSClassFromString(name);
        const char *image = cls ? class_getImageName(cls) : NULL;
        if (image) [images addObject:@(image)];
    }
    NSMutableArray<Class> *dateViewClasses = [NSMutableArray array];
    for (NSString *image in images) sbt_trace_scan_image(image.UTF8String, dateViewClasses);

    // A subclass calls into its traced superclass, so only the topmost
    // clock view classes are wrapped; snapshots still find every subclass.
    sbt_trace_date_view_classes = dateViewClasses;
    for (Class cls in dateViewClasses) {
        BOOL nested = NO;
        for (Class other in dateViewClasses)
            if (other != cls && [cls isSubclassOfClass:other]) nested = YES;
        if (!nested) sbt_trace_date_view_class(cls);
    }
    if (!dateViewClasses.count) SBT_TRACE("no clock view class found");
}
#endif

%group SpringBoard
%hook CSCoverSheetTransitionSettings
- (void)setIconsFlyIn:(bool)arg1 {
    %orig(sbc_pref_bool_live(CFSTR("noIconsFlyIn")) ? NO : arg1);
}
%end
%end

// Set in %ctor; the filter also injects into every UIKit app process.
static BOOL sbt_is_springboard = NO;

// ------------------------------------------------ settings for app processes
//
// Sandboxed processes — Messages, WhatsApp, Safari, the Spotlight UI — cannot
// read this tweak's preferences domain, so a setting read there silently
// reads as off. SpringBoard therefore publishes everything app-side hooks
// need as the 64-bit state of one Darwin notification, which any process may
// read. It is republished at launch and on every change from the Settings
// pane, so app-side switches apply without a respring.
//   bit 0        Fast Copy
//   bit 1        Dismiss Spotlight after opening a result
//   bit 3        Fast Page Transitions
//   bit 4        Fast Sheets
//   bits 16-31   Fast Page Transitions duration in ms
//   bits 32-47   Fast Sheets duration in ms

static const char *const kSBTAppStateName = "cz.kolbi.sbtweaker/appState";
#define SBT_APP_FAST_COPY          (1ULL << 0)
#define SBT_APP_DISMISS_SPOTLIGHT  (1ULL << 1)
#define SBT_APP_PAGE_TRANSITIONS   (1ULL << 3)
#define SBT_APP_SHEETS             (1ULL << 4)
#define SBT_APP_SLIDE_SHIFT        16
#define SBT_APP_SHEETS_SHIFT       32
static const double kNSMinDuration = 0.01, kNSMaxDuration = 1.0;

static int sbt_app_state_token(void) {
    static int token = NOTIFY_TOKEN_INVALID;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (notify_register_check(kSBTAppStateName, &token) != NOTIFY_STATUS_OK)
            token = NOTIFY_TOKEN_INVALID;
    });
    return token;
}

// 0 (everything off) when the state cannot be read.
static uint64_t sbt_app_state(void) {
    int token = sbt_app_state_token();
    uint64_t state = 0;
    if (token == NOTIFY_TOKEN_INVALID ||
        notify_get_state(token, &state) != NOTIFY_STATUS_OK) return 0;
    return state;
}

// Same value, cached so the hooks never make a notify round-trip. Refreshed on
// the main queue whenever SpringBoard republishes (and at once in SpringBoard
// itself, which publishes it).
static uint64_t sbt_cached_app_state = 0;

static void sbt_watch_app_state(void) {
    sbt_cached_app_state = sbt_app_state();
    int watchToken;
    notify_register_dispatch(kSBTAppStateName, &watchToken, dispatch_get_main_queue(), ^(int t) {
        sbt_cached_app_state = sbt_app_state();
    });
}

// SpringBoard only.
static void sbt_publish_app_state(void) {
    int token = sbt_app_state_token();
    if (token == NOTIFY_TOKEN_INVALID) return;
    uint64_t state = 0;
    if (sbc_pref_bool_live(CFSTR("fastCopy"))) state |= SBT_APP_FAST_COPY;
    if (sbc_pref_bool_live(CFSTR("dismissSpotlightAfterResult"))) state |= SBT_APP_DISMISS_SPOTLIGHT;
    if (sbc_pref_bool_live(CFSTR("noSlide"))) state |= SBT_APP_PAGE_TRANSITIONS;
    if (sbc_pref_bool_live(CFSTR("fastSheets"))) state |= SBT_APP_SHEETS;
    double slide = MIN(kNSMaxDuration, MAX(kNSMinDuration, sbc_pref_double_live(CFSTR("noSlideDuration"))));
    // Until the Settings pane has migrated it, the key is missing; keep the
    // shared duration it used to have rather than the 0.01 default.
    double sheets = sbc_prefs()[@"fastSheetsDuration"]
        ? MIN(kNSMaxDuration, MAX(kNSMinDuration, sbc_pref_double_live(CFSTR("fastSheetsDuration"))))
        : slide;
    state |= (uint64_t)llround(slide * 1000.0) << SBT_APP_SLIDE_SHIFT;
    state |= (uint64_t)llround(sheets * 1000.0) << SBT_APP_SHEETS_SHIFT;
    notify_set_state(token, state);
    sbt_cached_app_state = state;
    notify_post(kSBTAppStateName);
}

// Fast Copy: show the copy/paste callout bar immediately instead of after
// UIKit's built-in delay (its appear/disappear animation is removed by the
// CALayer hook below). Inspired by the classic Fast Copy tweak. Fires in
// SpringBoard and every app; the switch comes from the published app state.
%group FastCopy
%hook UITextSelectionView
- (void)showCalloutBarAfterDelay:(double)arg1 {
    %orig((sbt_cached_app_state & SBT_APP_FAST_COPY) ? 0 : arg1);
}
%end
%end

// ------------------------------------------------ fast page transitions
//
// Removes (or shortens) the push/pop slide inside apps: opening a
// conversation in Messages or WhatsApp, a post in Reddit, a settings row.
// Modal sheets, full-screen effects and every other animation keep their
// stock timing; a swipe-back is never touched.
//
// Forcing animated:NO on push/pop breaks apps (Reddit lost its back controls)
// because they rely on the animated code path: transition coordinator,
// viewWillAppear: with animated=YES, alongside animations. Instead the
// transition runs exactly as stock and the Core Animation animations added
// while it is set up are sped up to fit the configured duration.
//
// The duration comes from the published app state (see above), read at each
// push/pop, so changes apply without a respring.

// Target duration in seconds when `feature` is on, otherwise 0 (also when the
// state cannot be read, in which case nothing changes).
static double ns_durationFor(uint64_t feature) {
    uint64_t state = sbt_cached_app_state;
    if (!(state & feature)) return 0;
    uint64_t ms = (state >> SBT_APP_SLIDE_SHIFT) & 0xFFFF;
    // A state published before Fast Sheets had its own duration leaves its
    // bits empty; it then shares the page transition one as it used to.
    uint64_t sheetsMs = (state >> SBT_APP_SHEETS_SHIFT) & 0xFFFF;
    if (feature == SBT_APP_SHEETS && sheetsMs) ms = sheetsMs;
    if (ms == 0) return 0;
    return MIN(kNSMaxDuration, MAX(kNSMinDuration, ms / 1000.0));
}

static double ns_targetDuration(void) {
    return ns_durationFor(SBT_APP_PAGE_TRANSITIONS);
}

static BOOL ns_clamping = NO;
static double ns_clampDuration = 0;
static NSUInteger ns_clampToken = 0;

static BOOL ns_clampable(CAAnimation *anim) {
    // Only plain finite timing animations (and groups of them). Anything
    // else — iOS 26 Liquid Glass "match" animations (infinite by design),
    // emitters, repeating spinners — is left alone; speeding those up breaks
    // controls.
    if (![anim isKindOfClass:[CABasicAnimation class]] &&
        ![anim isKindOfClass:[CAKeyframeAnimation class]] &&
        ![anim isKindOfClass:[CAAnimationGroup class]]) return NO;
    if (!isfinite(anim.duration) || anim.duration > 2.0 || anim.speed <= 0) return NO;
    if (anim.repeatCount > 0 || anim.repeatDuration > 0 || anim.autoreverses) return NO;
    return YES;
}

static void ns_clampAnimation(CAAnimation *anim, CFTimeInterval target) {
    if (!ns_clampable(anim)) return;
    // Speed the animation up to fit instead of cutting it short, so a spring
    // still settles naturally at longer configured durations.
    // A duration of 0 means Core Animation's default of 0.25 s, not instant;
    // those used to be skipped and ran at full length.
    CFTimeInterval duration = anim.duration > 0 ? anim.duration : 0.25;
    CFTimeInterval active = duration / anim.speed;
    if (active > target) anim.speed = (float)(duration / target);
    // Drop delays too. A delayed animation (e.g. a navigation bar fade that
    // starts a little after the slide) otherwise shows its from-state until
    // the delay runs out — a one-frame flash once everything else is quick.
    // Delays inside a group are scaled by the group's speed already.
    if (anim.beginTime > 0) anim.beginTime = 0;
    if (anim.timeOffset != 0) anim.timeOffset = 0;
}

// Fast Copy, part two: the copy/paste menu also appears and disappears
// without its fade/zoom. Rather than hooking the presentation methods, which
// differ per iOS version, any animation added to a layer inside the menu's
// own views is made instant: UICalloutBar (iOS 15), _UIEditMenuContainerView
// and _UIEditMenuListView (iOS 16+).
static BOOL sbt_layer_in_edit_menu(CALayer *layer) {
    static Class classes[3];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        classes[0] = objc_getClass("UICalloutBar");
        classes[1] = objc_getClass("_UIEditMenuContainerView");
        classes[2] = objc_getClass("_UIEditMenuListView");
    });
    int depth = 0;
    for (CALayer *l = layer; l && depth < 12; l = l.superlayer, depth++) {
        id view = l.delegate;
        if (![view isKindOfClass:[UIView class]]) continue;
        for (int i = 0; i < 3; i++)
            if (classes[i] && [view isKindOfClass:classes[i]]) return YES;
    }
    return NO;
}

static const CFTimeInterval kSBTMenuDuration = 0.01;

// One hook for both features; installed in SpringBoard and apps.
%group Layer
%hook CALayer
- (void)addAnimation:(CAAnimation *)anim forKey:(NSString *)key {
    // Never mutate the caller's animation. Apps re-add animations read back
    // with animationForKey:, which are read-only, and Core Animation refuses
    // property changes on an animation it already owns: the setter throws an
    // uncaught ObjC exception that aborts the host process (Signal, WhatsApp,
    // the App Store, PingID; Spotify from -[CALayer _display]).
    //
    // A fresh copy is always mutable, and addAnimation:forKey: copies the
    // animation itself, so no caller can depend on this object's identity.
    // The @try is belt and braces: this runs in every app, and a throw here
    // kills that app rather than just losing the optimisation.
    if (anim && [NSThread isMainThread]) {
        CFTimeInterval target = 0;
        if (ns_clamping)
            target = ns_clampDuration;
        else if ((sbt_cached_app_state & SBT_APP_FAST_COPY) && sbt_layer_in_edit_menu(self))
            target = kSBTMenuDuration;
        if (target > 0 && ns_clampable(anim)) {
            @try {
                CAAnimation *mutable_ = [anim copy];
                if (mutable_) {
                    ns_clampAnimation(mutable_, target);
                    anim = mutable_;
                }
            } @catch (__unused NSException *e) {
                static dispatch_once_t once;
                dispatch_once(&once, ^{
                    NSLog(@"[SBT:LAYER] animation refused mutation, left untouched");
                });
            }
        }
    }
    %orig(anim, key);
}
%end
%end

%group NoSlide

static NSUInteger ns_startClamp(double duration) {
    ns_clamping = YES;
    ns_clampDuration = duration;
    return ++ns_clampToken;
}

static void ns_endClamp(NSUInteger token) {
    if (ns_clampToken == token) ns_clamping = NO;
}

// Called when a transition's animator actually runs. A swipe-back is
// interactive and is never touched, so it tracks the finger and can still be
// cancelled — that also cancels a window opened by the push/pop hooks.
// Otherwise clamping stays on at least for the rest of this run-loop turn,
// which covers the whole synchronous transition setup.
static void ns_beginClamp(id<UIViewControllerContextTransitioning> ctx) {
    if (!ctx) return;
    if ([ctx isInteractive]) { ns_clamping = NO; ns_clampToken++; return; }
    if (ns_clamping) return;
    double d = ns_targetDuration();
    if (d <= 0) return;
    NSUInteger token = ns_startClamp(d);
    dispatch_async(dispatch_get_main_queue(), ^{ ns_endClamp(token); });
}

static BOOL ns_gestureActive(UIGestureRecognizer *gr) {
    UIGestureRecognizerState st = gr.state;
    return st == UIGestureRecognizerStateBegan || st == UIGestureRecognizerStateChanged;
}

// App-agnostic window: from an animated push/pop until the navigation
// controller's transition completes. This catches transitions whose animator
// can't be hooked — WhatsApp returns its own animator through a forwarding
// delegate proxy. UIKit starts the transition a layout pass after push/pop
// returns, so a single run-loop turn would be too short here.
static void ns_clampNavTransition(UINavigationController *nc) {
    if (ns_gestureActive(nc.interactivePopGestureRecognizer)) return;
    id<UIViewControllerTransitionCoordinator> tc = nc.transitionCoordinator;
    if (!tc || !tc.isAnimated || tc.isInteractive) return;
    double d = ns_targetDuration();
    if (d <= 0) return;
    NSUInteger token = ns_startClamp(d);
    [tc animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> c) {
        ns_endClamp(token);
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((d + 1.0) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ns_endClamp(token); });
}

static char kNSDecidedKey;

// The first time UIKit consults the stock transition decides.
static void ns_decide(id transition, id<UIViewControllerContextTransitioning> ctx) {
    if (objc_getAssociatedObject(transition, &kNSDecidedKey)) return;
    objc_setAssociatedObject(transition, &kNSDecidedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ns_beginClamp(ctx);
}

static NSTimeInterval ns_cappedDuration(NSTimeInterval d, id<UIViewControllerContextTransitioning> ctx) {
    if (!ctx || [ctx isInteractive]) return d;
    double target = ns_targetDuration();
    return target > 0 ? MIN(d, target) : d;
}

// ------------------------- app-provided transitions behind a real delegate
//
// Animator classes are only known at runtime, so they are hooked as they
// show up: first the navigation delegate's class, then every animator class
// it returns. Each replacement is a block that captures the exact original
// IMP of the class it was installed on, so subclass/superclass pairs that
// both get hooked and call super never recurse into each other.

static NSMutableSet<NSValue *> *ns_hooked;

static Class ns_definingClass(Class cls, SEL sel) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        unsigned int n = 0;
        Method *list = class_copyMethodList(c, &n);
        BOOL found = NO;
        for (unsigned int i = 0; i < n && !found; i++)
            found = method_getName(list[i]) == sel;
        free(list);
        if (found) return c;
    }
    return Nil;
}

static void ns_hookOnce(Class cls, SEL sel, id (^makeBlock)(IMP orig)) {
    Class def = ns_definingClass(cls, sel);
    if (!def || def == objc_getClass("_UINavigationParallaxTransition")) return;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)def];
    @synchronized (ns_hooked) {
        if ([ns_hooked containsObject:key]) return;
        [ns_hooked addObject:key];
    }
    Method m = class_getInstanceMethod(def, sel);
    method_setImplementation(m, imp_implementationWithBlock(makeBlock(method_getImplementation(m))));
}

static void ns_hookAnimatorClass(Class cls) {
    ns_hookOnce(cls, @selector(animateTransition:), ^id(IMP orig) {
        return ^(id me, id<UIViewControllerContextTransitioning> ctx) {
            ns_beginClamp(ctx);
            ((void (*)(id, SEL, id))orig)(me, @selector(animateTransition:), ctx);
        };
    });
    ns_hookOnce(cls, @selector(interruptibleAnimatorForTransition:), ^id(IMP orig) {
        return ^id(id me, id<UIViewControllerContextTransitioning> ctx) {
            ns_beginClamp(ctx);
            return ((id (*)(id, SEL, id))orig)(me, @selector(interruptibleAnimatorForTransition:), ctx);
        };
    });
    ns_hookOnce(cls, @selector(transitionDuration:), ^id(IMP orig) {
        return ^NSTimeInterval(id me, id<UIViewControllerContextTransitioning> ctx) {
            return ns_cappedDuration(((NSTimeInterval (*)(id, SEL, id))orig)(me, @selector(transitionDuration:), ctx), ctx);
        };
    });
}

static void ns_hookNavigationDelegateClass(Class cls) {
    SEL sel = @selector(navigationController:animationControllerForOperation:fromViewController:toViewController:);
    ns_hookOnce(cls, sel, ^id(IMP orig) {
        return ^id(id me, UINavigationController *nc, UINavigationControllerOperation op,
                   UIViewController *from, UIViewController *to) {
            id animator = ((id (*)(id, SEL, id, UINavigationControllerOperation, id, id))orig)(me, sel, nc, op, from, to);
            if (animator) ns_hookAnimatorClass(object_getClass(animator));
            return animator;
        };
    });
}

%hook UINavigationController
- (void)setDelegate:(id<UINavigationControllerDelegate>)delegate {
    %orig;
    if (delegate) ns_hookNavigationDelegateClass(object_getClass(delegate));
}
- (void)pushViewController:(UIViewController *)vc animated:(BOOL)animated {
    %orig;
    if (animated) ns_clampNavTransition(self);
}
- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    UIViewController *r = %orig;
    if (animated) ns_clampNavTransition(self);
    return r;
}
- (NSArray *)popToViewController:(UIViewController *)vc animated:(BOOL)animated {
    NSArray *r = %orig;
    if (animated) ns_clampNavTransition(self);
    return r;
}
- (NSArray *)popToRootViewControllerAnimated:(BOOL)animated {
    NSArray *r = %orig;
    if (animated) ns_clampNavTransition(self);
    return r;
}
- (void)setViewControllers:(NSArray *)vcs animated:(BOOL)animated {
    %orig;
    if (animated) ns_clampNavTransition(self);
}
%end

// UIKit's stock push/pop animator. iOS 15-17 size the slide and the
// navigation bar animation from transitionDuration:.
%hook _UINavigationParallaxTransition
- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)ctx {
    NSTimeInterval original = %orig;
    return ns_cappedDuration(original, ctx);
}
- (void)animateTransition:(id<UIViewControllerContextTransitioning>)ctx {
    ns_decide(self, ctx);
    %orig;
}
- (id<UIViewImplicitlyAnimating>)interruptibleAnimatorForTransition:(id<UIViewControllerContextTransitioning>)ctx {
    ns_decide(self, ctx);
    return %orig;
}
- (void)animationEnded:(BOOL)completed {
    objc_setAssociatedObject(self, &kNSDecidedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}
%end

// ------------------------------------------------ fast sheets
//
// Modal presentations — the share sheet and the AirDrop page it opens,
// compose screens, alerts, full-screen modals — slide up and down through
// presentViewController:/dismissViewControllerAnimated:. The same clamp window
// as a page transition covers them: from the call until UIKit runs the
// completion (3 s at most, which also spans the wait while iOS starts the
// share sheet process). Swipe-to-dismiss is interactive and never goes through
// dismissViewControllerAnimated:, so it is untouched.

static void (^ns_clampedCompletion(void (^completion)(void)))(void) {
    double d = ns_durationFor(SBT_APP_SHEETS);
    if (d <= 0) return nil;
    NSUInteger token = ns_startClamp(d);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ ns_endClamp(token); });
    return ^{
        ns_endClamp(token);
        if (completion) completion();
    };
}

%hook UIViewController
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion {
    // UIKit refuses (without calling completion) while this controller is
    // already presenting something that is not on its way out.
    UIViewController *current = self.presentedViewController;
    BOOL willPresent = vc && (!current || current.isBeingDismissed);
    void (^wrapped)(void) = (animated && willPresent) ? ns_clampedCompletion(completion) : nil;
    %orig(vc, animated, wrapped ?: completion);
}

- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    // Only when there is something to dismiss: presented by us, or presented.
    BOOL willDismiss = self.presentedViewController || self.presentingViewController;
    void (^wrapped)(void) = (animated && willDismiss) ? ns_clampedCompletion(completion) : nil;
    %orig(animated, wrapped ?: completion);
}
%end

%end // NoSlide

// ------------------------------------------------ lock screen idle timeout
//
// The Lock Screen's dim-then-sleep countdown is not one constant. SpringBoard
// picks an enum bucket from whatever is on screen — 6s is the usual "reading
// notifications" one — maps that to seconds, and then floors every lock-screen
// descriptor through -[SBIdleTimerDescriptorFactory
// sanitizeDescriptorForLockscreenDefaults:] with minimumLockscreenIdleTime.
//
// Raising that floor therefore covers every state from a single getter: before
// and after Face ID, with notifications up, with Siri. It is re-read whenever
// the descriptor is rebuilt, so a change applies on the next lock rather than
// needing a respring. The getter itself tail-calls a block ivar, which %orig
// still evaluates when the option is off.
//
// Settings > Display & Brightness > Auto-Lock remains a ceiling over the whole
// thing: this cannot hold the screen on longer than Auto-Lock allows.

%group SpringBoard
%hook SBIdleTimerGlobalStateMonitor
- (double)minimumLockscreenIdleTime {
    SBT_TRACE("-minimumLockscreenIdleTime (lockScreenDurationEnabled=%d)",
              sbc_pref_bool_live(CFSTR("lockScreenDurationEnabled")));
    if (!sbc_pref_bool_live(CFSTR("lockScreenDurationEnabled"))) return %orig;
    double seconds = sbc_pref_double_live(CFSTR("lockScreenDuration"));
    return seconds > 0.0 ? seconds : %orig;
}
%end
%end

// -------------------------------- dismiss Spotlight after opening a result
//
// Tapping a Spotlight result launches the app, but SpringBoard leaves the
// search presented underneath it, so leaving that app reveals Spotlight again
// instead of the Home Screen. The typed query survives as well: Spotlight only
// clears its search field once its own clear timer has expired (eight minutes
// after the previous dismissal), so a quick return still shows the old text.
//
// Four narrow hooks, each a no-op where the class or method is absent:
//  - SBMainWorkspace: an app transition began while search was on screen, so
//    take the search down right there, while the app still covers the screen.
//  - SBHomeScreenReturnToSpotlightPolicy: the iPad/Mac "spotlight breadcrumbs"
//    path re-presents Spotlight when the Home Screen returns; refuse it.
//  - SPUISearchViewController, twice: clear the query on dismissal, and treat
//    the eight-minute clear timer as already expired when search is presented.
//    These two run in the Spotlight UI process (com.apple.Spotlight), which
//    the UIKit bundle filter already covers, because the search field lives
//    there rather than in SpringBoard.

// Read from the published app state: half of these hooks run in the
// sandboxed Spotlight UI process, which cannot read the preferences domain.
static BOOL sbt_dismiss_spotlight_enabled(void) {
    return (sbt_cached_app_state & SBT_APP_DISMISS_SPOTLIGHT) != 0;
}

static BOOL sbt_spotlight_is_on_screen(void) {
    id ctrl = [%c(SBIconController) sharedInstance];
    if (!ctrl) return NO;
    id mgr = [ctrl respondsToSelector:@selector(iconManager)] ? [ctrl iconManager] : nil;
    if ([mgr respondsToSelector:@selector(isShowingSpotlightOrLeadingCustomView)])
        return [mgr isShowingSpotlightOrLeadingCustomView];
    // iOS 17 and older name on the controller; gone on iOS 26.
    if ([ctrl respondsToSelector:@selector(isAnySearchVisibleOrTransitioning)])
        return [ctrl isAnySearchVisibleOrTransitioning];
    return NO;
}

static void sbt_dismiss_spotlight(void) {
    id ctrl = [%c(SBIconController) sharedInstance];
    if (!ctrl) return;
    id mgr = [ctrl respondsToSelector:@selector(iconManager)] ? [ctrl iconManager] : nil;
    if ([mgr respondsToSelector:@selector(dismissSpotlightAnimated:completionHandler:)]) {
        [mgr dismissSpotlightAnimated:NO completionHandler:nil];
        return;
    }
    id root = [ctrl respondsToSelector:@selector(rootFolderController)]
        ? [ctrl rootFolderController] : nil;
    if ([root respondsToSelector:@selector(dismissSpotlightAnimated:completionHandler:)]) {
        [root dismissSpotlightAnimated:NO completionHandler:nil];
        return;
    }
    if ([ctrl respondsToSelector:@selector(dismissSearchView)])
        [ctrl dismissSearchView];
}

%group SpringBoard
%hook SBMainWorkspace
- (void)_executeApplicationTransitionRequest:(id)request {
    // Every app transition that matters runs through here: launching the
    // result, and coming back out of that app afterwards. Both start with the
    // screen still covered by the app being raised or lowered, so this is the
    // one moment where taking the search down cannot be seen.
    //
    // The dismissal has to be synchronous. Deferring it — to the owning
    // transaction's completion, or to a timer — puts it after the return
    // animation has already uncovered the Home Screen, and Spotlight is then
    // visibly sitting there with its results until the dismissal lands.
    BOOL searchOnScreen = sbt_dismiss_spotlight_enabled() &&
                          sbt_spotlight_is_on_screen();
    if (searchOnScreen) sbt_dismiss_spotlight();
    %orig;
    if (!searchOnScreen) return;
    // SpringBoard refuses the dismissal outright while it is still putting
    // the transition together, so try once more on the next turn of the run
    // loop — still inside the frame that commits the transition.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sbt_dismiss_spotlight_enabled() && sbt_spotlight_is_on_screen())
            sbt_dismiss_spotlight();
    });
}
%end
%end

%group SpringBoard
%hook SBHomeScreenReturnToSpotlightPolicy
- (BOOL)willReactivateSpotlight {
    return sbt_dismiss_spotlight_enabled() ? NO : %orig;
}
%end
%end

%group Spotlight
%hook SPUISearchViewController
- (BOOL)clearQueryOnDismissal {
    return sbt_dismiss_spotlight_enabled() ? YES : %orig;
}

// Consulted from searchViewWillPresentFromSource:. Stock Spotlight only lets
// the field go once eight minutes have passed since the last dismissal, so
// swiping straight back down still shows the previous query and its results.
// Report the timer as expired instead, which clears the results and refetches
// the zero-keyword suggestions Spotlight opens with.
- (BOOL)checkClearTimer {
    if (!sbt_dismiss_spotlight_enabled()) return %orig;
    id controller = self;
    if ([controller respondsToSelector:@selector(clearTimerExpired)])
        [controller clearTimerExpired];
    return YES;
}
%end
%end

// ------------------------------------------------------------------ entry

// Every Home Screen configuration that may hold values written here.
static NSArray *sbc_known_root_configs(id cfg) {
    NSMutableArray *configs = [[sbc_root_configs() allObjects] mutableCopy];
    for (id extra in @[cfg ?: [NSNull null], sbc_root_cfg ?: [NSNull null]])
        if (extra != [NSNull null] && ![configs containsObject:extra]) [configs addObject:extra];
    return configs;
}

static void restore_home_grid(NSArray *configs, NSArray *lists) {
    // From iOS 17 the pages' list models are created with the custom grid
    // (sbc_root_list_grid), and only a respring builds them again. Showing the
    // stock grid over those models would misplace icons, so the custom grid
    // stays until then.
    if (sbc_is_ios17_or_newer()) return;
    BOOL restored = NO;
    for (id cfg in configs) {
        restored = sbc_restore_native(cfg, @"columns") || restored;
        restored = sbc_restore_native(cfg, @"rows") || restored;
    }
    for (id listView in lists) {
        if (sbc_restore_native(listView, @"autofit")) restored = YES;
        [listView setNeedsLayout];
    }
    if (restored) NSLog(@"[SBC] home grid restored");
}

static void restore_home_spacing(NSArray *configs) {
    BOOL restored = NO;
    for (id cfg in configs) restored = sbc_restore_native(cfg, @"insets") || restored;
    if (restored) NSLog(@"[SBC:SPACE] home insets restored");
}

static void restore_home_scale(id mgr, id cfg, NSArray *configs) {
    BOOL restored = NO;
    for (id config in configs) restored = restore_icon_scale(config) || restored;
    if (!restored || ![cfg respondsToSelector:@selector(iconImageInfo)]) return;
    refresh_home_icons(mgr, [cfg iconImageInfo]);
    NSLog(@"[SBC:SCALE] home scale restored");
}

static void restore_dock_scale(id dock, id dockCfg) {
    if (!restore_icon_scale(dockCfg) || !dock) return;
    refresh_list_view_icons(dock, [dockCfg iconImageInfo]);
    NSLog(@"[SBC:SCALE] dock scale restored");
}

static void sbc_apply(void) {
    NSDictionary *p = sbc_reload_prefs(); // refresh the cache used by the configuration getter hooks
    // A feature that is off, or everything with the master switch off, gets
    // SpringBoard's own values back, so switching off needs no respring.
    BOOL on = prefBool(p, @"enabled");
    if (!on) NSLog(@"[SBC] disabled, restoring stock values");

    int dockIcons    = clampi((int)prefInt(p, @"dockIcons"), 1, 8);
    int hsCols       = clampi((int)prefInt(p, @"hsCols"), 1, 10);
    int hsRows       = clampi((int)prefInt(p, @"hsRows"), 1, 10);
    int hsColsL      = clampi((int)prefInt(p, @"hsColsLandscape"), 1, 10);
    int hsRowsL      = clampi((int)prefInt(p, @"hsRowsLandscape"), 1, 10);
    double homeExL   = prefDouble(p, @"homeExL");
    double homeExR   = prefDouble(p, @"homeExR");
    double homeExT   = prefDouble(p, @"homeExT");
    double homeExB   = prefDouble(p, @"homeExB");
    double dockExL   = prefDouble(p, @"dockExL");
    double dockExR   = prefDouble(p, @"dockExR");
    double homeScale = prefDouble(p, @"homeScale");
    double dockScale = prefDouble(p, @"dockScale");

    NSLog(@"[SBC] apply dock=%d hs=%dx%d ls=%dx%d space=+%.0f/%.0f/%.0f/%.0f dockLR=%.0f/%.0f scale=%.2f/%.2f",
          dockIcons, hsCols, hsRows, hsColsL, hsRowsL,
          homeExL, homeExR, homeExT, homeExB, dockExL, dockExR, homeScale, dockScale);

    sbc_apply_drag_coefficient();

    id iconCtrl = [%c(SBIconController) sharedInstance];
    if (!iconCtrl) { NSLog(@"[SBC] SBIconController missing"); return; }
    id mgr = [iconCtrl respondsToSelector:@selector(iconManager)] ? [iconCtrl iconManager] : nil;
    if (!mgr) { NSLog(@"[SBC] icon manager missing"); return; }

    id cfg = root_layout_config(iconCtrl, mgr);
    if (!cfg) NSLog(@"[SBC] root layoutConfiguration nil");
    id dock = dock_list_view(iconCtrl, mgr);
    id dockCfg = dock_layout_config(dock);
    NSArray *rootConfigs = sbc_known_root_configs(cfg);

    if (on && prefBool(p, @"dockLayoutEnabled"))
        patch_dock(dock, dockIcons);
    else
        restore_dock(dock);

    if (on && prefBool(p, @"homeGridEnabled")) {
        if (cfg) patch_homescreen_grid(mgr, cfg, hsCols, hsRows);
    } else {
        restore_home_grid(rootConfigs, sbc_root_list_views(mgr));
    }

    if (on && prefBool(p, @"homeSpacingEnabled"))
        apply_home_spacing(cfg, p);
    else
        restore_home_spacing(rootConfigs);
    if (on && prefBool(p, @"dockSpacingEnabled"))
        apply_dock_spacing(dockCfg, p);
    else if (sbc_restore_native(dockCfg, @"insets"))
        NSLog(@"[SBC:SPACE] dock insets restored");
    if (on && prefBool(p, @"homeScaleEnabled") && homeScale > 0.0)
        apply_home_scale(mgr, cfg, homeScale);
    else
        restore_home_scale(mgr, cfg, rootConfigs);
    if (on && prefBool(p, @"dockScaleEnabled") && dockScale > 0.0)
        apply_dock_scale(dock, dockCfg, dockScale);
    else
        restore_dock_scale(dock, dockCfg);

    // Re-run the indicator offset against the new preferences.
    id rootFolder = [mgr respondsToSelector:@selector(rootFolderController)]
        ? [mgr rootFolderController] : nil;
    UIView *rootFolderView = [rootFolder respondsToSelector:@selector(rootFolderView)]
        ? [rootFolder rootFolderView] : nil;
    [rootFolderView setNeedsLayout];

    force_manager_relayout(mgr);
}

static void sbc_apply_notification(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // Give cfprefsd a moment to flush the plist written by the settings pane.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sbc_apply();
        sbt_publish_app_state();
    });
}

%group SpringBoard
%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // SBIconController and its manager are available after SpringBoard's
    // original launch method returns. Apply before the first rendered frame
    // instead of visibly correcting the layout three seconds later.
    sbc_apply(); // includes the drag coefficient
    sbt_publish_app_state();
    // Restore before autosave gets any chance to replace the preserved
    // snapshot with SpringBoard's post-rejailbreak fallback arrangement.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sbt_icon_restore_guard) sbt_restore_icon_layout();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sbt_icon_restore_guard = NO;
        });
    });
}

%end
%end

// Respring relay: the Settings pane is not allowed to relaunch SpringBoard on
// rootless/roothide, so it posts this notification and we do it from inside
// SpringBoard, where exitAndRelaunch: works.
@interface FBSystemService : NSObject
+ (instancetype)sharedInstance;
- (void)exitAndRelaunch:(BOOL)relaunch;
@end

// Any process may post a Darwin notification, so the notification alone is
// not trusted. The Settings pane first writes the request time into the
// preferences domain, which sandboxed apps cannot write; the request is
// honoured only if that timestamp is fresh, and it is consumed right away so
// a replayed notification does nothing.
static NSString *const kSBTRespringRequestKey = @"respringRequest";

static void sbc_respring_notification(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CFPreferencesAppSynchronize(kPrefsDomain);
        NSNumber *requested = CFBridgingRelease(CFPreferencesCopyAppValue(
            (__bridge CFStringRef)kSBTRespringRequestKey, kPrefsDomain));
        if (![requested isKindOfClass:[NSNumber class]]) return;
        CFPreferencesSetAppValue((__bridge CFStringRef)kSBTRespringRequestKey, NULL, kPrefsDomain);
        CFPreferencesAppSynchronize(kPrefsDomain);
        if (fabs(CFAbsoluteTimeGetCurrent() - requested.doubleValue) > 10.0) {
            NSLog(@"[SBT] ignoring stale respring request");
            return;
        }
        [[%c(FBSystemService) sharedInstance] exitAndRelaunch:YES];
    });
}

%ctor {
    // The filter injects into every UIKit process. Daemons without a bundle
    // need none of this; apps and app extensions (share sheet, widgets,
    // iMessage apps) get the app-side hooks.
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID) return;
    sbt_is_springboard = [bundleID isEqualToString:@"com.apple.springboard"];

    // Hooks that act inside apps; their switches come from the app state
    // SpringBoard publishes. The Spotlight hooks only find their class in the
    // Spotlight UI process.
    sbt_watch_app_state();
    %init(FastCopy);
    %init(Layer);
    %init(Spotlight);
    if (!sbt_is_springboard) {
        ns_hooked = [NSMutableSet set];
        %init(NoSlide);
        return;
    }

    // Everything below is SpringBoard-only: seeding prefs from arbitrary apps
    // is pointless, and the respring relay must never call exitAndRelaunch:
    // from inside a random app.
    %init(SpringBoard);

    // Prefer the class methods that take isWake, and only fall back to the
    // instance getter plus a remembered flag where they do not exist.
    Class wakeCtrl = objc_getClass("SBScreenWakeAnimationController");
    if (wakeCtrl &&
        [wakeCtrl respondsToSelector:@selector(backlightFadeDurationForSource:isWake:)] &&
        [wakeCtrl respondsToSelector:@selector(_animationSpeedForBacklightChangeSource:isWake:)]) {
        %init(WakeExact);
#if SBT_WAKE_TRACE
        sbt_trace_install_settings_hook();
#endif
    } else {
        NSLog(@"[SBT:WAKE] isWake class methods missing, using the legacy flag");
        %init(WakeLegacy);
    }
#if SBT_WAKE_TRACE
    SBT_TRACE("trace build: %s path, noWakeAnim=%d noSleepFade=%d",
              wakeCtrl && [wakeCtrl respondsToSelector:@selector(backlightFadeDurationForSource:isWake:)]
                  ? "exact" : "legacy",
              sbc_pref_bool_live(CFSTR("noWakeAnim")), sbc_pref_bool_live(CFSTR("noSleepFade")));
    // After launch, so the class scan does not delay SpringBoard starting.
    dispatch_async(dispatch_get_main_queue(), ^{ sbt_trace_install_view_hooks(); });
#endif
    sbc_install_landscape_hooks();
    sbc_install_home_layout_hooks();
    sbc_install_add_widget_hooks();
    sbt_install_home_double_tap_hook();
    // Do not write or migrate preferences during SpringBoard construction.
    // On iOS 15, synchronous cfprefsd writes here can stall SpringBoard before
    // it finishes launching. The Settings bundle owns seeding/migration; all
    // runtime reads already provide safe fallback values for missing keys.
    sbt_icon_restore_guard =
        sbc_pref_bool_live(CFSTR("iconLayoutBackupEnabled")) &&
        [[NSFileManager defaultManager] fileExistsAtPath:sbt_icon_layout_backup_path()];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, sbc_apply_notification,
                                    kApplyNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, sbc_respring_notification,
                                    CFSTR("cz.kolbi.sbtweaker/respring"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
