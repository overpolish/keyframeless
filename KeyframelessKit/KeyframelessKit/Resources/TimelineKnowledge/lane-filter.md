---
id: lane-filter
summary: Property categories and the lane filter for focusing the Advanced timeline
---

Some plugins group their properties into categories (for example Glow's **Core** and **Noise**). When there is more than one category, **category pills** let you switch between groups in the value-editor popover, the Animated dropdown, and the parameter list, and a **lane filter** on the Advanced timeline lets you show or hide individual properties so you can focus on a few at a time. Categories are optional - a plugin with no categories just lists its properties flat.

### Where categories appear

The value-editor popover (Constants and keyposes), the Animated dropdown, the Parameter Order list, and the lane filter all show category pills when a plugin has more than one category. Pick a pill to narrow the list to that category. The keypose popover opens on the clicked keypose's category; the Constants popover remembers the last category you used (in Basic timing).

### The lane filter

When two or more properties are animated, a **filter button** appears in the Advanced timeline's top toolbar (next to Dynamic and Maintain Timing). Click it to open the filter checklist - the same layout as the Animated dropdown: a search field, category pills when the plugin has categories, and one checkable row per property.

Each row's checkbox controls whether that property's lane is shown in the timeline below: leave it checked to show the lane, uncheck it to hide it. Use the search field to find a property by name, and the category pills to page between groups (search spans the current category).

Option-click a row to solo that property: every other lane hides and the soloed row turns the warning colour. Option-click the active solo again to clear it and bring every lane back.

While any property is hidden or soloed the filter button is tinted the warning colour and a small clear (×) button appears beside it - click it to show every lane again. You can hide every lane; when nothing is visible the timeline shows an "all lanes hidden" message until you bring at least one back.

On a plugin with layers (a multi-layer canvas), the filter is scoped to the selected layer, and the layer list appears beside the checklist so you can switch which layer you are filtering - the same companion panel the Animated dropdown uses.

The filter is a view aid only. Hiding a lane never changes the animation or the underlying data - it just declutters a busy timeline so you can focus on a few properties at a time. The visibility state is not saved with the clip; it resets when you reopen the inspector.
