/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import AppKit
import Foundation
import KeyframelessKit
import SwiftUI

/// Sonar: analyzes the project's audio into a timeline spectrogram that Shader
/// (and future visual plugins) sample by render time. Shows the whole project's
/// audio (all roles) on the reusable timeline; drop loads the shared model so
/// Steno and Sonar stay on the same project. Selection picks what gets
/// analyzed, so users can visualize just the music, just the voice, etc.
struct SonarView: View {
	@ObservedObject var model: AudioModel
	@StateObject private var audioPlayer = AudioPlayer()
	@State private var dropState: AudioSetupView.DropState = .idle
	@State private var isTargeted = false
	@State private var timelineLoadID = UUID()
	@State private var spectrogram: Spectrogram?
	@State private var isAnalyzing = false
	@State private var analyzeError: String?
	@State private var skippedClips: [String] = []
	@State private var analyzeTask: Task<Void, Never>?
	@State private var isPublishing = false
	@State private var justPublished = false
	@State private var sources: [SonarSource] = []

	var body: some View {
		VStack(spacing: KKSpacingLG) {
			topRow
			VStack(spacing: 0) {
				timeline
					.frame(maxHeight: .infinity)
				TimelineFooterMessages(clips: model.allAudioClips)
					.padding(.top, KKSpacingMD)
				ClipCountDisplay(
					selectedCount: model.sonarSelectedClips.count,
					totalCount: model.allAudioClips.count
				)
				.padding(.top, KKSpacingMD)
			}
			.layoutPriority(1)
			publishBar
			SonarSourcesList(sources: sources, onRename: rename, onDelete: delete)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onDisappear { audioPlayer.stop() }
		// The spectrogram is a live preview: it builds itself on load and keeps up
		// with the selection. Publishing is the only explicit action.
		//
		// Keyed on the clips' fingerprint signature, not clip count: re-dropping
		// the same project after a volume tweak yields the same number of clips, so
		// a count would miss it and leave a stale picture. The model computes the
		// signature once per load - doing it here would re-fingerprint every clip
		// on every body pass.
		.onAppear {
			analyzeIfNeeded()
			sources = SonarSourceStore.sources()
		}
		.onChange(of: model.allClipsSignature) { analyze() }
		.onChange(of: model.sonarSelectedClips) { analyze() }
	}

	private var topRow: some View {
		HStack {
			if let item = model.dropItems.first {
				Text(item.name)
					.font(.title2)
					.lineLimit(1)
			}
			Spacer()
			ClipSelectionToolbar(
				clips: model.allAudioClips,
				selectedClips: $model.sonarSelectedClips,
				showRoleFilters: true
			)
		}
	}

	private var timeline: some View {
		ZStack {
			RoundedRectangle(cornerRadius: 8)
				.strokeBorder(
					borderColor,
					style: StrokeStyle(
						lineWidth: 1.5, dash: model.allAudioClips.isEmpty ? [6, 4] : []))
			if model.allAudioClips.isEmpty {
				DropZoneEmptyState(dropState: dropState, isTargeted: isTargeted)
			} else {
				TimelineAxisView(
					duration: model.projectFormat?.sequenceDuration
						?? model.allAudioClips.map(\.end).max() ?? 0,
					format: model.projectFormat,
					useTimecode: model.useTimecode,
					clips: model.allAudioClips,
					selectedClips: $model.sonarSelectedClips,
					audioPlayer: audioPlayer,
					showWaveforms: true,
					showRoleLabels: true,
					showSpectrogramLane: true,
					spectrogram: spectrogram,
					spectrogramLoading: isAnalyzing
				)
				.id(timelineLoadID)
				.padding(.bottom, KKSpacingSM)
				.blur(radius: isTargeted ? 3 : 0)
			}
			FCPDropZoneView(
				onDocument: handleDrop,
				onDenied: handleDenied,
				onTargeted: { isTargeted = $0 }
			)
		}
		.frame(maxWidth: .infinity)
		.frame(minHeight: 80)
	}

	/// The label confirms the click landed; the sources list below is the lasting
	/// receipt. Only failures get a message here.
	private var publishBar: some View {
		VStack(spacing: KKSpacingSM) {
			PrimaryButton(
				label: publishButtonLabel,
				systemImage: justPublished ? "checkmark.circle.fill" : "square.and.arrow.up",
				disabled: isPublishing || isAnalyzing || spectrogram == nil,
				action: publish
			)
			.animation(.easeInOut(duration: 0.15), value: justPublished)
			if let analyzeError {
				HelperText(analyzeError, systemImage: "exclamationmark.triangle", warning: true)
			} else if !excludedNames.isEmpty {
				HelperText(
					skippedMessage, systemImage: "exclamationmark.triangle", warning: true)
			}
		}
	}

	/// Clips missing from disk (dropped at load, never shown on the timeline) plus
	/// any that failed to decode during analysis. Both are "audio you can see in
	/// FCP but won't find here", so they read as one message.
	private var excludedNames: [String] { model.excludedClipNames + skippedClips }

	/// Names them, because "some audio is missing" sends you hunting through the
	/// timeline for which. No count: the names carry it, and "+N more" covers the
	/// overflow - which also spares every translator a plural rule.
	private var skippedMessage: String {
		let names = excludedNames
		let list = names.prefix(2).joined(separator: ", ")
		let more = names.count > 2 ? " +\(names.count - 2) more" : ""
		return String(localized: "Excluded - media couldn't be read: \(list)\(more)")
	}

	private var publishButtonLabel: String {
		if justPublished { return String(localized: "Published") }
		return isPublishing ? String(localized: "Publishing…") : String(localized: "Publish")
	}

	private var borderColor: Color {
		if dropState == .denied { return .kkWarning }
		if isTargeted { return .kkAccent }
		return .white.opacity(0.15)
	}

	private func analyzeIfNeeded() {
		if spectrogram == nil { analyze() }
	}

	/// The store names it from the selection's roles, so the common case (pick a
	/// role, publish) needs no naming step. The selection itself is the identity:
	/// re-publishing the same clips refreshes that source, a different set makes a
	/// new one.
	private func publish() {
		guard let spectrogram else { return }
		let clips = selectedClips
		isPublishing = true
		analyzeError = nil
		Task {
			do {
				try SonarSourceStore.publish(
					spectrogram,
					clips: clips,
					projectName: model.dropItems.first?.name,
					timecodeStart: model.projectFormat?.tcStart ?? 0
				)
				sources = SonarSourceStore.sources()
				// Whatever a plugin was asking for, it has now - so drop the
				// note. Left behind, it would re-impose this selection on every
				// later drop of the project and quietly override the user.
				SonarRepublishRequests.clearSatisfied()
				justPublished = true
				// Drop `isPublishing` before the pause, or the button stays
				// disabled and greys out its own confirmation.
				isPublishing = false
				try? await Task.sleep(for: .seconds(2))
				justPublished = false
			} catch {
				analyzeError = error.localizedDescription
				isPublishing = false
			}
		}
	}

	private func rename(_ source: SonarSource, to newName: String) {
		SonarSourceStore.rename(source.id, to: newName)
		sources = SonarSourceStore.sources()
	}

	private func delete(_ source: SonarSource) {
		SonarSourceStore.remove(source.id)
		sources = SonarSourceStore.sources()
	}

	private var selectedClips: [FCPXMLParser.AudioClip] {
		model.sonarSelectedClips.sorted().compactMap { index in
			model.allAudioClips.indices.contains(index) ? model.allAudioClips[index] : nil
		}
	}

	/// Debounced: drag-selecting fires a change for every clip the cursor crosses,
	/// and each one would otherwise start a full re-assembly. Waiting for the
	/// selection to settle turns a drag across ten clips into one analysis.
	private func analyze() {
		analyzeTask?.cancel()
		let clips = selectedClips
		guard !clips.isEmpty else {
			spectrogram = nil
			skippedClips = []
			isAnalyzing = false
			return
		}
		isAnalyzing = true
		analyzeError = nil
		analyzeTask = Task {
			try? await Task.sleep(for: .milliseconds(200))
			guard !Task.isCancelled else { return }
			do {
				// `analyze` is nonisolated async, so the decode + FFT run off the
				// main actor; we're back on it here to build the image and publish.
				let result = try await SpectrogramAnalyzer.analyze(clips: clips)
				spectrogram = result.spectrogram
				skippedClips = result.skipped
			} catch is CancellationError {
				// A newer selection superseded this run; it owns the state now.
				return
			} catch {
				spectrogram = nil
				skippedClips = []
				analyzeError = error.localizedDescription
			}
			isAnalyzing = false
		}
	}

	private func handleDrop(_ doc: XMLDocument) {
		model.load(from: doc)
		dropState = .dropped
		isTargeted = false
		timelineLoadID = UUID()
	}

	private func handleDenied() {
		dropState = .denied
	}
}
