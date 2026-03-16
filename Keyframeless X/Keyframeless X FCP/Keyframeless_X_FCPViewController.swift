/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Cocoa
import CoreMedia
import ProExtensionHost

@objc class Keyframeless_X_FCPViewController: NSViewController {

	private let timelineLengthLabel = NSTextField(labelWithString: "Timeline: —")

	override func loadView() {
		view = NSView()
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		timelineLengthLabel.translatesAutoresizingMaskIntoConstraints = false
		timelineLengthLabel.alignment = .center
		timelineLengthLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular)
		view.addSubview(timelineLengthLabel)

		let insertButton = NSButton(
			title: "Insert Title", target: self, action: #selector(insertTitle))
		insertButton.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(insertButton)

		NSLayoutConstraint.activate([
			timelineLengthLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			timelineLengthLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
			insertButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			insertButton.bottomAnchor.constraint(
				equalTo: timelineLengthLabel.topAnchor, constant: -8),
		])

		let host = ProExtensionHostSingleton() as! FCPXHost
		host.timeline?.add(self)
		updateLabel()
	}

	override func viewWillDisappear() {
		super.viewWillDisappear()
		let host = ProExtensionHostSingleton() as! FCPXHost
		host.timeline?.remove(self)
	}

	private func updateLabel() {
		let host = ProExtensionHostSingleton() as! FCPXHost
		guard let timeline = host.timeline else {
			timelineLengthLabel.stringValue = "Timeline: —"
			return
		}
		let seconds = CMTimeGetSeconds(timeline.sequenceTimeRange.duration)
		if seconds.isNaN || seconds < 0 {
			timelineLengthLabel.stringValue = "Timeline: —"
		} else {
			timelineLengthLabel.stringValue = String(format: "Timeline: %.2fs", seconds)
		}
	}

	@objc func insertTitle() {
		let host = ProExtensionHostSingleton() as! FCPXHost
		let sequence = host.timeline?.activeSequence
		let frameDuration = sequence?.frameDuration ?? CMTime(value: 1, timescale: 30)
		let frameValue = frameDuration.value
		let timescale = frameDuration.timescale

		let wordDurationSecs = 0.5
		let words = "hello from keyframeless x".split(separator: " ").map(String.init)

		// Ticks per word, snapped to a whole number of frames
		let framesPerWord = Int(round(wordDurationSecs * Double(timescale) / Double(frameValue)))
		let ticksPerWord = framesPerWord * Int(frameValue)

		let totalTicks = ticksPerWord * words.count
		let totalDur = "\(totalTicks)/\(timescale)s"

		// Fade over 3 frames, capped so it never exceeds half the word duration
		let fadeTicks = min(3 * Int(frameValue), ticksPerWord / 2)
		let holdTicks = ticksPerWord - 2 * fadeTicks

		// Lane 1: base — all words dimmed, full duration, no animation (sentence always visible)
		let baseSpans = words.enumerated().map { j, word in
			let spacer = j < words.count - 1 ? " " : ""
			return
				"                      <text-style ref=\"base_\(j)\">\(word)\(spacer)</text-style>"
		}.joined(separator: "\n")
		let baseStyleDefs = words.indices.map { j in
			"""
						    <text-style-def id="base_\(j)">
						      <text-style font="Helvetica" fontSize="60" fontFace="Regular" fontColor="1 1 1 0.3" alignment="center"/>
						    </text-style-def>
			"""
		}.joined(separator: "\n")
		let baseTitle = """
					  <title ref="r2" lane="1" name="base" offset="0s" start="0s" duration="\(totalDur)">
					    <param name="Flatten" key="9999/999166631/999166633/2/351" value="1"/>
					    <param name="Alignment" key="9999/999166631/999166633/2/354/999169573/401" value="1 (Center)"/>
					    <text>
							\(baseSpans)
					    </text>
							\(baseStyleDefs)
					    <filter-video ref="r3" name="Gaussian">
					      <param name="Amount" key="9999/986883370/100/986883376/2/100" value="0.1"/>
					    </filter-video>
					  </title>
			"""

		// Lane 2: per-word overlays — active word white, others alpha=0, with fade keyframes
		let overlayTitles = words.enumerated().map { i, activeWord -> String in
			let offsetTicks = ticksPerWord * i
			let wordDur = "\(ticksPerWord)/\(timescale)s"
			let wordOffset = "\(offsetTicks)/\(timescale)s"

			let t0 = "0/\(timescale)s"
			let t1 = "\(fadeTicks)/\(timescale)s"
			let t2 = "\(fadeTicks + holdTicks)/\(timescale)s"
			let t3 = "\(ticksPerWord)/\(timescale)s"

			let spans = words.enumerated().map { j, word in
				let spacer = j < words.count - 1 ? " " : ""
				return
					"                      <text-style ref=\"ov\(i)_\(j)\">\(word)\(spacer)</text-style>"
			}.joined(separator: "\n")
			let styleDefs = words.indices.map { j in
				let color = j == i ? "1 1 1 1" : "1 1 1 0"
				return """
							    <text-style-def id="ov\(i)_\(j)">
							      <text-style font="Helvetica" fontSize="60" fontFace="Regular" fontColor="\(color)" alignment="center"/>
							    </text-style-def>
					"""
			}.joined(separator: "\n")

			return """
						  <title ref="r2" lane="2" name="\(activeWord)" offset="\(wordOffset)" start="0s" duration="\(wordDur)">
						    <param name="Flatten" key="9999/999166631/999166633/2/351" value="1"/>
						    <param name="Alignment" key="9999/999166631/999166633/2/354/999169573/401" value="1 (Center)"/>
						    <text>
				\(spans)
						    </text>
				\(styleDefs)
						    <adjust-blend>
						      <param name="amount">
						        <keyframeAnimation>
						          <keyframe time="\(t0)" value="0"/>
						          <keyframe time="\(t1)" value="1"/>
						          <keyframe time="\(t2)" value="1"/>
						          <keyframe time="\(t3)" value="0"/>
						        </keyframeAnimation>
						      </param>
						    </adjust-blend>
						  </title>
				"""
		}.joined(separator: "\n")

		let titleElements = baseTitle + "\n" + overlayTitles

		let fcpxml = """
			<?xml version="1.0" encoding="UTF-8"?>
			<!DOCTYPE fcpxml>
			<fcpxml version="1.14">
			  <resources>
			    <format id="r1" name="FFVideoFormat1080p30" frameDuration="\(frameValue)/\(timescale)s" width="1920" height="1080" colorSpace="1-1-1 (Rec. 709)"/>
			    <effect id="r2" name="Basic Title" uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>
			    <effect id="r3" name="Gaussian" uid=".../Effects.localized/Blur.localized/Gaussian.localized/Gaussian.moef"/>
			  </resources>
			  <library>
			    <event name="Keyframeless X">
			      <project name="hello from keyframeless x">
			        <sequence format="r1" duration="\(totalDur)" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
			          <spine>
			            <gap name="Gap" offset="0s" duration="\(totalDur)">
			\(titleElements)
			            </gap>
			          </spine>
			        </sequence>
			      </project>
			    </event>
			  </library>
			</fcpxml>
			"""

		let tmpURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("keyframeless_title.fcpxml")
		try? fcpxml.write(to: tmpURL, atomically: true, encoding: .utf8)
		NSWorkspace.shared.open(tmpURL)
	}

	@objc var hostInfoString: String {
		let host = ProExtensionHostSingleton() as! FCPXHost
		return String(format: "%@ %@", host.name, host.versionString)
	}

}

extension Keyframeless_X_FCPViewController: FCPXTimelineObserver {
	func sequenceTimeRangeChanged() {
		DispatchQueue.main.async { self.updateLabel() }
	}

	func activeSequenceChanged() {
		DispatchQueue.main.async { self.updateLabel() }
	}
}
