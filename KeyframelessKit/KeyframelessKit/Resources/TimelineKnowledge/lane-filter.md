---
id: lane-filter
summary: Property categories and the lane filter bar for focusing the Advanced timeline
---

Some plugins group their properties into categories (for example Glow's **Core** and **Noise**). When there is more than one category, **category pills** let you switch between groups in the value-editor popover, the Animated dropdown, and the parameter list, and a **filter bar** above the Advanced timeline lets you show, hide, or solo lanes so you can focus on a few at a time. Categories are optional - a plugin with no categories just lists its properties flat.

### Where categories appear

The value-editor popover (Constants and keyposes), the Animated dropdown, and the Parameter Order list all show category pills when a plugin has more than one category. Pick a pill to narrow the list to that category. The keypose popover opens on the clicked keypose's category; the Constants popover remembers the last category you used (in Basic timing).

### The lane filter bar

When two or more properties are animated, the Advanced timeline shows a filter bar across the top. Each property is a pill; properties in the same category are grouped into one capsule with the category name as a leading pill - for example `[ Core | Radius ]  [ Noise | Amount | Spread ]`. A plugin with no categories shows one pill per property instead, like `[ Position ] [ Scale ] [ Opacity ]`.

Click a property pill to hide or show that lane in the timeline below. The category's leading pill is a master that toggles the whole group at once; it stays highlighted as long as any lane in the group is still visible, so one more click on it turns the rest of the group off.

Click and drag across pills to set several at once to the first pill's new state (show or hide) - the drag carries across capsules, the same paint gesture used elsewhere throughout Keyframeless. The category master pills are left out of the drag so a sweep only paints individual lanes.

Option-click a property to solo it: every other lane hides and the soloed pill turns the warning colour. Option-clicking a category master solos the whole group. Option-click the active solo again to clear it and bring every lane back.

You can hide every lane; when nothing is visible the timeline shows an "All lanes hidden" message until you bring at least one back.

The filter is a view aid only. Hiding a lane never changes the animation or the underlying data - it just declutters a busy timeline so you can focus on a few properties at a time. The visibility state is not saved with the clip; it resets when you reopen the inspector.
