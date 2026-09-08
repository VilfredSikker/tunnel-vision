import SwiftUI

/// A session's plant at one stage. Animatable on progress, so the once-per-
/// second update grows smoothly instead of stepping.
struct GrowthSceneView: View, Animatable {
    let plan: GrowthPlan
    var progress: Double

    @Environment(\.colorScheme) private var colorScheme

    // Animatable is not actor-bound while View is; a plain Double crosses safely.
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let scene = GrowthScene.make(plan: plan, progress: progress)
            GrowthPainter(palette: GrowthPalette(colorScheme), scene: scene).draw(in: &context, size: size)
        }
        .accessibilityHidden(true)
    }
}

/// Today's finished plants side by side on one ground line. The session
/// count stays available as a tooltip.
struct GardenRowView: View {
    let records: [GrowthRecord]
    let count: Int

    private static let maxShown = 8

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            if records.count > Self.maxShown {
                Text("+\(records.count - Self.maxShown)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(records.suffix(Self.maxShown).enumerated()), id: \.offset) { _, record in
                GrowthSceneView(plan: record.plan, progress: record.progress)
                    .frame(width: 30, height: 24)
            }
        }
        .help(summary)
        .accessibilityLabel(summary)
    }

    private var summary: String {
        let finished = records.filter { $0.progress >= 1 }.count
        let sessions = "\(count) session\(count == 1 ? "" : "s") done today"
        return finished == records.count ? sessions : "\(sessions), \(records.count - finished) stopped early"
    }
}

// MARK: - Painting

/// Two greens, three canopy shades, four muted bloom colours, tuned per
/// appearance.
struct GrowthPalette {
    let stem: Color
    let leaves: [Color]
    let canopies: [Color]
    let blooms: [Color]
    let bloomCenter: Color
    let ground: Color

    init(_ scheme: ColorScheme) {
        let dark = scheme == .dark
        stem = dark ? Color(red: 0.47, green: 0.68, blue: 0.48) : Color(red: 0.33, green: 0.55, blue: 0.35)
        leaves = dark
            ? [Color(red: 0.5, green: 0.74, blue: 0.5), Color(red: 0.4, green: 0.65, blue: 0.44)]
            : [Color(red: 0.42, green: 0.68, blue: 0.42), Color(red: 0.33, green: 0.58, blue: 0.37)]
        canopies = dark
            ? [Color(red: 0.36, green: 0.6, blue: 0.42), Color(red: 0.45, green: 0.69, blue: 0.48), Color(red: 0.3, green: 0.53, blue: 0.38)]
            : [Color(red: 0.32, green: 0.56, blue: 0.38), Color(red: 0.42, green: 0.66, blue: 0.44), Color(red: 0.26, green: 0.48, blue: 0.33)]
        blooms = [
            Color(red: 0.87, green: 0.5, blue: 0.56),
            Color(red: 0.93, green: 0.73, blue: 0.38),
            Color(red: 0.68, green: 0.6, blue: 0.86),
            Color(red: 0.96, green: 0.9, blue: 0.74),
        ]
        bloomCenter = Color(red: 0.8, green: 0.6, blue: 0.3)
        ground = Color.primary.opacity(dark ? 0.22 : 0.16)
    }
}

/// Draws a scene into the largest box of its tier's aspect that fits,
/// resting on the bottom edge so plants in a row share one ground line.
struct GrowthPainter {
    let palette: GrowthPalette
    let scene: GrowthScene

    static func box(for tier: GrowthTier, in size: CGSize) -> CGRect {
        var width = size.width
        var height = width / tier.aspect
        if height > size.height {
            height = size.height
            width = height * tier.aspect
        }
        return CGRect(x: (size.width - width) / 2, y: size.height - height, width: width, height: height)
    }

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let box = Self.box(for: scene.tier, in: size)
        let hairline = max(1, box.height * 0.012)

        var ground = Path()
        let groundY = box.minY + GrowthScene.groundY * box.height
        ground.move(to: CGPoint(x: box.minX + box.width * 0.06, y: groundY))
        ground.addLine(to: CGPoint(x: box.maxX - box.width * 0.06, y: groundY))
        context.stroke(ground, with: .color(palette.ground), style: StrokeStyle(lineWidth: hairline, lineCap: .round))

        for stem in scene.stems where stem.grown > 0 {
            var path = Path()
            path.move(to: place(stem.from, in: box))
            let steps = 14
            for step in 1...steps {
                path.addLine(to: place(stem.point(at: stem.grown * Double(step) / Double(steps)), in: box))
            }
            context.stroke(
                path,
                with: .color(palette.stem),
                style: StrokeStyle(lineWidth: max(1, stem.width * box.height), lineCap: .round, lineJoin: .round)
            )
        }

        for canopy in scene.canopies where canopy.scale > 0 {
            let anchor = place(canopy.anchor, in: box)
            let center = CGPoint(
                x: anchor.x + canopy.offset.dx * box.height,
                y: anchor.y + canopy.offset.dy * box.height
            )
            let radius = canopy.radius * canopy.scale * box.height
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
                with: .color(palette.canopies[canopy.shade % palette.canopies.count])
            )
        }

        for (index, leaf) in scene.leaves.enumerated() where leaf.scale > 0 {
            let anchor = place(leaf.anchor, in: box)
            let length = leaf.length * leaf.scale * box.height
            let direction = CGPoint(x: cos(leaf.angle), y: sin(leaf.angle))
            let normal = CGPoint(x: -direction.y, y: direction.x)
            let tip = anchor.moved(by: direction, distance: length)
            let middle = anchor.moved(by: direction, distance: length * 0.5)
            let belly = length * 0.42
            var path = Path()
            path.move(to: anchor)
            path.addQuadCurve(to: tip, control: middle.moved(by: normal, distance: belly))
            path.addQuadCurve(to: anchor, control: middle.moved(by: normal, distance: -belly))
            context.fill(path, with: .color(palette.leaves[index % palette.leaves.count]))
        }

        for bloom in scene.blooms where bloom.scale > 0 {
            let center = place(bloom.center, in: box)
            let radius = bloom.radius * bloom.scale * box.height
            let color = palette.blooms[bloom.colorIndex % palette.blooms.count]
            for petal in 0..<bloom.petals {
                let angle = Double(petal) / Double(bloom.petals) * 2 * .pi - .pi / 2
                let petalCenter = center.moved(by: CGPoint(x: cos(angle), y: sin(angle)), distance: radius * 0.55)
                let shape = Path(ellipseIn: CGRect(x: -radius * 0.5, y: -radius * 0.32, width: radius, height: radius * 0.64))
                let transform = CGAffineTransform(translationX: petalCenter.x, y: petalCenter.y).rotated(by: angle)
                context.fill(shape.applying(transform), with: .color(color.opacity(0.92)))
            }
            let core = radius * 0.34
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: 2 * core, height: 2 * core)),
                with: .color(palette.bloomCenter)
            )
        }
    }

    private func place(_ unit: CGPoint, in box: CGRect) -> CGPoint {
        CGPoint(x: box.minX + unit.x * box.width, y: box.minY + unit.y * box.height)
    }
}

private extension CGPoint {
    func moved(by direction: CGPoint, distance: CGFloat) -> CGPoint {
        CGPoint(x: x + direction.x * distance, y: y + direction.y * distance)
    }
}
