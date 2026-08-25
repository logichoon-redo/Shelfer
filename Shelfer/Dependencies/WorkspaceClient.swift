//
//  WorkspaceClient.swift
//  Shelfer
//

import AppKit
import ComposableArchitecture

/// The bits of the desktop the shelf reaches out to.
struct WorkspaceClient {
    var revealInFinder: @Sendable ([URL]) async -> Void
}

extension WorkspaceClient: DependencyKey {
    static let liveValue = WorkspaceClient(
        revealInFinder: { urls in
            guard !urls.isEmpty else { return }
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    )

    static let testValue = WorkspaceClient(revealInFinder: { _ in })
}

extension DependencyValues {
    var workspace: WorkspaceClient {
        get { self[WorkspaceClient.self] }
        set { self[WorkspaceClient.self] = newValue }
    }
}
