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

static BOOL sbt_write_icon_layout_snapshot(id state) {
    if (![NSPropertyListSerialization propertyList:state
                              isValidForFormat:NSPropertyListBinaryFormat_v1_0])
        return NO;
    return [state writeToFile:sbt_icon_layout_backup_path() atomically:YES];
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

// ---------------------------------------------------------------- grid patches

static void disable_list_autofit(id listView, NSString *tag) {
    if ([listView respondsToSelector:@selector(setAutomaticallyAdjustsLayoutMetricsToFit:)]) {
        [listView setAutomaticallyAdjustsLayoutMetricsToFit:NO];
        NSLog(@"[SBC] %@ autoFit=NO", tag);
    }
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
            // Never rewrite a Home Screen model's grid. On iOS 15 this can
            // invalidate and remove widgets during icon-state restoration.
            // Configuration and SBIconListView metric hooks provide the
            // custom capacity/layout without modifying the saved icon state.
            [listView setNeedsLayout];
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

static void apply_dock_spacing(id dockCfg, double extraL, double extraR) {
    if (![dockCfg respondsToSelector:@selector(setPortraitLayoutInsets:)]) {
        NSLog(@"[SBC:SPACE] dock layoutConfiguration lacks setPortraitLayoutInsets:");
        return;
    }
    [dockCfg setPortraitLayoutInsets:UIEdgeInsetsMake(0.0, 16.0 + extraL,
                                                      0.0, 16.0 + extraR)];
    NSLog(@"[SBC:SPACE] dock insets +L%.1f/+R%.1f", extraL, extraR);
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
    // Hot hooks must not make a cfprefsd round-trip on
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
    return copy;
}

- (NSUInteger)numberOfPortraitRows {
    NSUInteger orig = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return orig;
    if (sbc_config_kind(self) != SBC_CFG_ROOT) return orig;
    if (!prefBool(p, @"homeGridEnabled")) return orig;
    return (NSUInteger)clampi((int)prefInt(p, @"hsRows"), 1, 10);
}

- (NSUInteger)numberOfPortraitColumns {
    NSUInteger orig = %orig;
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
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return orig;
    int kind = sbc_config_kind(self);
    if (kind == SBC_CFG_DOCK) {
        if (!prefBool(p, @"dockSpacingEnabled")) return orig;
        return UIEdgeInsetsMake(0.0, 16.0 + prefDouble(p, @"dockExL"),
                                0.0, 16.0 + prefDouble(p, @"dockExR"));
    }
    if (kind == SBC_CFG_ROOT) {
        if (!prefBool(p, @"homeSpacingEnabled")) return orig;
        UIEdgeInsets insets = UIEdgeInsetsMake(60.0 + prefDouble(p, @"homeExT"),
                                               27.0 + prefDouble(p, @"homeExL"),
                                               100.0 + prefDouble(p, @"homeExB"),
                                               27.0 + prefDouble(p, @"homeExR"));
        return constrained_grid_insets(insets,
            clampi((int)prefInt(p, @"hsCols"), 1, 10),
            clampi((int)prefInt(p, @"hsRows"), 1, 10),
            prefDouble(p, @"homeScale"), NO);
    }
    return orig;
}

- (SBIconImageInfo)iconImageInfo {
    SBIconImageInfo orig = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return orig;
    int kind = sbc_config_kind(self);
    if (kind != SBC_CFG_ROOT && kind != SBC_CFG_DOCK) return orig;
    if (kind == SBC_CFG_ROOT && !prefBool(p, @"homeScaleEnabled")) return orig;
    if (kind == SBC_CFG_DOCK && !prefBool(p, @"dockScaleEnabled")) return orig;
    double scale = kind == SBC_CFG_DOCK ? prefDouble(p, @"dockScale")
                                        : prefDouble(p, @"homeScale");
    if (scale <= 0.0 || scale > 2.0) return orig;
    return configured_icon_image_info(scale);
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
    return constrained_grid_insets(insets,
        clampi((int)prefInt(p, @"hsColsLandscape"), 1, 10),
        clampi((int)prefInt(p, @"hsRowsLandscape"), 1, 10),
        prefDouble(p, @"homeScale"), YES);
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

%group SpringBoard
%hook SBDockIconListModel
- (SBCGridSize)gridSize {
    SBCGridSize grid = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return grid;
    if (!prefBool(p, @"dockLayoutEnabled")) return grid;
    int dockIcons = clampi((int)prefInt(p, @"dockIcons"), 1, 8);
    if (grid.columns < dockIcons) grid.columns = (unsigned short)dockIcons;
    return grid;
}
%end
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
    double exL = prefDouble(p, @"homeExL"), exR = prefDouble(p, @"homeExR");
    double exT = prefDouble(p, @"homeExT"), exB = prefDouble(p, @"homeExB");
    double homeScale = prefDouble(p, @"homeScale");

    if (prefBool(p, @"homeGridEnabled") &&
        [cfg respondsToSelector:@selector(setNumberOfPortraitColumns:)]) {
        [cfg setNumberOfPortraitColumns:(NSUInteger)hsCols];
        if ([cfg respondsToSelector:@selector(setNumberOfPortraitRows:)])
            [cfg setNumberOfPortraitRows:(NSUInteger)hsRows];
    }
    if (prefBool(p, @"homeSpacingEnabled") &&
        [cfg respondsToSelector:@selector(setPortraitLayoutInsets:)])
        [cfg setPortraitLayoutInsets:UIEdgeInsetsMake(60.0 + exT, 27.0 + exL,
                                                    100.0 + exB, 27.0 + exR)];
    if (prefBool(p, @"homeScaleEnabled") &&
        homeScale > 0.0 && homeScale <= 2.0 &&
        [cfg respondsToSelector:@selector(setIconImageInfo:)])
        [cfg setIconImageInfo:configured_icon_image_info(homeScale)];
}

static void sbc_patch_dock_config(id dock) {
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled")) return;

    int dockIcons    = clampi((int)prefInt(p, @"dockIcons"), 1, 8);
    double dockExL   = prefDouble(p, @"dockExL");
    double dockExR   = prefDouble(p, @"dockExR");
    double dockScale = prefDouble(p, @"dockScale");

    id cfg = dock_layout_config(dock);
    if (prefBool(p, @"dockLayoutEnabled") &&
        [cfg respondsToSelector:@selector(setNumberOfPortraitColumns:)])
        [cfg setNumberOfPortraitColumns:(NSUInteger)dockIcons];
    if (prefBool(p, @"dockSpacingEnabled") &&
        [cfg respondsToSelector:@selector(setPortraitLayoutInsets:)])
        [cfg setPortraitLayoutInsets:UIEdgeInsetsMake(0.0, 16.0 + dockExL,
                                                    0.0, 16.0 + dockExR)];
    if (prefBool(p, @"dockScaleEnabled") &&
        dockScale > 0.0 && dockScale <= 2.0 &&
        [cfg respondsToSelector:@selector(setIconImageInfo:)])
        [cfg setIconImageInfo:configured_icon_image_info(dockScale)];
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
// Live single-key read through CFPreferences (the same channel the Settings
// pane writes through), unlike the cached sbc_prefs() used by the layout
// hooks — the cached value could be stale or not yet flushed by cfprefsd,
// which made the integrated version fail where the unconditional standalone
// tweak worked. The feature switches are self-contained: they are NOT gated
// by the master "enabled" switch.

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
    CGAffineTransform base = baseValue ? [baseValue CGAffineTransformValue] : current;

    // If SpringBoard legitimately replaced the transform (rather than merely
    // laying out the center again), adopt that as the new stock transform.
    if (lastTransformValue &&
        !CGAffineTransformEqualToTransform(current,
                                           [lastTransformValue CGAffineTransformValue]))
        base = current;

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
    (void)lastOffsetValue;
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
// Reject the gesture everywhere while passcode authentication is on screen,
// including empty areas outside the keypad itself. This walks the whole
// window, so it runs once per recognized double-tap rather than per touch.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
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
    if (!prefBool(p, @"enabled")) return;
    if (!prefBool(p, @"dragCoefficientEnabled")) return;
    double v = sbc_pref_double_live(CFSTR("dragCoefficient"));
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

%group SpringBoard
%hook SBScreenWakeAnimationController
- (id)_animationSettingsForBacklightChangeSource:(long long)source isWake:(BOOL)wake {
    if (wake != sbt_transition_is_wake)
        NSLog(@"[SBT:WAKE] transition -> %s (src=%lld)", wake ? "wake" : "sleep", source);
    sbt_transition_is_wake = wake;
    return %orig(source, wake);
}

- (double)backlightFadeDuration {
    if (sbt_transition_is_wake)
        return sbc_pref_bool_live(CFSTR("noWakeAnim")) ? 0 : %orig;
    return sbc_pref_bool_live(CFSTR("noSleepFade")) ? 0 : %orig;
}
%end
%end

%group SpringBoard
%hook SBFWakeAnimationSettings
- (double)backlightFadeDuration {
    if (sbt_transition_is_wake)
        return sbc_pref_bool_live(CFSTR("noWakeAnim")) ? 0 : %orig;
    return sbc_pref_bool_live(CFSTR("noSleepFade")) ? 0 : %orig;
}
- (double)speedMultiplierForWake {
    return sbc_pref_bool_live(CFSTR("noWakeAnim")) ? 1000 : %orig;
}
- (double)speedMultiplierForLiftToWake {
    return sbc_pref_bool_live(CFSTR("noWakeAnim")) ? 1000 : %orig;
}
%end
%end

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
//   bit 2        Load into app extensions (share sheet, widgets, ...)
//   bits 16-31   Fast Page Transitions duration in ms (0 = off)

static const char *const kSBTAppStateName = "cz.kolbi.sbtweaker/appState";
#define SBT_APP_FAST_COPY          (1ULL << 0)
#define SBT_APP_DISMISS_SPOTLIGHT  (1ULL << 1)
#define SBT_APP_EXTENSIONS         (1ULL << 2)
#define SBT_APP_SLIDE_SHIFT        16
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

// Same value, cached for hooks that run on every animation. Refreshed on the
// main queue whenever SpringBoard republishes.
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
    if (sbc_pref_bool_live(CFSTR("extensionsEnabled"))) state |= SBT_APP_EXTENSIONS;
    if (sbc_pref_bool_live(CFSTR("noSlide"))) {
        double d = MIN(kNSMaxDuration, MAX(kNSMinDuration, sbc_pref_double_live(CFSTR("noSlideDuration"))));
        state |= (uint64_t)llround(d * 1000.0) << SBT_APP_SLIDE_SHIFT;
    }
    notify_set_state(token, state);
    notify_post(kSBTAppStateName);
}

// Fast Copy: show the copy/paste callout bar immediately instead of after
// UIKit's built-in delay (its appear/disappear animation is removed by the
// CALayer hook below). Inspired by the classic Fast Copy tweak. Fires in
// SpringBoard and every app; the switch comes from the published app state.
%group FastCopy
%hook UITextSelectionView
- (void)showCalloutBarAfterDelay:(double)arg1 {
    %orig((sbt_app_state() & SBT_APP_FAST_COPY) ? 0 : arg1);
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

// Target duration in seconds, or 0 when the option is off (or the state
// cannot be read, in which case nothing changes).
static double ns_targetDuration(void) {
    uint64_t ms = (sbt_app_state() >> SBT_APP_SLIDE_SHIFT) & 0xFFFF;
    if (ms == 0) return 0;
    return MIN(kNSMaxDuration, MAX(kNSMinDuration, ms / 1000.0));
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
    CFTimeInterval active = anim.duration / anim.speed;
    if (active > target) anim.speed = (float)(anim.duration / target);
    // Drop delays too. A delayed animation (e.g. a navigation bar fade that
    // starts a little after the slide) otherwise shows its from-state until
    // the delay runs out — a one-frame flash once everything else is quick.
    // Delays inside a group are scaled by the group's speed already.
    if (anim.beginTime > 0) anim.beginTime = 0;
    anim.timeOffset = 0;
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
    if (anim && [NSThread isMainThread]) {
        if (ns_clamping)
            ns_clampAnimation(anim, ns_clampDuration);
        else if ((sbt_cached_app_state & SBT_APP_FAST_COPY) && sbt_layer_in_edit_menu(self))
            ns_clampAnimation(anim, kSBTMenuDuration);
    }
    %orig;
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
    return (sbt_app_state() & SBT_APP_DISMISS_SPOTLIGHT) != 0;
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
    BOOL searchOnScreen = sbt_is_springboard &&
                          sbt_dismiss_spotlight_enabled() &&
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

static void sbc_apply(void) {
    NSDictionary *p = sbc_reload_prefs(); // refresh the cache used by the configuration getter hooks
    if (!prefBool(p, @"enabled")) { NSLog(@"[SBC] disabled"); return; }

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

    id iconCtrl = [%c(SBIconController) sharedInstance];
    if (!iconCtrl) { NSLog(@"[SBC] SBIconController missing"); return; }
    id mgr = [iconCtrl iconManager];

    if (prefBool(p, @"dockLayoutEnabled"))
        patch_dock(iconCtrl, mgr, dockIcons);

    id cfg = root_layout_config(iconCtrl, mgr);
    if (cfg && prefBool(p, @"homeGridEnabled"))
        patch_homescreen_grid(iconCtrl, mgr, cfg, hsCols, hsRows);
    else if (!cfg) NSLog(@"[SBC] root layoutConfiguration nil");

    id dock = dock_list_view(iconCtrl, mgr);
    id dockCfg = dock_layout_config(dock);

    if (prefBool(p, @"homeSpacingEnabled"))
        apply_home_spacing(cfg, homeExL, homeExR, homeExT, homeExB);
    if (prefBool(p, @"dockSpacingEnabled"))
        apply_dock_spacing(dockCfg, dockExL, dockExR);
    if (prefBool(p, @"homeScaleEnabled") && homeScale > 0.0)
        apply_home_scale(mgr, cfg, homeScale);
    if (prefBool(p, @"dockScaleEnabled") && dockScale > 0.0)
        apply_dock_scale(dock, dockCfg, dockScale);

    // Re-run the indicator offset against the new preferences.
    id rootFolder = [mgr respondsToSelector:@selector(rootFolderController)]
        ? [mgr rootFolderController] : nil;
    UIView *rootFolderView = [rootFolder respondsToSelector:@selector(rootFolderView)]
        ? [rootFolder rootFolderView] : nil;
    [rootFolderView setNeedsLayout];

    sbc_apply_drag_coefficient();

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
    // need none of this. App extensions (share sheet, widgets, iMessage apps)
    // load the hooks only while "App Extensions" is on; an extension process
    // usually starts fresh each time it opens, so the switch applies on the
    // next open.
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleID = bundle.bundleIdentifier;
    if (!bundleID) return;
    if ([bundle.bundlePath hasSuffix:@".appex"] &&
        !(sbt_app_state() & SBT_APP_EXTENSIONS)) return;
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
    sbc_install_landscape_hooks();
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
