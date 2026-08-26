//
//  ShelfSurfaceTests.swift
//  ShelferTests
//

import AppKit
import Testing
@testable import Shelfer

@MainActor
struct ShelfSurfaceTests {
    @Test func movementSurfaceAcceptsTheFirstMouseFromAnInactiveApp() {
        let surface = ShelfSurface.SurfaceView()

        #expect(surface.acceptsFirstMouse(for: nil))
    }
}
