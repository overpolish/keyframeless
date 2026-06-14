---
id: value-editing
summary: How values are edited (always through a popover)
---

Every value in the plugin is edited inside a popover, never directly in the inspector row. Click a keypose, an interval, or a constants row and the popover opens with the controls for that value.

Inside the popover, each parameter row is available for editing.

A reset arrow appears next to the number whenever the value differs from the plugin default. Click it to revert that single value to its default.

Number fields can be scrubbed instead of typed: click on a field and drag to change its value live. Dragging right or up increases the value, left or down decreases it. Hold Shift while dragging for larger steps (ten times the normal amount) and Option for finer steps (a tenth). The pointer hides and stays pinned while you drag, then reappears where you started. A quick click without dragging selects the value for typing as usual. When two components are aspect-locked (the Linked toggle is on), scrubbing one scrubs its partner too, keeping the ratio.

For color parameters the popover swaps in a color well. For multi-component values (X/Y, box edges, etc.) you get one row per component plus the appropriate Linked toggle for the context (see Multi-Component Properties).
