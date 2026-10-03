import AppKit
import SwiftUI

private let disketteAccent = Color(red: 0.40, green: 0.85, blue: 0.55)

// MARK: - View

struct StorageMapView: View {
    let nodes: [StorageNode]
    let selectedPath: String?
    let childrenMap: [String: DirectoryScanResult]
    var externalHoverPath: String? = nil
    let onSelect: (StorageNode) -> Void
    let onOpen: (StorageNode) -> Void
    let hoverUpdate: ((String?) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredPath: String?
    @State private var prevLayout: SunburstLayout?
    @State private var animProgress: Double = 1.0

    private var effectiveHoveredPath: String? {
        hoveredPath ?? externalHoverPath
    }

    private var layout: SunburstLayout {
        buildSunburst(nodes: nodes, childrenMap: childrenMap)
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let localSize = min(w, h)
            let localCenter = CGPoint(x: localSize / 2, y: localSize / 2)
            let localOuterR = localSize * 0.46

            let bgCircle = Circle()
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .frame(width: localOuterR * 2, height: localOuterR * 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            let chartContent = SunburstCanvas(
                currentLayout: layout,
                previousLayout: prevLayout,
                progress: animProgress,
                centerPoint: localCenter,
                outerRadius: localOuterR,
                hoveredPath: effectiveHoveredPath,
                onHover: { path in
                    self.hoveredPath = path
                    hoverUpdate?(path)
                },
                onTap: { node in
                    if node.isDirectory {
                        onOpen(node)
                    } else {
                        onSelect(node)
                    }
                }
            )
            .frame(width: localSize, height: localSize)

            let centerLabel = VStack(spacing: 2) {
                Text(centerTitle)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(disketteAccent)
                Text(centerSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: SunburstLayout.centerRadius * 2)
            .position(x: localCenter.x, y: localCenter.y)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            ZStack {
                bgCircle
                chartContent
                centerLabel
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: effectiveHoveredPath)
            .frame(width: localSize, height: localSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: nodes.map { $0.path }) { _ in
            hoveredPath = nil
            if !reduceMotion {
                prevLayout = layout
                animProgress = 0.0
                withAnimation(.easeInOut(duration: 0.35)) {
                    animProgress = 1.0
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Storage map")
    }

    // ── Center label: title = size, subtitle = name ────────────────

    private var centerTitle: String {
        if let p = effectiveHoveredPath, let n = findNode(p, in: nodes, childrenMap: childrenMap) {
            return n.allocatedSize.formattedByteCount
        }
        if let p = selectedPath, let n = findNode(p, in: nodes, childrenMap: childrenMap) {
            return n.allocatedSize.formattedByteCount
        }
        return nodes.reduce(Int64(0)) { $0 + $1.allocatedSize }.formattedByteCount
    }

    private var centerSubtitle: String {
        if let p = effectiveHoveredPath, let n = findNode(p, in: nodes, childrenMap: childrenMap) {
            return n.name
        }
        if let p = selectedPath, let n = findNode(p, in: nodes, childrenMap: childrenMap) {
            return n.name
        }
        return nodes.isEmpty ? "Nothing scanned yet" : "\(nodes.count) items"
    }
}

// MARK: - Hit-test helper

private func findNode(_ path: String, in roots: [StorageNode], childrenMap: [String: DirectoryScanResult]) -> StorageNode? {
    if let n = roots.first(where: { $0.path == path }) { return n }
    for r in roots {
        if let children = childrenMap[r.path]?.nodes, let m = children.first(where: { $0.path == path }) { return m }
    }
    return nil
}

// MARK: - Canvas rendering — 3 rings with angle-containment hover & animation

@MainActor
private struct SunburstCanvas: View, Animatable {
    let currentLayout: SunburstLayout
    let previousLayout: SunburstLayout?
    var progress: Double
    let centerPoint: CGPoint
    let outerRadius: CGFloat
    let hoveredPath: String?
    let onHover: (String?) -> Void
    let onTap: (StorageNode) -> Void

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    // Precompute a set of segment ids that are related to the hovered one (angle containment)
    private var relatedSet: Set<String> {
        guard let hp = hoveredPath else { return [] }
        guard let hoveredSeg = currentLayout.segments.first(where: { $0.id == hp }) else { return [] }
        return Set(currentLayout.segments.filter { $0.id != hp && related(hoveredSeg, $0) }.map { $0.id })
    }

    var body: some View {
        Canvas { context, size in
            let c = centerPoint
            let thick = SunburstLayout.ringThickness
            let gap = SunburstLayout.ringGap
            let t = CGFloat(progress)

            for seg in currentLayout.segments {
                let depth = CGFloat(seg.depth)
                let effectiveGap = depth == 0 ? gap * 1.5 : gap
                let innerR = SunburstLayout.centerRadius + depth * (thick + effectiveGap)
                let drawInnerTarget = innerR - effectiveGap / 2
                let drawOuterTarget = innerR + thick + effectiveGap / 2

                let startA: CGFloat
                let endA: CGFloat
                let drawInner: CGFloat
                let drawOuter: CGFloat
                let animAlphaMultiplier: CGFloat

                if t < 1.0, let prev = previousLayout?.segments.first(where: { $0.id == seg.id }) {
                    startA = prev.startAngle + (seg.startAngle - prev.startAngle) * t
                    endA = prev.endAngle + (seg.endAngle - prev.endAngle) * t
                    let prevGap = prev.depth == 0 ? gap * 1.5 : gap
                    let prevInner = SunburstLayout.centerRadius + CGFloat(prev.depth) * (thick + prevGap)
                    let pDrawInner = prevInner - prevGap / 2
                    let pDrawOuter = prevInner + thick + prevGap / 2
                    drawInner = pDrawInner + (drawInnerTarget - pDrawInner) * t
                    drawOuter = pDrawOuter + (drawOuterTarget - pDrawOuter) * t
                    animAlphaMultiplier = 1.0
                } else if t < 1.0 {
                    startA = seg.startAngle
                    endA = seg.startAngle + (seg.endAngle - seg.startAngle) * t
                    drawInner = drawInnerTarget
                    drawOuter = drawInnerTarget + (drawOuterTarget - drawInnerTarget) * t
                    animAlphaMultiplier = t
                } else {
                    startA = seg.startAngle
                    endA = seg.endAngle
                    drawInner = drawInnerTarget
                    drawOuter = drawOuterTarget
                    animAlphaMultiplier = 1.0
                }

                guard endA > startA + 0.0001 else { continue }

                let isHovered = seg.id == hoveredPath
                let isRelated = relatedSet.contains(seg.id)

                // Alpha: hovered = 1.0, related = 0.85, unrelated = 0.28, no hover = 1.0
                let baseAlpha: CGFloat = switch (hoveredPath, isHovered, isRelated) {
                case (_, true, _):   1.0
                case (nil, _, _):    1.0
                case (_, false, true): 0.85
                default:             0.28
                }
                let alpha = baseAlpha * animAlphaMultiplier

                // Color: hovered gets brightness boost via channel addition
                var cr: CGFloat = 0, cg: CGFloat = 0, cb: CGFloat = 0, ca: CGFloat = 0
                seg.colorFamily.getRed(&cr, green: &cg, blue: &cb, alpha: &ca)
                let brightened: NSColor
                if isHovered {
                    brightened = NSColor(red: min(cr + 0.15, 1.0), green: min(cg + 0.15, 1.0), blue: min(cb + 0.15, 1.0), alpha: ca)
                } else {
                    brightened = seg.colorFamily
                }
                let fill = Color(brightened).opacity(alpha)

                var arcPath = Path()
                arcPath.addArc(center: c, radius: drawOuter,
                               startAngle: Angle(radians: Double(startA)),
                               endAngle: Angle(radians: Double(endA)), clockwise: false)
                arcPath.addArc(center: c, radius: drawInner,
                               startAngle: Angle(radians: Double(endA)),
                               endAngle: Angle(radians: Double(startA)), clockwise: true)
                arcPath.closeSubpath()

                let strokeColor = Color.black.opacity(0.4)
                let strokeWidth: CGFloat = 1.2

                if isHovered {
                    // Pop out along bisector by 5pt
                    let pop: CGFloat = 5
                    let tx = seg.bisector.x * pop
                    let ty = seg.bisector.y * pop
                    context.drawLayer { ctx in
                        ctx.translateBy(x: tx, y: ty)
                        ctx.fill(arcPath, with: .color(fill))
                        ctx.stroke(arcPath, with: .color(strokeColor), style: StrokeStyle(lineWidth: strokeWidth))
                    }
                } else {
                    context.fill(arcPath, with: .color(fill))
                    context.stroke(arcPath, with: .color(strokeColor), style: StrokeStyle(lineWidth: strokeWidth))
                }
            }
        }
        .overlay {
            HitOverlay(
                layout: currentLayout,
                centerPoint: centerPoint,
                ringThickness: SunburstLayout.ringThickness,
                ringGap: SunburstLayout.ringGap,
                onHover: onHover,
                onTap: onTap
            )
        }
    }
}

// MARK: - Continuous-hover hit overlay

private struct HitOverlay: View {
    let layout: SunburstLayout
    let centerPoint: CGPoint
    let ringThickness: CGFloat
    let ringGap: CGFloat
    let onHover: (String?) -> Void
    let onTap: (StorageNode) -> Void

    private var segById: [String: SunburstSegment] {
        Dictionary(layout.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Convert a point in the overlay's coordinate space to the segment id under it, or nil.
    private func hitTest(_ point: CGPoint) -> String? {
        let c = centerPoint
        let dx = point.x - c.x
        let dy = point.y - c.y  // Positive Y goes DOWN, matching SwiftUI Path.addArc
        let dist = sqrt(dx * dx + dy * dy)

        if dist < SunburstLayout.centerRadius { return nil }

        // Map atan2 (-pi, pi] to [-pi/2, 3pi/2) to match SunburstLayout angles
        var angle = atan2(dy, dx)
        if angle < -Double.pi / 2 {
            angle += 2 * .pi
        }

        let thick = ringThickness
        let gap = ringGap

        for seg in layout.segments {
            let depth = CGFloat(seg.depth)
            let effectiveGap = depth == 0 ? gap * 1.5 : gap
            let innerR = SunburstLayout.centerRadius + depth * (thick + effectiveGap)
            let drawInner = innerR - effectiveGap / 2
            let drawOuter = innerR + thick + effectiveGap / 2

            if dist >= drawInner && dist <= drawOuter {
                if angle >= seg.startAngle && angle < seg.endAngle {
                    return seg.id
                }
            }
        }
        return nil
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.001))
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        onHover(hitTest(location))
                    case .ended:
                        onHover(nil)
                    @unknown default: break
                    }
                }
                .onTapGesture { location in
                    if let path = hitTest(location), let node = segById[path]?.node {
                        onTap(node)
                    }
                }
        }
    }
}

// Preview data (FakePreviewData) lives in SunburstLayout.swift — verified by running the app directly.
