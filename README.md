# SBTweaker

A collection of SpringBoard tweaks in a single package, with a preference
bundle. These are reimplementations of my
[DarkSword Tweaks](https://github.com/kolbicz/DarkSword-Tweaks/) for the
[Relaxin jailbreak](https://relaxin.owngoal.dev/) (iOS 17.0 – 17.3.1),
converted from out-of-process RemoteCall code to classic in-process
substrate hooks.

## Features

- **Dock**: configurable icon count (4–7), plus optional restore of extra dock
  icons across resprings and icon-state validation
- **Home Screen grid**: configurable columns (3–7) and rows (4–8)
- **Spacing**: extra layout insets for the Home Screen (L/R/T/B) and dock
- **Icon scale**: separate scaling for Home Screen and dock icons
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

All settings live in Settings → SBTweaker. Changes take effect after a
respring (a respring button is included); the animation switches apply
immediately.

## Building

Requires the [roothide theos fork](https://github.com/roothide/theos)
installed at `~/theos-roothide` (adjust the `THEOS` export in the Makefile
otherwise) and an iOS 16.5 SDK. The Makefile already sets
`THEOS_PACKAGE_SCHEME=roothide`.

```sh
make package FINALPACKAGE=1
```

The resulting `.deb` lands in `packages/`.

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
