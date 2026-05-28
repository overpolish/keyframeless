/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

import KeyframelessKit
import SwiftUI

struct AppShell: View {
	@ObservedObject var audioModel: AudioModel
	@StateObject private var audioModelManager = AudioModelManager()
	@StateObject private var processingCoordinator = AudioProcessingCoordinator()
	@State private var selectedTab: AppTab = .audio
	@State private var availableVersion: String?
	@State private var currentVersion: String = ""
	@State private var updateDismissed = Self.dismissed
	private static var dismissed = false

	#if DEBUG
		// Flip to true + rebuild to force the banner in FCP. Env vars / scheme args
		// do NOT reach an FCP-hosted extension, so this is a compile-time switch.
		// (For pure UI work, use the #Preview in UpdateBanner.swift instead.)
		private static let forceUpdateBanner = false
	#endif

	var body: some View {
		VStack(spacing: KKSpacingMD) {
			if let availableVersion, !updateDismissed {
				UpdateBanner(
					version: availableVersion,
					currentVersion: currentVersion,
					url: KKUpdateChecker.shared().notesURL,
					onDismiss: {
						withAnimation { updateDismissed = true }
						Self.dismissed = true
					}
				)
				.transition(.move(edge: .top).combined(with: .opacity))
			}
			topBar
			Group {
				switch selectedTab {
				case .audio:
					switch audioModel.stage {
					case .setup:
						AudioSetupView(
							model: audioModel,
							audioModelManager: audioModelManager,
							isProcessing: processingCoordinator.isProcessing,
							onProcess: { replaceAll in
								guard !processingCoordinator.isProcessing else { return }
								if replaceAll {
									audioModel.editSelectedClips = nil
								}
								processingCoordinator.isProcessing = true
								processingCoordinator.process(
									model: audioModel,
									audioModelManager: audioModelManager,
									replaceAll: replaceAll
								)
							}
						)
					case .edit:
						AudioEditView(model: audioModel)
					}
				}
			}
		}
		.padding([.horizontal, .bottom], KKPadding2XL)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.blur(
			radius: audioModel.isDraggingToFCP || audioModel.paramsModalTemplate != nil
				|| audioModel.publishModalTemplate != nil
				|| audioModel.updateModalTemplate != nil ? 3 : 0
		)
		.animation(.easeInOut(duration: 0.2), value: audioModel.isDraggingToFCP)
		.allowsHitTesting(
			audioModel.paramsModalTemplate == nil && audioModel.publishModalTemplate == nil
				&& audioModel.updateModalTemplate == nil
				&& !processingCoordinator.isProcessing
		)
		.background(Color(nsColor: .windowBackground()))
		.onAppear {
			FontCache.warmup()
			#if DEBUG
				if Self.forceUpdateBanner {
					// Reset dismissal so the forced banner returns on every reopen.
					Self.dismissed = false
					updateDismissed = false
					currentVersion = KKUpdateChecker.shared().currentVersion
					availableVersion = "9.9.9"
					return
				}
			#endif
			KKUpdateChecker.shared().check { available in
				let checker = KKUpdateChecker.shared()
				guard available, let version = checker.availableVersion else { return }
				withAnimation {
					currentVersion = checker.currentVersion
					availableVersion = version
				}
			}
		}
		.overlay {
			if processingCoordinator.isProcessing {
				ProcessingOverlay(
					statusLabel: processingCoordinator.statusLabel,
					progress: processingCoordinator.progress,
					estimatedTimeRemaining: processingCoordinator.estimatedTimeRemaining,
					onCancel: { processingCoordinator.cancel() }
				)
				.transition(.opacity)
			}
			if let template = audioModel.paramsModalTemplate {
				PublishedParamsModal(
					templateName: template.name,
					params: audioModel.paramsModalParams,
					hasPerWordAnimation: audioModel.paramsModalHasPerWord,
					initialKinds: TemplatePublishedParamsStore.shared.kindMap(
						for: template.id),
					initialPerWordStartsAtZero: TemplatePublishedParamsStore.shared
						.params(for: template.id)?.perWordStartsAtZero ?? false,
					onSave: { params, perWordStartsAtZero in
						TemplatePublishedParamsStore.shared.setParams(
							params,
							hasPerWordAnimation: audioModel.paramsModalHasPerWord,
							for: template.id)
						TemplatePublishedParamsStore.shared.setPerWordStartsAtZero(
							perWordStartsAtZero, for: template.id)
						audioModel.paramsModalTemplate = nil
					},
					onDismiss: { audioModel.paramsModalTemplate = nil }
				)
				.transition(.opacity)
			}
			if let template = audioModel.publishModalTemplate {
				TemplatePublishModal(
					template: template,
					params: TemplatePublishedParamsStore.shared.params(for: template.id)?
						.allParams ?? [],
					hasPerWordAnimation: template.supportsPerWordAnimation,
					onDismiss: { audioModel.publishModalTemplate = nil }
				)
				.transition(.opacity)
			}
			if let (template, community) = audioModel.updateModalTemplate {
				TemplateUpdateModal(
					template: template,
					communityTemplate: community,
					params: TemplatePublishedParamsStore.shared.params(for: template.id)?
						.allParams ?? [],
					hasPerWordAnimation: template.supportsPerWordAnimation,
					onDismiss: { audioModel.updateModalTemplate = nil }
				)
				.transition(.opacity)
			}
		}
		.animation(.easeInOut(duration: 0.2), value: audioModel.paramsModalTemplate != nil)
		.animation(.easeInOut(duration: 0.2), value: audioModel.publishModalTemplate != nil)
		.animation(.easeInOut(duration: 0.2), value: audioModel.updateModalTemplate != nil)
	}

	private var topBar: some View {
		HStack(spacing: KKSpacingLG) {
			PillTabBar(selected: $selectedTab)
			WhatsNewButton(url: KKUpdateChecker.shared().notesURL)
			FeedbackButton(url: KKUpdateChecker.shared().feedbackURL)
			Spacer()
			toolNav
		}
		.overlay {
			Image("keyframeless-logo")
				.resizable()
				.scaledToFit()
				.frame(width: 36)
				.opacity(0.15)
		}
	}

	@ViewBuilder
	private var toolNav: some View {
		switch selectedTab {
		case .audio:
			PillIconToggle<AudioModel.Stage>(
				selection: $audioModel.stage,
				options: [
					(
						label: String(localized: "Setup"),
						systemImage: "sparkles.rectangle.stack.fill",
						value: .setup
					),
					(
						label: String(localized: "Edit"), systemImage: "bubble.and.pencil",
						value: .edit
					),
				],
				disabledValues: audioModel.audioClips.isEmpty ? [.edit] : []
			)
		}
	}
}
