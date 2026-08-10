# SBTweaker

A collection of SpringBoard tweaks in a single package, with a preference
bundle. It supports rootless and roothide jailbreaks on iOS 15 and newer.
These are in-process Substrate-hook reimplementations of my
[DarkSword Tweaks](https://github.com/kolbicz/DarkSword-Tweaks/).

## Features

- **Dock**: configurable icon count (4–7), plus optional restore of extra dock
  icons across resprings and icon-state validation
- **Home Screen grid**: configurable columns (3–8) and rows (4–8), set
  independently for portrait and landscape (landscape only affects rotating
  Home Screens, i.e. iPad)
- **Spacing**: extra portrait and landscape layout insets for the Home Screen,
  plus dock spacing
- **Icon scale**: separate Home Screen, landscape Home Screen, and dock scaling
- **Hide App Library**: removes the App Library page
- **Double Tap to Lock**: separate switches for Home Screen and Lock Screen
  (ignores icons, folders, dock and the passcode pad)
- **Animations**:
  - Drag Coefficient slider (UIAnimationDragCoefficient, 0.01–2.00,
    default 0.25; 1.0 = stock, leaves the system value untouched)
  - Disable Wake Animation (screen on)
  - Disable Screen Off Fade (screen off)
  - Disable Unlock Icon Fly-In
  - Faster Core Animation (clamps Core Animation durations and disables
    implicit animations — also inside apps)
  - Fast Copy (the copy/paste menu appears instantly — also inside apps)

All settings live in Settings → SBTweaker. The master switch disables every
feature. Changes take effect after a respring (a respring button is included);
the animation switches update within about one second.

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

## License

MIT — see [LICENSE](LICENSE). Fork, modify and recompile as you like.
