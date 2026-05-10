/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

				// Extract and store text ozml (always refresh from .moti)
				let result = PublishedParameter.parseAll(from: motiFile)
				if let textOzml = result.textOzml {
					if Thread.isMainThread {
						TemplatePublishedParamsStore.shared.setTextOzml(textOzml, for: uid)
					} else {
						DispatchQueue.main.async {
							TemplatePublishedParamsStore.shared.setTextOzml(textOzml, for: uid)
						}
					}
				}
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
		let validCustom = customTemplates.compactMap { template -> CaptionTemplate? in
			let path =
				template.uid.hasPrefix("~/")
				? motionTemplatesBase + "/" + template.uid.dropFirst(2)
				: template.uid
			guard FileManager.default.fileExists(atPath: path) else { return nil }
			guard let url = template.resolvedMotiURL(),
				let perWord = checkPerWordSupport(motiFile: url),
				perWord.keyPath != template.wordsInKeyPath
			else { return template }
			return CaptionTemplate(
				id: template.id, name: template.name, uid: template.uid,
				supportsPerWordAnimation: true,
				wordsInParamName: perWord.name,
				wordsInKeyPath: perWord.keyPath,
				isBuiltIn: template.isBuiltIn, isCustom: template.isCustom,
				author: template.author, thumbnailPath: template.thumbnailPath,
				previewGifPath: template.previewGifPath)
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
			let parentID = findParentSceneNodeID(for: objID, in: content) ?? objID
			let keyPath = "9999/\(parentID)/100/\(objID)/\(channel)"
			return PerWordInfo(name: paramName, keyPath: keyPath)
		}
		return nil
	}

	private static func findParentSceneNodeID(for childID: String, in content: String) -> String? {
		let childPattern = "<scenenode[^>]*\\sid=\"\(childID)\""
		guard let childRegex = try? NSRegularExpression(pattern: childPattern),
			let childMatch = childRegex.firstMatch(
				in: content, range: NSRange(content.startIndex..., in: content))
		else { return nil }
		let beforeChild = (content as NSString).substring(to: childMatch.range.location)
		let parentPattern = "<scenenode[^>]*\\sid=\"(\\d+)\""
		guard let parentRegex = try? NSRegularExpression(pattern: parentPattern) else { return nil }
		let matches = parentRegex.matches(
			in: beforeChild, range: NSRange(beforeChild.startIndex..., in: beforeChild))
		return matches.last.map { (beforeChild as NSString).substring(with: $0.range(at: 1)) }
	}
}
