# Widget placement test build

This experimental build is based on SBTweaker 1.3.3 and has the package
version `1.3.3+widgettest2`.

It synchronizes the ordinary model grid, the separate grid used when a page
directly contains widgets, and the list view's current-orientation drag grid
on iOS 18. iOS 15-17 continue using the non-destructive visual layout path
from v1.3.3.

It also adds opt-in portrait and landscape X/Y offsets for the Home Screen
page dots or Search indicator under Grid and Spacing Settings.

Please verify that existing widgets survive installation and respring, can be
moved into the additional custom rows on iOS 18, and retain their position
after another respring.
