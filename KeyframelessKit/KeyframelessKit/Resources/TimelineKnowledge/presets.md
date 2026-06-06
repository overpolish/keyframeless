---
id: presets
summary: Save an animation and re-apply it to any clip (built-in and custom presets)
---

Save an animation you like and re-apply it to any clip from the **Presets** row:

- **Default presets** - built-in starters like Pop In and Pop Out, marked with a Default badge. They are read-only.
- **Apply** - click a preset to replace the current animation with it.
- **Apply at playhead** - the insert button drops the preset's move in at the playhead and keeps your existing keyposes, so you can stack a Pop In early and a Pop Out later on the same clip.
- **Save** - type a name in the field and press `+` to save the current animation as your own preset.
- **Filter** - type in the same field to narrow the list.
- **Manage** - rename, overwrite with the current animation, or delete your own presets (built-ins can't be changed).

## How preset timing adapts

A preset stores its transitions as fixed durations and its holds as flexible. When you apply it, each move keeps the same length in seconds while the holds stretch or shrink to fill the clip - so a Pop In feels the same on a one-second title and a ten-second one. The animation is also fit to the clip's last reachable frame.

## Applying at the playhead

The insert button merges the preset in starting at the current playhead instead of replacing everything: keyposes before the playhead are kept, the preset's animated lanes are placed from the playhead onward, and any redundant hold keypose at the join is removed. Only the lanes the preset actually animates are touched - unused properties are left alone.

## Basic and Advanced

Presets work in both Basic and Advanced. If a preset is too rich for Basic to show (for example it animates several properties at once), applying it switches the inspector to Advanced so you see the real result.
