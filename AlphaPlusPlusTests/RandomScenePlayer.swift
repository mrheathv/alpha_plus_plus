import Foundation
import XCTest
@testable import AlphaPlusPlus

/// Somebody plausible, doing things nobody scripted.
///
/// **The scripted sessions only test what I thought of, and every bug so far
/// has been something nobody thought of.** A hand-written script is a list of
/// suspicions; this is a search. It plays a city for as long as it is given,
/// checking after every step that the picture still agrees — so the failures
/// it finds are the ones no author would have gone looking for.
///
/// **Plausible rather than chaotic**, deliberately. A player who clicks
/// uniformly at random builds a city no player would build, and the
/// interesting interactions — laying pipe under blocks, growing while a view
/// is up, bulldozing next to something — are the ones that come out of
/// *sequences* that make sense. Pure noise mostly measures how the game
/// handles noise.
///
/// Seeded, so a failure is reproducible from its seed alone, and
/// `ScenePlaytest.log` prints the run that produced it — because "step 147 of
/// a random walk" is otherwise a failure nobody can act on. It is the same
/// requirement `PlaytestHarness` already states for balance numbers: a result
/// nobody can re-derive is the thing these harnesses exist to stop producing.
@MainActor
struct RandomScenePlayer {

    private var rng: SeededRNG
    private let game: ScenePlaytest
    private let width: Int
    private let height: Int

    init(game: ScenePlaytest, seed: UInt64) {
        self.game = game
        self.rng = SeededRNG(seed: seed)
        self.width = game.controller.map.width
        self.height = game.controller.map.height
    }

    /// Plays `steps` of it, checking after each.
    ///
    /// `checkingEvery` exists because the check builds a whole second scene,
    /// which is the expensive part — a long run can afford to look less often
    /// and still find anything that persists.
    mutating func play(steps: Int, checkingEvery: Int = 1,
                       file: StaticString = #filePath, line: UInt = #line) {
        for step in 1 ... steps {
            take(Action.allCases.randomElement(using: &rng) ?? .letTimePass)
            if step % checkingEvery == 0 {
                game.check("step \(step)", file: file, line: line)
            }
        }
        game.check("the whole session", file: file, line: line)
    }

    /// What a player does. Listed rather than weighted by hand: `allCases`
    /// with a few duplicated entries is a weighting that stays readable, and
    /// the ones repeated are the ones a real session is mostly made of.
    private enum Action: CaseIterable {
        case letTimePass, letTimePass2, letTimePass3
        case zoneSomething, zoneSomething2
        case layARoad
        case buildAService
        case bulldozeSomething
        case changeView, changeView2
        case layAConduit
        case pauseOrPlay
        case drawALine
        case borrow
    }

    private mutating func take(_ action: Action) {
        switch action {
        case .letTimePass, .letTimePass2, .letTimePass3:
            game.tick(Int.random(in: 1 ... 3, using: &rng))

        case .zoneSomething, .zoneSomething2:
            let zone = [ZoneType.residential, .commercial, .industrial].randomElement(using: &rng)!
            game.click(zone, at: somewhere())

        case .layARoad:
            let from = somewhere()
            // Along an axis, like anybody drawing a street.
            let to = Bool.random(using: &rng)
                ? GridPosition(x: Int.random(in: 0 ..< width, using: &rng), y: from.y)
                : GridPosition(x: from.x, y: Int.random(in: 0 ..< height, using: &rng))
            game.drag(Bool.random(using: &rng) ? .road : .highway, from: from, to: to)

        case .buildAService:
            let zone = [ZoneType.policeStation, .fireStation, .park, .school,
                        .waterTower, .generator, .publicTransit, .tramStop]
                .randomElement(using: &rng)!
            game.click(zone, at: somewhere())

        case .bulldozeSomething:
            game.bulldoze(at: somewhere())

        case .changeView, .changeView2:
            game.look(at: OverlayMode.allCases.randomElement(using: &rng) ?? .none)

        case .layAConduit:
            // Only means anything in a view that takes the click — which is
            // the point: the player has to be *in* the water view to lay a
            // main, and that ordering is part of what is being tested.
            guard game.controller.overlayMode == .water
                || game.controller.overlayMode == .power else { return }
            let from = somewhere()
            let to = Bool.random(using: &rng)
                ? GridPosition(x: Int.random(in: 0 ..< width, using: &rng), y: from.y)
                : GridPosition(x: from.x, y: Int.random(in: 0 ..< height, using: &rng))
            game.dragInView(from: from, to: to)

        case .pauseOrPlay:
            if game.controller.isRunning { game.pause() } else { game.play() }

        case .drawALine:
            drawALine()

        case .borrow:
            // A session that runs out of money stops doing anything, and a
            // player in that position borrows. Cheaper than a test backdoor
            // into the treasury, and it exercises the debt path for free.
            game.borrowIfShort()
        }
    }

    /// Strings together stations of one kind, if the city has any.
    private mutating func drawALine() {
        let mode = TransitRoute.Mode.allCases.randomElement(using: &rng)!
        let stations = game.controller.map.tiles
            .filter { $0.isBuildingAnchor && $0.zone == mode.stationZone }
            .map(\.position)
        guard stations.count >= TransitRoute.minimumStops else { return }

        game.beginLine(mode)
        for stop in stations.shuffled(using: &rng).prefix(Int.random(in: 2 ... 4, using: &rng)) {
            game.clickInView(at: stop)
        }
        game.finishLine()
    }

    private mutating func somewhere() -> GridPosition {
        GridPosition(x: Int.random(in: 0 ..< width, using: &rng),
                     y: Int.random(in: 0 ..< height, using: &rng))
    }
}
