import Foundation
import XCTest

@testable import TunnelVision

final class GrowthTests: XCTestCase {
    func testTierFollowsDuration() {
        XCTAssertEqual(GrowthTier.forDuration(10 * 60), .flower)
        XCTAssertEqual(GrowthTier.forDuration(25 * 60), .flower)
        XCTAssertEqual(GrowthTier.forDuration(30 * 60), .plant)
        XCTAssertEqual(GrowthTier.forDuration(60 * 60), .plant)
        XCTAssertEqual(GrowthTier.forDuration(61 * 60), .forest)
        XCTAssertEqual(GrowthPlan(seed: 1, durationSeconds: 90 * 60).tier, .forest)
    }

    func testSameSeedDrawsTheSamePlantAndSeedsDiffer() {
        for minutes in [25, 45, 90] {
            let duration = TimeInterval(minutes * 60)
            let a = GrowthScene.make(plan: GrowthPlan(seed: 42, durationSeconds: duration), progress: 0.5)
            let b = GrowthScene.make(plan: GrowthPlan(seed: 42, durationSeconds: duration), progress: 0.5)
            XCTAssertEqual(a, b, "\(minutes) min: same seed, same plant")
            let c = GrowthScene.make(plan: GrowthPlan(seed: 43, durationSeconds: duration), progress: 0.5)
            XCTAssertNotEqual(a, c, "\(minutes) min: another seed, another plant")
        }
    }

    func testGrowthOnlyEverIncreasesAndFinishesAtOne() {
        for minutes in [25, 45, 60, 95, 150] {
            for seed: UInt64 in [1, 7, 12345, 987_654_321] {
                let plan = GrowthPlan(seed: seed, durationSeconds: TimeInterval(minutes * 60))
                var last = -1.0
                for step in 0...40 {
                    let scene = GrowthScene.make(plan: plan, progress: Double(step) / 40)
                    XCTAssertGreaterThanOrEqual(scene.growthTotal, last, "\(minutes) min seed \(seed) step \(step)")
                    last = scene.growthTotal
                }
                XCTAssertEqual(GrowthScene.make(plan: plan, progress: 0).growthTotal, 0, "nothing shows before the session starts")
                XCTAssertFalse(GrowthScene.make(plan: plan, progress: 0.5).isComplete)
                XCTAssertTrue(GrowthScene.make(plan: plan, progress: 1).isComplete, "\(minutes) min seed \(seed) ends fully grown")
            }
        }
    }

    func testLayoutDoesNotDependOnProgress() {
        let plan = GrowthPlan(seed: 99, durationSeconds: 45 * 60)
        let early = GrowthScene.make(plan: plan, progress: 0.2)
        let late = GrowthScene.make(plan: plan, progress: 0.9)
        XCTAssertEqual(early.stems.map(\.to), late.stems.map(\.to), "only growth changes, never the shapes")
        XCTAssertEqual(early.leaves.map(\.anchor), late.leaves.map(\.anchor))
        XCTAssertEqual(early.blooms.map(\.center), late.blooms.map(\.center))
    }

    func testForestPlantsMoreTreesForLongerSessions() {
        func trees(_ minutes: Int) -> Int {
            GrowthScene.make(plan: GrowthPlan(seed: 5, durationSeconds: TimeInterval(minutes * 60)), progress: 1).stems.count
        }
        XCTAssertEqual(trees(75), 3)
        XCTAssertEqual(trees(90), 4)
        XCTAssertEqual(trees(120), 5)
        XCTAssertEqual(trees(240), 5, "five is the cap")
    }

    func testSeedFromStartIsStable() {
        let date = Date(timeIntervalSince1970: 1_752_000_000)
        XCTAssertEqual(
            GrowthPlan(startedAt: date, durationSeconds: 1500).seed,
            GrowthPlan(startedAt: date, durationSeconds: 1500).seed
        )
        XCTAssertNotEqual(
            GrowthPlan(startedAt: date, durationSeconds: 1500).seed,
            GrowthPlan(startedAt: date.addingTimeInterval(1), durationSeconds: 1500).seed
        )
    }

    func testRecordAndSettingsRoundTrip() throws {
        let record = GrowthRecord(plan: GrowthPlan(seed: 3, durationSeconds: 1500), progress: 0.4)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(GrowthRecord.self, from: data), record)

        let old = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.countdownStyle, .garden, "older archives get the garden countdown")
        var settings = Settings()
        settings.countdownStyle = .compact
        let roundTrip = try JSONDecoder().decode(Settings.self, from: try JSONEncoder().encode(settings))
        XCTAssertEqual(roundTrip.countdownStyle, .compact)

        let json = """
        {"version":1,"tasks":[],"presets":[],"settings":{},"todayCount":1,"countDay":"2025-07-16"}
        """
        let archive = try JSONDecoder().decode(Archive.self, from: Data(json.utf8))
        XCTAssertTrue(archive.garden.isEmpty, "archives from before the garden still decode")
    }

    func testSceneBoxRestsOnTheBottomEdge() {
        let wide = GrowthPainter.box(for: .forest, in: CGSize(width: 100, height: 100))
        XCTAssertEqual(wide.maxY, 100)
        XCTAssertEqual(wide.width, 100)
        XCTAssertEqual(wide.height, 100 / 2.2, accuracy: 0.001)

        let square = GrowthPainter.box(for: .flower, in: CGSize(width: 150, height: 60))
        XCTAssertEqual(square.size, CGSize(width: 60, height: 60))
        XCTAssertEqual(square.minX, 45, "centred horizontally")
        XCTAssertEqual(square.maxY, 60)
    }
}
