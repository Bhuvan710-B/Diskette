import Foundation

struct StorageNode: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let allocatedSize: Int64
    let isDirectory: Bool
    let category: StorageCategory
    let explanation: StorageExplanation
    let skippedItemCount: Int
    let excludedChildNames: Set<String>

    // Metadata collected from URLResourceValues at scan time.
    let fileExtension: String?        // e.g. "jpg", "zip" — nil for directories
    let kind: String?                 // "PDF document", "JPEG image", "Folder", etc.
    let creationDate: Date?
    let contentModificationDate: Date?

    init(
        name: String,
        path: String,
        allocatedSize: Int64,
        isDirectory: Bool,
        category: StorageCategory,
        explanation: StorageExplanation,
        skippedItemCount: Int,
        excludedChildNames: Set<String> = [],
        fileExtension: String? = nil,
        kind: String? = nil,
        creationDate: Date? = nil,
        contentModificationDate: Date? = nil
    ) {
        self.name = name
        self.path = path
        self.allocatedSize = allocatedSize
        self.isDirectory = isDirectory
        self.category = category
        self.explanation = explanation
        self.skippedItemCount = skippedItemCount
        self.excludedChildNames = excludedChildNames
        self.fileExtension = fileExtension
        self.kind = kind
        self.creationDate = creationDate
        self.contentModificationDate = contentModificationDate
    }

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }

    var hasAccessibilityWarning: Bool {
        skippedItemCount > 0
    }
}

struct StorageExplanation: Hashable, Sendable {
    let summary: String
    let purpose: String
    let associatedApplication: String?
    let safety: StorageSafetyLevel
    let deletionImpact: String
    let certainty: String
}

enum StorageSafetyLevel: String, Hashable, Sendable {
    case safe
    case caution
    case dangerous

    var title: String {
        switch self {
        case .safe: "Generally safe"
        case .caution: "Use caution"
        case .dangerous: "Potentially dangerous"
        }
    }
}

enum StorageCategory: String, CaseIterable, Hashable, Sendable {
    case applications = "Applications"
    case documents = "Documents"
    case downloads = "Downloads"
    case pictures = "Pictures"
    case movies = "Movies"
    case music = "Music"
    case applicationData = "Application Data"
    case caches = "Caches"
    case developerData = "Developer Data"
    case other = "Other"

    var systemImage: String {
        switch self {
        case .applications: "app.dashed"
        case .documents: "doc.text"
        case .downloads: "arrow.down.circle"
        case .pictures: "photo"
        case .movies: "film"
        case .music: "music.note"
        case .applicationData: "tray.full"
        case .caches: "arrow.triangle.2.circlepath"
        case .developerData: "hammer"
        case .other: "folder"
        }
    }
}

struct ScanProgress: Sendable {
    let currentPath: String
    let completedRootCount: Int
    let totalRootCount: Int
    let scannedItemCount: Int
    let availableRoots: [StorageNode]
    let availableChildren: [String: DirectoryScanResult]

    var fractionComplete: Double {
        guard totalRootCount > 0 else { return 0 }
        return Double(completedRootCount) / Double(totalRootCount)
    }
}

struct StorageScanResult: Sendable {
    let roots: [StorageNode]
    let initialChildren: [String: DirectoryScanResult]
    let unavailableLocations: [String]
    let wasCancelled: Bool
}

struct DirectoryScanResult: Sendable {
    let nodes: [StorageNode]
    let totalSize: Int64
    let skippedItemCount: Int
}
