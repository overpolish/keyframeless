/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import AppKit
import Foundation

struct CaptionTemplate: Identifiable, Equatable, Codable {
	let id: String
	let name: String
	let uid: String
	let supportsPerWordAnimation: Bool
	let wordsInParamName: String?
	let wordsInKeyPath: String?
	let isBuiltIn: Bool
	let isCustom: Bool
	var author: String?
	var thumbnailPath: String?
	var previewGifPath: String?

	static let basicTitle = CaptionTemplate(
		id: "basic-title",
		name: "Basic Title",
		uid: ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti",
		supportsPerWordAnimation: false,
		wordsInParamName: nil,
		wordsInKeyPath: nil,
		isBuiltIn: true,
		isCustom: false,
		thumbnailPath: nil,
		previewGifPath: nil
	)

	static func findThumbnail(in directory: URL) -> String? {
		let largePNG = directory.appendingPathComponent("large.png")
		let smallPNG = directory.appendingPathComponent("small.png")
		if FileManager.default.fileExists(atPath: largePNG.path) {
			return largePNG.path
		} else if FileManager.default.fileExists(atPath: smallPNG.path) {
			return smallPNG.path
		}
		return nil
	}

	func loadThumbnail() -> NSImage? {
		if isBuiltIn {
			return loadGifMiddleFrame() ?? loadBuiltInPNG()
		}
		if let gifFrame = loadGifMiddleFrame() { return gifFrame }
		guard let thumbnailPath else { return nil }
		return NSImage(contentsOfFile: thumbnailPath)
	}

	func loadPreviewGifURL() -> URL? {
		if isBuiltIn {
			return Bundle.main.url(forResource: "BasicTitlePreview", withExtension: "gif")
		}
		guard let previewGifPath else { return nil }
		let url = URL(fileURLWithPath: previewGifPath)
		return FileManager.default.fileExists(atPath: url.path) ? url : nil
	}

	private func loadBuiltInPNG() -> NSImage? {
		let path =
			"/Applications/Final Cut Pro.app/Contents/PlugIns/MediaProviders/MotionEffect.fxp/Contents/Resources/PETemplates.localized/Titles.localized/Bumper:Opener.localized/Basic Title.localized/large.png"
		return NSImage(contentsOfFile: path)
	}

	static func gifMiddleFrame(from source: CGImageSource) -> NSImage? {
		let count = CGImageSourceGetCount(source)
		guard count > 0 else { return nil }
		let middleIndex = count / 2
		guard let cgImage = CGImageSourceCreateImageAtIndex(source, middleIndex, nil) else {
			return nil
		}
		return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
	}

	private func loadGifMiddleFrame() -> NSImage? {
		guard let url = loadPreviewGifURL(),
			let source = CGImageSourceCreateWithURL(url as CFURL, nil)
		else { return nil }
		return Self.gifMiddleFrame(from: source)
	}

	func resolvedMotiURL() -> URL? {
		if uid.hasPrefix("~/") {
			let relative = String(uid.dropFirst(2))
			let base = FileManager.default.homeDirectoryForCurrentUser
				.appendingPathComponent("Movies/Motion Templates.localized")
			return base.appendingPathComponent(relative)
		}
		return URL(fileURLWithPath: uid)
	}

	static func readAuthor(in directory: URL) -> String? {
		let file = directory.appendingPathComponent("author.txt")
		guard
			let text = try? String(contentsOf: file, encoding: .utf8)
				.trimmingCharacters(in: .whitespacesAndNewlines),
			!text.isEmpty
		else { return nil }
		return text
	}

	static func fromMotiFile(at url: URL) -> CaptionTemplate? {
		let dir = url.deletingLastPathComponent()
		let name = url.deletingPathExtension().lastPathComponent
		let thumbnailPath = findThumbnail(in: dir)
		let author = readAuthor(in: dir)
		let perWord = CaptionTemplateScanner.checkPerWordSupport(motiFile: url)

		let standardPath = (url.standardizedFileURL.path as NSString).resolvingSymlinksInPath
		let motionTemplatesBase =
			(FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Movies/Motion Templates.localized")
			.standardizedFileURL.path as NSString).resolvingSymlinksInPath
		let uid: String
		if standardPath.hasPrefix(motionTemplatesBase + "/") {
			let relative = String(standardPath.dropFirst(motionTemplatesBase.count + 1))
			uid = "~/\(relative)"
		} else {
			uid = standardPath
		}

		return CaptionTemplate(
			id: "custom:\(url.path)",
			name: name,
			uid: uid,
			supportsPerWordAnimation: perWord != nil,
			wordsInParamName: perWord?.name,
			wordsInKeyPath: perWord?.keyPath,
			isBuiltIn: false,
			isCustom: true,
			author: author,
			thumbnailPath: thumbnailPath
		)
	}
}
