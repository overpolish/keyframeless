/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

/// One entry in a `KKDropdown`. `icon`/`color` are optional so the same component
/// serves plain value menus and colour-coded kind pickers. Only the icon is tinted
/// with `color`; the label text stays in the default foreground.
struct KKDropdownItem<Value: Hashable>: Identifiable {
	let value: Value
	let label: String
	var icon: String? = nil
	var color: Color? = nil
	var id: Value { value }
}

/// The app's standard dropdown: a `kkPanel` button with a chevron that opens a
/// popover of `kkSelectableBackground` rows. Matches FontPicker / FrameratePicker.
/// Fills the width it's given (label truncates, chevron pinned right); wrap in a
/// `.frame(width:)` for a compact fixed size.
struct KKDropdown<Value: Hashable>: View {
	@Binding var selection: Value
	let items: [KKDropdownItem<Value>]
	@State private var isOpen = false

	private var current: KKDropdownItem<Value>? {
		items.first { $0.value == selection }
	}

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			if let icon = current?.icon {
				Image(systemName: icon)
					.font(.caption2)
					.foregroundStyle(current?.color ?? .secondary)
			}
			Text(current?.label ?? "")
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(.primary)
				.lineLimit(1)
				.frame(maxWidth: .infinity, alignment: .leading)
			Image(systemName: "chevron.up.chevron.down")
				.font(.caption2)
				.foregroundStyle(.secondary)
		}
		.frame(height: KKInspectorRowHeight)
		.padding(.horizontal, KKPaddingLG)
		.kkPanel(cornerRadius: KKRadiusMD)
		.background(
			// Close the popover if the button scrolls (its global Y shifts);
			// otherwise the popover detaches and floats over the list.
			GeometryReader { geo in
				Color.clear
					.onChange(of: geo.frame(in: .global).minY) {
						if isOpen { isOpen = false }
					}
			}
		)
		.contentShape(Rectangle())
		.onTapGesture { isOpen.toggle() }
		.popover(isPresented: $isOpen, arrowEdge: .top) {
			VStack(spacing: 0) {
				ForEach(items) { item in
					HStack(spacing: KKSpacingSM) {
						if let icon = item.icon {
							Image(systemName: icon)
								.font(.caption2)
								.foregroundStyle(item.color ?? .secondary)
								.frame(width: 14, alignment: .center)
						}
						Text(item.label)
							.font(.system(size: 12))
							.foregroundStyle(.primary)
						Spacer(minLength: KKSpacingLG)
					}
					.padding(.horizontal, KKPaddingLG)
					.padding(.vertical, KKSpacingMD)
					.kkSelectableBackground(selection == item.value)
					.contentShape(Rectangle())
					.onTapGesture {
						selection = item.value
						isOpen = false
					}
				}
			}
			.frame(minWidth: 150)
			.padding(KKPaddingMD)
			.background(PopoverBackgroundClearer())
		}
	}
}
