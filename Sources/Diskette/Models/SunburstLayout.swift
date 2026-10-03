import AppKit
import Foundation
import SwiftUI

// MARK: - Segment types

struct SunburstSegment: Identifiable {
    let id: String                  // stable path-based id
    let node: StorageNode
    let depth: Int                  // 0 = innermost ring
    let startAngle: CGFloat         // radians, from -π to π (standard math coords)
    let endAngle: CGFloat
    let innerRadius: CGFloat        // ring inner edge, fixed per depth
    let outerRadius: CGFloat        // ring outer edge, fixed per depth
    let colorFamily: NSColor        // inherited from depth-0 ancestor
    let bisector: CGPoint           // unit vector at midpoint angle, for hover pop direction
}

struct SunburstLayout {
    let segments: [SunburstSegment]
    let rootTotal: Int64
    let maxDepth: Int
    static let centerRadius: CGFloat = 72   // inner radius of ring 0
    static let ringThickness: CGFloat = 34  // each ring thickness
    static let ringGap: CGFloat = 2.0       // gap between rings (slightly wider for visual breathing)
}

// MARK: - Palette — fixed 7-color from approved mockup

enum DiskettePalette {
    static let baseColors: [NSColor] = [
        NSColor(red: 0x37/255.0, green: 0x8A/255.0, blue: 0xDD/255.0, alpha: 1.0),   // #378ADD
        NSColor(red: 0x1D/255.0, green: 0x9E/255.0, blue: 0x75/255.0, alpha: 1.0),   // #1D9E75
        NSColor(red: 0xD8/255.0, green: 0x5A/255.0, blue: 0x30/255.0, alpha: 1.0),   // #D85A30
        NSColor(red: 0xBA/255.0, green: 0x75/255.0, blue: 0x17/255.0, alpha: 1.0),   // #BA7517
        NSColor(red: 0x7F/255.0, green: 0x77/255.0, blue: 0xDD/255.0, alpha: 1.0),   // #7F77DD
        NSColor(red: 0xD4/255.0, green: 0x53/255.0, blue: 0x7E/255.0, alpha: 1.0),   // #D4537E
        NSColor(red: 0x63/255.0, green: 0x99/255.0, blue: 0x22/255.0, alpha: 1.0),   // #639922
    ]

    /// Assign a distinct hue from the fixed palette based on index.
    static func color(for index: Int) -> NSColor {
        return baseColors[index % baseColors.count]
    }

    /// Lighten a color by adding `25 * depth` to each RGB channel, clamped to 255.
    static func lightened(_ base: NSColor, byDepth depth: Int) -> NSColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getRed(&r, green: &g, blue: &b, alpha: &a)
        let delta = CGFloat(25.0) / 255.0 * CGFloat(depth)
        let newR = min(r + delta, 1.0)
        let newG = min(g + delta, 1.0)
        let newB = min(b + delta, 1.0)
        return NSColor(red: newR, green: newG, blue: newB, alpha: a)
    }

    // Backward-compatible sidebar colour look-up (unchanged from prior palette).
    static func baseColor(for category: StorageCategory) -> NSColor {
        switch category {
        case .applications:      return NSColor(red: 0.22, green: 0.53, blue: 0.90, alpha: 1.0)
        case .documents:         return NSColor(red: 0.10, green: 0.62, blue: 0.44, alpha: 1.0)
        case .downloads:         return NSColor(red: 0.85, green: 0.35, blue: 0.15, alpha: 1.0)
        case .pictures:          return NSColor(red: 0.84, green: 0.32, blue: 0.51, alpha: 1.0)
        case .movies:            return NSColor(red: 0.90, green: 0.27, blue: 0.28, alpha: 1.0)
        case .music:             return NSColor(red: 0.00, green: 0.51, blue: 0.00, alpha: 1.0)
        case .applicationData:   return NSColor(red: 0.29, green: 0.23, blue: 0.65, alpha: 1.0)
        case .caches:            return NSColor(red: 0.79, green: 0.52, blue: 0.00, alpha: 1.0)
        case .developerData:     return NSColor(red: 0.65, green: 0.65, blue: 0.15, alpha: 1.0)
        case .other:             return NSColor(red: 0.42, green: 0.45, blue: 0.50, alpha: 1.0)
        }
    }
}

// MARK: - Angle-containment relationship check

let angleEpsilon: CGFloat = 0.001

/// Returns true if segment `a` is fully contained within segment `b`'s angular range, or vice versa.
/// Because this is a strict hierarchical partition, containment alone identifies the full ancestor/descendant chain.
func related(_ a: SunburstSegment, _ b: SunburstSegment) -> Bool {
    return (a.startAngle >= b.startAngle - angleEpsilon && a.endAngle <= b.endAngle + angleEpsilon) ||
           (b.startAngle >= a.startAngle - angleEpsilon && b.endAngle <= a.endAngle + angleEpsilon)
}

// MARK: - Layout builder — 3-ring radial (depth 0, 1, 2)

@MainActor
func buildSunburst(
    nodes: [StorageNode],
    childrenMap: [String: DirectoryScanResult]
) -> SunburstLayout {
    let total = nodes.reduce(Int64(0)) { $0 + $1.allocatedSize }
    guard total > 0 else {
        return SunburstLayout(segments: [], rootTotal: 0, maxDepth: 0)
    }

    var flat: [SunburstSegment] = []
    var seen = Set<String>()

    func add(_ seg: SunburstSegment) {
        guard !seen.contains(seg.id) else { return }
        seen.insert(seg.id)
        flat.append(seg)
    }

    // Build depth-0 segments (ring 0: direct children of current folder)
    let sortedNodes = nodes.sorted { $0.allocatedSize > $1.allocatedSize }
    let itemTotal0 = max(sortedNodes.reduce(Int64(0)) { $0 + $1.allocatedSize }, 1)

    var cursor = -Double.pi / 2
    var colorIndex = 0
    for item in sortedNodes {
        let arc = 2 * .pi * Double(item.allocatedSize) / Double(itemTotal0)

        let mid = cursor + arc / 2
        let bisector = CGPoint(x: cos(mid), y: sin(mid))
        // Ring 0 assigns each segment a distinct hue from the fixed palette
        let baseColor = DiskettePalette.color(for: colorIndex)
        colorIndex += 1
        let innerR = SunburstLayout.centerRadius
        let outerR = innerR + SunburstLayout.ringThickness

        add(SunburstSegment(
            id: item.path, node: item, depth: 0,
            startAngle: CGFloat(cursor), endAngle: CGFloat(cursor + arc),
            innerRadius: innerR, outerRadius: outerR,
            colorFamily: baseColor, bisector: bisector
        ))

        // Build depth-1 children
        if item.isDirectory, let childResult = childrenMap[item.path], childResult.totalSize > 0 {
            let children = childResult.nodes.sorted { $0.allocatedSize > $1.allocatedSize }
            if !children.isEmpty {
                let childTotal = max(children.reduce(Int64(0)) { $0 + $1.allocatedSize }, 1)
                var childCursor = cursor
                for child in children {
                    // Skip recursion into tiny segments that would render as unreadable slivers
                    let childArc = arc * Double(child.allocatedSize) / Double(childTotal)
                    guard childArc > 0.05 else { continue }
                    let childMid = childCursor + childArc / 2
                    let childBisector = CGPoint(x: cos(childMid), y: sin(childMid))
                    // Deeper segments inherit parent's color and lightened
                    let lightened = DiskettePalette.lightened(baseColor, byDepth: 1)
                    let childInner = innerR + SunburstLayout.ringThickness + SunburstLayout.ringGap
                    let childOuter = childInner + SunburstLayout.ringThickness
                    add(SunburstSegment(
                        id: child.path, node: child, depth: 1,
                        startAngle: CGFloat(childCursor), endAngle: CGFloat(childCursor + childArc),
                        innerRadius: childInner, outerRadius: childOuter,
                        colorFamily: lightened, bisector: childBisector
                    ))

                    // Build depth-2 grandchildren (only for directories with enough arc)
                    if child.isDirectory, let grandchildResult = childrenMap[child.path], grandchildResult.totalSize > 0 {
                        let grandchildren = grandchildResult.nodes.sorted { $0.allocatedSize > $1.allocatedSize }
                        if !grandchildren.isEmpty {
                            let grandTotal = max(grandchildren.reduce(Int64(0)) { $0 + $1.allocatedSize }, 1)
                            var grandCursor = childCursor
                            for grandchild in grandchildren {
                                let grandArc = childArc * Double(grandchild.allocatedSize) / Double(grandTotal)
                                // Skip even smaller segments
                                guard grandArc > 0.05 else { continue }
                                let grandMid = grandCursor + grandArc / 2
                                let grandBisector = CGPoint(x: cos(grandMid), y: sin(grandMid))
                                let deepLightened = DiskettePalette.lightened(baseColor, byDepth: 2)
                                let grandInner = childOuter + SunburstLayout.ringGap
                                let grandOuter = grandInner + SunburstLayout.ringThickness
                                add(SunburstSegment(
                                    id: grandchild.path, node: grandchild, depth: 2,
                                    startAngle: CGFloat(grandCursor), endAngle: CGFloat(grandCursor + grandArc),
                                    innerRadius: grandInner, outerRadius: grandOuter,
                                    colorFamily: deepLightened, bisector: grandBisector
                                ))
                                grandCursor += grandArc
                            }
                        }
                    }

                    childCursor += childArc
                }
            }
        }

        cursor += arc
    }

    let maxD = flat.contains(where: { $0.depth == 2 }) ? 2 : (flat.contains(where: { $0.depth == 1 }) ? 1 : 0)
    return SunburstLayout(segments: flat, rootTotal: total, maxDepth: maxD)
}

// MARK: - Synthetic "other" node factory (kept for preview/fallback use)

private extension StorageNode {
    init(otherOf source: StorageNode?, size: Int64) {
        self.init(
            name: "(other)",
            path: (source?.path ?? "/") + "/__other__",
            allocatedSize: size,
            isDirectory: false,
            category: source?.category ?? .other,
            explanation: StorageExplanation(
                summary: "Small items grouped together",
                purpose: "",
                associatedApplication: nil,
                safety: .safe,
                deletionImpact: "",
                certainty: ""
            ),
            skippedItemCount: 0
        )
    }
}

// MARK: - Preview data (sync, no async, no disk I/O)

struct FakePreviewData {
    static let nodes: [StorageNode] = [
        StorageNode(name: "Applications", path: "/Applications", allocatedSize: 8_500_000_000,
                     isDirectory: true, category: .applications,
                     explanation: StorageExplanation(summary: "Installed apps", purpose: "",
                                                      associatedApplication: nil, safety: .caution,
                                                      deletionImpact: "", certainty: ""),
                     skippedItemCount: 0),
        StorageNode(name: "Documents", path: "/Users/bhuvan/Documents", allocatedSize: 4_200_000_000,
                     isDirectory: true, category: .documents,
                     explanation: StorageExplanation(summary: "Personal docs", purpose: "",
                                                      associatedApplication: nil, safety: .caution,
                                                      deletionImpact: "", certainty: ""),
                     skippedItemCount: 0),
        StorageNode(name: "Downloads", path: "/Users/bhuvan/Downloads", allocatedSize: 2_100_000_000,
                     isDirectory: true, category: .downloads,
                     explanation: StorageExplanation(summary: "Downloaded files", purpose: "",
                                                      associatedApplication: nil, safety: .caution,
                                                      deletionImpact: "", certainty: ""),
                     skippedItemCount: 0),
        StorageNode(name: "Movies", path: "/Users/bhuvan/Movies", allocatedSize: 1_500_000_000,
                     isDirectory: true, category: .movies,
                     explanation: StorageExplanation(summary: "Movie files", purpose: "",
                                                      associatedApplication: nil, safety: .caution,
                                                      deletionImpact: "", certainty: ""),
                     skippedItemCount: 0),
    ]

    static let childrenMap: [String: DirectoryScanResult] = [
        "/Applications": DirectoryScanResult(nodes: [
            StorageNode(name: "Xcode.app", path: "/Applications/Xcode.app", allocatedSize: 5_000_000_000,
                         isDirectory: true, category: .applications,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
            StorageNode(name: "Safari.app", path: "/Applications/Safari.app", allocatedSize: 50_000_000,
                         isDirectory: true, category: .applications,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
        ], totalSize: 5_050_000_000, skippedItemCount: 0),
        "/Applications/Xcode.app": DirectoryScanResult(nodes: [
            StorageNode(name: "Contents", path: "/Applications/Xcode.app/Contents", allocatedSize: 3_000_000_000,
                         isDirectory: true, category: .applications,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
            StorageNode(name: "Info.plist", path: "/Applications/Xcode.app/Contents/Info.plist", allocatedSize: 1_000_000,
                         isDirectory: false, category: .other,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
        ], totalSize: 3_000_001_000, skippedItemCount: 0),
        "/Applications/Safari.app": DirectoryScanResult(nodes: [
            StorageNode(name: "Contents", path: "/Applications/Safari.app/Contents", allocatedSize: 30_000_000,
                         isDirectory: true, category: .applications,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
        ], totalSize: 30_000_000, skippedItemCount: 0),
        "/Users/bhuvan/Documents": DirectoryScanResult(nodes: [
            StorageNode(name: "Projects", path: "/Users/bhuvan/Documents/Projects", allocatedSize: 2_000_000_000,
                         isDirectory: true, category: .documents,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
            StorageNode(name: "Photos", path: "/Users/bhuvan/Documents/Photos", allocatedSize: 1_000_000_000,
                         isDirectory: true, category: .documents,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
        ], totalSize: 3_000_000_000, skippedItemCount: 0),
        "/Users/bhuvan/Documents/Projects": DirectoryScanResult(nodes: [
            StorageNode(name: "Diskette", path: "/Users/bhuvan/Documents/Projects/Diskette", allocatedSize: 1_200_000_000,
                         isDirectory: true, category: .developerData,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
            StorageNode(name: "Notes.txt", path: "/Users/bhuvan/Documents/Projects/Notes.txt", allocatedSize: 500_000_000,
                         isDirectory: false, category: .documents,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
        ], totalSize: 1_700_000_000, skippedItemCount: 0),
        "/Users/bhuvan/Documents/Photos": DirectoryScanResult(nodes: [
            StorageNode(name: "Vacation.jpg", path: "/Users/bhuvan/Documents/Photos/Vacation.jpg", allocatedSize: 600_000_000,
                         isDirectory: false, category: .pictures,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
            StorageNode(name: "Profile.png", path: "/Users/bhuvan/Documents/Photos/Profile.png", allocatedSize: 400_000_000,
                         isDirectory: false, category: .pictures,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
        ], totalSize: 1_000_000_000, skippedItemCount: 0),
        "/Users/bhuvan/Downloads": DirectoryScanResult(nodes: [
            StorageNode(name: "Installer.dmg", path: "/Users/bhuvan/Downloads/Installer.dmg", allocatedSize: 1_500_000_000,
                         isDirectory: false, category: .other,
                         explanation: StorageExplanation(summary: "", purpose: "",
                                                          associatedApplication: nil, safety: .safe,
                                                          deletionImpact: "", certainty: ""),
                         skippedItemCount: 0),
        ], totalSize: 1_500_000_000, skippedItemCount: 0),
    ]
}

// Preview (for Xcode canvas only — does not compile via swift build):
// #Preview("Sunburst 3-ring with fake data") {
//     StorageMapView(
//         nodes: FakePreviewData.nodes,
//         selectedPath: nil,
//         childrenMap: FakePreviewData.childrenMap,
//         onSelect: { _ in },
//         onOpen: { _ in },
//         hoverUpdate: { _ in }
//     )
//     .frame(width: 500, height: 500)
// }
