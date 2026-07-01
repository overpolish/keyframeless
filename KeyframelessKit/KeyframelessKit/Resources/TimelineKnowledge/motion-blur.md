---
id: motion-blur
summary: Motion blur quality (Fast/Accurate), shutter, and samples
---

Motion blur smears anything that is moving, so fast motion looks natural instead of choppy. It works on every animated property. Controls:

- **Quality** (Fast / Accurate): how the blur is made. Only shown in plugins that offer Fast.
  - **Fast** (the default where offered): quick and light. Its render cost stays the same no matter how long the trail, so it keeps up in real time even on heavy shots. It blurs the effect's own motion (moving, scaling, spinning, and so on). The faster the motion or the wider the Shutter, the longer the trail.
  - **Accurate**: renders the frame a few times across the shutter and blends them. Slower, and the cost climbs as you raise Samples, but it also blurs moving footage underneath, not just the effect's motion. Use it when the footage itself needs to blur, or for the cleanest result on heavy spinning.
- **Shutter**: 0° to 360°, default 180°. 0° gives a sharp frame with no blur. 180° is a half-frame trail, the classic film look. 360° blurs across a whole frame for the strongest smear.
- **Samples**: 2 to 128. Only shown on Accurate (Fast needs no samples, its cost is fixed). More samples give smoother blur but take longer to render. About 2 to 32 covers most needs. The starting value depends on the plugin.
