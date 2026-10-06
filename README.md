# SBTweaker

A collection of SpringBoard tweaks in a single package, with a preference
bundle. It supports rootless and roothide jailbreaks on iOS 15 and newer.
These are in-process Substrate-hook reimplementations of my
[DarkSword Tweaks](https://github.com/kolbicz/DarkSword-Tweaks/).

## Features

- **Dock**: configurable icon count (1–8), including live capacity updates
  so newly enabled slots can be filled without a respring
- **Home Screen grid**: configurable columns and rows (1–10), set
  independently for portrait and landscape (landscape only affects rotating
  Home Screens, i.e. iPad)
- **Spacing**: independent portrait and landscape Home Screen insets, plus
  independent left and right dock spacing
- **Icon scale**: separate Home Screen and Dock scaling; the Home value applies
  in portrait and landscape
- **Hide App Library**: removes the App Library page
- **Spotlight**: optionally dismisses Spotlight and clears its search field
  when you open a result, so leaving that app returns to the Home Screen
  instead of the search you came from
- **Lock Screen Timeout**: hold the Lock Screen awake longer before it dims and
  sleeps (5–300s, capped by Auto-Lock)
- **Page & Search Indicator**: opt-in portrait and landscape X/Y offsets for the
  Home Screen page dots or Search indicator
- **Double Tap to Lock**: separate switches for Home Screen and Lock Screen
  (ignores icons, folders and dock, and is disabled while passcode UI is shown)
- **Icon Layout Backup**: opt-in automatic backup on native icon-state changes
  and guarded restore of Home Screen, folders and Dock after rejailbreaking
- **Animations**:
  - Drag Coefficient slider (UIAnimationDragCoefficient, 0.01–2.00,
    default 1.0; 1.0 = stock, leaves the system value untouched)
  - Disable Wake Animation (screen on)
  - Disable Screen Off Fade (screen off)
  - Disable Unlock Icon Fly-In
  - Fast Copy (the copy/paste menu appears instantly — also inside apps)
- **Page Transitions**: Fast Page Transitions with Transition Duration
  (0.01–1.00 s, default 0.01 = instant) speeds up the slide when an app opens a
  new page or goes back, including app-provided transitions; swipe-back is
  unchanged and changes apply without a respring

All settings live in Settings → SBTweaker. Every feature is opt-in and off by
default; enabling the master switch alone changes nothing. Layout controls
apply live, and a respring button is included for changes that need one.

## Version 1.3.7

- Fast Copy also makes the copy/paste menu's own animations instant: any
  animation added inside `UICalloutBar` (iOS 15) or `_UIEditMenuContainerView`
  / `_UIEditMenuListView` (iOS 16+) is sped up, independent of the
  presentation methods, which differ per iOS version.
- Fast Copy and the Spotlight option now work in sandboxed apps. Their
  switches, together with Fast Page Transitions, reach apps as one 64-bit
  Darwin notification state that SpringBoard republishes at launch and on
  every change, since sandboxed processes cannot read the preferences domain.
- The respring notification is honoured only together with a fresh request
  timestamp that the Settings pane writes to the preferences domain, so
  other apps can no longer trigger a respring.
- Missing preference keys fall back to `SBTDefaults.h` in the tweak as well.
- SpringBoard-only hooks moved into their own group, and daemons without a
  bundle get no hooks at all. App extensions load the app-side hooks only
  while the new Apply in App Extensions switch is on (default); the extension
  reads that bit from the published app state in its constructor.
- The Lock Screen double-tap checks for passcode UI only when a double-tap is
  recognized, and configs identified as neither Home Screen nor Dock are
  cached so their getters skip the layout provider.
- `%orig` is no longer used inside argument lists, which the roothide Theos
  fork's Logos expands incorrectly.

## Version 1.3.6

- Added an opt-in Fast Page Transitions option. Instead of forcing
  `animated:NO`, which breaks apps that set up their back controls during the
  transition, the push/pop still runs as an animated transition and the
  Core Animation animations added for it are sped up to fit Transition
  Duration.
  Sandboxed apps cannot read the preferences domain, so SpringBoard publishes
  the value as a Darwin notification state that apps read per transition.
- Removed Faster Core Animation. Fast Page Transitions replaces it inside
  apps, where it usually could not read its setting anyway, and its blanket
  disabling of implicit animations could break controls.

## Version 1.3.5

- Added an opt-in Lock Screen Timeout option. SpringBoard floors every
  lock-screen idle descriptor with `minimumLockscreenIdleTime`, so raising that
  one value covers each state — before and after Face ID, notifications shown,
  Siri — and applies on the next lock without a respring. Auto-Lock still caps
  the total.
- Added opt-in page dots / Search indicator offsets, applied as a view
  transform so SpringBoard's own centre updates do not undo them.
- Widened the Dock icon count to 1-8 and split Dock spacing into independent
  left and right values, migrating any existing combined value to both.

## Version 1.3.4

- Added an opt-in Spotlight option that dismisses the search page and clears
  its query when a result is opened, so leaving that app returns to the Home
  Screen instead of the previous search.
- Fixed the icon layout backup path on roothide: the snapshot is kept inside
  the randomized jailbreak root instead of the shared mobile container, where
  sandboxed and non-roothide apps could read it.

## Version 1.3.3

- Fixed custom Home Screen rows and columns reverting to stock when widgets
  are present on iOS/iPadOS 15.
- Added support for the widget-specific `SBIconLocationRootWithWidgets` layout
  used by SpringBoard.
- Preserved existing widgets across resprings by no longer rewriting Home
  Screen model grid state; custom sizing now uses layout metrics only.

## Version 1.3.2

- Fixed SpringBoard hanging during respring on iOS/iPadOS 15 by removing
  synchronous preference writes and migration from early SpringBoard startup.
- Replaced class-based injection with explicit SpringBoard, UIKit and UIKitCore
  bundle filters for compatibility across iOS 15–17.
- Expanded Home Screen grid rows and columns to 1–10.
- Expanded Dock capacity to 8 icons.
- Expanded left/right spacing to 160, top spacing to 200 and bottom spacing to
  400 in portrait and landscape.

## Version 1.3.1

- Moved Home Screen grid and spacing controls into one dedicated submenu.
- Restored independent landscape spacing values.
- Added separate grid and spacing enable switches for portrait and landscape.
- Aligned numeric sliders using a consistent label column.
- Fixed injection into UIKit application processes for the existing Faster
  Core Animation and Fast Copy features.

## Version 1.3

- Added independent, off-by-default gates for every layout or animation value.
- Added live Dock capacity updates without requiring a respring.
- Added device-aware stock grid defaults and non-destructive preference
  migrations that preserve existing settings.
- Unified Home Screen spacing and scaling across portrait and landscape while
  retaining independent portrait/landscape row and column counts.
- Fixed first-frame icon sizing and spacing during respring; removed the old
  delayed layout application.
- Fixed absolute, idempotent Home and Dock icon scaling.
- Improved Home Screen double-tap handling and prevented double-tap-to-lock
  while the passcode interface is visible.
- Added automatic icon-layout backup while jailbroken and guarded restoration
  when jailbroken SpringBoard returns.
- Removed the unreliable Spotlight dismissal/clearing experiment.

## Building

### Rootless

The default build uses standard Theos from `~/theos`, the rootless package
scheme, and an iOS 15.6 SDK with an iOS 15.0 deployment target:

```sh
make package FINALPACKAGE=1
```

### Roothide

With the roothide Theos fork installed at `~/roothide-theos` and its iOS 16.5
SDK, build the roothide variant with:

```sh
make clean package FINALPACKAGE=1 \
  THEOS="$HOME/roothide-theos" \
  TARGET=iphone:clang:16.5:15.0 \
  THEOS_PACKAGE_SCHEME=roothide
```

Both `.deb` files land in `packages/`. The rootless build uses the
`iphoneos-arm64` architecture and the roothide build uses `iphoneos-arm64e`.

## Credits

- [DarkSword Tweaks](https://github.com/kolbicz/DarkSword-Tweaks/) — my
  tweak collection, implemented by [cyanide](https://github.com/0xjohnnydev/cyanide);
  this package reimplements them as in-process substrate hooks.
- SBCustomizer (from [cyanide](https://github.com/0xjohnnydev/cyanide)) —
  used as the starting point for this project.
- [Speedster](https://github.com/Hoangdus/Speedster/) — reference for the
  wake/sleep animation settings (backlightFadeDuration vs.
  speedMultiplierForWake mapping).
- Fast Copy — inspiration for the instant copy/paste menu
  ([idownloadblog](https://www.idownloadblog.com/2010/10/25/fast-copy-speeds-up-your-iphones-copy-and-paste-functionality/)).
- [IconRestore](https://github.com/OwnGoalStudio/IconRestore) by
  [OwnGoalStudio](https://github.com/OwnGoalStudio) — reference for guarding
  SpringBoard's native icon-state saves while restoring a preserved layout.

## License

MIT — see [LICENSE](LICENSE). Fork, modify and recompile as you like.
