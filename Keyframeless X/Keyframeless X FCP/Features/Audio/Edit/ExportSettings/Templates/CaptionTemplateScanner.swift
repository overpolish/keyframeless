/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import Foundation

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
				let thumbnailPath = CaptionTemplate.findThumbnail(in: entry)
				let perWord = checkPerWordSupport(motiFile: motiFile)
				let gifPath = entry.appendingPathComponent("preview.gif")
				let previewGifPath =
					FileManager.default.fileExists(atPath: gifPath.path) ? gifPath.path : nil

				templates.append(
					CaptionTemplate(
						id: uid,
						name: name,
						uid: uid,
						supportsPerWordAnimation: perWord != nil,
						wordsInParamName: perWord?.name,
						wordsInKeyPath: perWord?.keyPath,
						isBuiltIn: false,
						isCustom: false,
						author: CaptionTemplate.readAuthor(in: entry),
						thumbnailPath: thumbnailPath,
						previewGifPath: previewGifPath
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

	struct PerWordInfo {
		let name: String
		let keyPath: String
	}

	static func checkPerWordSupport(motiFile: URL) -> PerWordInfo? {
		guard let data = try? Data(contentsOf: motiFile, options: .mappedIfSafe),
			let content = String(data: data, encoding: .utf8)
		else { return nil }

		guard let pubStart = content.range(of: "<publishSettings>"),
			let pubEnd = content.range(of: "</publishSettings>")
		else { return nil }

		let publishBlock = content[pubStart.lowerBound..<pubEnd.upperBound]
		let knownNames = ["Animate On", "Words In"]
		for paramName in knownNames {
			guard publishBlock.contains("name=\"\(paramName)\"") else { continue }
			let pattern =
				"object=\"(\\d+)\"\\s+channel=\"([^\"]+)\"\\s+name=\"\(NSRegularExpression.escapedPattern(for: paramName))\""
			guard let regex = try? NSRegularExpression(pattern: pattern),
				let match = regex.firstMatch(
					in: String(publishBlock),
					range: NSRange(publishBlock.startIndex..., in: publishBlock))
			else { continue }
			let objID = (publishBlock as NSString).substring(with: match.range(at: 1))
			var channel = (publishBlock as NSString).substring(with: match.range(at: 2))
			if channel.hasPrefix("./") {
				channel = String(channel.dropFirst(2))
			}
			let keyPath = "9999/1825766846/100/\(objID)/\(channel)"
			return PerWordInfo(name: paramName, keyPath: keyPath)
		}
		return nil
	}
}
