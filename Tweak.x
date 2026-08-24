#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>
#import <stdint.h>
#import <stdbool.h>
#import <math.h>
#import "SBTDefaults.h"

// SBTweaker — injection-tweak conversions of cyanide tweaks, all running
// inside SpringBoard on the main thread (no RemoteCall plumbing):
//  - sbcustomizer.m: home grid / dock size / labels
//  - darksword_layout.m: spacing & icon scaling
//  - darksword disable_app_library(): hide App Library
//  - darksword_tweaks.m double-tap-to-lock: home & lock screen gestures
//  - FastAnimations: core animation clamp & Fast Copy callout (these two
//    also load into every UIKit app via the com.apple.UIKit filter entry)
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
- (id)icons;
- (BOOL)importState:(id)state;
- (void)noteIconStateChangedExternally;
- (id)icon;
- (BOOL)isDock;
- (void)setAutomaticallyAdjustsLayoutMetricsToFit:(BOOL)value;
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
static BOOL sbc_pref_bool_live(CFStringRef key, BOOL def);

static int clampi(int v, int lo, int hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static NSInteger prefInt(NSDictionary *p, NSString *key, NSInteger def) {
    id v = p[key];
    return v ? [v integerValue] : def;
}

static double prefDouble(NSDictionary *p, NSString *key, double def) {
    id v = p[key];
    return v ? [v doubleValue] : def;
}

static BOOL prefBool(NSDictionary *p, NSString *key, BOOL def) {
    id v = p[key];
    return v ? [v boolValue] : def;
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
    return @"/var/mobile/Library/Preferences/cz.kolbi.sbtweaker.iconlayout.plist";
}

static BOOL sbt_icon_restore_guard = NO;

static BOOL sbt_write_icon_layout_snapshot(id state) {
    if (![NSPropertyListSerialization propertyList:state
                              isValidForFormat:NSPropertyListBinaryFormat_v1_0])
        return NO;
    return [state writeToFile:sbt_icon_layout_backup_path() atomically:YES];
}

static BOOL sbt_restore_icon_layout(void) {
    if (!sbc_pref_bool_live(CFSTR("iconLayoutBackupEnabled"), NO)) return NO;
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:sbt_icon_layout_backup_path()];
    if (!state.count) return NO;

    id controller = [%c(SBIconController) sharedInstance];
    id model = [controller respondsToSelector:@selector(model)] ? [controller model] : nil;
    BOOL restored = NO;
    @try {
        id store = [%c(SBDefaultIconModelStore) sharedInstance];
        NSURL *url = [store respondsToSelector:@selector(currentIconStateURL)]
            ? [store currentIconStateURL] : nil;
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

%hook SBIconModelPropertyListFileStore
- (BOOL)saveCurrentIconState:(id)state error:(NSError **)error {
    if (sbt_icon_restore_guard) return YES;
    BOOL result = %orig;
    if (result && sbc_pref_bool_live(CFSTR("iconLayoutBackupEnabled"), NO))
        sbt_write_icon_layout_snapshot(state);
    return result;
}

- (BOOL)_save:(id)state url:(NSURL *)url error:(NSError **)error {
    if (sbt_icon_restore_guard) return YES;
    BOOL result = %orig;
    if (result && sbc_pref_bool_live(CFSTR("iconLayoutBackupEnabled"), NO)) {
        NSURL *currentURL = nil;
        if ([self respondsToSelector:@selector(currentIconStateURL)])
            currentURL = [(id)self currentIconStateURL];
        if (!currentURL || [url.path isEqualToString:currentURL.path])
            sbt_write_icon_layout_snapshot(state);
    }
    return result;
}
%end

// ---------------------------------------------------------------- grid patches

static void disable_list_autofit(id listView, NSString *tag) {
    if ([listView respondsToSelector:@selector(setAutomaticallyAdjustsLayoutMetricsToFit:)]) {
        [listView setAutomaticallyAdjustsLayoutMetricsToFit:NO];
        NSLog(@"[SBC] %@ autoFit=NO", tag);
    }
}

static BOOL patch_list_model_grid(id listView, NSString *tag, int cols, int rows) {
    id model = list_view_model(listView);
    if (!model || ![model respondsToSelector:@selector(gridSize)]) return NO;

    SBCGridSize grid = { (unsigned short)cols, (unsigned short)rows };
    if ([model respondsToSelector:@selector(setGridSize:)]) {
        [model setGridSize:grid];
    } else if ([model respondsToSelector:@selector(changeGridSize:options:)]) {
        [model changeGridSize:grid options:0];
    } else {
        NSLog(@"[SBC] %@ model lacks grid setter", tag);
        return NO;
    }
    NSLog(@"[SBC] %@ gridSize -> %dx%d", tag, cols, rows);
    return YES;
}

static void patch_dock(id iconCtrl, id mgr, int dockIcons) {
    id dock = dock_list_view(iconCtrl, mgr);
    if (!dock) { NSLog(@"[SBC] dock: nil dockListView"); return; }
    disable_list_autofit(dock, @"dockListView");

    id model = list_view_model(dock);
    if (model && [model respondsToSelector:@selector(gridSize)] &&
        [model respondsToSelector:@selector(setGridSize:)]) {
        SBCGridSize old = [model gridSize];
        SBCGridSize grid = { (unsigned short)dockIcons, old.rows };
        [model setGridSize:grid];
        NSLog(@"[SBC] dock gridSize -> %dx%d", dockIcons, old.rows);
    }

    id cfg = dock_layout_config(dock);
    if ([cfg respondsToSelector:@selector(setNumberOfPortraitColumns:)]) {
        [cfg setNumberOfPortraitColumns:(NSUInteger)dockIcons];
        NSLog(@"[SBC] dock portraitColumns -> %d", dockIcons);
    }
    [dock setNeedsLayout];
}

static void patch_homescreen_grid(id iconCtrl, id mgr, id cfg, int cols, int rows) {
    if ([cfg respondsToSelector:@selector(setNumberOfPortraitColumns:)]) {
        [cfg setNumberOfPortraitColumns:(NSUInteger)cols];
        if ([cfg respondsToSelector:@selector(setNumberOfPortraitRows:)])
            [cfg setNumberOfPortraitRows:(NSUInteger)rows];
        NSLog(@"[SBC] hs provider cols=%d rows=%d", cols, rows);
    }

    id rootFolder = [mgr respondsToSelector:@selector(rootFolderController)] ? [mgr rootFolderController] : nil;
    if (rootFolder && [rootFolder respondsToSelector:@selector(iconListViewCount)] &&
        [rootFolder respondsToSelector:@selector(iconListViewAtIndex:)]) {
        NSUInteger count = MIN([rootFolder iconListViewCount], 64);
        for (NSUInteger i = 0; i < count; i++) {
            id listView = [rootFolder iconListViewAtIndex:i];
            if (!listView) continue;
            NSString *tag = [NSString stringWithFormat:@"page[%lu]", (unsigned long)i];
            disable_list_autofit(listView, tag);
            patch_list_model_grid(listView, tag, cols, rows);
        }
    }
}

// ---------------------------------------------------- spacing (darksword_layout)

static void apply_home_spacing(id cfg, double exL, double exR, double exT, double exB) {
    if (![cfg respondsToSelector:@selector(setPortraitLayoutInsets:)]) {
        NSLog(@"[SBC:SPACE] layoutConfiguration lacks setPortraitLayoutInsets:");
        return;
    }
    // Base insets from the original: {60, 27, 100, 27} + user extras.
    [cfg setPortraitLayoutInsets:UIEdgeInsetsMake(60.0 + exT, 27.0 + exL,
                                                  100.0 + exB, 27.0 + exR)];
    NSLog(@"[SBC:SPACE] home insets +L%.1f/R%.1f/T%.1f/B%.1f", exL, exR, exT, exB);
}

static void apply_dock_spacing(id dockCfg, double extraH) {
    if (![dockCfg respondsToSelector:@selector(setPortraitLayoutInsets:)]) {
        NSLog(@"[SBC:SPACE] dock layoutConfiguration lacks setPortraitLayoutInsets:");
        return;
    }
    [dockCfg setPortraitLayoutInsets:UIEdgeInsetsMake(0.0, 16.0 + extraH,
                                                      0.0, 16.0 + extraH)];
    NSLog(@"[SBC:SPACE] dock insets +H%.1f", extraH);
}

// ----------------------------------------------------- scaling (darksword_layout)

static SBIconImageInfo configured_icon_image_info(double scale) {
    // SpringBoard's iOS 15–17 application-icon baseline. Returning/writing an
    // absolute value makes repeated layout passes idempotent (no compounding).
    SBIconImageInfo info;
    info.size = CGSizeMake(60.0 * scale, 60.0 * scale);
    info.scale = 2.0;
    info.continuousCornerRadius = 13.5 * scale;
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

// SBApplicationIcon only — widgets/folders assert on forced 60x60.
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

static void apply_home_scale(id mgr, id cfg, double scale) {
    if (scale <= 0.0 || scale > 2.0 || ![cfg respondsToSelector:@selector(iconImageInfo)]) return;
    // The getter hook already returns the stock geometry scaled once.
    SBIconImageInfo info = [cfg iconImageInfo];

    id rootFolder = [mgr respondsToSelector:@selector(rootFolderController)] ? [mgr rootFolderController] : nil;
    if (![rootFolder respondsToSelector:@selector(iconListViewCount)]) return;
    NSUInteger count = MIN([rootFolder iconListViewCount], 64);
    for (NSUInteger i = 0; i < count; i++) {
        id listView = [rootFolder iconListViewAtIndex:i];
        if (!listView) continue;
        if ([listView respondsToSelector:@selector(isDock)] && [listView isDock]) continue;
        refresh_list_view_icons(listView, info);
    }
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

@interface SBDockIconListModel : NSObject
- (SBCGridSize)gridSize;
@end

static NSDictionary *sbc_cachedPrefs = nil;
static CFAbsoluteTime sbc_prefs_loaded_at = 0;

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
    // Hot hooks such as CATransaction must not make a cfprefsd round-trip on
    // every call. Refresh at most once per second so switches still feel live.
    if (!sbc_cachedPrefs || CFAbsoluteTimeGetCurrent() - sbc_prefs_loaded_at >= 1.0)
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

#define SBC_CFG_UNKNOWN 0
#define SBC_CFG_ROOT    1
#define SBC_CFG_DOCK    2

static int sbc_config_kind(id cfg) {
    if (!cfg) return SBC_CFG_UNKNOWN;
    if (sbc_root_cfg && cfg == sbc_root_cfg) return SBC_CFG_ROOT;
    if (sbc_dock_cfg && cfg == sbc_dock_cfg) return SBC_CFG_DOCK;

    // Refresh identities from the live layout provider.
    id iconCtrl = [%c(SBIconController) sharedInstance];
    id mgr = [iconCtrl respondsToSelector:@selector(iconManager)] ? [iconCtrl iconManager] : nil;
    id provider = [mgr respondsToSelector:@selector(listLayoutProvider)] ? [mgr listLayoutProvider] : nil;
    if ([provider respondsToSelector:@selector(layoutForIconLocation:)]) {
        id rl = [provider layoutForIconLocation:@"SBIconLocationRoot"];
        sbc_root_cfg = [rl respondsToSelector:@selector(layoutConfiguration)] ? [rl layoutConfiguration] : nil;
        id dl = [provider layoutForIconLocation:@"SBIconLocationDock"];
        sbc_dock_cfg = [dl respondsToSelector:@selector(layoutConfiguration)] ? [dl layoutConfiguration] : nil;
    }
    if (cfg == sbc_root_cfg) return SBC_CFG_ROOT;
    if (cfg == sbc_dock_cfg) return SBC_CFG_DOCK;
    return SBC_CFG_UNKNOWN;
}

%hook SBIconListGridLayoutConfiguration
- (NSUInteger)numberOfPortraitRows {
    NSUInteger orig = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", NO)) return orig;
    if (sbc_config_kind(self) != SBC_CFG_ROOT) return orig;
    if (!prefBool(p, @"homeGridEnabled", NO)) return orig;
    return (NSUInteger)clampi((int)prefInt(p, @"hsRows", 6), 4, 8);
}

- (NSUInteger)numberOfPortraitColumns {
    NSUInteger orig = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", NO)) return orig;
    int kind = sbc_config_kind(self);
    // Fallback for the dock only: identity lookup can fail during boot (the
    // provider chain may not be up when icon-state validation first asks),
    // which used to cost us the 5th dock icon. A single-row, 4-wide grid is
    // unambiguous enough — the App Library breakage came from the *home*
    // branch matching everything, and that branch stays identity-only.
    // The dock-count switch owns both its geometry and capacity. This
    // fallback keeps the configured slot count available during boot-time
    // icon-state validation before object identity has been established.
    if (kind == SBC_CFG_UNKNOWN && prefBool(p, @"dockLayoutEnabled", NO) &&
        orig == 4 && [self numberOfPortraitRows] == 1) {
        static BOOL logged = NO;
        if (!logged) { logged = YES; NSLog(@"[SBC] dock config identified by 1-row fallback"); }
        kind = SBC_CFG_DOCK;
    }
    if (kind == SBC_CFG_DOCK && prefBool(p, @"dockLayoutEnabled", NO))
        return (NSUInteger)clampi((int)prefInt(p, @"dockIcons", 5), 4, 7);
    if (kind == SBC_CFG_ROOT && prefBool(p, @"homeGridEnabled", NO))
        return (NSUInteger)clampi((int)prefInt(p, @"hsCols", 5), 3, 8);
    return orig;
}

- (UIEdgeInsets)portraitLayoutInsets {
    UIEdgeInsets orig = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", NO)) return orig;
    int kind = sbc_config_kind(self);
    if (kind == SBC_CFG_DOCK) {
        if (!prefBool(p, @"dockSpacingEnabled", NO)) return orig;
        double h = prefDouble(p, @"dockExH", 30.0);
        return UIEdgeInsetsMake(0.0, 16.0 + h, 0.0, 16.0 + h);
    }
    if (kind == SBC_CFG_ROOT) {
        if (!prefBool(p, @"homeSpacingEnabled", NO)) return orig;
        UIEdgeInsets insets = UIEdgeInsetsMake(60.0 + prefDouble(p, @"homeExT", 40.0),
                                               27.0 + prefDouble(p, @"homeExL", 20.0),
                                               100.0 + prefDouble(p, @"homeExB", 180.0),
                                               27.0 + prefDouble(p, @"homeExR", 20.0));
        return constrained_grid_insets(insets,
            clampi((int)prefInt(p, @"hsCols", 5), 3, 8),
            clampi((int)prefInt(p, @"hsRows", 6), 4, 8),
            prefDouble(p, @"homeScale", 0.98), NO);
    }
    return orig;
}

- (SBIconImageInfo)iconImageInfo {
    SBIconImageInfo orig = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", NO)) return orig;
    int kind = sbc_config_kind(self);
    if (kind != SBC_CFG_ROOT && kind != SBC_CFG_DOCK) return orig;
    if (kind == SBC_CFG_ROOT && !prefBool(p, @"homeScaleEnabled", NO)) return orig;
    if (kind == SBC_CFG_DOCK && !prefBool(p, @"dockScaleEnabled", NO)) return orig;
    double scale = kind == SBC_CFG_DOCK ? prefDouble(p, @"dockScale", 0.98)
                                        : prefDouble(p, @"homeScale", 0.98);
    if (scale <= 0.0 || scale > 2.0) return orig;
    return configured_icon_image_info(scale);
}
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
    if (!prefBool(p, @"enabled", NO)) return orig;
    if (sbc_config_kind(self) != SBC_CFG_ROOT) return orig;
    if (!prefBool(p, @"homeGridEnabled", NO)) return orig;
    return (NSUInteger)clampi((int)prefInt(p, @"hsRowsLandscape", 5), 4, 8);
}

static NSUInteger sbc_landscape_columns(id self, SEL _cmd) {
    NSUInteger orig = sbc_orig_landscape_columns
        ? sbc_orig_landscape_columns(self, _cmd) : 0;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", NO)) return orig;
    if (sbc_config_kind(self) != SBC_CFG_ROOT) return orig;
    if (!prefBool(p, @"homeGridEnabled", NO)) return orig;
    return (NSUInteger)clampi((int)prefInt(p, @"hsColsLandscape", 6), 3, 8);
}

static UIEdgeInsets sbc_landscape_insets(id self, SEL _cmd) {
    UIEdgeInsets orig = sbc_orig_landscape_insets
        ? sbc_orig_landscape_insets(self, _cmd) : UIEdgeInsetsZero;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", NO) ||
        !prefBool(p, @"homeSpacingEnabled", NO) ||
        sbc_config_kind(self) != SBC_CFG_ROOT)
        return orig;
    UIEdgeInsets insets = UIEdgeInsetsMake(orig.top + prefDouble(p, @"homeExT", 0.0),
                                           orig.left + prefDouble(p, @"homeExL", 0.0),
                                           orig.bottom + prefDouble(p, @"homeExB", 0.0),
                                           orig.right + prefDouble(p, @"homeExR", 0.0));
    return constrained_grid_insets(insets,
        clampi((int)prefInt(p, @"hsColsLandscape", 6), 3, 8),
        clampi((int)prefInt(p, @"hsRowsLandscape", 5), 4, 8),
        prefDouble(p, @"homeScale", 1.0), YES);
}

static SBIconImageInfo sbc_landscape_icon_info(id self, SEL _cmd) {
    SBIconImageInfo orig = sbc_orig_landscape_icon_info
        ? sbc_orig_landscape_icon_info(self, _cmd) : (SBIconImageInfo){0};
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", NO) ||
        !prefBool(p, @"homeScaleEnabled", NO) ||
        sbc_config_kind(self) != SBC_CFG_ROOT)
        return orig;
    double scale = prefDouble(p, @"homeScale", 1.0);
    return scale > 0.0 && scale <= 2.0 ? configured_icon_image_info(scale) : orig;
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

%hook SBDockIconListModel
- (SBCGridSize)gridSize {
    SBCGridSize grid = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", NO)) return grid;
    if (!prefBool(p, @"dockLayoutEnabled", NO)) return grid;
    int dockIcons = clampi((int)prefInt(p, @"dockIcons", 5), 4, 7);
    if (grid.columns < dockIcons) grid.columns = (unsigned short)dockIcons;
    return grid;
}
%end

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

static NSMutableSet *sbc_patched_set(void) {
    static NSMutableSet *s = nil;
    if (!s) s = [NSMutableSet new];
    return s;
}

static void sbc_patch_root_config(id cfg) {
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", NO)) return;

    int hsCols       = clampi((int)prefInt(p, @"hsCols", 5), 3, 8);
    int hsRows       = clampi((int)prefInt(p, @"hsRows", 6), 4, 8);
    double exL = prefDouble(p, @"homeExL", 20.0), exR = prefDouble(p, @"homeExR", 20.0);
    double exT = prefDouble(p, @"homeExT", 40.0), exB = prefDouble(p, @"homeExB", 180.0);
    double homeScale = prefDouble(p, @"homeScale", 0.98);

    if (prefBool(p, @"homeGridEnabled", NO) &&
        [cfg respondsToSelector:@selector(setNumberOfPortraitColumns:)]) {
        [cfg setNumberOfPortraitColumns:(NSUInteger)hsCols];
        if ([cfg respondsToSelector:@selector(setNumberOfPortraitRows:)])
            [cfg setNumberOfPortraitRows:(NSUInteger)hsRows];
    }
    if (prefBool(p, @"homeSpacingEnabled", NO) &&
        [cfg respondsToSelector:@selector(setPortraitLayoutInsets:)])
        [cfg setPortraitLayoutInsets:UIEdgeInsetsMake(60.0 + exT, 27.0 + exL,
                                                    100.0 + exB, 27.0 + exR)];
    if (prefBool(p, @"homeScaleEnabled", NO) &&
        homeScale > 0.0 && homeScale <= 2.0 &&
        [cfg respondsToSelector:@selector(setIconImageInfo:)])
        [cfg setIconImageInfo:configured_icon_image_info(homeScale)];
}

static void sbc_patch_dock_config(id dock) {
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", NO)) return;

    int dockIcons    = clampi((int)prefInt(p, @"dockIcons", 5), 4, 7);
    double dockExH   = prefDouble(p, @"dockExH", 30.0);
    double dockScale = prefDouble(p, @"dockScale", 0.98);

    id cfg = dock_layout_config(dock);
    if (prefBool(p, @"dockLayoutEnabled", NO) &&
        [cfg respondsToSelector:@selector(setNumberOfPortraitColumns:)])
        [cfg setNumberOfPortraitColumns:(NSUInteger)dockIcons];
    if (prefBool(p, @"dockSpacingEnabled", NO) &&
        [cfg respondsToSelector:@selector(setPortraitLayoutInsets:)])
        [cfg setPortraitLayoutInsets:UIEdgeInsetsMake(0.0, 16.0 + dockExH,
                                                    0.0, 16.0 + dockExH)];
    if (prefBool(p, @"dockScaleEnabled", NO) &&
        dockScale > 0.0 && dockScale <= 2.0 &&
        [cfg respondsToSelector:@selector(setIconImageInfo:)])
        [cfg setIconImageInfo:configured_icon_image_info(dockScale)];
    [dock setNeedsLayout];
}

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
    if (dockCfg) sbc_dock_cfg = dockCfg;
    if (cfg && ![sbc_patched_set() containsObject:cfg]) {
        [sbc_patched_set() addObject:cfg];
        sbc_patch_root_config(cfg);
    }
    return provider;
}
%end

%hook SBDockIconListView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    id cfg = dock_layout_config(self);
    if (cfg) sbc_dock_cfg = cfg;
    if ([sbc_patched_set() containsObject:self]) return;
    [sbc_patched_set() addObject:self];
    sbc_patch_dock_config(self);
}
%end

// ------------------------------------------------------------ App Library
//
// Integrated from the standalone NoAppLibrary tweak (itself a conversion of
// cyanide's darksword disable_app_library()). The App Library lives in the
// root folder controller's trailingCustomViewControllers; hooking the getter
// persistently beats the one-shot remote poke, which raced with SpringBoard
// repopulating the list on iOS 17.
//
// Live single-key read through CFPreferences (the same channel the Settings
// pane writes through), unlike the cached sbc_prefs() used by the layout
// hooks — the cached value could be stale or not yet flushed by cfprefsd,
// which made the integrated version fail where the unconditional standalone
// tweak worked. The feature switches are self-contained: they are NOT gated
// by the master "enabled" switch.

static BOOL sbc_pref_bool_live(CFStringRef key, BOOL def) {
    NSDictionary *prefs = sbc_prefs();
    id master = prefs[@"enabled"];
    if (key != CFSTR("enabled") && master && ![master boolValue]) return NO;
    id value = prefs[(__bridge NSString *)key];
    return value ? [value boolValue] : def;
}

static double sbc_pref_double_live(CFStringRef key, double def) {
    NSDictionary *prefs = sbc_prefs();
    id value = prefs[(__bridge NSString *)key];
    return value ? [value doubleValue] : def;
}

static BOOL sbc_hide_app_library(void) {
    BOOL hide = sbc_pref_bool_live(CFSTR("hideAppLibrary"), NO);
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
%hook SBRootFolderController
- (NSArray *)trailingCustomViewControllers {
    return sbc_hide_app_library() ? @[] : %orig;
}
- (id)trailingCustomViewController {
    return sbc_hide_app_library() ? nil : %orig;
}
%end

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
%end

// Absent on some versions — the hook then simply never fires.
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
    if (!prefBool(p, @"enabled", NO) ||
        !prefBool(p, @"dockLayoutEnabled", NO))
        return original;
    return MAX(original,
               (NSUInteger)clampi((int)prefInt(p, @"dockIcons", 4), 4, 7));
}
%end

// iPad: also remove the App Library button from the floating dock.
%hook SBFloatingDockDefaults
- (BOOL)appLibraryEnabled {
    return sbc_hide_app_library() ? NO : %orig;
}
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
// Each area has its own switch (dtlHomeScreen / dtlLockScreen), read live;
// since recognizers are installed when the views appear, changes fully take
// effect after a respring.

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
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    UIView *root = gestureRecognizer.view;
    UIWindow *window = root.window;
    // Reject the gesture everywhere while passcode authentication is on
    // screen, including empty areas outside the keypad itself.
    if (sbt_view_contains_visible_passcode_ui(window ?: root)) return NO;

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
    if (!sbc_pref_bool_live(CFSTR("dtlHomeScreen"), NO)) return;
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

%hook CSCoverSheetViewController
- (void)viewDidLoad {
    %orig;
    // Guard against the Logos superclass pitfall: if CSCoverSheetViewController
    // does not override viewDidLoad itself, Substrate hooks UIViewController's
    // implementation and this would run for every view controller in
    // SpringBoard (attaching a lock recognizer to each view — a likely
    // watchdog/hang source). Only proceed for actual cover sheet instances.
    if (![self isKindOfClass:%c(CSCoverSheetViewController)]) return;
    if (!sbc_pref_bool_live(CFSTR("dtlLockScreen"), NO)) return;
    UIView *v = self.view;
    if (!v) return;
    if (objc_getAssociatedObject(v, &kDTLockGestureKey)) return;

    UITapGestureRecognizer *gr = dtl_makeRecognizer();
    gr.delegate = sbt_lock_double_tap_delegate();
    [v addGestureRecognizer:gr];
    objc_setAssociatedObject(v, &kDTLockGestureKey, gr, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
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
    drag_t d;
    if (!find_drag(&d)) { NSLog(@"[SBT:DRAG] find_drag failed"); return; }

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

static void sbc_apply_drag_coefficient(void) {
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", NO)) return;
    if (!prefBool(p, @"dragCoefficientEnabled", NO)) return;
    double v = sbc_pref_double_live(CFSTR("dragCoefficient"), 1.0);
    if (v < 0.01 || v > 2.0) return;
    if (fabs(v - 1.0) < 1e-9) return; // stock — leave the global untouched
    override_drag_coefficient(v);
}

// ------------------------------------------------ wake/sleep & icon fly-in
//
// Simplified after Speedster (github.com/Hoangdus/Speedster): plain getter
// hooks replace the previous fetch-and-ivar-poke machinery (which poked
// _animationSettingsForBacklightChangeSource:isWake: results). The mapping
// on SBFWakeAnimationSettings is:
//   backlightFadeDuration        -> screen OFF (sleep)
//   speedMultiplierForWake       -> screen ON (wake)
//   speedMultiplierForLiftToWake -> screen ON (lift to wake)
// ------------------------------------------------ wake/sleep & icon fly-in
//
// iOS 17 reality (confirmed on-device):
//   sleep (screen off) is governed by backlightFadeDuration alone.
//   wake  (screen on)  is gated by backlightFadeDuration AND the
//   speedMultiplierForWake/LiftToWake values — the multipliers alone do
//   nothing while the fade ramp is non-zero.
// backlightFadeDuration is ONE getter shared by both transitions, so
// per-direction switches need to know which transition is running. The
// controller fetches its settings via
// _animationSettingsForBacklightChangeSource:isWake: at transition time —
// track that flag and scope the getter by current transition. Each switch
// is then self-contained like the darksword originals:
//   wake:  fade 0 + multipliers 1000   iff noWakeAnim
//   sleep: fade 0                      iff noSleepFade
// Read live, so the toggles are instant.

static BOOL sbt_transition_is_wake = YES;

%hook SBScreenWakeAnimationController
- (id)_animationSettingsForBacklightChangeSource:(long long)source isWake:(BOOL)wake {
    if (wake != sbt_transition_is_wake)
        NSLog(@"[SBT:WAKE] transition -> %s (src=%lld)", wake ? "wake" : "sleep", source);
    sbt_transition_is_wake = wake;
    return %orig(source, wake);
}

- (double)backlightFadeDuration {
    if (sbt_transition_is_wake)
        return sbc_pref_bool_live(CFSTR("noWakeAnim"), NO) ? 0 : %orig;
    return sbc_pref_bool_live(CFSTR("noSleepFade"), NO) ? 0 : %orig;
}
%end

%hook SBFWakeAnimationSettings
- (double)backlightFadeDuration {
    if (sbt_transition_is_wake)
        return sbc_pref_bool_live(CFSTR("noWakeAnim"), NO) ? 0 : %orig;
    return sbc_pref_bool_live(CFSTR("noSleepFade"), NO) ? 0 : %orig;
}
- (double)speedMultiplierForWake {
    return sbc_pref_bool_live(CFSTR("noWakeAnim"), NO) ? 1000 : %orig;
}
- (double)speedMultiplierForLiftToWake {
    return sbc_pref_bool_live(CFSTR("noWakeAnim"), NO) ? 1000 : %orig;
}
%end

%hook CSCoverSheetTransitionSettings
- (void)setIconsFlyIn:(bool)arg1 {
    %orig(sbc_pref_bool_live(CFSTR("noIconsFlyIn"), NO) ? NO : arg1);
}
%end

// Faster Core Animation: clamp every explicit CA transaction duration to
// near zero. Injection equivalent of the FastAnimations hook — the
// DarkSword/cyanide variant uses CALayer.speed on all SpringBoard windows
// instead, because a remote call cannot hook.
static BOOL sbt_is_springboard = NO;

static inline double sbt_scaled_duration(double original) {
    if (original <= 0.0)  return 0.0;
    if (original <= 0.05) return original;
    return 0.01;
}

%hook CATransaction
+ (void)setAnimationDuration:(double)arg1 {
    if (sbc_pref_bool_live(CFSTR("fasterCoreAnimation"), NO))
        %orig(sbt_scaled_duration(arg1));
    else
        %orig(arg1);
}
// FastAnimations parity: kill implicit animations inside apps entirely.
// SpringBoard legitimately toggles disableActions itself, so pass through.
+ (void)setDisableActions:(BOOL)arg1 {
    if (!sbc_pref_bool_live(CFSTR("fasterCoreAnimation"), NO) || sbt_is_springboard)
        %orig(arg1);
    else
        %orig(YES);
}
%end

// Fast Copy: show the copy/paste callout bar immediately instead of after
// UIKit's built-in delay. Inspired by the classic Fast Copy tweak. Fires in
// every app, not just SpringBoard (the substrate filter includes
// com.apple.UIKit).
%hook UITextSelectionView
- (void)showCalloutBarAfterDelay:(double)arg1 {
    %orig(sbc_pref_bool_live(CFSTR("fastCopy"), NO) ? 0 : arg1);
}
%end

#if 0 // Removed: the Spotlight implementation is unreliable on iOS 15–17.
// --------------------------------------- dismiss Spotlight after result tap
//
// Spotlight's concrete result controllers changed across iOS 15–17. Rather
// than hard-linking one private class, observe result actions and dynamically
// hook search-owned table/collection delegates as they are installed. All
// hooks are gated by class/view names and preserve their original methods.

static BOOL sbt_name_is_search_related(NSString *name) {
    if (!name.length) return NO;
    return [name containsString:@"SPUI"] ||
           [name containsString:@"Spotlight"] ||
           [name containsString:@"Search"];
}

static BOOL sbt_spotlight_query_needs_clear = NO;
static BOOL sbt_spotlight_dismiss_pending = NO;

static BOOL sbt_view_is_search_related(UIView *view) {
    for (UIView *candidate = view; candidate; candidate = candidate.superview) {
        if (sbt_name_is_search_related(NSStringFromClass([candidate class])))
            return YES;
    }
    UIResponder *responder = view.nextResponder;
    for (NSUInteger i = 0; responder && i < 12; i++, responder = responder.nextResponder) {
        if (sbt_name_is_search_related(NSStringFromClass([responder class])))
            return YES;
    }
    return NO;
}

static BOOL sbt_action_looks_like_search_result(SEL action, id target, UIView *sender) {
    if (!sbt_view_is_search_related(sender)) return NO;
    for (UIView *view = sender; view; view = view.superview) {
        if ([NSStringFromClass([view class]) containsString:@"Result"]) return YES;
    }
    NSString *targetName = NSStringFromClass([target class]);
    if ([targetName containsString:@"Result"]) return YES;
    NSString *actionName = NSStringFromSelector(action).lowercaseString;
    return [actionName containsString:@"result"] ||
           [actionName containsString:@"select"] ||
           [actionName containsString:@"open"] ||
           [actionName containsString:@"launch"];
}

static void sbt_clear_search_text_in_view(UIView *view, BOOL searchContext) {
    BOOL related = searchContext || sbt_name_is_search_related(NSStringFromClass([view class]));
    if (related && [view isKindOfClass:[UISearchBar class]]) {
        UISearchBar *bar = (UISearchBar *)view;
        bar.text = @"";
        [bar resignFirstResponder];
    } else if (related && [view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        field.text = @"";
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
        [field resignFirstResponder];
    }
    for (UIView *subview in view.subviews)
        sbt_clear_search_text_in_view(subview, related);
}

static void sbt_invoke_search_dismiss_selector(id target, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:selector]) return;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments > 3) return;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    if (signature.numberOfArguments == 3) {
        BOOL animated = YES;
        [invocation setArgument:&animated atIndex:2];
    }
    [invocation invoke];
}

static void sbt_invoke_bool_selector(id target, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:selector]) return;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 3) return;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    [invocation setArgument:&value atIndex:2];
    [invocation invoke];
}

static void sbt_dismiss_search_controller_in_view(UIView *view, BOOL searchContext) {
    BOOL related = searchContext || sbt_name_is_search_related(NSStringFromClass([view class]));
    if (related) {
        UIResponder *responder = view.nextResponder;
        if ([responder isKindOfClass:[UIViewController class]]) {
            UIViewController *controller = (UIViewController *)responder;
            sbt_invoke_search_dismiss_selector(controller, @"dismissSearchView");
            sbt_invoke_search_dismiss_selector(controller, @"dismissAnimated:");
            if (controller.presentingViewController)
                [controller dismissViewControllerAnimated:YES completion:nil];
        }
    }
    for (UIView *subview in view.subviews)
        sbt_dismiss_search_controller_in_view(subview, related);
}

static void sbt_clear_and_dismiss_spotlight(void) {
    if (!sbc_pref_bool_live(CFSTR("dismissSpotlightAfterResult"), NO)) return;

    UIApplication *application = [UIApplication sharedApplication];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            sbt_clear_search_text_in_view(window, NO);
            sbt_dismiss_search_controller_in_view(window, NO);
        }
    }

    NSArray<NSString *> *classNames = @[@"SBSearchViewController",
                                         @"SBSearchController",
                                         @"SBSpotlightController",
                                         @"SPUISearchViewController"];
    NSArray<NSString *> *sharedSelectors = @[@"sharedInstance",
                                              @"sharedController"];
    NSArray<NSString *> *dismissSelectors = @[@"dismissSearchView",
                                               @"dismissSearchViewAnimated:",
                                               @"dismissAnimated:",
                                               @"hideSearch"];
    for (NSString *className in classNames) {
        Class cls = objc_getClass(className.UTF8String);
        if (!cls) continue;
        id target = nil;
        for (NSString *sharedName in sharedSelectors) {
            SEL shared = NSSelectorFromString(sharedName);
            if ([cls respondsToSelector:shared]) {
                target = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
                break;
            }
        }
        if (!target && [className isEqualToString:@"SPUISearchViewController"])
            continue;
        // SBSearchViewController is the SpringBoard owner on iOS 15–17.
        // Its public-to-SpringBoard visibility property is the reliable
        // dismissal path; the other selectors cover version-specific owners.
        sbt_invoke_bool_selector(target, @"setVisible:", NO);
        for (NSString *dismissName in dismissSelectors)
            sbt_invoke_search_dismiss_selector(target, dismissName);
    }
}

static void sbt_clear_spotlight_query_if_needed(void) {
    if (!sbt_spotlight_query_needs_clear) return;
    UIApplication *application = [UIApplication sharedApplication];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            sbt_clear_search_text_in_view(window, NO);
    }
    // Keep the flag until a search-owned text input is actually cleared.
    // iPadOS 15 may retain the controller and restore its query after dismiss.
}

static void sbt_spotlight_result_will_be_selected(void) {
    sbt_spotlight_query_needs_clear = YES;
    // App launches can preserve the underlying Spotlight presentation even
    // after an early setVisible:NO. Keep this pending until SpringBoard is
    // active again so returning Home cannot reveal the old search screen.
    sbt_spotlight_dismiss_pending = YES;
    // This must happen before SpringBoard handles the result action. Once the
    // original callback starts the app-launch transition, Spotlight's page is
    // retained underneath the app and changing only the controller's visible
    // flag is too late to affect the state restored on return to Home.
    sbt_clear_and_dismiss_spotlight();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sbt_clear_and_dismiss_spotlight();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sbt_clear_spotlight_query_if_needed();
    });
}

static NSMutableDictionary<NSString *, NSValue *> *sbt_search_originals(void) {
    static NSMutableDictionary *originals = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ originals = [NSMutableDictionary new]; });
    return originals;
}

static NSString *sbt_search_hook_key(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%p:%@", cls, NSStringFromSelector(selector)];
}

static IMP sbt_search_original_for_object(id object, SEL selector) {
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        NSValue *value = sbt_search_originals()[sbt_search_hook_key(cls, selector)];
        if (value) return [value pointerValue];
    }
    return NULL;
}

static void sbt_search_collection_selected(id self, SEL _cmd, id collectionView,
                                           NSIndexPath *indexPath) {
    sbt_spotlight_result_will_be_selected();
    IMP original = sbt_search_original_for_object(self, _cmd);
    if (original) ((void (*)(id, SEL, id, NSIndexPath *))original)(self, _cmd,
                                                                   collectionView, indexPath);
}

static void sbt_hook_search_delegate(id delegate, SEL selector, IMP replacement) {
    if (!delegate || !sbt_name_is_search_related(NSStringFromClass([delegate class]))) return;
    Class cls = object_getClass(delegate);
    NSString *key = sbt_search_hook_key(cls, selector);
    if (sbt_search_originals()[key]) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;

    // Materialize inherited implementations on the concrete search delegate
    // before hooking, so unrelated UIKit delegates are never affected.
    class_addMethod(cls, selector, method_getImplementation(method),
                    method_getTypeEncoding(method));
    IMP original = NULL;
    MSHookMessageEx(cls, selector, replacement, &original);
    if (original) sbt_search_originals()[key] = [NSValue valueWithPointer:original];
}

%hook UICollectionView
- (void)setDelegate:(id)delegate {
    %orig;
    sbt_hook_search_delegate(delegate,
        @selector(collectionView:didSelectItemAtIndexPath:),
        (IMP)sbt_search_collection_selected);
}
%end

%hook UITableView
- (void)setDelegate:(id)delegate {
    %orig;
    sbt_hook_search_delegate(delegate,
        @selector(tableView:didSelectRowAtIndexPath:),
        (IMP)sbt_search_collection_selected);
}
%end

%hook UIApplication
- (BOOL)sendAction:(SEL)action to:(id)target from:(id)sender forEvent:(UIEvent *)event {
    BOOL searchResult = sbt_is_springboard &&
        [sender isKindOfClass:[UIView class]] &&
        sbt_action_looks_like_search_result(action, target, sender);
    if (searchResult) sbt_spotlight_result_will_be_selected();
    BOOL result = %orig;
    return result;
}
%end

%hook UITextField
- (BOOL)becomeFirstResponder {
    BOOL result = %orig;
    if (result && sbt_spotlight_query_needs_clear && sbt_view_is_search_related(self)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.text = @"";
            [self sendActionsForControlEvents:UIControlEventEditingChanged];
            sbt_spotlight_query_needs_clear = NO;
        });
    }
    return result;
}
%end

static void (*sbt_orig_search_set_visible)(id, SEL, BOOL) = NULL;

static void sbt_search_set_visible(id self, SEL _cmd, BOOL visible) {
    if (sbt_orig_search_set_visible)
        sbt_orig_search_set_visible(self, _cmd, visible);
    if (visible && sbt_spotlight_query_needs_clear) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sbt_clear_spotlight_query_if_needed();
        });
    }
}

static void sbt_install_search_visibility_hook(void) {
    Class cls = objc_getClass("SBSearchViewController");
    SEL selector = @selector(setVisible:);
    if (!cls || !class_getInstanceMethod(cls, selector)) return;
    MSHookMessageEx(cls, selector, (IMP)sbt_search_set_visible,
                    (IMP *)&sbt_orig_search_set_visible);
}

// A result-launched app can retain Spotlight as the SpringBoard scene beneath
// it even when the search controller has been told to hide. Consume the
// one-shot flag only on an actual Home return. After the normal app-minimize
// transaction completes, a menu click makes SpringBoard leave its retained
// search presentation exactly as if Home had been pressed while Spotlight was
// visible. This deliberately does not run for app-switcher transitions.
%hook SBUIController
- (BOOL)handleHomeButtonSinglePressUp {
    BOOL shouldReturnToIcons = sbt_is_springboard &&
        sbt_spotlight_dismiss_pending &&
        sbc_pref_bool_live(CFSTR("dismissSpotlightAfterResult"), NO);
    if (shouldReturnToIcons)
        sbt_clear_and_dismiss_spotlight();

    BOOL result = %orig;
    if (shouldReturnToIcons) {
        sbt_spotlight_dismiss_pending = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[%c(SBUIController) sharedInstance] clickedMenuButton];
            sbt_clear_and_dismiss_spotlight();
        });
    }
    return result;
}
%end

#endif

// ------------------------------------------------------------------ entry

static void sbc_apply(void) {
    NSDictionary *p = sbc_reload_prefs(); // refresh the cache used by the configuration getter hooks
    if (!prefBool(p, @"enabled", NO)) { NSLog(@"[SBC] disabled"); return; }

    int dockIcons    = clampi((int)prefInt(p, @"dockIcons", 5), 4, 7);
    int hsCols       = clampi((int)prefInt(p, @"hsCols", 5), 3, 8);
    int hsRows       = clampi((int)prefInt(p, @"hsRows", 6), 4, 8);
    int hsColsL      = clampi((int)prefInt(p, @"hsColsLandscape", 6), 3, 8);
    int hsRowsL      = clampi((int)prefInt(p, @"hsRowsLandscape", 5), 4, 8);
    double homeExL   = prefDouble(p, @"homeExL", 20.0);
    double homeExR   = prefDouble(p, @"homeExR", 20.0);
    double homeExT   = prefDouble(p, @"homeExT", 40.0);
    double homeExB   = prefDouble(p, @"homeExB", 180.0);
    double dockExH   = prefDouble(p, @"dockExH", 30.0);
    double homeScale = prefDouble(p, @"homeScale", 0.98);
    double dockScale = prefDouble(p, @"dockScale", 0.98);

    NSLog(@"[SBC] apply dock=%d hs=%dx%d ls=%dx%d space=+%.0f/%.0f/%.0f/%.0f dockH=%.0f scale=%.2f/%.2f",
          dockIcons, hsCols, hsRows, hsColsL, hsRowsL,
          homeExL, homeExR, homeExT, homeExB, dockExH, homeScale, dockScale);

    id iconCtrl = [%c(SBIconController) sharedInstance];
    if (!iconCtrl) { NSLog(@"[SBC] SBIconController missing"); return; }
    id mgr = [iconCtrl iconManager];

    if (prefBool(p, @"dockLayoutEnabled", NO))
        patch_dock(iconCtrl, mgr, dockIcons);

    id cfg = root_layout_config(iconCtrl, mgr);
    if (cfg && prefBool(p, @"homeGridEnabled", NO))
        patch_homescreen_grid(iconCtrl, mgr, cfg, hsCols, hsRows);
    else if (!cfg) NSLog(@"[SBC] root layoutConfiguration nil");

    id dock = dock_list_view(iconCtrl, mgr);
    id dockCfg = dock_layout_config(dock);

    if (prefBool(p, @"homeSpacingEnabled", NO))
        apply_home_spacing(cfg, homeExL, homeExR, homeExT, homeExB);
    if (prefBool(p, @"dockSpacingEnabled", NO))
        apply_dock_spacing(dockCfg, dockExH);
    if (prefBool(p, @"homeScaleEnabled", NO) && homeScale > 0.0)
        apply_home_scale(mgr, cfg, homeScale);
    if (prefBool(p, @"dockScaleEnabled", NO) && dockScale > 0.0)
        apply_dock_scale(dock, dockCfg, dockScale);

    sbc_apply_drag_coefficient();

    force_manager_relayout(mgr);
}

static void sbc_apply_notification(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    // Give cfprefsd a moment to flush the plist written by the settings pane.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sbc_apply();
    });
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // SBIconController and its manager are available after SpringBoard's
    // original launch method returns. Apply before the first rendered frame
    // instead of visibly correcting the layout three seconds later.
    sbc_apply();
    sbc_apply_drag_coefficient();
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

// Single source of truth: these defaults are written into the settings plist
// for any key that has no stored value yet, at SpringBoard start (and also by
// the settings pane when it opens). Everything then reads them through
// CFPreferences — the literal fallbacks in the pref helpers are only a last
// resort if a key is missing entirely. Existing user values are never
// overwritten.
static NSDictionary *sbc_default_values(void) {
    return SBTDefaultValues();
}

// The version records the defaults schema only. Upgrades seed newly added
// keys but never overwrite a user's existing choices.
#define kSBTDefaultsVersion SBTDefaultsVersion

static void sbc_seed_defaults(void) {
    NSDictionary *defs = sbc_default_values();
    CFPreferencesAppSynchronize(kPrefsDomain);

    NSNumber *stored = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("defaultsVersion"), kPrefsDomain));
    BOOL force = !stored || [stored integerValue] < kSBTDefaultsVersion;

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

// Respring relay: the Settings pane is not allowed to relaunch SpringBoard on
// rootless/roothide, so it posts this notification and we do it from inside
// SpringBoard, where exitAndRelaunch: works.
@interface FBSystemService : NSObject
+ (instancetype)sharedInstance;
- (void)exitAndRelaunch:(BOOL)relaunch;
@end

static void sbc_respring_notification(CFNotificationCenterRef center, void *observer,
                                      CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[%c(FBSystemService) sharedInstance] exitAndRelaunch:YES];
    });
}

%ctor {
    // The filter also injects into every UIKit app (needed for the CA and
    // text-callout hooks). Everything below is SpringBoard-only: seeding
    // prefs from arbitrary apps is pointless, and the respring relay must
    // never call exitAndRelaunch: from inside a random app.
    sbt_is_springboard = [[[NSBundle mainBundle] bundleIdentifier]
                          isEqualToString:@"com.apple.springboard"];
    if (!sbt_is_springboard) return;

    sbc_install_landscape_hooks();
    sbt_install_home_double_tap_hook();
    sbc_seed_defaults();
    sbt_icon_restore_guard =
        sbc_pref_bool_live(CFSTR("iconLayoutBackupEnabled"), NO) &&
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
