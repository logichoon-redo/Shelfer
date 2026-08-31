//
//  FinderHandoffTests.swift
//  ShelferTests
//

import AppKit
import Testing
@testable import Shelfer

@MainActor
struct FinderHandoffTests {
    @Test func handoffReadsAllPathMetadataFromItsPrivatePasteboard() throws {
        let pasteboardName = NSPasteboard.Name(
            FinderHandoff.pasteboardNamePrefix + UUID().uuidString
        )
        let pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()

        let expected = [
            FinderHandoff.Item(path: "/tmp/one.json", isDirectory: false),
            FinderHandoff.Item(path: "/tmp/Folder", isDirectory: true),
        ]
        let data = try JSONEncoder().encode(expected)
        #expect(pasteboard.setData(data, forType: FinderHandoff.pasteboardType))

        var components = URLComponents()
        components.scheme = FinderHandoff.scheme
        components.host = FinderHandoff.host
        components.queryItems = [
            URLQueryItem(name: "pasteboard", value: pasteboardName.rawValue),
        ]

        let url = try #require(components.url)
        let request = try #require(FinderHandoff.request(from: url))
        #expect(request.items == expected)
        #expect(request.mode == .files)
    }

    @Test func pathHandoffPreservesEverySelectedPathWithoutFileAccess() throws {
        let pasteboardName = NSPasteboard.Name(
            FinderHandoff.pasteboardNamePrefix + UUID().uuidString
        )
        let pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()

        let duplicatePath = "/tmp/Folder/../Folder/document.txt"
        let items = [
            FinderHandoff.Item(path: duplicatePath, isDirectory: false),
            FinderHandoff.Item(path: "/tmp/Folder/document.txt", isDirectory: false),
            FinderHandoff.Item(path: "/tmp/Folder", isDirectory: true),
        ]
        let data = try JSONEncoder().encode(items)
        #expect(pasteboard.setData(data, forType: FinderHandoff.pasteboardType))

        var components = URLComponents()
        components.scheme = FinderHandoff.scheme
        components.host = FinderHandoff.host
        components.queryItems = [
            URLQueryItem(name: "pasteboard", value: pasteboardName.rawValue),
            URLQueryItem(name: "mode", value: FinderHandoff.Mode.paths.rawValue),
        ]

        let url = try #require(components.url)
        let request = try #require(FinderHandoff.request(from: url))
        #expect(request.mode == .paths)
        #expect(
            FinderHandoff.pathContents(from: request.items) == [
                .path("/tmp/Folder/document.txt"),
                .path("/tmp/Folder"),
            ]
        )
    }

    @Test func handoffRejectsUnrelatedPasteboards() {
        let url = URL(string: "shelfer://finder-add?pasteboard=public.board")!
        #expect(FinderHandoff.items(from: url) == nil)
    }

    @Test func handoffRejectsUnknownModesAndMalformedPayloads() throws {
        let unknownModeBoard = NSPasteboard.Name(
            FinderHandoff.pasteboardNamePrefix + UUID().uuidString
        )
        let unknownModePasteboard = NSPasteboard(name: unknownModeBoard)
        #expect(
            unknownModePasteboard.setData(
                try JSONEncoder().encode([
                    FinderHandoff.Item(path: "/tmp/file.txt", isDirectory: false)
                ]),
                forType: FinderHandoff.pasteboardType
            )
        )

        var unknownModeComponents = URLComponents()
        unknownModeComponents.scheme = FinderHandoff.scheme
        unknownModeComponents.host = FinderHandoff.host
        unknownModeComponents.queryItems = [
            URLQueryItem(name: "pasteboard", value: unknownModeBoard.rawValue),
            URLQueryItem(name: "mode", value: "unknown"),
        ]
        #expect(
            FinderHandoff.request(from: try #require(unknownModeComponents.url)) == nil
        )

        let malformedBoard = NSPasteboard.Name(
            FinderHandoff.pasteboardNamePrefix + UUID().uuidString
        )
        let malformedPasteboard = NSPasteboard(name: malformedBoard)
        #expect(
            malformedPasteboard.setData(
                Data("not-json".utf8),
                forType: FinderHandoff.pasteboardType
            )
        )

        var malformedComponents = URLComponents()
        malformedComponents.scheme = FinderHandoff.scheme
        malformedComponents.host = FinderHandoff.host
        malformedComponents.queryItems = [
            URLQueryItem(name: "pasteboard", value: malformedBoard.rawValue),
            URLQueryItem(name: "mode", value: FinderHandoff.Mode.paths.rawValue),
        ]
        #expect(
            FinderHandoff.request(from: try #require(malformedComponents.url)) == nil
        )
    }

    @Test func emptyHandoffPayloadIsRejected() throws {
        let pasteboardName = NSPasteboard.Name(
            FinderHandoff.pasteboardNamePrefix + UUID().uuidString
        )
        let pasteboard = NSPasteboard(name: pasteboardName)
        #expect(
            pasteboard.setData(
                try JSONEncoder().encode([FinderHandoff.Item]()),
                forType: FinderHandoff.pasteboardType
            )
        )

        var components = URLComponents()
        components.scheme = FinderHandoff.scheme
        components.host = FinderHandoff.host
        components.queryItems = [
            URLQueryItem(name: "pasteboard", value: pasteboardName.rawValue),
        ]

        #expect(FinderHandoff.request(from: try #require(components.url)) == nil)
    }

    @Test func directoryCoverageDoesNotConfuseSiblingPathPrefixes() {
        let root = URL(filePath: "/Users/me/Downloads", directoryHint: .isDirectory)

        #expect(
            FinderFileAccessAuthorizer.directory(
                root,
                contains: URL(filePath: "/Users/me/Downloads/file.json")
            )
        )
        #expect(
            !FinderFileAccessAuthorizer.directory(
                root,
                contains: URL(filePath: "/Users/me/Downloads-old/file.json")
            )
        )
    }
}
