/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AudioToolbox
import Foundation

/// Decodes FCP's `<filter-audio><data key="effectState">…</data>` blob into a
/// CoreAudio `kAudioUnitProperty_ClassInfo` dictionary and writes it onto a
/// raw v2 `AudioUnit`.
///
/// FCP wraps the AU's `ClassInfo` dictionary inside an `NSKeyedArchiver`
/// envelope under the top-level key `"effectState"`. The AU's property-set
/// path expects the *inner* dictionary, not the archive envelope; passing the
/// envelope crashes the AU. This helper unwraps + writes in one shot and is
/// the only place the unarchive sequence is implemented.
enum FCPEffectStateDecoder {

	/// Returns true if state was successfully written into the AU. Errors are
	/// logged and treated as "render with stock defaults" (caller can choose
	/// to fall back to applying static `<param>` overrides).
	static func apply(state: Data, to au: AudioUnit, filterName: String) -> Bool {
		guard let dict = decode(state: state, filterName: filterName) else { return false }
		var classInfo: CFPropertyList = dict as CFPropertyList
		let status = AudioUnitSetProperty(
			au, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0,
			&classInfo, UInt32(MemoryLayout<CFPropertyList>.size))
		if status != noErr {
			print("[FCPEffectState] ClassInfo set failed (\(status)) for \(filterName)")
			return false
		}
		return true
	}

	private static func decode(state: Data, filterName: String) -> NSDictionary? {
		let unarchiver: NSKeyedUnarchiver
		do {
			unarchiver = try NSKeyedUnarchiver(forReadingFrom: state)
		} catch {
			print(
				"[FCPEffectState] unarchiver init failed for \(filterName): "
					+ "\(error.localizedDescription)")
			return nil
		}
		unarchiver.requiresSecureCoding = false
		let dict = unarchiver.decodeObject(forKey: "effectState") as? NSDictionary
		unarchiver.finishDecoding()
		if dict == nil {
			print("[FCPEffectState] no 'effectState' key in archive for \(filterName)")
		}
		return dict
	}
}
