import CoreGraphics
import Foundation

// MARK: - Tier

/// What a session grows into. Decided by its length, so the destination is
/// known from the first second.
enum GrowthTier: String, Codable, CaseIterable, Sendable {
    case flower
    case plant
    case forest

    /// Under thirty minutes a flower, up to an hour a plant, longer a forest.
    static func forDuration(_ seconds: TimeInterval) -> GrowthTier {
        if seconds < 30 * 60 { return .flower }
        if seconds <= 60 * 60 { return .plant }
        return .forest
    }

    /// Width over height the scene is laid out for. Views fit a box of this
    /// shape into whatever space they have, so a forest is wide and a
    /// flower is square.
    var aspect: Double {
        switch self {
        case .flower: 1.0
        case .plant: 1.3
        case .forest: 2.2
        }
    }
}

// MARK: - Plan and record

/// One session's plant: the seed fixes every shape, the duration fixes the
/// tier, and progress decides how much of it is on screen.
struct GrowthPlan: Codable, Equatable, Sendable {
    var seed: UInt64
    var durationSeconds: TimeInterval

    var tier: GrowthTier { .forDuration(durationSeconds) }

    init(seed: UInt64, durationSeconds: TimeInterval) {
        self.seed = seed
        self.durationSeconds = durationSeconds
    }

    /// Seeded from the start instant: pause, resume and every redraw show
    /// the same plant, and no two sessions look alike.
    init(startedAt: Date, durationSeconds: TimeInterval) {
        let millis = max(0, startedAt.timeIntervalSince1970 * 1000)
        self.init(seed: UInt64(millis), durationSeconds: durationSeconds)
    }
}

/// A session that ended today, as far as it got.
struct GrowthRecord: Codable, Equatable, Sendable {
    var plan: GrowthPlan
    /// 0...1 of the plan that grew; 1 means the timer ran out.
    var progress: Double
}

// MARK: - Deterministic randomness

/// SplitMix64: small, deterministic, and plenty for shapes.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func value(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range, using: &self)
    }

    mutating func chance(_ probability: Double) -> Bool {
        value(in: 0...1) < probability
    }

    mutating func pick(_ count: Int) -> Int {
        Int.random(in: 0..<count, using: &self)
    }
}

// MARK: - Scene

/// Everything on screen at one progress, laid out in a unit square with y
/// pointing down and the ground near the bottom. Positions are unit
/// coordinates; radii and lengths are fractions of the box height so
/// circles stay round when the box is wide.
struct GrowthScene: Equatable, Sendable {
    /// A stem, trunk or branch: a quadratic curve grown from `from` toward `to`.
    struct Stem: Equatable, Sendable {
        var from: CGPoint
        var control: CGPoint
        var to: CGPoint
        /// Line width as a fraction of the box height.
        var width: Double
        /// 0...1 of the curve that has grown.
        var grown: Double

        func point(at t: Double) -> CGPoint {
            let u = 1 - t
            return CGPoint(
                x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
                y: u * u * from.y + 2 * u * t * control.y + t * t * to.y
            )
        }
    }

    struct Leaf: Equatable, Sendable {
        var anchor: CGPoint
        /// Direction the tip points, radians, y down.
        var angle: Double
        /// Fraction of the box height.
        var length: Double
        /// 0...1 unfolded.
        var scale: Double
    }

    struct Bloom: Equatable, Sendable {
        var center: CGPoint
        /// Fraction of the box height.
        var radius: Double
        var petals: Int
        /// Index into the view's small bloom palette.
        var colorIndex: Int
        /// 0...1 opened.
        var scale: Double
    }

    struct Canopy: Equatable, Sendable {
        /// The trunk top this puff hangs off.
        var anchor: CGPoint
        /// Offset from the anchor, in fractions of the box height.
        var offset: CGVector
        /// Fraction of the box height.
        var radius: Double
        /// Index into the view's canopy greens.
        var shade: Int
        /// 0...1 filled in.
        var scale: Double
    }

    static let groundY: Double = 0.92

    var tier: GrowthTier
    var stems: [Stem] = []
    var leaves: [Leaf] = []
    var blooms: [Bloom] = []
    var canopies: [Canopy] = []

    /// Sum of every part's growth. Never decreases as progress advances.
    var growthTotal: Double {
        stems.reduce(0) { $0 + $1.grown }
            + leaves.reduce(0) { $0 + $1.scale }
            + blooms.reduce(0) { $0 + $1.scale }
            + canopies.reduce(0) { $0 + $1.scale }
    }

    /// Every part fully grown.
    var isComplete: Bool {
        stems.allSatisfy { $0.grown >= 1 }
            && leaves.allSatisfy { $0.scale >= 1 }
            && blooms.allSatisfy { $0.scale >= 1 }
            && canopies.allSatisfy { $0.scale >= 1 }
    }

    /// The plan at `progress`. Shapes are drawn from the seed in a fixed
    /// order; progress only decides how far each has grown, so the same plan
    /// looks the same at every stage and across redraws.
    static func make(plan: GrowthPlan, progress: Double) -> GrowthScene {
        let clamped = progress.isFinite ? min(1, max(0, progress)) : 0
        var rng = SeededGenerator(seed: plan.seed)
        var scene = GrowthScene(tier: plan.tier)
        switch plan.tier {
        case .flower: scene.growFlower(progress: clamped, rng: &rng)
        case .plant: scene.growPlant(progress: clamped, rng: &rng)
        case .forest: scene.growForest(progress: clamped, duration: plan.durationSeconds, rng: &rng)
        }
        return scene
    }

    /// 0...1 of the window `start...end` that `progress` has covered.
    static func ramp(_ progress: Double, _ start: Double, _ end: Double) -> Double {
        guard end > start else { return progress >= end ? 1 : 0 }
        return min(1, max(0, (progress - start) / (end - start)))
    }

    // MARK: Flower: one stem, a few leaves, a bloom at the top.

    private mutating func growFlower(progress p: Double, rng: inout SeededGenerator) {
        let base = CGPoint(x: 0.5, y: Self.groundY)
        let lean = rng.value(in: -0.08...0.08)
        let bend = rng.value(in: -0.12...0.12)
        let topY = rng.value(in: 0.24...0.3)
        let stem = Stem(
            from: base,
            control: CGPoint(x: 0.5 + bend, y: 0.6),
            to: CGPoint(x: 0.5 + lean, y: topY),
            width: 0.014,
            grown: Self.ramp(p, 0, 0.55)
        )
        stems.append(stem)

        // Leaves unfold once the stem has passed them.
        var spots: [(t: Double, left: Bool)] = [(0.38, true), (0.58, false)]
        if rng.chance(0.5) {
            spots.append((0.74, rng.chance(0.5)))
        }
        for spot in spots {
            let length = rng.value(in: 0.13...0.18)
            let tilt = rng.value(in: 0.45...0.7)
            let start = 0.55 * spot.t
            leaves.append(Leaf(
                anchor: stem.point(at: spot.t),
                angle: spot.left ? .pi + tilt : -tilt,
                length: length,
                scale: Self.ramp(p, start, start + 0.18)
            ))
        }

        blooms.append(Bloom(
            center: stem.to,
            radius: rng.value(in: 0.1...0.13),
            petals: 5 + rng.pick(3),
            colorIndex: rng.pick(4),
            scale: Self.ramp(p, 0.6, 1)
        ))
    }

    // MARK: Plant: a trunk, branches with leaves, small blooms on some tips.

    private mutating func growPlant(progress p: Double, rng: inout SeededGenerator) {
        let base = CGPoint(x: 0.5, y: Self.groundY)
        let lean = rng.value(in: -0.06...0.06)
        let bend = rng.value(in: -0.1...0.1)
        let trunk = Stem(
            from: base,
            control: CGPoint(x: 0.5 + bend, y: 0.62),
            to: CGPoint(x: 0.5 + lean, y: 0.3),
            width: 0.016,
            grown: Self.ramp(p, 0, 0.5)
        )
        stems.append(trunk)

        let branchCount = 3 + rng.pick(2)
        let spots: [Double] = [0.3, 0.5, 0.68, 0.84]
        for index in 0..<branchCount {
            let t = spots[index]
            let left = index.isMultiple(of: 2)
            let side: Double = left ? -1 : 1
            let anchor = trunk.point(at: t)
            let reach = rng.value(in: 0.16...0.26)
            let rise = rng.value(in: 0.1...0.18)
            let tip = CGPoint(x: anchor.x + side * reach, y: anchor.y - rise)
            let start = 0.5 * t
            let end = min(0.88, start + 0.28)
            let branch = Stem(
                from: anchor,
                control: CGPoint(x: anchor.x + side * reach * 0.6, y: anchor.y - rise * 0.15),
                to: tip,
                width: 0.009,
                grown: Self.ramp(p, start, end)
            )
            stems.append(branch)

            // Two leaves per branch, midway and at the tip.
            for leafT in [0.55, 1.0] {
                let length = rng.value(in: 0.09...0.13)
                let up = rng.value(in: 0.35...0.7)
                let leafStart = start + (end - start) * leafT
                leaves.append(Leaf(
                    anchor: branch.point(at: leafT),
                    angle: left ? .pi + up : -up,
                    length: length,
                    scale: Self.ramp(p, leafStart, min(1, leafStart + 0.14))
                ))
            }
            if rng.chance(0.5) {
                blooms.append(Bloom(
                    center: tip,
                    radius: rng.value(in: 0.04...0.055),
                    petals: 5,
                    colorIndex: rng.pick(4),
                    scale: Self.ramp(p, 0.86, 1)
                ))
            }
        }

        // Crown leaves once the trunk is up.
        for angle in [Double.pi + 0.95, -0.95] {
            leaves.append(Leaf(
                anchor: trunk.to,
                angle: angle,
                length: rng.value(in: 0.1...0.14),
                scale: Self.ramp(p, 0.5, 0.64)
            ))
        }
    }

    // MARK: Forest: trees that fill in one after another.

    private mutating func growForest(progress p: Double, duration: TimeInterval, rng: inout SeededGenerator) {
        // Three trees past the hour, one more per extra half hour, five at most.
        let extra = Int(max(0, duration - 3600) / 1800)
        let count = min(5, 3 + extra)
        // Seeded planting order instead of strictly left to right.
        var order = Array(0..<count)
        order.shuffle(using: &rng)
        let slot = 1.0 / Double(count)
        for index in 0..<count {
            let x = 0.15 + 0.7 * (Double(index) + 0.5) / Double(count) + rng.value(in: -0.02...0.02)
            let height = rng.value(in: 0.36...0.58)
            let lean = rng.value(in: -0.02...0.02)
            let start = Double(order[index]) * slot
            let trunkEnd = start + slot * 0.45
            let top = CGPoint(x: x + lean, y: Self.groundY - height)
            stems.append(Stem(
                from: CGPoint(x: x, y: Self.groundY),
                control: CGPoint(x: x + lean * 0.3, y: Self.groundY - height * 0.5),
                to: top,
                width: 0.02,
                grown: Self.ramp(p, start, trunkEnd)
            ))
            let radius = height * rng.value(in: 0.26...0.32)
            let shade = rng.pick(3)
            // Three overlapping puffs: one on top, two lower at the sides.
            let puffs: [(dx: Double, dy: Double, size: Double, from: Double, to: Double)] = [
                (0, 0.15, 1.0, trunkEnd, start + slot * 0.8),
                (-0.65, 0.5, 0.75, trunkEnd + slot * 0.1, start + slot * 0.9),
                (0.65, 0.5, 0.75, trunkEnd + slot * 0.2, start + slot),
            ]
            for (puffIndex, puff) in puffs.enumerated() {
                canopies.append(Canopy(
                    anchor: top,
                    offset: CGVector(dx: puff.dx * radius, dy: puff.dy * radius),
                    radius: radius * puff.size,
                    shade: (shade + puffIndex) % 3,
                    scale: Self.ramp(p, puff.from, puff.to)
                ))
            }
        }
    }
}
