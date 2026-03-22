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
	let supportsAnimateOn: Bool
	let isBuiltIn: Bool
	let isCustom: Bool
	var thumbnailPath: String?
	var previewGifPath: String?

	static let basicTitle = CaptionTemplate(
		id: "basic-title",
		name: "Basic Title",
		uid: ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti",
		supportsAnimateOn: false,
		isBuiltIn: true,
		isCustom: false,
		thumbnailPath: nil,
		previewGifPath: nil
	)

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

	private func loadGifMiddleFrame() -> NSImage? {
		guard let url = loadPreviewGifURL(),
			let source = CGImageSourceCreateWithURL(url as CFURL, nil)
		else { return nil }
		let count = CGImageSourceGetCount(source)
		guard count > 0 else { return nil }
		let middleIndex = count / 2
		guard let cgImage = CGImageSourceCreateImageAtIndex(source, middleIndex, nil) else {
			return nil
		}
		return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
	}

	static func fromMotiFile(at url: URL) -> CaptionTemplate? {
		let dir = url.deletingLastPathComponent()
		let name = url.deletingPathExtension().lastPathComponent

		let smallPNG = dir.appendingPathComponent("small.png")
		let largePNG = dir.appendingPathComponent("large.png")
		let thumbnailPath: String?
		if FileManager.default.fileExists(atPath: largePNG.path) {
			thumbnailPath = largePNG.path
		} else if FileManager.default.fileExists(atPath: smallPNG.path) {
			thumbnailPath = smallPNG.path
		} else {
			thumbnailPath = nil
		}

		let supportsAnimateOn = CaptionTemplateScanner.checkAnimateOnSupport(motiFile: url)

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
			supportsAnimateOn: supportsAnimateOn,
			isBuiltIn: false,
			isCustom: true,
			thumbnailPath: thumbnailPath
		)
	}
}

class CustomTemplateStore {
	static let shared = CustomTemplateStore()
	private(set) var templates: [CaptionTemplate] = []

	private var fileURL: URL? {
		FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
			.first?
			.appendingPathComponent("Keyframeless/custom_templates.json")
	}

	private init() { load() }

	func add(_ template: CaptionTemplate) {
		guard !templates.contains(where: { $0.id == template.id }) else { return }
		templates.append(template)
		save()
	}

	func remove(_ template: CaptionTemplate) {
		templates.removeAll { $0.id == template.id }
		save()
	}

	private func save() {
		guard let url = fileURL else { return }
		let dir = url.deletingLastPathComponent()
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		try? JSONEncoder().encode(templates).write(to: url, options: .atomic)
	}

	private func load() {
		guard let url = fileURL,
			let data = try? Data(contentsOf: url),
			let saved = try? JSONDecoder().decode([CaptionTemplate].self, from: data)
		else { return }
		templates = saved
	}
}

enum CaptionTemplateScanner {

	private static let templatesBase: URL? = {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(
				"Movies/Motion Templates.localized/Titles.localized/Keyframeless")
	}()

	static func scan(customTemplates: [CaptionTemplate] = []) -> [CaptionTemplate] {
		var templates: [CaptionTemplate] = []

		if let base = templatesBase,
			let entries = try? FileManager.default.contentsOfDirectory(
				at: base, includingPropertiesForKeys: [.isDirectoryKey])
		{
			for entry in entries {
				guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey]),
					values.isDirectory == true
				else { continue }

				let name = entry.lastPathComponent
				let motiFile = entry.appendingPathComponent("\(name).moti")
				guard FileManager.default.fileExists(atPath: motiFile.path) else { continue }

				let uid = "~/Titles.localized/Keyframeless/\(name)/\(name).moti"
				let smallPNG = entry.appendingPathComponent("small.png")
				let largePNG = entry.appendingPathComponent("large.png")

				let thumbnailPath: String?
				if FileManager.default.fileExists(atPath: largePNG.path) {
					thumbnailPath = largePNG.path
				} else if FileManager.default.fileExists(atPath: smallPNG.path) {
					thumbnailPath = smallPNG.path
				} else {
					thumbnailPath = nil
				}

				let supportsAnimateOn = checkAnimateOnSupport(motiFile: motiFile)

				templates.append(
					CaptionTemplate(
						id: uid,
						name: name,
						uid: uid,
						supportsAnimateOn: supportsAnimateOn,
						isBuiltIn: false,
						isCustom: false,
						thumbnailPath: thumbnailPath
					)
				)
			}
		}

		templates.append(.basicTitle)

		let motionTemplatesBase = FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent("Movies/Motion Templates.localized").path
		let validCustom = customTemplates.filter { template in
			let path =
				template.uid.hasPrefix("~/")
				? motionTemplatesBase + "/" + template.uid.dropFirst(2)
				: template.uid
			return FileManager.default.fileExists(atPath: path)
		}
		templates.append(contentsOf: validCustom)

		return templates
	}

	static func checkAnimateOnSupport(motiFile: URL) -> Bool {
		guard let data = try? Data(contentsOf: motiFile, options: .mappedIfSafe),
			let content = String(data: data, encoding: .utf8)
		else { return false }
		return content.contains("Animate On")
	}
}
