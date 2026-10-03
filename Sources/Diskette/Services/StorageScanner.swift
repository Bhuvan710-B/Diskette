import Foundation

actor StorageScanner {
    private let fileManager = FileManager.default
    private let classifier = StorageClassifier()
    private let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey,
        .typeIdentifierKey,
        .creationDateKey,
        .contentModificationDateKey,
    ]

    func scanHomeDirectory(
        onProgress: @Sendable (ScanProgress) async -> Void
    ) async -> StorageScanResult {
        let roots = scanRoots()
        var nodes: [StorageNode] = []
        var initialChildren: [String: DirectoryScanResult] = [:]
        var unavailableLocations: [String] = []
        var scannedItemCount = 0

        for (index, root) in roots.enumerated() {
            if Task.isCancelled { break }
            await onProgress(ScanProgress(
                currentPath: root.url.path,
                completedRootCount: index,
                totalRootCount: roots.count,
                scannedItemCount: scannedItemCount,
                availableRoots: nodes.sorted { $0.allocatedSize > $1.allocatedSize },
                availableChildren: initialChildren
            ))

            guard fileManager.fileExists(atPath: root.url.path) else { continue }
            let result = scanDirectory(
                root.url,
                rootCategory: root.category,
                excludingDirectChildrenNamed: root.excludedChildNames
            )
            scannedItemCount += result.scannedItemCount

            if result.isAvailable {
                let rootValues = (try? root.url.resourceValues(forKeys: [.typeIdentifierKey, .creationDateKey, .contentModificationDateKey])) ?? URLResourceValues()
                let node = StorageNode(
                    name: root.title,
                    path: root.url.path,
                    allocatedSize: result.totalSize,
                    isDirectory: true,
                    category: root.category,
                    explanation: classifier.explanation(for: root.url, category: root.category, isDirectory: true),
                    skippedItemCount: result.skippedItemCount,
                    excludedChildNames: root.excludedChildNames,
                    fileExtension: root.url.pathExtension.isEmpty ? nil : root.url.pathExtension,
                    kind: kindFromExtension(root.url.pathExtension, isDirectory: true),
                    creationDate: rootValues.creationDate,
                    contentModificationDate: rootValues.contentModificationDate
                )
                nodes.append(node)
                initialChildren[node.path] = result.directoryResult
            } else {
                unavailableLocations.append(root.url.path)
            }
        }

        let sortedNodes = nodes.sorted { $0.allocatedSize > $1.allocatedSize }
        await onProgress(ScanProgress(
            currentPath: "Finishing scan",
            completedRootCount: roots.count,
            totalRootCount: roots.count,
            scannedItemCount: scannedItemCount,
            availableRoots: sortedNodes,
            availableChildren: initialChildren
        ))
        return StorageScanResult(
            roots: sortedNodes,
            initialChildren: initialChildren,
            unavailableLocations: unavailableLocations,
            wasCancelled: Task.isCancelled
        )
    }

    func scanChildren(of node: StorageNode) -> DirectoryScanResult {
        scanDirectory(
            node.url,
            rootCategory: node.category,
            excludingDirectChildrenNamed: node.excludedChildNames
        ).directoryResult
    }

    private func scanRoots() -> [RootSpecification] {
        let home = fileManager.homeDirectoryForCurrentUser
        let standardHomeFolders: Set<String> = [
            "Documents", "Downloads", "Pictures", "Movies", "Music", "Library", ".xcode"
        ]

        return [
            RootSpecification(title: "Applications", url: URL(fileURLWithPath: "/Applications"), category: .applications),
            RootSpecification(title: "Documents", url: home.appending(path: "Documents"), category: .documents),
            RootSpecification(title: "Downloads", url: home.appending(path: "Downloads"), category: .downloads),
            RootSpecification(title: "Pictures", url: home.appending(path: "Pictures"), category: .pictures),
            RootSpecification(title: "Movies", url: home.appending(path: "Movies"), category: .movies),
            RootSpecification(title: "Music", url: home.appending(path: "Music"), category: .music),
            RootSpecification(title: "Application Data", url: home.appending(path: "Library/Application Support"), category: .applicationData),
            RootSpecification(title: "Caches", url: home.appending(path: "Library/Caches"), category: .caches),
            RootSpecification(title: "Developer Data", url: home.appending(path: "Library/Developer"), category: .developerData),
            RootSpecification(title: "Xcode Data", url: home.appending(path: ".xcode"), category: .developerData),
            RootSpecification(title: "Other", url: home, category: .other, excludedChildNames: standardHomeFolders)
        ]
    }

    private func scanDirectory(
        _ url: URL,
        rootCategory: StorageCategory,
        excludingDirectChildrenNamed excludedNames: Set<String> = []
    ) -> ScanComputation {
        var childNodes: [StorageNode] = []
        var totalSize: Int64 = 0
        var skippedItemCount = 0
        var scannedItemCount = 0

        guard let directoryContents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ) else {
            return ScanComputation(nodes: [], totalSize: 0, skippedItemCount: 0, scannedItemCount: 0, isAvailable: false)
        }

        for child in directoryContents where !excludedNames.contains(child.lastPathComponent) {
            if Task.isCancelled { break }
            let calculation = calculateSize(at: child)
            scannedItemCount += calculation.scannedItemCount
            skippedItemCount += calculation.skippedItemCount
            totalSize += calculation.size

            let category = classifier.category(for: child, rootCategory: rootCategory)
            childNodes.append(StorageNode(
                name: child.lastPathComponent,
                path: child.path,
                allocatedSize: calculation.size,
                isDirectory: calculation.isDirectory,
                category: category,
                explanation: classifier.explanation(for: child, category: category, isDirectory: calculation.isDirectory),
                skippedItemCount: calculation.skippedItemCount,
                fileExtension: calculation.fileExt,
                kind: calculation.kind,
                creationDate: calculation.creationDate,
                contentModificationDate: calculation.contentModificationDate
            ))
        }

        return ScanComputation(
            nodes: childNodes.sorted { $0.allocatedSize > $1.allocatedSize },
            totalSize: totalSize,
            skippedItemCount: skippedItemCount,
            scannedItemCount: scannedItemCount,
            isAvailable: true
        )
    }

    private func calculateSize(at url: URL) -> SizeCalculation {
        guard let rootValues = try? url.resourceValues(forKeys: resourceKeys) else {
            return SizeCalculation(size: 0, isDirectory: false, skippedItemCount: 1, scannedItemCount: 0,
                                   fileExt: nil, kind: nil, creationDate: nil, contentModificationDate: nil)
        }
        let isDirectory = rootValues.isDirectory == true
        if rootValues.isSymbolicLink == true {
            return SizeCalculation(size: 0, isDirectory: false, skippedItemCount: 0, scannedItemCount: 0,
                                   fileExt: nil, kind: nil, creationDate: nil, contentModificationDate: nil)
        }

        let ext = url.pathExtension.isEmpty ? nil : url.pathExtension
        let kind = kindFromExtension(ext, isDirectory: isDirectory)
        let created = rootValues.creationDate
        let modified = rootValues.contentModificationDate

        if !isDirectory {
            return SizeCalculation(
                size: allocatedSize(from: rootValues),
                isDirectory: false,
                skippedItemCount: 0,
                scannedItemCount: 1,
                fileExt: ext,
                kind: kind,
                creationDate: created,
                contentModificationDate: modified
            )
        }

        var size: Int64 = 0
        var skippedItemCount = 0
        var scannedItemCount = 0
        var lastModified: Date?
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in
                skippedItemCount += 1
                return true
            }
        ) else {
            return SizeCalculation(size: 0, isDirectory: true, skippedItemCount: 1, scannedItemCount: 0,
                                   fileExt: ext, kind: kind, creationDate: created, contentModificationDate: modified)
        }

        for case let item as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? item.resourceValues(forKeys: resourceKeys) else {
                skippedItemCount += 1
                continue
            }
            if values.isSymbolicLink == true || values.isDirectory == true { continue }
            size += allocatedSize(from: values)
            scannedItemCount += 1
            if let m = values.contentModificationDate,
               lastModified == nil || m > lastModified! {
                lastModified = m
            }
        }

        return SizeCalculation(
            size: size,
            isDirectory: true,
            skippedItemCount: skippedItemCount,
            scannedItemCount: scannedItemCount,
            fileExt: ext,
            kind: kind,
            creationDate: created,
            contentModificationDate: lastModified ?? modified
        )
    }

    private func allocatedSize(from values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }
}

private struct RootSpecification {
    let title: String
    let url: URL
    let category: StorageCategory
    let excludedChildNames: Set<String>

    init(
        title: String,
        url: URL,
        category: StorageCategory,
        excludedChildNames: Set<String> = []
    ) {
        self.title = title
        self.url = url
        self.category = category
        self.excludedChildNames = excludedChildNames
    }
}

private struct ScanComputation: Sendable {
    let nodes: [StorageNode]
    let totalSize: Int64
    let skippedItemCount: Int
    let scannedItemCount: Int
    let isAvailable: Bool

    var directoryResult: DirectoryScanResult {
        DirectoryScanResult(nodes: nodes, totalSize: totalSize, skippedItemCount: skippedItemCount)
    }
}

private struct SizeCalculation {
    let size: Int64
    let isDirectory: Bool
    let skippedItemCount: Int
    let scannedItemCount: Int
    let fileExt: String?
    let kind: String?
    let creationDate: Date?
    let contentModificationDate: Date?
}

private func kindFromExtension(_ ext: String?, isDirectory: Bool) -> String? {
    guard let ext else { return isDirectory ? "Folder" : nil }
    switch ext.lowercased() {
    case "jpg", "jpeg": return "JPEG image"
    case "png": return "PNG image"
    case "gif": return "GIF image"
    case "heic", "heif": return "HEIC image"
    case "pdf": return "PDF document"
    case "zip", "tar", "gz", "tgz", "rar", "7z": return "Archive"
    case "mp4", "mov", "avi", "mkv", "webm": return "Video"
    case "mp3", "wav", "aac", "flac", "m4a": return "Audio"
    case "doc", "docx": return "Word document"
    case "xls", "xlsx", "csv": return "Spreadsheet"
    case "ppt", "pptx": return "Presentation"
    case "txt", "md", "rtf": return "Text document"
    case "app": return "Application"
    case "swift", "m", "mm", "h", "cpp", "c": return "Source code"
    default: return "\(ext) file"
    }
}
