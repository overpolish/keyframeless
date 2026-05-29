---
id: animated-properties
summary: Opting properties in to animation via the Animated dropdown
---

Plugins don't animate every property by default. You opt each property in to animation using the Animated dropdown.

At the bottom of the lane list there is an "Add properties…" button. Click it to open the Animated popover, which lists every property the plugin exposes with a checkbox next to each. Check a property to give it a lane in the timeline; uncheck it to drop the lane and revert to the value in the Constants panel.

The popover has a search field at the top so you can filter long property lists quickly.

When no properties are opted in, the lane list shows a "No animated properties" empty state - everything renders as constants and the timeline is hidden.

Opting in to animation is non-destructive: turning a lane on starts it from the current constant value, so you can add and remove lanes as your animation grows without losing data.
