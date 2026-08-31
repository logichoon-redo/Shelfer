//
//  SharingClientTests.swift
//  ShelferTests
//

import Foundation
import Testing
@testable import Shelfer

struct SharingClientTests {
    @Test func airDropTurnsTextIntoARealTemporaryTextFile() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let prepared = try AirDropItemPreparer.prepare(
            [.text("Meeting notes\nSecond line")],
            temporaryRoot: root
        )
        let textFile = try #require(prepared.urls.first)

        #expect(textFile.lastPathComponent == "Meeting notes.txt")
        #expect(try String(contentsOf: textFile, encoding: .utf8) == "Meeting notes\nSecond line")
        #expect(prepared.temporaryDirectory != nil)

        prepared.cleanup()
        #expect(!FileManager.default.fileExists(atPath: textFile.path))
    }

    @Test func airDropPreservesOrderAndDisambiguatesMatchingTextNames() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let existingFile = root.appendingPathComponent("original.pdf")

        let prepared = try AirDropItemPreparer.prepare(
            [
                .text("Same title\nFirst"),
                .file(existingFile),
                .text("Same title\nSecond"),
            ],
            temporaryRoot: root
        )
        defer { prepared.cleanup() }

        #expect(prepared.urls.map(\.lastPathComponent) == [
            "Same title.txt",
            "original.pdf",
            "Same title 2.txt",
        ])
    }

    @Test func airDropDoesNotCreateTemporaryFilesForExistingFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            root.appendingPathComponent("first.png"),
            root.appendingPathComponent("second.pdf"),
        ]

        let prepared = try AirDropItemPreparer.prepare(
            files.map(ShelfItem.Content.file),
            temporaryRoot: root
        )

        #expect(prepared.urls == files)
        #expect(prepared.temporaryDirectory == nil)
    }

    @Test func airDropTurnsStoredPathsIntoPrivatePlainTextFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let prepared = try AirDropItemPreparer.prepare(
            [
                .path("/Users/test/My Project/App.swift"),
                .path("/Users/test/My Project/Tests.swift"),
            ],
            temporaryRoot: root
        )
        defer { prepared.cleanup() }

        #expect(prepared.urls.map(\.lastPathComponent) == [
            "File Paths.txt",
            "File Paths 2.txt",
        ])
        #expect(
            try prepared.urls.map { try String(contentsOf: $0, encoding: .utf8) } == [
                "/Users/test/My Project/App.swift",
                "/Users/test/My Project/Tests.swift",
            ]
        )

        let directory = try #require(prepared.temporaryDirectory)
        let directoryPermissions = try FileManager.default.attributesOfItem(
            atPath: directory.path
        )[.posixPermissions] as? NSNumber
        let filePermissions = try FileManager.default.attributesOfItem(
            atPath: prepared.urls[0].path
        )[.posixPermissions] as? NSNumber
        #expect(directoryPermissions?.intValue == 0o700)
        #expect(filePermissions?.intValue == 0o600)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ShelferSharingClientTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
