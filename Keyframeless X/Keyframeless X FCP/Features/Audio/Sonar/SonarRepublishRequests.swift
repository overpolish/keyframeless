/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import Foundation
import KeyframelessKit

/// The Sonar half of the republish handshake.
///
/// A plugin bound to a source that isn't published on this Mac leaves a request
/// in the shared container (`KKSonarWriteRepublishRequest`). It can't ask Sonar
/// anything directly - separate sandboxes, no shared process - so the note just
/// waits there. This is the side that reads it.
///
/// The payoff is that the user never has to remember what they picked. Drop the
/// project, and the clips a shader is waiting on are already selected: all
/// that's left is Publish, which reproduces the same content hash, the same key,
/// and reconnects the binding on its own.
enum SonarRepublishRequests {

	/// Clip indices a plugin in `project` is waiting on, or nil if nothing is.
	///
	/// Nil is the ordinary answer. Requests are rare, and Sonar's default (the
	/// whole project) is the right selection when there isn't one.
	static func pendingSelection(
		project: String?, clips: [FCPXMLParser.AudioClip]
	) -> Set<Int>? {
		// Before hashing anything. This runs on every project drop, and the
		// answer is almost always "nobody asked" - fingerprinting every clip to
		// discover that would be work done for nothing, every time.
		let requests = KKSonarPendingRepublishRequests()
		guard !requests.isEmpty else { return nil }

		let published = KKSpectrogramPublishedSources()
		var indexForKey: [String: Int] = [:]
		for (index, clip) in clips.enumerated() {
			indexForKey[SonarSourceStore.clipKey(for: clip)] = index
		}
		for request in requests
		where isOutstanding(request, in: published)
			&& sameProject(KKSonarTicketProjectName(request), project)
		{
			let keys = KKSonarTicketClipKeys(request)
			guard !keys.isEmpty else { continue }
			let indices = Set(keys.compactMap { indexForKey[$0] })
			// Only an exact match will do. A partial one would publish a
			// DIFFERENT selection under the same name, hash to something else,
			// and leave the shader just as unbound - while looking like it
			// worked. Better to leave the default alone and let the user pick.
			if indices.count == keys.count { return indices }
		}
		return nil
	}

	/// Forgets requests whose source is published again.
	///
	/// The plugin clears its own once it sees the source resolve, but that needs
	/// someone to open its inspector, which may never happen. Without this a
	/// satisfied request would sit there and re-impose its selection on every
	/// later drop, overriding the user.
	static func clearSatisfied() {
		let published = KKSpectrogramPublishedSources()
		for request in KKSonarPendingRepublishRequests()
		where !isOutstanding(request, in: published) {
			KKSonarClearRepublishRequest(KKSonarTicketKey(request))
		}
	}

	/// Ticket vs dropped project, case-insensitively. Everywhere else that
	/// project names scope anything (source ids, name collisions) they go
	/// through a case-folding slug, so "Project" renamed to "PROJECT" is the
	/// same project here too - an exact compare would silently drop the
	/// preselection and look like the ticket never existed.
	private static func sameProject(_ a: String?, _ b: String?) -> Bool {
		switch (a, b) {
		case (nil, nil): return true
		case let (a?, b?): return a.caseInsensitiveCompare(b) == .orderedSame
		default: return false
		}
	}

	/// Is this request still waiting on something?
	///
	/// Decided by the manifest, never by whether the file was tidied up. That's
	/// what makes a request that outlived its cleanup inert rather than a
	/// nuisance that silently re-imposes its selection on every later drop.
	private static func isOutstanding(
		_ request: [String: Any], in published: [[String: Any]]
	) -> Bool {
		KKSonarSourceForKey(KKSonarTicketKey(request), published) == nil
	}
}
