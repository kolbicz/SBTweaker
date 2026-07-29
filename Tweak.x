#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdint.h>
#import <stdbool.h>
#import <math.h>

// SBTweaker — injection-tweak conversions of cyanide tweaks, all running
// inside SpringBoard on the main thread (no RemoteCall plumbing):
//  - sbcustomizer.m: home grid / dock size / labels
//  - darksword_layout.m: spacing & icon scaling
//  - darksword disable_app_library(): hide App Library
//  - darksword_tweaks.m double-tap-to-lock: home & lock screen gestures
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

static CFStringRef const kPrefsDomain = CFSTR("cz.kolbi.sbtweaker");
static CFStringRef const kApplyNotification = CFSTR("cz.kolbi.sbtweaker/apply");

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
        if ([cfg respondsToSelector:@selector(setNumberOfLandscapeColumns:)])
            [cfg setNumberOfLandscapeColumns:(NSUInteger)rows];
        if ([cfg respondsToSelector:@selector(setNumberOfLandscapeRows:)])
            [cfg setNumberOfLandscapeRows:(NSUInteger)cols];
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

static SBIconImageInfo scaled_icon_image_info(double scale) {
    SBIconImageInfo info;
    info.size = CGSizeMake(60.0 * scale, 60.0 * scale);
    info.scale = 2.0;
    info.continuousCornerRadius = 13.5 * scale;
    return info;
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
    if (scale <= 0.0 || scale > 2.0) return;
    SBIconImageInfo info = scaled_icon_image_info(scale);
    if ([cfg respondsToSelector:@selector(setIconImageInfo:)])
        [cfg setIconImageInfo:info];

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
    if (scale <= 0.0 || scale > 2.0 || !dock) return;
    SBIconImageInfo info = scaled_icon_image_info(scale);
    if ([dockCfg respondsToSelector:@selector(setIconImageInfo:)])
        [dockCfg setIconImageInfo:info];
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
    return sbc_cachedPrefs;
}

static NSDictionary *sbc_prefs(void) {
    if (!sbc_cachedPrefs) sbc_reload_prefs();
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
    if (!prefBool(p, @"enabled", YES)) return orig;
    if (sbc_config_kind(self) != SBC_CFG_ROOT) return orig;
    return (NSUInteger)clampi((int)prefInt(p, @"hsRows", 6), 4, 8);
}

- (NSUInteger)numberOfPortraitColumns {
    NSUInteger orig = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", YES)) return orig;
    int kind = sbc_config_kind(self);
    // Fallback for the dock only: identity lookup can fail during boot (the
    // provider chain may not be up when icon-state validation first asks),
    // which used to cost us the 5th dock icon. A single-row, 4-wide grid is
    // unambiguous enough — the App Library breakage came from the *home*
    // branch matching everything, and that branch stays identity-only.
    // Gated by restoreDockIcons — this fallback exists purely to survive
    // boot-time icon-state validation.
    if (kind == SBC_CFG_UNKNOWN && prefBool(p, @"restoreDockIcons", YES) &&
        orig == 4 && [self numberOfPortraitRows] == 1) {
        static BOOL logged = NO;
        if (!logged) { logged = YES; NSLog(@"[SBC] dock config identified by 1-row fallback"); }
        kind = SBC_CFG_DOCK;
    }
    if (kind == SBC_CFG_DOCK)
        return (NSUInteger)clampi((int)prefInt(p, @"dockIcons", 5), 4, 7);
    if (kind == SBC_CFG_ROOT)
        return (NSUInteger)clampi((int)prefInt(p, @"hsCols", 5), 3, 7);
    return orig;
}

- (UIEdgeInsets)portraitLayoutInsets {
    UIEdgeInsets orig = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", YES)) return orig;
    int kind = sbc_config_kind(self);
    if (kind == SBC_CFG_DOCK) {
        double h = prefDouble(p, @"dockExH", 30.0);
        return UIEdgeInsetsMake(0.0, 16.0 + h, 0.0, 16.0 + h);
    }
    if (kind == SBC_CFG_ROOT) {
        return UIEdgeInsetsMake(60.0 + prefDouble(p, @"homeExT", 40.0),
                                27.0 + prefDouble(p, @"homeExL", 20.0),
                                100.0 + prefDouble(p, @"homeExB", 180.0),
                                27.0 + prefDouble(p, @"homeExR", 20.0));
    }
    return orig;
}

- (SBIconImageInfo)iconImageInfo {
    SBIconImageInfo orig = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", YES)) return orig;
    int kind = sbc_config_kind(self);
    if (kind != SBC_CFG_ROOT && kind != SBC_CFG_DOCK) return orig;
    double scale = kind == SBC_CFG_DOCK ? prefDouble(p, @"dockScale", 0.98)
                                        : prefDouble(p, @"homeScale", 0.98);
    if (scale <= 0.0 || scale > 2.0) return orig;
    return scaled_icon_image_info(scale);
}
%end

%hook SBDockIconListModel
- (SBCGridSize)gridSize {
    SBCGridSize grid = %orig;
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", YES)) return grid;
    if (!prefBool(p, @"restoreDockIcons", YES)) return grid;
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
    if (!prefBool(p, @"enabled", YES)) return;

    int hsCols       = clampi((int)prefInt(p, @"hsCols", 5), 3, 7);
    int hsRows       = clampi((int)prefInt(p, @"hsRows", 6), 4, 8);
    double exL = prefDouble(p, @"homeExL", 20.0), exR = prefDouble(p, @"homeExR", 20.0);
    double exT = prefDouble(p, @"homeExT", 40.0), exB = prefDouble(p, @"homeExB", 180.0);
    double homeScale = prefDouble(p, @"homeScale", 0.98);

    if ([cfg respondsToSelector:@selector(setNumberOfPortraitColumns:)]) {
        [cfg setNumberOfPortraitColumns:(NSUInteger)hsCols];
        if ([cfg respondsToSelector:@selector(setNumberOfPortraitRows:)])
            [cfg setNumberOfPortraitRows:(NSUInteger)hsRows];
        if ([cfg respondsToSelector:@selector(setNumberOfLandscapeColumns:)])
            [cfg setNumberOfLandscapeColumns:(NSUInteger)hsRows];
        if ([cfg respondsToSelector:@selector(setNumberOfLandscapeRows:)])
            [cfg setNumberOfLandscapeRows:(NSUInteger)hsCols];
    }
    if ([cfg respondsToSelector:@selector(setPortraitLayoutInsets:)])
        [cfg setPortraitLayoutInsets:UIEdgeInsetsMake(60.0 + exT, 27.0 + exL,
                                                    100.0 + exB, 27.0 + exR)];
    if (homeScale > 0.0 && homeScale <= 2.0 && [cfg respondsToSelector:@selector(setIconImageInfo:)])
        [cfg setIconImageInfo:scaled_icon_image_info(homeScale)];
}

static void sbc_patch_dock_config(id dock) {
    NSDictionary *p = sbc_prefs();
    if (!prefBool(p, @"enabled", YES)) return;

    int dockIcons    = clampi((int)prefInt(p, @"dockIcons", 5), 4, 7);
    double dockExH   = prefDouble(p, @"dockExH", 30.0);
    double dockScale = prefDouble(p, @"dockScale", 0.98);

    id cfg = dock_layout_config(dock);
    if ([cfg respondsToSelector:@selector(setNumberOfPortraitColumns:)])
        [cfg setNumberOfPortraitColumns:(NSUInteger)dockIcons];
    if ([cfg respondsToSelector:@selector(setPortraitLayoutInsets:)])
        [cfg setPortraitLayoutInsets:UIEdgeInsetsMake(0.0, 16.0 + dockExH,
                                                    0.0, 16.0 + dockExH)];
    if (dockScale > 0.0 && dockScale <= 2.0 && [cfg respondsToSelector:@selector(setIconImageInfo:)])
        [cfg setIconImageInfo:scaled_icon_image_info(dockScale)];
}

%hook SBHIconManager
- (id)listLayoutProvider {
    id provider = %orig;
    id layout = [provider respondsToSelector:@selector(layoutForIconLocation:)]
                ? [provider layoutForIconLocation:@"SBIconLocationRoot"] : nil;
    id cfg = [layout respondsToSelector:@selector(layoutConfiguration)] ? [layout layoutConfiguration] : nil;
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
    CFTypeRef v = CFPreferencesCopyAppValue(key, kPrefsDomain);
    BOOL r = def;
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue(v);
        else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            int n = 0;
            CFNumberGetValue(v, kCFNumberIntType, &n);
            r = (n != 0);
        }
        CFRelease(v);
    }
    return r;
}

static double sbc_pref_double_live(CFStringRef key, double def) {
    CFTypeRef v = CFPreferencesCopyAppValue(key, kPrefsDomain);
    double r = def;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID())
            CFNumberGetValue(v, kCFNumberDoubleType, &r);
        CFRelease(v);
    }
    return r;
}

static BOOL sbc_hide_app_library(void) {
    BOOL hide = sbc_pref_bool_live(CFSTR("hideAppLibrary"), YES);
    static BOOL logged = NO;
    if (!logged) { logged = YES; NSLog(@"[SBC:APPLIB] hideAppLibrary=%d", hide); }
    return hide;
}

// The class is SBRootFolderController on some iOS versions and
// SBHRootFolderController on others — hook whichever exists (a hook on an
// absent class/method simply never fires).
%hook SBRootFolderController
- (NSArray *)trailingCustomViewControllers {
    return sbc_hide_app_library() ? @[] : %orig;
}
%end

%hook SBHRootFolderController
- (NSArray *)trailingCustomViewControllers {
    return sbc_hide_app_library() ? @[] : %orig;
}
%end

%hook SBRootFolderView
- (NSArray *)trailingCustomViewControllers {
    return sbc_hide_app_library() ? @[] : %orig;
}
%end

%hook SBHRootFolderView
- (NSArray *)trailingCustomViewControllers {
    return sbc_hide_app_library() ? @[] : %orig;
}
%end

// Absent on some versions — the hook then simply never fires.
%hook SBIconController
- (BOOL)isAppLibrarySupported {
    return sbc_hide_app_library() ? NO : %orig;
}
%end

// Belt and braces for state captured before the hooks were installed: clear
// the ivars directly, like the original disable_app_library() did.
static void sbc_poke_trailing(id obj) {
    if (!obj) return;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), "_trailingCustomViewControllers");
    if (iv) {
        object_setIvar(obj, iv, [NSArray array]);
        NSLog(@"[SBC:APPLIB] cleared _trailingCustomViewControllers on %@", object_getClass(obj));
    }
}

static void sbc_disable_app_library(void) {
    if (!sbc_hide_app_library()) return;
    id iconCtrl = [%c(SBIconController) sharedInstance];
    if (!iconCtrl) return;
    id mgr = [iconCtrl respondsToSelector:@selector(iconManager)] ? [iconCtrl iconManager] : nil;
    id rootFC = [mgr respondsToSelector:@selector(rootFolderController)] ? [mgr rootFolderController] : nil;
    if (!rootFC) return;

    sbc_poke_trailing(rootFC);

    id rootView = [rootFC respondsToSelector:@selector(rootFolderView)] ? [rootFC rootFolderView] : nil;
    if (rootView) sbc_poke_trailing(rootView);
}

// -------------------------------------------------------- Double-tap to lock
//
// Integrated from the standalone DoubleTapLock tweak (itself a conversion of
// darksword_tweak_double_tap_to_lock_in_session() from cyanide). The two
// behavioral details are kept:
//  1. Home screen: a transparent, backmost "catcher" view per icon list page,
//     so taps on icons/dock never reach the recognizer (an accidental second
//     tap after launching an app must not lock the device).
//  2. Lock screen: recognizer on the cover sheet main page view only — the
//     passcode window is deliberately excluded.
// Each area has its own switch (dtlHomeScreen / dtlLockScreen), read live;
// since recognizers are installed when the views appear, changes fully take
// effect after a respring.

@interface SBIconListView : UIView
- (BOOL)isDock;
@end

@interface CSMainPageContentViewController : UIViewController
@end

static char kDTLockCatcherKey;
static char kDTLockGestureKey;

static UITapGestureRecognizer *dtl_makeRecognizer(void) {
    UITapGestureRecognizer *gr = [[UITapGestureRecognizer alloc]
        initWithTarget:[%c(SpringBoard) sharedApplication]
                action:@selector(_simulateLockButtonPress)];
    gr.numberOfTapsRequired = 2;
    gr.cancelsTouchesInView = NO;
    gr.delaysTouchesBegan = NO;
    return gr;
}

%hook SBIconListView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    if (!sbc_pref_bool_live(CFSTR("dtlHomeScreen"), YES)) return;

    NSString *cls = NSStringFromClass([self class]);
    if (![cls containsString:@"IconListView"]) return;
    if ([cls containsString:@"Dock"] || [cls containsString:@"Folder"]) return;
    if ([self respondsToSelector:@selector(isDock)] && [self isDock]) return;

    if (objc_getAssociatedObject(self, &kDTLockCatcherKey)) return;

    UIView *catcher = [[UIView alloc] initWithFrame:self.bounds];
    catcher.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    catcher.userInteractionEnabled = YES;
    [self insertSubview:catcher atIndex:0];
    [catcher addGestureRecognizer:dtl_makeRecognizer()];

    objc_setAssociatedObject(self, &kDTLockCatcherKey, catcher, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
%end

%hook CSMainPageContentViewController
- (void)viewDidLoad {
    %orig;
    if (!sbc_pref_bool_live(CFSTR("dtlLockScreen"), YES)) return;
    UIView *v = self.view;
    if (!v) return;
    if (objc_getAssociatedObject(v, &kDTLockGestureKey)) return;

    UITapGestureRecognizer *gr = dtl_makeRecognizer();
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
    if (!prefBool(p, @"enabled", YES)) return;
    double v = sbc_pref_double_live(CFSTR("dragCoefficient"), 0.25);
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
        return sbc_pref_bool_live(CFSTR("noWakeAnim"), YES) ? 0 : %orig;
    return sbc_pref_bool_live(CFSTR("noSleepFade"), YES) ? 0 : %orig;
}
%end

%hook SBFWakeAnimationSettings
- (double)backlightFadeDuration {
    if (sbt_transition_is_wake)
        return sbc_pref_bool_live(CFSTR("noWakeAnim"), YES) ? 0 : %orig;
    return sbc_pref_bool_live(CFSTR("noSleepFade"), YES) ? 0 : %orig;
}
- (double)speedMultiplierForWake {
    return sbc_pref_bool_live(CFSTR("noWakeAnim"), YES) ? 1000 : %orig;
}
- (double)speedMultiplierForLiftToWake {
    return sbc_pref_bool_live(CFSTR("noWakeAnim"), YES) ? 1000 : %orig;
}
%end

%hook CSCoverSheetTransitionSettings
- (void)setIconsFlyIn:(bool)arg1 {
    %orig(sbc_pref_bool_live(CFSTR("noIconsFlyIn"), YES) ? NO : arg1);
}
%end

// ------------------------------------------------------------------ entry

static void sbc_apply(void) {
    NSDictionary *p = sbc_reload_prefs(); // refresh the cache used by the configuration getter hooks
    if (!prefBool(p, @"enabled", YES)) { NSLog(@"[SBC] disabled"); return; }

    int dockIcons    = clampi((int)prefInt(p, @"dockIcons", 5), 4, 7);
    int hsCols       = clampi((int)prefInt(p, @"hsCols", 5), 3, 7);
    int hsRows       = clampi((int)prefInt(p, @"hsRows", 6), 4, 8);
    double homeExL   = prefDouble(p, @"homeExL", 20.0);
    double homeExR   = prefDouble(p, @"homeExR", 20.0);
    double homeExT   = prefDouble(p, @"homeExT", 40.0);
    double homeExB   = prefDouble(p, @"homeExB", 180.0);
    double dockExH   = prefDouble(p, @"dockExH", 30.0);
    double homeScale = prefDouble(p, @"homeScale", 0.98);
    double dockScale = prefDouble(p, @"dockScale", 0.98);

    NSLog(@"[SBC] apply dock=%d hs=%dx%d space=+%.0f/%.0f/%.0f/%.0f dockH=%.0f scale=%.2f/%.2f",
          dockIcons, hsCols, hsRows,
          homeExL, homeExR, homeExT, homeExB, dockExH, homeScale, dockScale);

    id iconCtrl = [%c(SBIconController) sharedInstance];
    if (!iconCtrl) { NSLog(@"[SBC] SBIconController missing"); return; }
    id mgr = [iconCtrl iconManager];

    patch_dock(iconCtrl, mgr, dockIcons);

    id cfg = root_layout_config(iconCtrl, mgr);
    if (cfg) patch_homescreen_grid(iconCtrl, mgr, cfg, hsCols, hsRows);
    else NSLog(@"[SBC] root layoutConfiguration nil");

    id dock = dock_list_view(iconCtrl, mgr);
    id dockCfg = dock_layout_config(dock);

    apply_home_spacing(cfg, homeExL, homeExR, homeExT, homeExB);
    apply_dock_spacing(dockCfg, dockExH);
    if (homeScale > 0.0) apply_home_scale(mgr, cfg, homeScale);
    if (dockScale > 0.0) apply_dock_scale(dock, dockCfg, dockScale);

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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sbc_apply();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sbc_apply_drag_coefficient();
    });
    // App Library poke: retry a few times, rootFolderView may not exist yet
    // early on. No-ops unless hideAppLibrary is enabled.
    for (int delay = 2; delay <= 10; delay += 4) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sbc_disable_app_library();
        });
    }
}
%end

// Single source of truth: these defaults are written into the settings plist
// for any key that has no stored value yet, at SpringBoard start (and also by
// the settings pane when it opens). Everything then reads them through
// CFPreferences — the literal fallbacks in the pref helpers are only a last
// resort if a key is missing entirely. Existing user values are never
// overwritten.
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

// Bump kSBTDefaultsVersion to force every install onto the defaults once
// (e.g. after shipping a bad default). Existing user values are otherwise
// never touched.
static NSInteger const kSBTDefaultsVersion = 3;

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
    sbc_seed_defaults();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, sbc_apply_notification,
                                    kApplyNotification, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, sbc_respring_notification,
                                    CFSTR("cz.kolbi.sbtweaker/respring"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
