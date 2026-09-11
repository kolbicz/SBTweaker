# Widget placement test build

This experimental build is based on SBTweaker 1.3.3 and has the package
version `1.3.3+widgettest5`.

It applies the custom Home Screen grid to iOS 18 widget placement. iOS 15-17
continue using the non-destructive visual layout path from v1.3.3.

It also adds opt-in portrait and landscape X/Y offsets for the Home Screen
page dots or Search indicator under Grid and Spacing Settings.

## What changed since widgettest4

Earlier test builds overrode
`-[SBIconListModel gridSizeWhenDirectlyContainingNonDefaultSizedIcons]`, which
is not a layout query. SpringBoard reads it in only two places — when the first
non-default-sized icon is added to a page and when the last one is removed —
and both early-out when the value is empty, which is the normal case. Returning
a real grid turned those no-ops into `changeGridSize:` calls, so adding a widget
rewrote the page's stored grid and removing the last widget reset it to
`initialGridSize`, discarding the custom grid. The value was also scaled by the
default icon cell size, leaving it in different units from the grid everything
else computes against.

That override now preserves SpringBoard's empty value, and the scaling is gone.
Placement does not need it: `gridCellInfoWithOptions:` builds the layout from
`gridSizeWithOptions:`, which dispatches plain `gridSize`, and that is hooked.

## What to check

- Existing widgets survive installation and respring.
- Widgets can be moved into the additional custom rows on iOS 18.
- A widget deliberately placed with an empty row beneath it stays put across a
  respring, and the extra rows below remain usable.
- Deleting the last widget from a page does not reset the custom grid.

Console shows `[SBC:I18] <location> <source> grid AxB (stock CxD)` whenever a
grid is reported. Lines with source `widget` should now be rare — that is the
restored early-out. A `widget` grid several times larger than the `standard`
one means the old path is still being taken.

Try extra rows before extra columns: positions are held as grid cell indices
and coordinates relative to the grid, so a column change is more likely to
disturb existing placements.
