/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

enum OzmlBuilder {

	private static let channelFactory =
		"<factory id=\"1\" uuid=\"fdc1944b229111d7b1c300039389b702\">\n"
		+ "\t<description>Channel</description>\n\t<manufacturer>Apple</manufacturer>\n"
		+ "\t<version>1</version>\n</factory>\n"

	private static let fontFactory =
		"<factory id=\"1\" uuid=\"8eafb077e84c45e1996a83033a3a2c49\">\n"
		+ "\t<description>Channel</description>\n\t<manufacturer>Apple</manufacturer>\n"
		+ "\t<version>1</version>\n</factory>\n"

	private static func wrap(_ factory: String, _ body: String) -> String {
		"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE ozxmlscene>\n"
			+ "<ozml version=\"5.14\">\n" + factory + body + "</ozml>\n"
	}

	static func colorChannel(_ name: String, _ paramID: Int, _ value: Double) -> Data {
		let body =
			"<parameter name=\"\(name)\" id=\"\(paramID)\" factoryID=\"1\">\n"
			+ "\t<flags>8589934608</flags>\n"
			+ "\t<curve type=\"1\" default=\"\(value)\" value=\"\(value)\">\n"
			+ "\t\t<min>-6</min>\n\t\t<max>8</max>\n"
			+ "\t</curve>\n</parameter>\n"
		return wrap(channelFactory, body).data(using: .utf8)!
	}

	static func colorEntries(
		keyBase: String, r: Double, g: Double, b: Double
	) -> [FCPNativePasteboardBuilder.EffectValueEntry] {
		[
			("Red", "/1", 1, r),
			("Green", "/2", 2, g),
			("Blue", "/3", 3, b),
		].map { name, suffix, paramID, value in
			FCPNativePasteboardBuilder.EffectValueEntry(
				key: "\(keyBase)\(suffix)", data: colorChannel(name, paramID, value))
		}
	}

	static func slider(name: String, paramID: String, value: Double, flags: Int = 8_589_934_608)
		-> Data
	{
		// The template doesn't carry a UI range, and the field is unbounded, so widen
		// the curve range to encompass the value (values > 100 or negatives would
		// otherwise clamp). Stays 0…100 for the common in-range case.
		let lo = Swift.min(0, value)
		let hi = Swift.max(100, value)
		let body =
			"<parameter name=\"\(name)\" id=\"\(paramID)\" factoryID=\"1\">\n"
			+ "\t<flags>\(flags)</flags>\n"
			+ "\t<curve type=\"1\" default=\"\(value)\" value=\"\(value)\">\n"
			+ "\t\t<min>\(lo)</min>\n\t\t<max>\(hi)</max>\n"
			+ "\t</curve>\n</parameter>\n"
		return wrap(channelFactory, body).data(using: .utf8)!
	}

	static func toggle(name: String, paramID: String, value: Bool) -> Data {
		let v = value ? 1.0 : 0.0
		let body =
			"<parameter name=\"\(name)\" id=\"\(paramID)\" factoryID=\"1\">\n"
			+ "\t<flags>8589934608</flags>\n"
			+ "\t<curve type=\"0\" default=\"\(v)\" value=\"\(v)\"/>\n"
			+ "</parameter>\n"
		return wrap(channelFactory, body).data(using: .utf8)!
	}

	private static let groupFactory =
		"<factory id=\"1\" uuid=\"e7bf3809229011d798e500039389b702\">\n"
		+ "\t<description>Channel</description>\n\t<manufacturer>Apple</manufacturer>\n"
		+ "\t<version>1</version>\n</factory>\n"

	/// Enables a filter GROUP (e.g. Drop Shadow). FCP represents an enabled filter as
	/// an override at the group key with the group's flags minus the `0x8000` disable
	/// bit; absence of this override means disabled. Captured from an FCP paste.
	static func filterEnable(name: String, paramID: String, enabledFlags: Int) -> Data {
		let body =
			"<parameter name=\"\(name)\" id=\"\(paramID)\" factoryID=\"1\">\n"
			+ "\t<flags>\(enabledFlags)</flags>\n"
			+ "\t<foldFlags>131076</foldFlags>\n"
			+ "</parameter>\n"
		return wrap(groupFactory, body).data(using: .utf8)!
	}

	static func font(name: String, paramID: String = "83", font: String, defaultFont: String)
		-> Data
	{
		let body =
			"<parameter name=\"\(name)\" id=\"\(paramID)\" factoryID=\"1\">\n"
			+ "\t<font>\(font)</font>\n"
			+ "\t<defaultFont>\(defaultFont)</defaultFont>\n"
			+ "</parameter>\n"
		return wrap(fontFactory, body).data(using: .utf8)!
	}

	static func wordsIn(
		paramName: String = "Words In",
		paramID: String = "100",
		wordStarts: [Double],
		titleStartTime: Double,
		mediaStartTime: Double,
		frameRate: FCPNativePasteboardBuilder.FrameRate,
		startsAtZero: Bool
	) -> Data {
		let wordCount = wordStarts.count
		let divisor = Double(wordCount)
		var keypointXml = ""
		for (i, wordStart) in wordStarts.enumerated() {
			let wordOffset = wordStart - titleStartTime
			let timeTicks =
				FCPNativePasteboardBuilder.frames(
					seconds: mediaStartTime + wordOffset, frameRate: frameRate)
				* frameRate.numerator
			let value = startsAtZero ? Double(i) / divisor : Double(i + 1) / divisor
			let valueStr = value == 1 ? "1" : String(format: "%g", value)
			keypointXml += "\t\t<keypoint interpolation=\"1\" flags=\"0\">\n"
			keypointXml += "\t\t\t<time>\(timeTicks) \(frameRate.denominator) 1 0</time>\n"
			keypointXml += "\t\t\t<value>\(valueStr)</value>\n"
			keypointXml += "\t\t</keypoint>\n"
		}
		let firstValue = startsAtZero ? "0" : String(format: "%g", 1.0 / divisor)
		let body =
			"<parameter name=\"\(paramName)\" id=\"\(paramID)\" factoryID=\"1\">\n"
			+ "\t<flags>12901679376</flags>\n"
			+ "\t<curve type=\"1\" default=\"\(firstValue)\" value=\"\(firstValue)\">\n"
			+ "\t\t<numberOfKeypoints>\(wordCount)</numberOfKeypoints>\n"
			+ "\t\t<min>0</min>\n\t\t<max>1</max>\n"
			+ keypointXml + "\t</curve>\n</parameter>\n"
		return wrap(channelFactory, body).data(using: .utf8)!
	}
}
