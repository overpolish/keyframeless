/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Cocoa
import CoreMedia
import ProExtensionHost

@objc class Keyframeless_X_FCPViewController: NSViewController {

	private let timelineLengthLabel = NSTextField(labelWithString: "Timeline: —")

	override func awakeFromNib() {
		super.awakeFromNib()
	}

	override var nibName: NSNib.Name? {
		return NSNib.Name("Keyframeless_X_FCPViewController")
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
		// Use the sequence's frame duration, fall back to 1/30s if no project is open
		let frameDuration = sequence?.frameDuration ?? CMTime(value: 1, timescale: 30)
		let frameValue = frameDuration.value  // e.g. 1001 for 29.97, 1 for 30
		let timescale = frameDuration.timescale  // e.g. 30000 for 29.97, 30 for 30

		// Express 5 seconds as a whole number of frames at this timescale
		let durationFrames = Int(round(5.0 * Double(timescale) / Double(frameValue)))
		let durationTicks = durationFrames * Int(frameValue)
		let dur = "\(durationTicks)/\(timescale)s"

		let fcpxml = """
			<?xml version="1.0" encoding="UTF-8"?>
			<!DOCTYPE fcpxml>
			<fcpxml version="1.9">
			  <resources>
			    <format id="r1" name="FFVideoFormat1080p30" frameDuration="\(frameValue)/\(timescale)s" width="1920" height="1080" colorSpace="1-1-1 (Rec. 709)"/>
			    <effect id="r2" name="Basic Title" uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>
			    <effect id="r3" name="Gaussian" uid=".../Effects.localized/Blur.localized/Gaussian.localized/Gaussian.moef"/>
			  </resources>
			  <library>
			    <event name="Keyframeless X">
			      <project name="hello from keyframeless x">
			        <sequence format="r1" duration="\(dur)" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
			          <spine>
			            <gap name="Gap" offset="0s" start="0s" duration="\(dur)">
			              <title ref="r2" lane="1" name="hello from keyframeless x - Basic Title" offset="0s" start="0s" duration="\(dur)">
			                <param name="Flatten" key="9999/999166631/999166633/2/351" value="1"/>
			                <param name="Alignment" key="9999/999166631/999166633/2/354/3142713059/401" value="1 (Center)"/>
			                <text>
			                  <text-style ref="ts1">hello from keyframeless x</text-style>
			                </text>
			                <text-style-def id="ts1">
			                  <text-style font="Helvetica" fontSize="60" fontColor="1 1 1 1" alignment="center" fontFace="Regular"/>
			                </text-style-def>
			                <filter-video ref="r3" name="Gaussian">
			                  <param name="Amount" key="9999/986883370/100/986883376/2/100" value="0.1"/>
			                </filter-video>
			              </title>
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
