/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI
import UniformTypeIdentifiers

struct LabeledField<Content: View>: View {
	let label: String
	@ViewBuilder let content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: KKSpacingXS) {
			Text(label)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
			content
		}
	}
}

struct PublishTextField: NSViewRepresentable {
	@Binding var text: String
	let placeholder: String
	@Binding var requestFocus: Bool

	func makeNSView(context: Context) -> AccentTextField {
		let field = AccentTextField()
		field.placeholderString = placeholder
		field.isBezeled = false
		field.drawsBackground = false
		field.focusRingType = .none
		field.font = .systemFont(ofSize: 11)
		field.delegate = context.coordinator
		field.stringValue = text
		return field
	}

	func updateNSView(_ nsView: AccentTextField, context: Context) {
		if nsView.stringValue != text {
			nsView.stringValue = text
		}
		if requestFocus {
			DispatchQueue.main.async {
				nsView.window?.makeFirstResponder(nsView)
				requestFocus = false
			}
		}
	}

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	class Coordinator: NSObject, NSTextFieldDelegate {
		var parent: PublishTextField
		init(_ parent: PublishTextField) { self.parent = parent }

		func controlTextDidChange(_ obj: Notification) {
			guard let field = obj.object as? NSTextField else { return }
			parent.text = field.stringValue
		}
	}
}

struct GifDropZone: View {
	let gifURL: URL?
	@Binding var isDropTargeted: Bool
	let onPick: () -> Void
	let onDrop: ([NSItemProvider]) -> Bool

	@State private var gifProgress: CGFloat = 0

	var body: some View {
		ZStack {
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.fill(Color.white.opacity(0.06))
			if let gifURL {
				GeometryReader { geo in
					AnimatedGifView(url: gifURL, progress: $gifProgress)
						.frame(width: geo.size.width, height: geo.size.height)
				}
				.allowsHitTesting(false)
				.id(gifURL)
			} else {
				VStack(spacing: KKSpacingSM) {
					Image(systemName: "photo.badge.plus")
						.font(.system(size: 16))
						.foregroundStyle(.secondary.opacity(0.5))
					Text("Drop preview .gif")
						.font(.system(size: 10))
						.foregroundStyle(.secondary.opacity(0.5))
				}
			}
			if isDropTargeted {
				RoundedRectangle(cornerRadius: KKRadiusMD)
					.strokeBorder(Color.kkAccent, lineWidth: KKBorderWidthSM)
			}
		}
		.aspectRatio(16.0 / 9.0, contentMode: .fit)
		.clipShape(RoundedRectangle(cornerRadius: KKRadiusMD))
		.overlay(
			RoundedRectangle(cornerRadius: KKRadiusMD)
				.strokeBorder(
					Color.secondary.opacity(0.2),
					style: gifURL != nil
						? StrokeStyle(lineWidth: KKBorderWidthXS)
						: StrokeStyle(lineWidth: KKBorderWidthXS, dash: [4, 3])
				)
		)
		.contentShape(Rectangle())
		.onTapGesture { onPick() }
		.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
			onDrop(providers)
		}
	}
}

struct ModalContainer<Content: View>: View {
	let width: CGFloat
	let onDismiss: () -> Void
	@ViewBuilder let content: () -> Content

	var body: some View {
		ZStack {
			Color.black.opacity(0.5)
				.ignoresSafeArea()
				.onTapGesture { onDismiss() }
			VStack(alignment: .leading, spacing: KKSpacingXL) {
				content()
			}
			.padding(KKPaddingXL)
			.frame(width: width)
			.kkPanel()
			.background(
				RoundedRectangle(cornerRadius: KKRadiusMD + 4)
					.fill(Color(nsColor: .windowBackgroundColor))
			)
		}
	}
}

enum GifValidator {
	static let maxSize = 300 * 1024

	struct Result {
		let isTooLarge: Bool
		let isWrongAspect: Bool
	}

	static func validate(_ url: URL) -> Result {
		let size =
			(try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
		let tooLarge = size > maxSize

		var wrongAspect = true
		if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
			let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
			let w = props[kCGImagePropertyPixelWidth] as? Int,
			let h = props[kCGImagePropertyPixelHeight] as? Int, h > 0
		{
			let ratio = Double(w) / Double(h)
			wrongAspect = abs(ratio - 16.0 / 9.0) > 0.05
		}

		return Result(isTooLarge: tooLarge, isWrongAspect: wrongAspect)
	}
}

enum FilePicker {
	static func pickGif(onSelect: @escaping (URL) -> Void) {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType.gif]
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let url = panel.url else { return }
		onSelect(url)
	}

	static func pickMoti(onSelect: @escaping (URL) -> Void) {
		let panel = NSOpenPanel()
		panel.allowedContentTypes = [UTType(filenameExtension: "moti") ?? .data]
		panel.allowsMultipleSelection = false
		guard panel.runModal() == .OK, let url = panel.url else { return }
		onSelect(url)
	}

	static func handleDrop(
		_ providers: [NSItemProvider], extension ext: String,
		onSelect: @escaping (URL) -> Void
	) -> Bool {
		for provider in providers {
			provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
				guard let data = item as? Data,
					let url = URL(dataRepresentation: data, relativeTo: nil),
					url.pathExtension.lowercased() == ext
				else { return }
				DispatchQueue.main.async { onSelect(url) }
			}
		}
		return true
	}
}

extension PublishedParameter.ParamKind {
	var displayLabel: String {
		switch self {
		case .off: return String(localized: "Off")
		case .color: return String(localized: "Color")
		case .slider: return String(localized: "Value")
		case .toggle: return String(localized: "Toggle")
		case .dropdown: return String(localized: "Dropdown")
		case .rotation: return String(localized: "Rotation")
		case .point: return String(localized: "Point")
		case .font: return String(localized: "Font")
		case .animation: return String(localized: "Animation")
		}
	}

	var displayIcon: String {
		switch self {
		case .off: return "circle.slash"
		case .color: return "paintpalette"
		case .slider: return "slider.horizontal.3"
		case .toggle: return "checkmark.circle"
		case .dropdown: return "chevron.down.square"
		case .rotation: return "arrow.clockwise"
		case .point: return "dot.arrowtriangles.up.right.down.left.circle"
		case .font: return "textformat"
		case .animation: return "directcurrent"
		}
	}

	var displayColor: Color {
		// Neutral grey for every kind; per-word animation keeps its green accent.
		switch self {
		case .animation: return .green
		default: return .secondary
		}
	}
}

struct ParamKindRow: View {
	let name: String
	@Binding var kind: PublishedParameter.ParamKind
	var hasOptions: Bool = false
	var hasPoint: Bool = false

	private var kinds: [PublishedParameter.ParamKind] {
		var k: [PublishedParameter.ParamKind] = [.off, .color, .slider, .toggle, .rotation]
		if hasOptions { k.append(.dropdown) }
		if hasPoint { k.append(.point) }
		return k
	}

	var body: some View {
		HStack(spacing: KKSpacingMD) {
			Text(name)
				.font(.system(size: 11))
				.foregroundStyle(.primary)
				.lineLimit(2)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: KKSpacingMD)
			KKDropdown(
				selection: $kind,
				items: kinds.map {
					KKDropdownItem(
						value: $0, label: $0.displayLabel, icon: $0.displayIcon,
						color: $0.displayColor)
				}
			)
			.frame(width: 116)
		}
		.padding(.vertical, KKPaddingXS)
	}
}

struct FontModeRow: View {
	let name: String
	@Binding var fontMode: TemplatePublishedParamsStore.FontMode

	var body: some View {
		HStack(spacing: KKSpacingMD) {
			Image(systemName: "textformat")
				.font(.system(size: 9))
				.foregroundStyle(.secondary)
			Text(name)
				.font(.system(size: 11))
				.foregroundStyle(.primary)
			Spacer()
			PillToggle(
				selection: $fontMode,
				options: [
					(
						label: String(localized: "Base"),
						value: TemplatePublishedParamsStore.FontMode.base
					),
					(
						label: String(localized: "Custom"),
						value: TemplatePublishedParamsStore.FontMode.custom
					),
				]
			)
		}
		.padding(.vertical, KKPaddingXS)
	}
}

struct ParamControlRow: View {
	let param: PublishedParameter
	let templateID: String
	@ObservedObject var store: TemplatePublishedParamsStore
	var compact: Bool = false

	private func binding<T>(
		_ keyPath: WritableKeyPath<TemplatePublishedParamsStore.ParamValue, T>
	) -> Binding<T> {
		Binding(
			get: { store.value(paramID: param.id, for: templateID)[keyPath: keyPath] },
			set: { newVal in
				var val = store.value(paramID: param.id, for: templateID)
				val[keyPath: keyPath] = newVal
				store.setValue(val, paramID: param.id, for: templateID)
			}
		)
	}

	private var labelWidth: CGFloat { compact ? 96 : 120 }

	var body: some View {
		HStack(spacing: KKSpacingMD) {
			Text(param.name)
				.font(compact ? .system(size: 10) : .caption)
				.foregroundStyle(.primary)
				.lineLimit(1)
				.frame(width: labelWidth, alignment: .leading)
			control
				.frame(maxWidth: .infinity, alignment: .leading)
		}
	}

	private func pointField(_ axis: String, _ value: Binding<Double>) -> some View {
		HStack(spacing: KKSpacingXS) {
			Text(axis)
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(.secondary)
				.fixedSize()
			TextField("", value: value, format: .number.precision(.fractionLength(0)))
				.textFieldStyle(.plain)
				.font(.system(size: 11).monospacedDigit())
				.multilineTextAlignment(.trailing)
				.frame(width: 26)
				.frame(height: KKInspectorRowHeight)
				.padding(.horizontal, KKPaddingXS)
				.kkPanel(cornerRadius: KKRadiusMD)
		}
	}

	@ViewBuilder private var control: some View {
		switch param.kind {
		case .color:
			HStack(spacing: 0) {
				Spacer(minLength: 0)
				ColorSwatch(
					colorR: binding(\.r), colorG: binding(\.g),
					colorB: binding(\.b), colorA: binding(\.a))
			}
		case .slider:
			TextField("", value: binding(\.sliderValue), format: .number)
				.textFieldStyle(.plain)
				.font(.system(size: 11))
				.frame(maxWidth: .infinity, alignment: .leading)
				.frame(height: KKInspectorRowHeight)
				.padding(.horizontal, KKPaddingLG)
				.kkPanel(cornerRadius: KKRadiusMD)
		case .toggle:
			HStack(spacing: 0) {
				Spacer(minLength: 0)
				Toggle("", isOn: binding(\.toggleValue))
					.toggleStyle(.checkbox).controlSize(.small).labelsHidden()
					.tint(.kkAccent)
			}
		case .dropdown:
			if let options = param.options {
				KKDropdown(
					selection: binding(\.enumValue),
					items: options.map { KKDropdownItem(value: $0.tag, label: $0.name) })
			}
		case .point:
			HStack(spacing: KKSpacingSM) {
				Spacer(minLength: 0)
				pointField("x", binding(\.pointX))
				pointField("y", binding(\.pointY))
			}
		case .rotation:
			HStack(spacing: KKSpacingSM) {
				Spacer(minLength: 0)
				CircularSlider(degrees: binding(\.sliderValue))
					.frame(width: 13, height: 13)
				TextField(
					"", value: binding(\.sliderValue),
					format: .number.precision(.fractionLength(0))
				)
				.textFieldStyle(.plain)
				.font(.system(size: 11).monospacedDigit())
				.multilineTextAlignment(.trailing)
				.frame(width: 34)
				Text("°").font(.system(size: 10)).foregroundStyle(.secondary)
			}
		default:
			EmptyView()
		}
	}
}

struct FontControlRow: View {
	let param: PublishedParameter
	let templateID: String
	@ObservedObject var store: TemplatePublishedParamsStore
	var compact: Bool = false
	@State private var isFontOpen = false

	private var customFont: Binding<String> {
		Binding(
			get: {
				store.value(paramID: param.id, for: templateID).customFont ?? param.defaultFont
					?? "HelveticaNeue"
			},
			set: { newVal in
				var val = store.value(paramID: param.id, for: templateID)
				val.customFont = newVal
				store.setValue(val, paramID: param.id, for: templateID)
			}
		)
	}

	private var displayName: String {
		NSFont(name: customFont.wrappedValue, size: 12)?.displayName ?? customFont.wrappedValue
	}

	var body: some View {
		HStack(spacing: KKSpacingSM) {
			Text(param.name)
				.font(.system(size: 10))
				.foregroundStyle(.primary)
				.lineLimit(1)
			Spacer()
			HStack(spacing: KKSpacingSM) {
				Text(displayName)
					.font(.custom(customFont.wrappedValue, size: 11))
					.lineLimit(1)
					.frame(maxWidth: .infinity, alignment: .leading)
				Image(systemName: "chevron.up.chevron.down")
					.font(.caption2)
					.foregroundStyle(.secondary)
			}
			.frame(height: KKInspectorRowHeight)
			.padding(.horizontal, KKPaddingLG)
			.kkPanel(cornerRadius: KKRadiusMD)
			.contentShape(RoundedRectangle(cornerRadius: KKRadiusMD))
			.onTapGesture { isFontOpen.toggle() }
			.popover(isPresented: $isFontOpen, arrowEdge: compact ? .leading : .top) {
				FontListPopover(selectedFont: customFont, fonts: FontCache.families)
					.background(PopoverBackgroundClearer())
			}
		}
	}
}
