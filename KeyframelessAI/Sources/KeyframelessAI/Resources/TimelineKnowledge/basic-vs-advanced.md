---
id: basic-vs-advanced
summary: Basic timing vs Advanced timing modes
---

Every animatable property has two timing modes: Basic and Advanced. Switch between them with the pill switch at the top of the property's row.

Basic is for simple in-and-hold-and-out animations. The UI is three labelled phases - In, Hold, Out - each with its own checkbox. Turn In on to ease into the hold value from the start of the clip; turn Out on to ease out of the hold at the end. With both off, the property holds flat. The hold boundary point is draggable inside the timeline to shift where the In ends and the Out begins.

Advanced gives you the full keypose + interval model: add as many keyposes as you want anywhere along the clip, each interval gets its own easing curve and optional modulation. Use Advanced when you need multi-step motion, custom holds in the middle, or different easing curves between different intervals.

Switching from Basic to Advanced is always allowed; your Basic setup converts into the equivalent keyposes and intervals and you can keep going from there.

Switching from Advanced back to Basic is only allowed when your Advanced state is compatible with the three-phase model (roughly: two keyposes with simple in/out shaping). If it isn't, the pill shows a confirmation with a Switch Anyway option - taking it resets the lane to the default two-keypose Basic setup and discards your Advanced configuration.
