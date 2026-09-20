import XCTest
@testable import AlphaPlusPlus

/// **Mints a folder of ready-made cities to open in the game.**
///
/// Save and load have always supported more than one city — they are files in
/// a directory. What was missing is any way to *get* an interesting one:
/// hand-building a 64×64 city to look at a mechanic is an hour of clicking,
/// which is why there were no test cities to look at.
///
/// Everything needed already existed and nothing joined it up.
/// `PlaytestHarness.buildCity` generates a full city at any size with
/// services, utilities and transit; `GameController.snapshot()` turns a
/// running city into a `CitySave`; `CitySaveFile.write(_:to:)` puts one on
/// disk. This is the thirty lines between them.
///
/// **Opt-in**, because it writes into the real Application Support folder the
/// game's Open panel defaults to, and a test that littered there on every run
/// would be rude:
///
/// ```sh
/// TEST_RUNNER_MINT_CITIES=1 xcodebuild -project AlphaPlusPlus.xcodeproj \
///   -scheme AlphaPlusPlus -configuration Release -derivedDataPath ./build \
///   ENABLE_TESTABILITY=YES test \
///   -only-testing:AlphaPlusPlusTests/CityMinterTests
/// ```
///
/// Release, and for the same reason the balance harness asks for it: minting
/// these means ticking several full cities, which is ~55x faster there. The
/// `TEST_RUNNER_` prefix is what xcodebuild forwards, and it strips it.
///
/// **Each city is a state you cannot reach quickly by playing**, which is the
/// bar for adding one. A pretty city is not worth a fixture; a city that is
/// *already* on fire, or has *already* had its network rot for three hundred
/// days, is.
@MainActor
final class CityMinterTests: XCTestCase {

    /// A city worth opening, and what makes it different from the last one.
    private struct Recipe {
        let name: String
        /// What it is for — written into the log, so a folder of eight files
        /// does not become eight names nobody remembers the point of.
        let purpose: String
        let spec: PlaytestHarness.CitySpec
        /// Days to run before saving. The default settles a city (~160).
        var days: Int = 200
        /// Applied to the running controller before the clock starts — how a
        /// city gets to a state play would take hours to reach.
        var prepare: (GameController) -> Void = { _ in }
        /// Site a seaport and an airport. Only legal where there is a shore.
        var withPorts: Bool = false
        /// Keep ticking past `days` until this many blocks are alight.
        ///
        /// A disaster is an *event*, so saving at a fixed day is saving at a
        /// coin toss — the first mint of Firestorm caught exactly one block
        /// burning, which is a city that has clearly *had* a fire rather than
        /// one having one. Bounded, because on a map that never ignites this
        /// would otherwise never return.
        var untilAlight: Int = 0
    }

    private func recipes() -> [Recipe] {
        let large = MapSize.large.dimension

        return [
            Recipe(
                name: "Metropolis",
                purpose: "a settled, fully-served 64×64 city — the default 'real city'",
                spec: .init(size: large)
            ),

            // The layout `DesignPlaytestTests` proves is the better way to
            // build, and the only one where transit is worth its price: a
            // city of three-block commutes has nothing for a line to carry.
            Recipe(
                name: "Long Commute",
                purpose: "industry zoned apart, with a subway network drawn — route diagrams have something in them",
                spec: {
                    var spec = PlaytestHarness.CitySpec(size: large)
                    spec.segregateIndustry = true
                    spec.transitStations = .subway
                    spec.drawTransitRoutes = true
                    return spec
                }()
            ),

            // No fire stations and no coverage, aged past the grace period,
            // then left to burn. `CityHazards.gracePeriodDays` is 90, so a
            // city minted at day 200 is well clear of it.
            Recipe(
                name: "Firestorm",
                purpose: "an unserviced city mid-disaster — fire spread, flames, damaged blocks",
                spec: {
                    var spec = PlaytestHarness.CitySpec(size: large)
                    spec.includeServices = false
                    return spec
                }(),
                days: 320,
                untilAlight: 4
            ),

            // Phase 6's measured scenario, saved rather than asserted: stop
            // paying public works and the network does not wait to burst, it
            // stops reaching the far side of the street first.
            Recipe(
                name: "Rustbelt",
                purpose: "public works defunded for 300 days — worn roads, failing mains, a red Roads meter",
                spec: .init(size: large),
                days: 380,
                prepare: { $0.setFundingLevel(0, for: .road) }
            ),

            // The first fixture with water in it, and the only one where a
            // seaport is legal at all.
            Recipe(
                name: "Harbour",
                purpose: "a coastal city — bridges, waterfront land value, and shore to berth a seaport on",
                spec: {
                    var spec = PlaytestHarness.CitySpec(size: large)
                    spec.terrain = .coastal
                    spec.terrainSeed = coastalSeedWithABerth(size: large)
                    return spec
                }(),
                withPorts: true
            ),

            Recipe(
                name: "Riverrun",
                purpose: "a river cutting the map in two — the case bridges exist for",
                spec: {
                    var spec = PlaytestHarness.CitySpec(size: large)
                    spec.terrain = .river
                    return spec
                }(),
                withPorts: true
            ),

            // Past anything MapSize offers, so the tick cost measured in
            // HarnessTimingTests can be felt rather than read.
            Recipe(
                name: "Sprawl",
                purpose: "128×128 — bigger than the New City panel offers, to feel what tick cost does",
                spec: .init(size: 128),
                days: 120
            ),
        ]
    }

    /// Put a dock on the shore and an airport inland.
    ///
    /// The harness's service rotation cannot do this: a seaport is the one
    /// building in the game whose legality depends on the terrain, so it has
    /// to be *sited* rather than dealt out on a stride.
    ///
    /// **It demolishes first, and goes through `place(at:)` rather than
    /// writing to the map.** The first version required a 3×3 of untouched
    /// ground and found none — by the time `buildCity` has run, a coastal map
    /// has 547 scattered empty tiles out of 4,096 and a block of nine dry
    /// empty cells against the shore essentially does not occur. Clearing a
    /// block to make room is what a player does to build a dock, and routing
    /// it through the controller means the fixture exercises
    /// `RegionalTrade.canBerth` for real instead of trusting a second copy
    /// of the rule written here. `bulldoze(at:)` is the right-click quick
    /// erase — it clears a whole building free of charge, which is what makes
    /// room without also costing the treasury the fixture needs.
    private func addPorts(_ controller: GameController) {
        func site(_ zone: ZoneType, needsShore: Bool) {
            for position in controller.map.tiles.map(\.position).sortedByPosition() {
                let map = controller.map
                let cells = map.footprintCells(origin: position, size: 3)
                // **Roads may be built over**, which the first version
                // refused — and refusing made the airport unplaceable
                // anywhere. `CitySpec.roadSpacing` is 3, so a road runs along
                // every third row and *every* 3×3 footprint on the map
                // contains one. The harness already takes this licence for
                // its own 3×3 power plants, which sit on the reserved strip
                // at `size - 4` — row 60 on a 64 map, which is a road row —
                // so every city ever measured for this project already has
                // plants standing on roads.
                guard !cells.isEmpty, cells.allSatisfy({ !map[$0].isWater }) else { continue }
                guard RegionalTrade.canBerth(cells, in: map) == needsShore else { continue }

                for cell in cells { controller.bulldoze(at: cell) }
                controller.selectedTool = zone
                if controller.place(at: position) == .placed { return }
            }
        }
        site(.seaport, needsShore: true)
        site(.airport, needsShore: false)
    }

    /// The first terrain seed whose coastline can actually take a dock.
    ///
    /// **Found by measuring, because the obvious seed could not.** A seaport
    /// is 3×3 and must stand on dry land with water within one tile, and on
    /// seed 7's coast — 620 tiles of sea — *no* nine-cell block of dry ground
    /// touches the water at all. The shoreline is ragged enough that every
    /// dry tile beside the sea has another finger of sea inside the 3×3 it
    /// would need.
    ///
    /// That is a fact about the coastline rather than a rule worth relaxing:
    /// the berth rule is the whole point of the seaport, and a fixture that
    /// weakened it to get a building placed would be testing something the
    /// game does not do. So the fixture picks a coast that works and says
    /// which one.
    ///
    /// Tested against bare terrain rather than a built city — buildings never
    /// change where the water is, so the geometry is identical and this costs
    /// milliseconds instead of a city-build per candidate.
    private func coastalSeedWithABerth(size: Int) -> UInt64 {
        for seed in UInt64(1) ... 60 {
            var map = CityMap(width: size, height: size)
            TerrainGenerator.apply(.coastal, to: &map, seed: seed)
            let berthable = map.tiles.map(\.position).contains { origin in
                let cells = map.footprintCells(origin: origin, size: 3)
                guard !cells.isEmpty, cells.allSatisfy({ !map[$0].isWater }) else { return false }
                return RegionalTrade.canBerth(cells, in: map)
            }
            if berthable { return seed }
        }
        XCTFail("no coastal seed in 1...60 produced a shoreline a 3×3 dock could stand on")
        return 1
    }

    /// What a minted city opens with, when what it actually earned was less.
    private let startingTreasury = 250_000

    func testMintTestCities() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MINT_CITIES"] != nil,
            "writes into Application Support; set TEST_RUNNER_MINT_CITIES=1 to run it"
        )

        let directory = try CitySaveFile.defaultDirectory()
        var log = "minted into \(directory.path)\n"

        for recipe in recipes() {
            let started = Date()
            let controller = GameController(
                map: PlaytestHarness.buildCity(recipe.spec),
                rng: SeededRNG(seed: 1),
                peakPopulation: Unlocks.everythingUnlocked
            )
            if recipe.withPorts { addPorts(controller) }
            recipe.prepare(controller)
            for _ in 0 ..< recipe.days { controller.advanceSimulation() }

            // A disaster has to be caught *while* it is happening.
            var extra = 0
            while Fire.count(in: controller.map) < recipe.untilAlight, extra < 400 {
                controller.advanceSimulation()
                extra += 1
            }

            // **A sandbox opens solvent.** These cities run at the harness's
            // default tax on a profile CLAUDE.md already records as
            // structurally marginal, so several of them minted bankrupt —
            // and a fixture you open into a death spiral is one you cannot
            // use to look at anything. The treasury is floored rather than
            // the economics retuned, because the economics are not what
            // these are for; `PlaytestScenarioTests` is where that is
            // measured and nothing here should quietly become a second
            // opinion on it.
            let played = controller.snapshot()
            let save = CitySave(
                map: played.map,
                treasury: max(played.treasury, startingTreasury),
                taxRate: played.taxRate,
                bondBalance: played.bondBalance,
                history: played.history,
                peakPopulation: played.peakPopulation
            )
            let url = directory.appendingPathComponent("\(recipe.name).alphacity")
            try CitySaveFile.write(save, to: url)

            // Read it straight back. A minted city that cannot be opened is
            // worse than none, and this is the one place in the project that
            // exercises write-then-read on a *real* generated city rather
            // than a hand-built fixture — which is exactly the shape that
            // would have caught the funding dials breaking every save.
            let reloaded = try CitySaveFile.read(from: url)
            XCTAssertEqual(reloaded.map.width, recipe.spec.size, "\(recipe.name) did not survive a round trip")

            func count(_ zone: ZoneType) -> Int {
                controller.map.tiles.filter { $0.isBuildingAnchor && $0.zone == zone }.count
            }
            // Counted separately, because "ports 1" does not say *which* of
            // the two failed to find a site — and that is the whole question
            // when one of them has a terrain rule and the other does not.
            let docks = count(.seaport), airfields = count(.airport)
            let ports = docks + airfields
            let water = controller.map.tiles.filter(\.isWater).count
            let fire = Fire.count(in: controller.map)
            // `Infrastructure.wears(_:)` is the definition of what can rot,
            // called rather than restated — and `wear` is Optional because a
            // tile that has been repaired must compare equal to one that was
            // never broken.
            let worn = controller.map.tiles.filter {
                Infrastructure.wears($0) && ($0.wear ?? 0) > 0.5
            }.count
            if recipe.withPorts {
                XCTAssertEqual(docks, 1, "\(recipe.name): no shore could take a dock")
                XCTAssertEqual(airfields, 1, "\(recipe.name): nowhere inland took an airport")
            }
            if recipe.untilAlight > 0 {
                XCTAssertGreaterThanOrEqual(fire, recipe.untilAlight, "\(recipe.name) is not actually alight")
            }

            log += String(
                format: "%-14@ pop %5d  $%8d  alight %2d  worn %4d  water %4d  dock %d air %d  %5.1fs  — %@\n",
                recipe.name as NSString, controller.population, save.treasury,
                fire, worn, water, docks, airfields,
                Date().timeIntervalSince(started), recipe.purpose as NSString
            )
        }
        print(log)
    }
}
