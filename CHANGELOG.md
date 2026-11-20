# Changelog

## 1.5.1

- Extra Top and Extra Bottom spacing now go down to -200 and Extra Left and
  Extra Right to -160 (previously -20), in portrait and landscape. That
  makes room to move the icons much lower on the screen, for example. Icons
  never go past the screen edge: spacing stops once it reaches the edge.

## 1.5.0

- Excluded Apps: a new list under Inside Apps in the settings. SBTweaker
  does nothing inside the apps switched on there: Fast Copy, Fast Page
  Transitions and Fast Sheets stay off in them. Switching an app on applies
  right away; after switching one off, reopen that app.
- Manual icon layout backup: Back Up Layout Now saves the Home Screen,
  folders and Dock, and Restore Backup brings that layout back at any time.
  It is kept separately from the automatic backup and works whether or not
  that is switched on.
- Switching Double Tap to Lock on now takes effect immediately, like
  switching it off.
- Switching Icon Layout Backup off and on again no longer restores the
  layout from before it was switched off. Layout changes made right after a
  respring are no longer lost when there was nothing to restore.
- When a sheet opens during a page transition, Fast Page Transitions and
  Fast Sheets are now both fast; one of them used to play at stock speed.
- The custom Dock count is no longer applied to other single-row layouts
  once the Dock has been found.
- Reset to Defaults asks for confirmation first.
- Smaller performance improvements: settings are no longer re-read every
  ten seconds, Fast Copy does less work for each animation inside apps, and
  less is written to the system log.

## 1.4.0

- Switching off Dock count, Dock or Home Screen spacing, or Icon Scale now
  takes effect right away instead of after a respring, as does the master
  switch for these. The Home Screen grid on iOS 17 and later still needs a
  respring, because SpringBoard builds its pages with the grid at launch.
- Spacing is now added to your device's own margins, so with every extra at
  0 the Home Screen and Dock look exactly stock on every iPhone and iPad.
  If you had adjusted spacing before, check your values after updating:
  icons may sit slightly differently than before.
- Fast Sheets has its own duration, separate from Fast Page Transitions.
  Your current duration is carried over to both.
- Fast Page Transitions and Fast Sheets now also speed up animations that
  used the system's default length, which used to keep their stock speed.
- Setting Drag Coefficient back to 1.0, or switching it off, restores stock
  animation speed right away instead of after a respring.
- Switching off Double Tap to Lock now takes effect immediately.
- Disable Wake Animation is reliable now: the screen no longer sometimes
  fades in anyway.
- Icon Layout Backup no longer restores an outdated layout after a respring
  if the backup could not be updated, and skips restoring when nothing
  changed. Saving the backup no longer slows down SpringBoard.
- Number fields in Settings accept a decimal comma (1,5) and no longer save
  the minimum when left empty.
- Smaller performance improvements for Home Screen layout, animations inside
  apps and the page indicator.

## 1.3.10

- Fixed apps crashing with Fast Page Transitions, Fast Sheets or Fast Copy
  on. Some apps (Signal, WhatsApp, the App Store, PingID) could close while
  a screen opened or closed, because SBTweaker changed the timing of an
  animation the app had marked as read-only.

## 1.3.9

- Icon Scale now starts from the device's own icon size instead of a 60 pt
  icon at 2x. On 3x iPhones such as the Pro Max models icons are no longer
  smaller than the setting says and are drawn at full resolution; on iPad,
  pages with widgets keep their own icon size.
- Free Icon Placement now works on iPad (iPadOS 17): apps stay on the spot
  they are dropped on, like widgets already did. Rotation works as before.
- With a low Drag Coefficient, icons no longer vanish for a few seconds after
  adding a widget. While a widget is added, animations run at normal speed;
  the configured speed returns once edit mode is left or an app is opened,
  but no sooner than 3 seconds after adding.

## 1.3.8

- Widgets can now be placed on any row and column of a custom Home Screen
  grid on iOS 18, instead of only on the 2x2 blocks of the stock grid, and
  stay under your finger while you drag them.
- Home Screen pages are now created with the custom grid on iOS 17 and 18,
  so they hold as many icons as they show and widgets can move into the
  extra rows and columns.
- Added an opt-in Free Icon Placement switch for iOS 17 under Grid and
  Spacing: apps and widgets stay on the spot they are dropped on, with gaps,
  like on iOS 18, and the layout survives a respring. With a custom grid,
  widgets can then use any row and column too. Takes effect after a respring.

## 1.3.7

- Added an opt-in Fast Sheets switch: sheets and pop-ups — the share sheet
  and its AirDrop page, compose screens, alerts — slide up and close as fast
  as Transition Duration allows. Swiping a sheet down is unchanged.
- Fast Copy now also removes the copy/paste menu's appear and disappear
  animation, not just the delay before it shows.
- Fixed Fast Copy not working in sandboxed apps such as Messages, WhatsApp
  and Safari, which cannot read the tweak's settings. SpringBoard now
  publishes every in-app switch to apps.
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
