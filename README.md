# SBTweaker

A collection of SpringBoard tweaks in a single package, with a preference
bundle. It supports rootless and roothide jailbreaks on iOS 15 and newer.
These are in-process Substrate-hook reimplementations of my
[DarkSword Tweaks](https://github.com/kolbicz/DarkSword-Tweaks/).

## Features

- **Dock**: configurable icon count (4–7), including live capacity updates
  so newly enabled slots can be filled without a respring
- **Home Screen grid**: configurable columns (3–8) and rows (4–8), set
  independently for portrait and landscape (landscape only affects rotating
  Home Screens, i.e. iPad)
- **Spacing**: shared portrait/landscape Home Screen insets, plus dock spacing
- **Icon scale**: separate Home Screen and Dock scaling; the Home value applies
  in portrait and landscape
- **Hide App Library**: removes the App Library page
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
  - Faster Core Animation (clamps Core Animation durations and disables
    implicit animations — also inside apps)
  - Fast Copy (the copy/paste menu appears instantly — also inside apps)

All settings live in Settings → SBTweaker. Every feature is opt-in and off by
default; enabling the master switch alone changes nothing. Layout controls
apply live, and a respring button is included for changes that need one.

## Version 1.3

- Added independent, off-by-default gates for every layout or animation value.
- Added live Dock capacity updates for 4–7 icons without requiring a respring.
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
