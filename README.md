<div align="center">
	<img height="75px" alt="keyframeless logo" src="./Assets/keyframeless.png" />
</div>

<h1 align="center">Keyframeless</h1>

<div align="center">
	<img alt="Release" src="https://img.shields.io/github/v/release/overpolish/keyframeless?color=ff5000" />
    <img alt="License PolyForm Noncommercial 1.0.0" src="https://img.shields.io/badge/license-PolyForm_Noncommercial_1.0.0-ff5000" />
    <img alt="macOS 15+" src="https://img.shields.io/badge/15%2B-macOS?logo=apple&label=macOS&labelColor=5C5C5C&color=ff5000">
    <img alt="Architectures - Silicon and Intel" src="https://img.shields.io/badge/Silicon_%7C_Intel-architectures?logo=apple&label=Compatible%20with&labelColor=5C5C5C&color=ff5000">
</div>

<br />

<div align="center">
	Drastically speed up editing with intuitive On Screen Controls, and <i>no</i> keyframes.
</div>

<br />

<div align="center">
	<img width="200" alt="Keyframeless - One timing engine. Every plugin." src="./Assets/Marketing/keyframeless-header.png" />
	<img width="200" alt="Canvas - Draw directly in Final Cut Pro." src="./Assets/Marketing/keyframeless-canvas.png" />
	<img width="200" alt="Magic Move - Hold. Move. Hold. No keyframes." src="./Assets/Marketing/keyframeless-magicmove.png" />
</div>

<div align="center">
	<img width="200" alt="AI Captions - Edit captions before they hit the timeline." src="./Assets/Marketing/keyframeless-ai-captions.png" />
	<img width="200" alt="Glow - The glow Final Cut never shipped." src="./Assets/Marketing/keyframeless-glow.png" />
	<img width="200" alt="Rounded - No more shape masks." src="./Assets/Marketing/keyframeless-rounded.png" />
</div>

<br />

<details>
<summary><b>Table of Contents</b></summary>

- [Install](#-install)
- [Supercharge Your Workflow](#️-supercharge-your-workflow)
  - [Canvas](#canvas)
  - [Magic Move](#magic-move)
  - [AI Captions](#ai-captions)
  - [Glow](#glow)
  - [Rounded](#rounded)
- [Source & License](#-source--license)

</details>

<br />

# 🤝 Install

Grab the installer from Payhip - one payment to help support continued development, all future updates included.

<div align="center">
	<a href="https://store.overpolish.co/b/QG73g"><b>Buy on Payhip →</b></a>
</div>

<br />

<br />

<div align="center">
	<img width="500" alt="Installation window showcasing the various tools available for install." src="./.github/images/installer-1.png" />
</div>

<br />

If you'd rather build Keyframeless yourself than pay for the installer, you can - clone the repo, open it in Xcode, and go. Note the source is [PolyForm Noncommercial](./LICENSE), self-built use is for personal projects only. Paying gets you a signed installer with a [commercial-use license](./COMMERCIAL-LICENSE.md) for paid client work, plus all future plugins and updates.

<br />

# ⚡️ Supercharge Your Workflow

## Canvas

Actual vector drawing inside Final Cut Pro. Drop in SVGs or draw paths from scratch with bezier control - the drawing tool Final Cut never had.

Each path animates independently with draw-on, trim, opacity, and the same timing engine the rest of the suite uses. Handwritten signatures, scribbled annotations, animated illustrations, all without leaving the timeline. Drag handles directly in the viewer for fine-tuning, `opt+click` to add points, double-click to toggle linear/curve.

<div align="center">
	<img alt="Canvas demo" src="./.github/images/canvas-demo-1.gif" />
</div>

## Magic Move

Animation built around a simple mental model - think in seconds, not keyframes. Each property (Position, Scale, Rot X/Y/Z, Opacity) gets its own lane in the sequencer, and you fill it with as many `hold` and `move` segments as you need. Drag to resize, double-click to split, `cmd-click` to delete, `shift-click` to lock a segment to an absolute duration.

Real easing curves per transition - Linear, EaseIn/Out/InOut, Elastic, Bounce - rather than the 3 options FCP gives you. Hold segments can ride a Bounce or Wiggle effect with adjustable intensity and frequency, so static doesn't have to mean lifeless.

<div align="center">
	<img alt="Magic Move demo" src="./.github/images/magicmove-demo-1.gif" />
</div>

## AI Captions

Ever felt like AI caption tools are too basic? No way to edit captions before pulling them into Final Cut Pro, leaving you to fix things title-by-title? This is the first clip-based caption workflow - see your Final Cut Pro audio timeline, pick which clips to transcribe, and use different models for different clips.

There's also community captions - download and use existing ones, or make your own Motion Templates, drag them in, and you're good to go. Customize published parameters **BEFORE** dragging them into Final Cut Pro so you don't have to touch titles once they're on the timeline.

Supported Models:

- Whisper
- Parakeet

<div align="center">
	<img alt="AI Captions demo" src="./.github/images/ai-captions-demo-1.gif" />
</div>

<br />

<div align="center">
	<a href="http://www.youtube.com/watch?v=OLCgGaR87rE" title="An Actual Caption Tool for Final Cut Pro">
		<img src="https://img.youtube.com/vi/OLCgGaR87rE/maxresdefault.jpg" alt="AI Captions Walkthrough" width="480" />
	</a>
	<p>An Actual Caption Tool for Final Cut Pro</p>
</div>

<br />
<br />

> [!WARNING]
> Intel performance is limited by CPU. For best performance, and better models, Silicon is recommended.

## Glow

Add glow effects with solid, gradient, and dynamic colour support. Also doubles as a drop shadow. Animate glow in and out with full timing control, and use outward noise for organic, evolving edges.

<div align="center">
	<img alt="Glow demo" src="./.github/images/glow-demo-1.gif" />
</div>

## Rounded

Easily crop and round your video's corners.

<div align="center">
	<img alt="Rounded demo" src="./.github/images/rounded-demo-1.gif" />
</div>

<br />

# 📜 Source & License

Keyframeless is dual-licensed:

- **Source code:** [PolyForm Noncommercial 1.0.0](./LICENSE) enabling you to read it, learn from it, and build it for personal use.
- **Paid installer (Payhip):** [Commercial-use license](./COMMERCIAL-LICENSE.md) granted to the named purchaser. One person, non-transferable, all current and future updates included.

Older releases were distributed under GPLv3 and stay that way - [Final GPLv3 release](https://github.com/overpolish/keyframeless/releases/tag/2026-04-11)
