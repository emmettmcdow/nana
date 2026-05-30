//
//  ContextManager.swift
//  nana
//

import Foundation
import SwiftUI

enum ContextSource: Codable, Equatable {
    case iCloudContainer(identifier: String)
    case userBookmark(bookmarkData: Data)
}

struct WorkspaceContext: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var source: ContextSource
}

class ContextManager: ObservableObject {
    @Published private(set) var contexts: [WorkspaceContext] = []
    @Published private(set) var activeID: UUID?

    private var accessedURL: URL?
    private var accessedKind: ContextSource?

    private let contextsKey = "contexts.list"
    private let activeIDKey = "contexts.activeID"

    init() {
        load()
    }

    var activeContext: WorkspaceContext? {
        guard let id = activeID else { return nil }
        return contexts.first(where: { $0.id == id })
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: contextsKey),
           let decoded = try? JSONDecoder().decode([WorkspaceContext].self, from: data)
        {
            contexts = decoded
        }
        if let s = UserDefaults.standard.string(forKey: activeIDKey),
           let id = UUID(uuidString: s)
        {
            activeID = id
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(contexts) {
            UserDefaults.standard.set(data, forKey: contextsKey)
        }
        if let id = activeID {
            UserDefaults.standard.set(id.uuidString, forKey: activeIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeIDKey)
        }
    }

    /// Adds an iCloud context if no contexts exist. Returns the context that should be activated.
    func bootstrapICloudIfNeeded() -> WorkspaceContext? {
        if !contexts.isEmpty {
            return activeContext ?? contexts.first
        }
        guard let containerID = Bundle.main.object(forInfoDictionaryKey: "CloudKitContainerIdentifier") as? String else {
            print("ContextManager: no CloudKitContainerIdentifier in Info.plist; cannot bootstrap")
            return nil
        }
        let entry = WorkspaceContext(id: UUID(), displayName: "Notes",
                                     source: .iCloudContainer(identifier: containerID))
        contexts.append(entry)
        activeID = entry.id
        save()
        return entry
    }

    /// Registers a new user-picked directory as a context, persisting a security-scoped bookmark.
    func addUserContext(url: URL) -> WorkspaceContext? {
        guard let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            print("ContextManager: failed to create bookmark for \(url.path)")
            return nil
        }
        let entry = WorkspaceContext(id: UUID(),
                                     displayName: url.lastPathComponent,
                                     source: .userBookmark(bookmarkData: bookmarkData))
        contexts.append(entry)
        save()
        return entry
    }

    func setActive(_ id: UUID) {
        guard contexts.contains(where: { $0.id == id }) else { return }
        activeID = id
        save()
    }

    /// Resolves a context to a URL and begins access (security-scoped for user bookmarks).
    /// Must be paired with stopAccessing(). Only one context may be accessed at a time.
    func startAccessing(_ ctx: WorkspaceContext) -> URL? {
        switch ctx.source {
        case let .iCloudContainer(id):
            let fm = FileManager.default
            guard let url = fm.url(forUbiquityContainerIdentifier: id) else {
                print("ContextManager: could not resolve iCloud container \(id)")
                return nil
            }
            try? fm.startDownloadingUbiquitousItem(at: url)
            accessedURL = url
            accessedKind = ctx.source
            return url

        case let .userBookmark(data):
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                print("ContextManager: bookmark for \(ctx.displayName) failed to resolve")
                return nil
            }
            guard url.startAccessingSecurityScopedResource() else {
                print("ContextManager: could not start security-scoped access for \(ctx.displayName)")
                return nil
            }
            accessedURL = url
            accessedKind = ctx.source
            return url
        }
    }

    func stopAccessing() {
        guard let url = accessedURL, let kind = accessedKind else { return }
        switch kind {
        case .iCloudContainer:
            break
        case .userBookmark:
            url.stopAccessingSecurityScopedResource()
        }
        accessedURL = nil
        accessedKind = nil
    }
}
