import AppKit
import SwiftUI

private let disketteAccent = Color(red: 0.40, green: 0.85, blue: 0.55)

struct ExplorerView: View {
    @StateObject private var store = ExplorerStore()
    @State private var hoveredChartPath: String?
    @State private var hoveredListItemPath: String?

    private var activeHoverPath: String? {
        hoveredChartPath ?? hoveredListItemPath
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .navigationTitle("Diskette")
        .toolbar { toolbar }
        .onAppear { store.startScan() }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // ── Sidebar ───────────────────────────────────────────────────────

    private var sidebar: some View {
        let selection = Binding<String?>(
            get: { store.breadcrumb.first?.path },
            set: { path in
                guard let path else { return }
                if let node = store.roots.first(where: { $0.path == path }) {
                    store.selectRoot(node)
                }
            }
        )
        return List(selection: selection) {
            Section("Locations") {
                ForEach(store.roots) { node in
                    StorageRow(node: node, showsPath: false, isActiveHover: false, isSelected: node.path == selection.wrappedValue)
                        .tag(node.path)
                        .help(node.path)
                }
            }
            if !store.unavailableLocations.isEmpty {
                Section("Unavailable") {
                    ForEach(store.unavailableLocations, id: \.self) { path in
                        Label(path, systemImage: "lock.slash")
                            .foregroundStyle(.secondary)
                            .help("Grant Full Disk Access if it should be included.")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Storage locations")
    }

    // ── Detail pane: chart centered, inspector below, dedicated Contents column on right ──

    private var detail: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider()

            HStack(spacing: 0) {
                // Main chart & inspector area (horizontally centered)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        // Chart — centered horizontally within available chart area
                        StorageMapView(
                            nodes: store.visualizationNodes,
                            selectedPath: store.selectedPath,
                            childrenMap: store.childrenByPath,
                            externalHoverPath: activeHoverPath,
                            onSelect: { store.selectNode($0) },
                            onOpen: { store.openNode($0) },
                            hoverUpdate: { path in
                                hoveredChartPath = path
                                if path != nil { hoveredListItemPath = nil }
                            }
                        )
                        .id(store.breadcrumb.last?.path ?? "root")
                        .frame(maxWidth: 400, maxHeight: 400)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 16)

                        // Inspector panel below the chart
                        InspectorView(node: store.selectedNode, store: store)
                            .frame(maxWidth: 440)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 1)
                            )
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                    }
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Single source of truth: Contents column (vertical, scrollable within window)
                SunburstLegendColumn(
                    nodes: store.visualizationNodes,
                    activeHoverPath: activeHoverPath,
                    selectedPath: store.selectedPath,
                    store: store,
                    onSelect: { store.selectNode($0) },
                    onOpen: { store.openNode($0) },
                    onReveal: { store.revealInFinder($0) },
                    onHover: { path in
                        hoveredListItemPath = path
                        if path != nil { hoveredChartPath = nil }
                    }
                )
                .frame(width: 290)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // ── Breadcrumb ────────────────────────────────────────────────────

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(store.breadcrumb.enumerated()), id: \.element.path) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    Button(node.name) {
                        store.revealAncestor(node)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == store.breadcrumb.count - 1 ? .primary : .secondary)
                    .accessibilityLabel(node.name)
                    .accessibilityHint("Shows this folder.")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Path")
    }

    // ── Empty state ───────────────────────────────────────────────────

    private var emptyChildren: some View {
        VStack(spacing: 8) {
            if let current = store.breadcrumb.last, store.isLoading(current) {
                ProgressView("Reading folder...")
            } else if store.isScanning && store.roots.isEmpty {
                ProgressView("Scanning this Mac...")
            } else if store.breadcrumb.isEmpty {
                Text("Locations appear as each scan completes.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No readable items in this folder.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // ── Toolbar ───────────────────────────────────────────────────────

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Diskette")
                    .font(.headline)
                Text(store.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 280, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        ToolbarItem(placement: .status) {
            if store.isScanning, let progress = store.progress {
                ProgressView(value: progress.fractionComplete)
                    .frame(width: 120)
                    .help("\(progress.completedRootCount) of \(progress.totalRootCount) locations")
                    .accessibilityLabel("Scan progress")
                    .accessibilityValue("\(progress.completedRootCount) of \(progress.totalRootCount) locations")
            } else if !store.roots.isEmpty {
                Text(store.scannedAllocatedSize.formattedByteCount)
                    .foregroundStyle(.secondary)
                    .help("Total allocated size of scanned locations.")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.rescan()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(store.isScanning)
            .help("Scan this Mac again.")
            .keyboardShortcut("r", modifiers: [.command])
        }
    }
}

// MARK: - Storage row

private struct StorageRow: View {
    let node: StorageNode
    let showsPath: Bool
    let isActiveHover: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color(DiskettePalette.baseColor(for: node.category)).opacity(isActiveHover || isSelected ? 1.0 : 0.0))
                .frame(width: 3)
                .accessibilityHidden(true)

            Image(systemName: node.isDirectory ? node.category.systemImage : "doc")
                .foregroundStyle(Color(DiskettePalette.baseColor(for: node.category)))
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .lineLimit(1)
                if showsPath {
                    Text(node.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if node.hasAccessibilityWarning {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help("Some items inside could not be read.")
                    .accessibilityLabel("Some items could not be read")
            }
            Text(node.allocatedSize.formattedByteCount)
                .foregroundStyle(isActiveHover ? .primary : .secondary)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .background(isActiveHover ? Color(DiskettePalette.baseColor(for: node.category)).opacity(0.12) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.name), \(node.allocatedSize.formattedByteCount), \(node.category.rawValue)")
    }
}

// MARK: - Date formatting

private let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
}()

// MARK: - Inspector panel

private struct InspectorView: View {
    let node: StorageNode?
    let store: ExplorerStore

    var body: some View {
        Group {
            if let node {
                VStack(alignment: .leading, spacing: 12) {
                    // Header
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: node.category.systemImage)
                                .font(.title3)
                                .foregroundStyle(Color(DiskettePalette.baseColor(for: node.category)))
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name)
                                    .font(.title3.weight(.semibold))
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Text(node.path)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            Button("Reveal in Finder") { store.revealInFinder(node) }
                            if node.isDirectory {
                                Button("Open Folder") { store.openNode(node) }
                                    .disabled(store.breadcrumb.last?.path == node.path)
                            }
                        }
                    }

                    // Info rows
                    VStack(alignment: .leading, spacing: 6) {
                        labeledRow("Type", typeDescription(for: node))
                        labeledRow("Allocated size", node.allocatedSize.formattedByteCount, isAccent: true)
                        labeledRow("Category", node.category.rawValue)
                        if let app = node.explanation.associatedApplication {
                            labeledRow("App", app)
                        }
                    }

                    // File details (only for files, only if any field present)
                    if !node.isDirectory, !fileDetailRows(node).isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(fileDetailRows(node), id: \.0) { row in
                                labeledRow(row.0, row.1)
                            }
                        }
                    }

                    // Warnings
                    if node.hasAccessibilityWarning {
                        Label(
                            "\(node.skippedItemCount) item\(node.skippedItemCount == 1 ? "" : "s") unreadable — size may be incomplete.",
                            systemImage: "lock.slash"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("Select an item to view details")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .accessibilityLabel("Select an item")
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityLabel("Inspector")
    }

    private func fileDetailRows(_ node: StorageNode) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let kind = node.kind, !kind.isEmpty {
            rows.append(("Kind", kind))
        }
        if let ext = node.fileExtension, !ext.isEmpty {
            rows.append(("Extension", ".\(ext)"))
        }
        if let created = node.creationDate {
            rows.append(("Created", dateFmt.string(from: created)))
        }
        if let modified = node.contentModificationDate {
            rows.append(("Modified", dateFmt.string(from: modified)))
        }
        return rows
    }

    private func labeledRow(_ label: String, _ value: String, isAccent: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
                .accessibilityHidden(true)
            Text(value)
                .font(.callout)
                .foregroundStyle(isAccent ? disketteAccent : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func typeDescription(for n: StorageNode) -> String {
        if n.isDirectory { return "Folder" }
        if let kind = n.kind, !kind.isEmpty { return kind }
        if let ext = n.fileExtension { return "\(ext.uppercased()) file" }
        return "File"
    }
}

// MARK: - Color legend column (Single source of truth for folder contents)

private struct SunburstLegendColumn: View {
    let nodes: [StorageNode]
    let activeHoverPath: String?
    let selectedPath: String?
    let store: ExplorerStore
    let onSelect: (StorageNode) -> Void
    let onOpen: (StorageNode) -> Void
    let onReveal: (StorageNode) -> Void
    let onHover: (String?) -> Void

    var body: some View {
        let sortedNodes = nodes.sorted { $0.allocatedSize > $1.allocatedSize }

        VStack(alignment: .leading, spacing: 0) {
            // Column Header
            HStack {
                Text("Contents")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(sortedNodes.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider()

            if sortedNodes.isEmpty {
                VStack(spacing: 8) {
                    if let current = store.breadcrumb.last, store.isLoading(current) {
                        ProgressView("Reading folder...")
                            .controlSize(.small)
                    } else if store.isScanning && store.roots.isEmpty {
                        ProgressView("Scanning this Mac...")
                            .controlSize(.small)
                    } else {
                        Text("No readable items in this folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(sortedNodes.enumerated()), id: \.element.path) { idx, node in
                            LegendRow(
                                node: node,
                                colorIndex: idx,
                                isActiveHover: node.path == activeHoverPath,
                                isSelected: node.path == selectedPath,
                                onSelect: { onSelect(node) },
                                onOpen: { onOpen(node) },
                                onReveal: { onReveal(node) },
                                onHover: { hovering in
                                    onHover(hovering ? node.path : nil)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder contents")
    }
}

// MARK: - Legend Row

private struct LegendRow: View {
    let node: StorageNode
    let colorIndex: Int
    let isActiveHover: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        let color = Color(DiskettePalette.color(for: colorIndex))
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            if node.isDirectory {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(color.opacity(0.85))
                    .frame(width: 14)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }

            Text(node.name)
                .font(.callout)
                .foregroundStyle(isSelected || isActiveHover ? Color.primary : Color.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if node.hasAccessibilityWarning {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Text(node.allocatedSize.formattedByteCount)
                .font(.caption.monospacedDigit())
                .foregroundStyle(disketteAccent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? color.opacity(0.20) : (isActiveHover ? color.opacity(0.10) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if node.isDirectory {
                onOpen()
            }
        }
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            onHover(hovering)
        }
        .contextMenu {
            if node.isDirectory {
                Button("Open") { onOpen() }
            }
            Button("Reveal in Finder") { onReveal() }
        }
        .help("\(node.name)\n\(node.allocatedSize.formattedByteCount)")
        .accessibilityLabel("\(node.name), \(node.allocatedSize.formattedByteCount)")
    }
}
