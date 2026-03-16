/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import CoreMedia
import Foundation

enum FCPXMLBuilder {

	static func titlesXML(words: [String], frameDuration: CMTime) -> String {
		let frameValue = frameDuration.value
		let timescale = frameDuration.timescale

		let wordDurationSecs = 0.5
		let framesPerWord = Int(round(wordDurationSecs * Double(timescale) / Double(frameValue)))
		let ticksPerWord = framesPerWord * Int(frameValue)

		let totalTicks = ticksPerWord * words.count
		let totalDur = "\(totalTicks)/\(timescale)s"

		let fadeTicks = min(3 * Int(frameValue), ticksPerWord / 2)
		let holdTicks = ticksPerWord - 2 * fadeTicks

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

		return """
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
			\(baseTitle)
			\(overlayTitles)
			            </gap>
			          </spine>
			        </sequence>
			      </project>
			    </event>
			  </library>
			</fcpxml>
			"""
	}

}
