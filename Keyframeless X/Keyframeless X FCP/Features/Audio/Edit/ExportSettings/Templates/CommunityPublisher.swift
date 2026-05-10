/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation

enum CommunityPublisher {
	private static let owner = CommunityTemplateStore.owner
	private static let repo = CommunityTemplateStore.repo
	private static let baseBranch = CommunityTemplateStore.branch
	private static let apiBase = CommunityTemplateStore.apiBase

	struct TemplatePayload {
		let id: String
		let name: String
		let author: String
		let perWord: Bool
		let perWordStartsAtZero: Bool
		let params: [[String: String]]
		let version: Int
		let motiDirectoryURL: URL?
		let previewGifURL: URL?
	}

	enum PublishError: LocalizedError {
		case motiNotFound
		case gitHub(String)
		case network(Error)

		var errorDescription: String? {
			switch self {
			case .motiNotFound: return "Template .moti directory not found"
			case .gitHub(let msg): return "GitHub: \(msg)"
			case .network(let err): return "Network: \(err.localizedDescription)"
			}
		}
	}

	static func publish(_ payload: TemplatePayload) async throws {
		let token = Token.decoded
		let branchName = "community/\(payload.id)"
		let isUpdate = payload.version > 1

		let mainSHA = try await getRef(branch: baseBranch, token: token)

		// For updates the branch may already exist; create or force-update
		if isUpdate {
			try? await updateRef(branch: branchName, sha: mainSHA, token: token)
		}
		do {
			try await createRef(branch: branchName, sha: mainSHA, token: token)
		} catch {
			try await updateRef(branch: branchName, sha: mainSHA, token: token)
		}

		var treeEntries: [[String: String]] = []
		let templateFolder = sanitizePath(payload.name)

		if let motiDir = payload.motiDirectoryURL {
			let resolvedMotiDir = motiDir.resolvingSymlinksInPath().standardizedFileURL.path
			let motiFiles = try collectFiles(in: motiDir)
			for file in motiFiles {
				let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL.path
				let originalName =
					resolvedFile.hasPrefix(resolvedMotiDir + "/")
					? String(resolvedFile.dropFirst(resolvedMotiDir.count + 1))
					: file.lastPathComponent
				let fileName: String
				if originalName.hasSuffix(".moti") {
					fileName = "\(templateFolder).moti"
				} else {
					fileName = sanitizePath(originalName)
				}
				let treePath = "Captions/\(payload.id)/\(templateFolder)/\(fileName)"
				let blobSHA = try await createBlob(fileURL: file, token: token)
				treeEntries.append([
					"path": treePath,
					"mode": "100644",
					"type": "blob",
					"sha": blobSHA,
				])
			}
		}

		if let gifURL = payload.previewGifURL {
			let gifBlobSHA = try await createBlob(fileURL: gifURL, token: token)
			treeEntries.append([
				"path": "Captions/\(payload.id)/\(templateFolder)/preview.gif",
				"mode": "100644",
				"type": "blob",
				"sha": gifBlobSHA,
			])
		}

		var indexEntry: [String: Any] = [
			"id": payload.id,
			"name": payload.name,
			"author": payload.author,
			"perWord": payload.perWord,
			"params": payload.params,
			"version": payload.version,
		]
		if payload.perWord {
			indexEntry["perWordStartsAtZero"] = payload.perWordStartsAtZero
		}
		let indexData = try JSONSerialization.data(
			withJSONObject: indexEntry, options: [.prettyPrinted, .sortedKeys])
		let indexBlobSHA = try await createBlobFromData(indexData, token: token)
		treeEntries.append([
			"path": "Captions/\(payload.id)/\(templateFolder)/metadata.json",
			"mode": "100644",
			"type": "blob",
			"sha": indexBlobSHA,
		])

		// Use existing branch tree as base so unchanged files are preserved
		let baseTreeSHA: String
		if isUpdate, let treeSHA = try? await getTreeSHA(branch: branchName, token: token) {
			baseTreeSHA = treeSHA
		} else {
			baseTreeSHA = mainSHA
		}

		let treeSHA = try await createTree(
			baseTreeSHA: baseTreeSHA, entries: treeEntries, token: token)

		let commitMessage =
			isUpdate
			? "Update community template: \(payload.name) to v\(payload.version)"
			: "Add community template: \(payload.name)"
		let commitSHA = try await createCommit(
			message: commitMessage, treeSHA: treeSHA, parentSHA: mainSHA, token: token)

		try await updateRef(branch: branchName, sha: commitSHA, token: token)

		let prTitle =
			isUpdate
			? "Update template: \(payload.name) v\(payload.version)"
			: "Add template: \(payload.name)"
		var prBody =
			isUpdate
			? "Updates community template **\(payload.name)** to version \(payload.version)"
			: "Adds community template **\(payload.name)**"
		if !payload.author.isEmpty {
			prBody += " by \(payload.author)"
		}
		prBody += "\n\nID: `\(payload.id)`"
		if payload.perWord { prBody += "\nSupports per-word animation" }
		if !payload.params.isEmpty {
			prBody +=
				"\nParameters: \(payload.params.map { $0["name"] ?? "" }.joined(separator: ", "))"
		}

		try await createPR(
			title: prTitle, body: prBody, head: branchName, token: token)
	}

	private static func sanitizePath(_ path: String) -> String {
		path
			.replacingOccurrences(of: ":", with: "-")
			.replacingOccurrences(of: "\\", with: "-")
			.replacingOccurrences(of: "\0", with: "")
	}

	private static func collectFiles(in directory: URL) throws -> [URL] {
		let fm = FileManager.default
		guard
			let enumerator = fm.enumerator(
				at: directory,
				includingPropertiesForKeys: [.isRegularFileKey],
				options: [.skipsHiddenFiles]
			)
		else {
			throw PublishError.motiNotFound
		}
		var files: [URL] = []
		for case let url as URL in enumerator {
			let values = try url.resourceValues(forKeys: [.isRegularFileKey])
			if values.isRegularFile == true {
				files.append(url)
			}
		}
		return files
	}

	private static func getRef(branch: String, token: String) async throws -> String {
		let url = URL(string: "\(apiBase)/repos/\(owner)/\(repo)/git/ref/heads/\(branch)")!
		let data = try await request(url: url, method: "GET", token: token)
		guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			let obj = json["object"] as? [String: Any],
			let sha = obj["sha"] as? String
		else { throw PublishError.gitHub("Failed to get ref for \(branch)") }
		return sha
	}

	private static func getTreeSHA(branch: String, token: String) async throws -> String {
		let commitSHA = try await getRef(branch: branch, token: token)
		let url = URL(string: "\(apiBase)/repos/\(owner)/\(repo)/git/commits/\(commitSHA)")!
		let data = try await request(url: url, method: "GET", token: token)
		guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			let tree = json["tree"] as? [String: Any],
			let sha = tree["sha"] as? String
		else { throw PublishError.gitHub("Failed to get tree SHA") }
		return sha
	}

	private static func createRef(branch: String, sha: String, token: String) async throws {
		let url = URL(string: "\(apiBase)/repos/\(owner)/\(repo)/git/refs")!
		let body: [String: Any] = ["ref": "refs/heads/\(branch)", "sha": sha]
		_ = try await request(url: url, method: "POST", body: body, token: token)
	}

	private static func createBlob(fileURL: URL, token: String) async throws -> String {
		let fileData = try Data(contentsOf: fileURL)
		return try await createBlobFromData(fileData, token: token)
	}

	private static func createBlobFromData(_ data: Data, token: String) async throws -> String {
		let url = URL(string: "\(apiBase)/repos/\(owner)/\(repo)/git/blobs")!
		let body: [String: Any] = [
			"content": data.base64EncodedString(),
			"encoding": "base64",
		]
		let responseData = try await request(url: url, method: "POST", body: body, token: token)
		guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
			let sha = json["sha"] as? String
		else { throw PublishError.gitHub("Failed to create blob") }
		return sha
	}

	private static func createTree(
		baseTreeSHA: String, entries: [[String: String]], token: String
	) async throws -> String {
		let url = URL(string: "\(apiBase)/repos/\(owner)/\(repo)/git/trees")!
		let body: [String: Any] = ["base_tree": baseTreeSHA, "tree": entries]
		let data = try await request(url: url, method: "POST", body: body, token: token)
		guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			let sha = json["sha"] as? String
		else { throw PublishError.gitHub("Failed to create tree") }
		return sha
	}

	private static func createCommit(
		message: String, treeSHA: String, parentSHA: String, token: String
	) async throws -> String {
		let url = URL(string: "\(apiBase)/repos/\(owner)/\(repo)/git/commits")!
		let body: [String: Any] = [
			"message": message,
			"tree": treeSHA,
			"parents": [parentSHA],
		]
		let data = try await request(url: url, method: "POST", body: body, token: token)
		guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
			let sha = json["sha"] as? String
		else { throw PublishError.gitHub("Failed to create commit") }
		return sha
	}

	private static func updateRef(branch: String, sha: String, token: String) async throws {
		let url = URL(
			string: "\(apiBase)/repos/\(owner)/\(repo)/git/refs/heads/\(branch)")!
		let body: [String: Any] = ["sha": sha, "force": true]
		_ = try await request(url: url, method: "PATCH", body: body, token: token)
	}

	private static func createPR(
		title: String, body: String, head: String, token: String
	) async throws {
		let url = URL(string: "\(apiBase)/repos/\(owner)/\(repo)/pulls")!
		let payload: [String: Any] = [
			"title": title,
			"body": body,
			"head": head,
			"base": baseBranch,
		]
		_ = try await request(url: url, method: "POST", body: payload, token: token)
	}

	private static func request(
		url: URL, method: String, body: [String: Any]? = nil, token: String
	) async throws -> Data {
		var req = URLRequest(url: url)
		req.httpMethod = method
		req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
		req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
		if let body {
			req.httpBody = try JSONSerialization.data(withJSONObject: body)
			req.setValue("application/json", forHTTPHeaderField: "Content-Type")
		}
		let (data, response) = try await URLSession.shared.data(for: req)
		guard let http = response as? HTTPURLResponse else {
			throw PublishError.gitHub("Invalid response")
		}
		if http.statusCode >= 400 {
			let msg =
				(try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"]
				as? String ?? "HTTP \(http.statusCode)"
			throw PublishError.gitHub(msg)
		}
		return data
	}
}

extension CommunityPublisher {
	fileprivate enum Token {
		private static let _k: [UInt8] = [
			0x5a, 0x07, 0x7a, 0xa5, 0x86, 0x2c, 0x25, 0xdc, 0xb6, 0x6c, 0x14, 0x6c, 0xa7, 0x91,
			0xd6, 0x3c,
			0x6d, 0x1c, 0x1a, 0x55, 0xd8, 0xf7, 0xaa, 0x27, 0x70, 0x50, 0xb3, 0xd0, 0x18, 0xe3,
			0x63, 0xbe,
			0xee, 0xa4, 0x89, 0xb9, 0x0c, 0x75, 0x90, 0x7e, 0xba, 0x06, 0xc2, 0x9f, 0x31, 0x6e,
			0x47, 0x05,
			0xbd, 0x1c, 0xb4, 0x1a, 0xf4, 0xff, 0xe3, 0x24, 0x90, 0x6f, 0x56, 0x8b, 0x94, 0xc9,
			0x58, 0xe1,
			0x95, 0x4c, 0xa5, 0xf6, 0x34, 0x28, 0x9d, 0xf8, 0x06, 0x4b, 0x91, 0xab, 0x71, 0x71,
			0x29, 0x7f,
			0x5a, 0xdd, 0x51, 0xd5, 0x45, 0xc3, 0xac, 0x7d, 0x38, 0xcf, 0xb8, 0xa8, 0x36,
		]

		private static let _c: [UInt8] = [
			0x3d, 0x6e, 0x0e, 0xcd, 0xf3, 0x4e, 0x7a, 0xac, 0xd7, 0x18, 0x4b, 0x5d, 0x96, 0xd0,
			0x9e, 0x0a,
			0x3e, 0x28, 0x49, 0x0c, 0xe8, 0xc1, 0xeb, 0x55, 0x0a, 0x25, 0xdb, 0x9d, 0x68, 0x8b,
			0x09, 0xc8,
			0xde, 0xfb, 0xec, 0x8b, 0x4e, 0x01, 0xd7, 0x06, 0xdc, 0x61, 0xf0, 0xe6, 0x73, 0x29,
			0x0c, 0x66,
			0xfe, 0x5b, 0xd0, 0x62, 0xa5, 0x8e, 0x94, 0x76, 0xc4, 0x0e, 0x1c, 0xcf, 0xd2, 0xa5,
			0x16, 0xa8,
			0xad, 0x2e, 0xe8, 0x9a, 0x79, 0x61, 0xe9, 0xca, 0x6e, 0x28, 0xf9, 0xea, 0x0b, 0x32,
			0x6f, 0x4c,
			0x03, 0x8a, 0x14, 0x91, 0x09, 0xab, 0xfd, 0x16, 0x6a, 0x9a, 0xd7, 0xc2, 0x44,
		]

		static var decoded: String {
			String(bytes: zip(_k, _c).map { $0 ^ $1 }, encoding: .utf8) ?? ""
		}
	}
}
