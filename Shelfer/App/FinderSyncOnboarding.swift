//
//  FinderSyncOnboarding.swift
//  Shelfer
//

import AppKit
import AVFoundation
import Combine
import FinderSync
import SwiftUI

enum FinderSyncOnboardingPolicy {
    static let hasPresentedKey = "onboarding.hasPresented.v2"

    static func shouldAutoPresent(hasPresented: Bool) -> Bool {
        !hasPresented
    }
}

enum ShelferOnboardingPage: Int, CaseIterable, Hashable {
    case basics
    case finderIntegration
}

private enum ShelferTutorialFeature: String, CaseIterable, Identifiable {
    case shake
    case collect
    case paths
    case actions

    var id: Self { self }

    var icon: String {
        switch self {
        case .shake:
            "hand.draw.fill"
        case .collect:
            "plus.rectangle.on.folder.fill"
        case .paths:
            "option"
        case .actions:
            "arrow.up.and.down.and.arrow.left.and.right"
        }
    }

    var title: String {
        switch self {
        case .shake:
            "Pick up and shake"
        case .collect:
            "Collect as you go"
        case .paths:
            "Keep paths for the CLI"
        case .actions:
            "Use it anywhere"
        }
    }

    var description: String {
        switch self {
        case .shake:
            "Drag files in Finder and shake the pointer to create a shelf."
        case .collect:
            "Drop files, folders, text, or links onto the same shelf."
        case .paths:
            "Hold Option while dragging to store paths instead of file data."
        case .actions:
            "Drag items out, double-click to copy, or right-click for more actions."
        }
    }

    var videoResource: String {
        switch self {
        case .shake:
            "tutorial-shake"
        case .collect:
            "tutorial-collect"
        case .paths:
            "tutorial-paths"
        case .actions:
            "tutorial-actions"
        }
    }
}

@MainActor
struct FinderSyncExtensionAccess {
    var isEnabled: () -> Bool
    var openSystemSettings: () -> Void

    static let live = Self(
        isEnabled: { FIFinderSyncController.isExtensionEnabled },
        openSystemSettings: {
            FIFinderSyncController.showExtensionManagementInterface()
        }
    )
}

@MainActor
final class FinderSyncOnboardingModel: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var page: ShelferOnboardingPage = .basics

    private let extensionAccess: FinderSyncExtensionAccess

    init(extensionAccess: FinderSyncExtensionAccess) {
        self.extensionAccess = extensionAccess
        self.isEnabled = extensionAccess.isEnabled()
    }

    convenience init() {
        self.init(extensionAccess: .live)
    }

    func refresh() {
        isEnabled = extensionAccess.isEnabled()
    }

    func openSystemSettings() {
        extensionAccess.openSystemSettings()
    }

    func showBasics() {
        page = .basics
    }

    func showFinderIntegration() {
        page = .finderIntegration
        refresh()
    }
}

@MainActor
final class FinderSyncOnboardingController {
    private let defaults: UserDefaults
    private let extensionAccess: FinderSyncExtensionAccess
    private var model: FinderSyncOnboardingModel?
    private var windowController: NSWindowController?

    init(
        defaults: UserDefaults = .standard,
        extensionAccess: FinderSyncExtensionAccess
    ) {
        self.defaults = defaults
        self.extensionAccess = extensionAccess
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, extensionAccess: .live)
    }

    func presentIfNeeded() {
        guard FinderSyncOnboardingPolicy.shouldAutoPresent(
            hasPresented: defaults.bool(
                forKey: FinderSyncOnboardingPolicy.hasPresentedKey
            )
        ) else {
            return
        }

        defaults.set(
            true,
            forKey: FinderSyncOnboardingPolicy.hasPresentedKey
        )
        present()
    }

    func present() {
        if let windowController {
            model?.refresh()
            model?.showBasics()
            show(windowController)
            return
        }

        let model = FinderSyncOnboardingModel(extensionAccess: extensionAccess)
        let rootView = FinderSyncOnboardingView(
            model: model,
            dismiss: { [weak self] in
                self?.windowController?.close()
            }
        )
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Getting Started"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 520))
        window.minSize = window.frame.size
        window.maxSize = window.frame.size
        window.center()
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let windowController = NSWindowController(window: window)
        self.model = model
        self.windowController = windowController
        show(windowController)
    }

    func refreshIfPresented() {
        guard windowController?.window?.isVisible == true else { return }
        model?.refresh()
    }

    private func show(_ windowController: NSWindowController) {
        NSApp.activate()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }
}

private struct FinderSyncOnboardingView: View {
    @ObservedObject var model: FinderSyncOnboardingModel
    let dismiss: () -> Void
    @State private var selectedFeature: ShelferTutorialFeature = .shake

    var body: some View {
        VStack(spacing: 0) {
            pageIndicator
                .padding(.bottom, 20)

            Group {
                switch model.page {
                case .basics:
                    basicsPage

                case .finderIntegration:
                    finderIntegrationPage
                }
            }
            .id(model.page)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(.easeInOut(duration: 0.28), value: model.page)

            Spacer(minLength: 16)

            footer
        }
        .padding(.horizontal, 40)
        .padding(.top, 30)
        .padding(.bottom, 28)
        .frame(width: 760, height: 520)
    }

    private var basicsPage: some View {
        VStack(spacing: 0) {
            onboardingHeader(
                icon: "cursorarrow.motionlines",
                title: "Meet Shelfer",
                description: "Keep files, text, and useful paths close while you work."
            )

            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 8) {
                    ForEach(ShelferTutorialFeature.allCases) { feature in
                        tutorialRow(feature)
                    }
                }
                .frame(width: 364)
                .animation(.easeInOut(duration: 0.24), value: selectedFeature)

                tutorialPreview
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 24)

            Label(
                "Tip: Double-click a lower corner to tuck a shelf against either screen edge.",
                systemImage: "lightbulb.fill"
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 16)
        }
    }

    private var finderIntegrationPage: some View {
        VStack(spacing: 0) {
            onboardingHeader(
                icon: "folder.badge.gearshape",
                title: "Use Shelfer from Finder",
                description: "Enable Shelfer Finder Menu to put Add to Shelfer and "
                    + "Add Paths to Shelfer directly in Finder’s shortcut menu."
            )

            VStack(alignment: .leading, spacing: 13) {
                onboardingStep(
                    number: 1,
                    text: "Open the Finder Extensions settings page."
                )
                onboardingStep(
                    number: 2,
                    text: "Turn on “Shelfer Finder Menu”."
                )
                onboardingStep(
                    number: 3,
                    text: "Return to Shelfer and confirm the status below."
                )
            }
            .padding(18)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
            .padding(.top, 24)

            statusView
                .padding(.top, 18)
        }
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity)
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(ShelferOnboardingPage.allCases, id: \.self) { page in
                Capsule()
                    .fill(page == model.page ? Color.primary : Color.secondary.opacity(0.25))
                    .frame(width: page == model.page ? 18 : 7, height: 7)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.page)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(model.page.rawValue + 1) of 2")
    }

    @ViewBuilder
    private var footer: some View {
        switch model.page {
        case .basics:
            HStack {
                Button("Skip") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Continue") {
                    model.showFinderIntegration()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }

        case .finderIntegration:
            HStack(spacing: 10) {
                Button("Back") {
                    model.showBasics()
                }

                Spacer()

                if model.isEnabled {
                    Button("Open Finder Settings") {
                        model.openSystemSettings()
                    }

                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not Now") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Check Again") {
                        model.refresh()
                    }

                    Button("Open System Settings") {
                        model.openSystemSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func onboardingHeader(
        icon: String,
        title: String,
        description: String
    ) -> some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
                .padding(.bottom, 16)

            Text(title)
                .font(.system(size: 25, weight: .semibold))

            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 430)
                .padding(.top, 9)
        }
    }

    private func tutorialRow(_ feature: ShelferTutorialFeature) -> some View {
        let isSelected = selectedFeature == feature

        return Button {
            withAnimation(.easeInOut(duration: 0.24)) {
                selectedFeature = feature
            }
        } label: {
            HStack(alignment: isSelected ? .top : .center, spacing: 14) {
                Image(systemName: feature.icon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    .padding(.top, isSelected ? 1 : 0)

                VStack(alignment: .leading, spacing: isSelected ? 6 : 2) {
                    Text(feature.title)
                        .font(.system(size: 13, weight: .semibold))

                    Text(feature.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(isSelected ? nil : 1)
                        .fixedSize(horizontal: false, vertical: isSelected)
                        .lineSpacing(2)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, isSelected ? 11 : 7)
            .frame(minHeight: isSelected ? 76 : 48, alignment: .topLeading)
            .background(
                isSelected
                    ? Color.blue.opacity(0.14)
                    : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityIdentifier("tutorial.feature.\(feature.rawValue)")
        .accessibilityLabel(feature.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(
            "Select to show the full description and play this feature preview"
        )
    }

    private var tutorialPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15)
                .fill(Color.black.opacity(0.84))

            TutorialPreviewPlayer(resourceName: selectedFeature.videoResource)
                .id(selectedFeature)
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .transition(.opacity)
                .accessibilityLabel("\(selectedFeature.title) preview")

            LinearGradient(
                colors: [.clear, .black.opacity(0.62)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .allowsHitTesting(false)

            VStack {
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text(selectedFeature.title)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(12)
            }
            .allowsHitTesting(false)
        }
        .frame(height: 232)
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.18), value: selectedFeature)
    }

    private var statusView: some View {
        Label(
            model.isEnabled
                ? "Finder integration is enabled"
                : "Finder integration is not enabled yet",
            systemImage: model.isEnabled
                ? "checkmark.circle.fill"
                : "exclamationmark.circle.fill"
        )
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(model.isEnabled ? Color.green : Color.secondary)
        .contentTransition(.symbolEffect(.replace))
        .animation(.easeInOut(duration: 0.25), value: model.isEnabled)
    }

    private func onboardingStep(number: Int, text: String) -> some View {
        HStack(spacing: 12) {
            Text(String(number))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(.blue, in: Circle())

            Text(text)
                .font(.system(size: 13))
        }
    }
}

private struct TutorialPreviewPlayer: NSViewRepresentable {
    let resourceName: String

    func makeNSView(context: Context) -> TutorialLoopingPlayerView {
        TutorialLoopingPlayerView()
    }

    func updateNSView(_ nsView: TutorialLoopingPlayerView, context: Context) {
        let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "mov",
            subdirectory: "TutorialClips"
        ) ?? Bundle.main.url(forResource: resourceName, withExtension: "mov")
        nsView.play(url: url)
    }

    static func dismantleNSView(
        _ nsView: TutorialLoopingPlayerView,
        coordinator: Void
    ) {
        nsView.stop()
    }
}

private final class TutorialLoopingPlayerView: NSView {
    private let playerLayer = AVPlayerLayer()
    private var queuePlayer: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?
    private var currentURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            queuePlayer?.pause()
        } else {
            queuePlayer?.play()
        }
    }

    func play(url: URL?) {
        guard let url else {
            stop()
            return
        }
        guard url != currentURL else {
            queuePlayer?.play()
            return
        }

        stop()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        playerLayer.player = player
        queuePlayer = player
        playerLooper = AVPlayerLooper(player: player, templateItem: item)
        currentURL = url
        player.play()
    }

    func stop() {
        queuePlayer?.pause()
        playerLayer.player = nil
        playerLooper = nil
        queuePlayer = nil
        currentURL = nil
    }
}
