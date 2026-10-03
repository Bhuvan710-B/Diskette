import AppKit
import Foundation
import SwiftUI

@MainActor
final class ExplorerStore: ObservableObject {
    @Published private(set) var roots: [StorageNode] = []
    @Published private(set) var childrenByPath: [String: DirectoryScanResult] = [:]
    @Published private(set) var loadingPaths: Set<String> = []
    @Published private(set) var unavailableLocations: [String] = []
    @Published private(set) var progress: ScanProgress?
    @Published private(set) var isScanning = false
    @Published private(set) var wasCancelled = false
    @Published var selectedPath: String?
    @Published var breadcrumb: [StorageNode] = []

    private let scanner = StorageScanner()
    private var scanTask: Task<Void, Never>?

    var selectedNode: StorageNode? {
        guard let selectedPath else { return nil }
        if let selected = breadcrumb.last, selected.path == selectedPath {
            return selected
        }
        return node(at: selectedPath)
    }

    var visibleChildren: [StorageNode] {
        guard let current = breadcrumb.last else { return roots }
        return childrenByPath[current.path]?.nodes ?? []
    }

    var visualizationNodes: [StorageNode] {
        breadcrumb.isEmpty ? roots : visibleChildren
    }

    var scannedAllocatedSize: Int64 {
        roots.reduce(0) { $0 + $1.allocatedSize }
    }

    var statusText: String {
        if isScanning, let progress {
            let current = URL(fileURLWithPath: progress.currentPath).lastPathComponent
            return "Scanning \(current) · \(progress.scannedItemCount.formatted()) items"
        }
        if wasCancelled {
            return "Scan cancelled. Showing completed locations only."
        }
        if roots.isEmpty {
            return "No accessible storage locations were found."
        }
        return "Allocated sizes from this Mac. Not guaranteed reclaimable space."
    }

    func startScan() {
        scanTask?.cancel()
        roots = []
        childrenByPath = [:]
        loadingPaths = []
        unavailableLocations = []
        progress = nil
        wasCancelled = false
        selectedPath = nil
        breadcrumb = []
        isScanning = true

        scanTask = Task { [scanner] in
            let result = await scanner.scanHomeDirectory { progress in
                await MainActor.run {
                    self.progress = progress
                    self.roots = progress.availableRoots
                    self.childrenByPath.merge(progress.availableChildren) { _, new in new }
                    if self.selectedPath == nil, let first = progress.availableRoots.first {
                        self.selectRoot(first)
                    }
                }
            }

            guard !Task.isCancelled else { return }
            self.roots = result.roots
            self.childrenByPath.merge(result.initialChildren) { _, new in new }
            self.unavailableLocations = result.unavailableLocations
            self.wasCancelled = result.wasCancelled
            self.isScanning = false
            if selectedPath == nil, let first = result.roots.first {
                selectRoot(first)
            }
        }
    }

    func rescan() {
        startScan()
    }

    func selectRoot(_ node: StorageNode) {
        breadcrumb = [node]
        selectedPath = node.path
        ensureChildren(of: node)
    }

    func selectNode(_ node: StorageNode) {
        selectedPath = node.path
        if node.isDirectory, let current = breadcrumb.last, current.path != node.path {
            if !breadcrumb.contains(where: { $0.path == node.path }) {
                breadcrumb.append(node)
            }
            ensureChildren(of: node)
        }
    }

    func openNode(_ node: StorageNode) {
        selectedPath = node.path
        guard node.isDirectory else { return }
        if let index = breadcrumb.firstIndex(where: { $0.path == node.path }) {
            breadcrumb = Array(breadcrumb.prefix(through: index))
        } else {
            breadcrumb.append(node)
        }
        ensureChildren(of: node)
    }

    func revealAncestor(_ node: StorageNode) {
        guard let index = breadcrumb.firstIndex(where: { $0.path == node.path }) else { return }
        breadcrumb = Array(breadcrumb.prefix(through: index))
        selectedPath = node.path
        ensureChildren(of: node)
    }

    func revealInFinder(_ node: StorageNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func children(for node: StorageNode) -> [StorageNode] {
        childrenByPath[node.path]?.nodes ?? []
    }

    func isLoading(_ node: StorageNode) -> Bool {
        loadingPaths.contains(node.path)
    }

    private func node(at path: String) -> StorageNode? {
        if let root = roots.first(where: { $0.path == path }) {
            return root
        }
        // Search the currently-browsed directory's children — this is the fast path
        // used most of the time when a user clicks an item in the hierarchy panel.
        if let current = breadcrumb.last,
           let children = childrenByPath[current.path],
           let match = children.nodes.first(where: { $0.path == path }) {
            return match
        }
        // Fallback: search all cached children (lazy-loaded directories).
        for result in childrenByPath.values {
            if let match = result.nodes.first(where: { $0.path == path }) {
                return match
            }
        }
        return breadcrumb.first(where: { $0.path == path })
    }

    private func ensureChildren(of node: StorageNode) {
        guard node.isDirectory, childrenByPath[node.path] == nil, !loadingPaths.contains(node.path) else { return }
        loadingPaths.insert(node.path)
        Task { [scanner] in
            let result = await scanner.scanChildren(of: node)
            guard !Task.isCancelled else { return }
            childrenByPath[node.path] = result
            loadingPaths.remove(node.path)
        }
    }
}
