import Foundation

struct StorageClassifier: Sendable {
    func category(for url: URL, rootCategory: StorageCategory? = nil) -> StorageCategory {
        let path = url.path
        if path.contains("/Library/Caches") { return .caches }
        if path.contains("/Library/Developer") || path.contains(".xcode") || path.contains("DerivedData") { return .developerData }
        if path.contains("/Library/Application Support") { return .applicationData }
        return rootCategory ?? .other
    }

    func explanation(for url: URL, category: StorageCategory, isDirectory: Bool) -> StorageExplanation {
        let path = url.path
        let name = url.lastPathComponent

        if path == "/System" || path.hasPrefix("/System/") || path == "/usr" || path.hasPrefix("/usr/") {
            return StorageExplanation(
                summary: "A protected macOS system location.",
                purpose: "macOS uses this location for operating system components.",
                associatedApplication: "macOS",
                safety: .dangerous,
                deletionImpact: "Deleting or modifying its contents can damage macOS or prevent it from starting.",
                certainty: "This is a protected system path."
            )
        }

        switch category {
        case .caches:
            return StorageExplanation(
                summary: "Cached data created to make apps and services faster.",
                purpose: "Caches store temporary or regenerable files for faster access.",
                associatedApplication: appName(near: url),
                safety: .safe,
                deletionImpact: "The related app may be slower while it rebuilds this data. Some caches may require you to sign in again or re-download content.",
                certainty: "This location follows a standard macOS cache convention, but individual contents can vary."
            )
        case .applicationData:
            return StorageExplanation(
                summary: "Data stored by an application or service.",
                purpose: "Application Support commonly contains settings, local databases, downloads, and user-created app content.",
                associatedApplication: appName(near: url),
                safety: .caution,
                deletionImpact: "Deleting it can reset an app, remove offline content, or permanently lose local app data.",
                certainty: "Application Support is a standard location, but Diskette cannot determine the purpose of every item inside it."
            )
        case .developerData:
            return StorageExplanation(
                summary: "Files created by development tools.",
                purpose: "This may contain build products, simulators, toolchains, or project caches.",
                associatedApplication: developerTool(near: url),
                safety: .caution,
                deletionImpact: "Deleting it may force tools to rebuild, remove simulators, or affect local projects and tool configuration.",
                certainty: "This classification is based on common developer directory conventions."
            )
        case .applications:
            return StorageExplanation(
                summary: "An installed application or application bundle.",
                purpose: "Applications contain the executable code and resources needed to run software.",
                associatedApplication: name.replacingOccurrences(of: ".app", with: ""),
                safety: .caution,
                deletionImpact: "Removing an application stops it from being available. Its separate support data may remain elsewhere.",
                certainty: "Diskette recognizes this as an application location."
            )
        case .documents, .downloads, .pictures, .movies, .music:
            return StorageExplanation(
                summary: isDirectory ? "A personal folder." : "A personal file.",
                purpose: "This is stored in one of your personal media or document locations.",
                associatedApplication: nil,
                safety: .caution,
                deletionImpact: "Deleting it may permanently remove your personal data unless it is backed up elsewhere.",
                certainty: "Diskette can identify the enclosing standard personal folder, not the importance of this item."
            )
        case .other:
            return StorageExplanation(
                summary: isDirectory ? "A folder stored in your home directory." : "A file stored in your home directory.",
                purpose: "Diskette could not confidently assign a more specific category.",
                associatedApplication: nil,
                safety: .caution,
                deletionImpact: "Deleting it may affect data or settings. Review its contents and backups first.",
                certainty: "Diskette does not have enough deterministic evidence to explain this item more specifically."
            )
        }
    }

    private func appName(near url: URL) -> String? {
        let components = url.pathComponents
        guard let index = components.firstIndex(of: "Application Support"), components.indices.contains(index + 1) else { return nil }
        return components[index + 1]
    }

    private func developerTool(near url: URL) -> String? {
        let path = url.path.lowercased()
        if path.contains("xcode") || path.contains("deriveddata") { return "Xcode" }
        if path.contains("simulator") { return "Simulator" }
        return nil
    }
}
