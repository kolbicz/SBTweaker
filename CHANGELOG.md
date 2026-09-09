# Changelog

## 1.3.4

- Added an opt-in Spotlight option: opening a search result now dismisses
  Spotlight and clears its search field, so leaving the app shows the Home
  Screen instead of the search it was launched from.
- Suppressed the iPad/Mac return-to-Spotlight breadcrumb re-presentation while
  the option is on.
- Fixed the icon layout backup leaking into the shared mobile container on
  roothide; the snapshot now stays inside the randomized jailbreak root.

## 1.3.3

- Fixed custom Home Screen rows and columns reverting to the stock grid when
  widgets are present on iOS/iPadOS 15.
- Added support for SpringBoard's `SBIconLocationRootWithWidgets` pages.
- Stopped rewriting Home Screen model grid state, preserving existing widgets
  and icon placement across resprings.

## 1.3.2

- Fixed SpringBoard hanging during respring on iOS/iPadOS 15.
- Expanded Home Screen grids to 1–10, Dock capacity to 8, horizontal spacing
  to 160, top spacing to 200, and bottom spacing to 400.
- Updated injection filters for iOS 15–17 compatibility.

## 1.3.1

- Grouped portrait and landscape grid/spacing controls into one submenu.
- Restored independent landscape spacing and per-orientation enable switches.
- Fixed preference slider alignment and UIKit process injection.

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
