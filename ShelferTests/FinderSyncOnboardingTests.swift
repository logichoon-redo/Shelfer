//
//  FinderSyncOnboardingTests.swift
//  ShelferTests
//

import Foundation
import Testing
@testable import Shelfer

@MainActor
struct FinderSyncOnboardingTests {
    @Test func autoPresentsTheFullOnboardingOnlyOnce() {
        #expect(FinderSyncOnboardingPolicy.shouldAutoPresent(hasPresented: false))
        #expect(!FinderSyncOnboardingPolicy.shouldAutoPresent(hasPresented: true))
    }

    @Test func modelOpensSettingsAndRefreshesExtensionStatus() {
        var isEnabled = false
        var settingsOpenCount = 0
        let access = FinderSyncExtensionAccess(
            isEnabled: { isEnabled },
            openSystemSettings: { settingsOpenCount += 1 }
        )
        let model = FinderSyncOnboardingModel(extensionAccess: access)

        #expect(!model.isEnabled)
        #expect(model.page == .basics)

        model.showFinderIntegration()
        #expect(model.page == .finderIntegration)

        model.openSystemSettings()
        #expect(settingsOpenCount == 1)

        isEnabled = true
        model.refresh()
        #expect(model.isEnabled)

        model.showBasics()
        #expect(model.page == .basics)
    }

    @Test func tutorialPreviewClipsAreBundledWithTheApp() {
        let appBundle = Bundle(for: AppDelegate.self)
        let resourceNames = [
            "tutorial-shake",
            "tutorial-collect",
            "tutorial-paths",
            "tutorial-actions",
        ]

        for resourceName in resourceNames {
            #expect(
                appBundle.url(
                    forResource: resourceName,
                    withExtension: "mov"
                ) != nil,
                "Missing bundled tutorial clip: \(resourceName).mov"
            )
        }
    }
}
