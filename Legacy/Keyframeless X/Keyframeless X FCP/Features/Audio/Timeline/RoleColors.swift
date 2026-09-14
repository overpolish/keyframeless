/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit

/// FCP's role colours for the Sonar timeline.
///
/// The palette below is FCP's own, lifted from `_sRoleBaseColors` in
/// Flexo.framework - a 26-entry table of hardcoded RGB triples that
/// `+[FFColorForRole initialize]` divides by 255 to build
/// `_sIndexedRoleColorSchemes`. Each role is assigned an index into that table
/// (`_roleColorIndexForRoleUID:inLibrary:`), and the scheme's `baseColor` is
/// what the timeline tints with. Verified against the live process: index 0
/// matches `fallbackColorSchemeWhenNoAudioRoles.baseColor` exactly.
///
/// A user's *custom* role colours are still not reachable from a workflow
/// extension (no public API, and the FCPXML carries role names only), so these
/// are the stock defaults and we draw the role *name* alongside - the name is
/// what disambiguates when someone has recoloured their roles.
enum RoleColors {

	private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
		NSColor(
			srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
			alpha: 1)
	}

	/// role -> FCP palette entry. Indices refer to `_sRoleBaseColors`.
	private static let known: [String: NSColor] = [
		"dialogue": rgb(29, 52, 84),  // [0] #1D3454 blue
		"music": rgb(21, 84, 44),  // [1] #15542C green
		"effects": rgb(23, 87, 92),  // [2] #17575C teal
		"titles": rgb(80, 53, 133),  // [3] #503585 purple
		"video": rgb(39, 74, 91),  // [15] #274A5B slate blue
		"captions": rgb(23, 87, 71),  // [7] #175747 sea green
	]

	static func color(for role: String?) -> NSColor {
		guard let role = role?.lowercased(), !role.isEmpty else {
			return rgb(104, 111, 123)  // [19] #686F7B - FCP's "no roles" grey
		}
		return known[role] ?? generated(for: role)
	}

	/// Custom roles get a stable hue derived from the name, in the same dark,
	/// desaturated register as FCP's palette so they don't scream.
	private static func generated(for role: String) -> NSColor {
		var hash: UInt64 = 5381
		for byte in role.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
		return NSColor(
			hue: CGFloat(hash % 360) / 360.0, saturation: 0.62, brightness: 0.34, alpha: 1)
	}

	/// Display form: "dialogue" -> "Dialogue".
	static func label(for role: String?) -> String? {
		guard let role, !role.isEmpty else { return nil }
		return role.prefix(1).uppercased() + role.dropFirst()
	}
}
