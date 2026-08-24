# Changelog

## 1.3

- Made every impactful feature explicitly opt-in and off by default.
- Added live Dock count and capacity updates for 4–7 icons.
- Added device-aware iPhone/iPad grid defaults.
- Preserved existing preferences during defaults-schema upgrades; only missing
  keys and invalid legacy zero grid values are repaired.
- Kept independent portrait and landscape grid counts while sharing Home
  spacing and scale across both orientations.
- Applied icon layout configuration during SpringBoard's initial layout pass,
  eliminating the delayed post-respring correction.
- Made icon scaling absolute and idempotent for Home Screen and Dock icons.
- Prevented Lock Screen double-tap-to-lock while passcode UI is visible.
- Added automatic jailbroken icon-layout backup and guarded startup restore,
  informed by OwnGoalStudio's IconRestore implementation.
- Removed the unreliable Spotlight feature.

## 1.2

- Added rootless and roothide packages for iOS 15 and newer.
- Added independent portrait and landscape grid counts.
- Improved layout, App Library, and Home Screen double-tap compatibility.
