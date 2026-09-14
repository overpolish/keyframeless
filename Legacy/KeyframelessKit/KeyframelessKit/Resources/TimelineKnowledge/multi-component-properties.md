---
id: multi-component-properties
summary: How multi-component values (X/Y, box edges) behave in transitions vs holds
---

Properties with more than one component (Radius X / Radius Y, Box left / right / top / bottom, Position X / Y, etc.) behave differently depending on whether you are editing a transition or a hold.

On a transition, the component toggles only appear in Basic mode. They let you turn off the transition for specific components, so for example you can ease in X while leaving Y unchanged. Advanced transitions don't have these toggles - in Advanced you control per-component motion by placing keyposes per component instead.

On a hold, the component toggles control which components actually move during the hold's modulation, and a Linked toggle is available. Linked is the proportional mode: with it on, the components move together along the same axis, which on a two-component value like Position produces a 45-degree diagonal. Turn Linked off to let each component move on its own axis, so X and Y modulate independently and the motion stops being locked to a 45-degree line.

Linked only exists on holds. Transitions never have a Linked toggle.
