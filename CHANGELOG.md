# Changelog

## 1.3.7

- Added an opt-in Fast Sheets switch: sheets and pop-ups — the share sheet
  and its AirDrop page, compose screens, alerts — slide up and close as fast
  as Transition Duration allows. Swiping a sheet down is unchanged, as is the
  short wait while iOS starts the share sheet.
- Fast Copy now also removes the copy/paste menu's appear and disappear
  animation, not just the delay before it shows.
- Fixed Fast Copy and the Spotlight option not working in sandboxed apps
  (Messages, WhatsApp, Safari, the Spotlight UI), which cannot read the
  tweak's settings. SpringBoard now publishes every in-app switch to apps.
- Only the Settings pane can trigger a respring now; other apps can no longer
  respring the device by posting SBTweaker's notification.
- The tweak now uses the same defaults as the Settings pane everywhere; the
  built-in fallbacks for the Dock count, spacing and icon scale disagreed.
- SpringBoard-only code no longer loads into apps, so apps start faster.
- Double-tap to lock on the Lock Screen no longer scans the whole screen on
  every touch, and Home Screen layout passes avoid repeated lookups for App
  Library and folder grids.

## 1.3.6

- Added an opt-in Fast Page Transitions option with a Transition Duration
  setting (0.01-1.00 s, default 0.01). It speeds up the slide when an app opens
  a new page — a chat, a post, a settings page — or goes back, including apps
  that provide their own transition, such as WhatsApp. Swipe-back is
  unchanged, and changes apply without a respring.
- Removed Faster Core Animation; Fast Page Transitions replaces it inside
  apps.

## 1.3.5

- Added an opt-in Lock Screen Timeout option that holds the Lock Screen awake
  longer before it dims and sleeps, so notifications stay readable. Auto-Lock
  still caps the total.
- Added opt-in portrait and landscape offsets for the Home Screen page dots and
  Search indicator, under Grid and Spacing Settings.
- Widened the Dock icon count to 1-8.
- Split Dock spacing into independent left and right values; an existing
  combined value carries over to both.

## 1.3.4

- Added an opt-in Spotlight option: opening a search result now dismisses
  Spotlight and clears its search field, so leaving the app shows the Home
  Screen instead of the search it was launched from.
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
