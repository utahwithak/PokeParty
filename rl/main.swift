//
//  main.swift — shield-policy data generator + evaluator (RL milestone 1).
//
//  Sweeps a ranked Great League pool pairwise, solves each matchup's optimal
//  shield play with ShieldSearch (the oracle/teacher), then replays the battle
//  under the oracle policy while logging a ShieldObservation feature vector and
//  the oracle's decision at every shield opportunity. Output is JSONL for the
//  Python behavioral-cloning trainer (rl/train_shield.py).
//
//  Compiled like bench/: the real engine sources with -O (see rl/build.sh).
//
//  Usage:
//    ./generate <data-dir> [poolSize] [outDir]           generate training data
//    ./generate <data-dir> [poolSize] [outDir] --eval    play the trained net
//        (outDir/shield_policy.json) against the built-in heuristic on the
//        held-out validation matchups and report battle outcomes.
//

import Foundation

// MARK: - Data loading (mirrors bench/main.swift)

struct GameMasterFile: Decodable {
    let pokemon: [Pokemon]
    let moves: [Move]
}

struct RankEntry: Decodable {
    let speciesId: String
    let moveset: [String]
}

let dataDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "data"
let poolSize = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 150 : 150
let outDir = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "data"

let gmData = try Data(contentsOf: URL(fileURLWithPath: "\(dataDir)/gamemaster.json"))
let rankData = try Data(contentsOf: URL(fileURLWithPath: "\(dataDir)/rankings-1500.json"))
let gm = try JSONDecoder().decode(GameMasterFile.self, from: gmData)
let rankings = try JSONDecoder().decode([RankEntry].self, from: rankData)

let movesById = Dictionary(uniqueKeysWithValues: gm.moves.map { ($0.moveId, $0) })
let speciesById = Dictionary(uniqueKeysWithValues: gm.pokemon.map { ($0.speciesId, $0) })

struct PoolEntry {
    let id: String
    let combatant: MatchupSimulator.Combatant
    let stats: BattlePokemon.Stats
}

var pool: [PoolEntry] = []
for entry in rankings {
    guard pool.count < poolSize else { break }
    guard let species = speciesById[entry.speciesId],
          entry.moveset.count >= 2 else { continue }
    let combatant = MatchupSimulator.Combatant(
        species: species,
        shadow: species.isShadow,
        fastMoveId: entry.moveset[0],
        chargedMoveIds: Array(entry.moveset.dropFirst()))
    guard let stats = MatchupSimulator.optimalStats(for: combatant, cpCap: 1500),
          movesById[combatant.fastMoveId] != nil,
          combatant.chargedMoveIds.allSatisfy({ movesById[$0] != nil })
    else { continue }
    pool.append(PoolEntry(id: entry.speciesId, combatant: combatant, stats: stats))
}
print("Pool: \(pool.count) Great League mons (ranked order, real movesets)")

// MARK: - Validation split (must match train_shield.py: crc32(key) % 10 == 0)

func crc32(_ s: String) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in Array(s.utf8) {
        crc ^= UInt32(b)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    return ~crc
}

// MARK: - Eval mode: learned net vs the built-in heuristic on val matchups

if CommandLine.arguments.contains("--eval") {
    let net = try ShieldPolicyNet(contentsOf: URL(fileURLWithPath: "\(outDir)/shield_policy.json"))

    var valPairs: [(Int, Int)] = []
    for i in 0..<pool.count {
        for j in (i + 1)..<pool.count where crc32("\(pool[i].id)|\(pool[j].id)") % 10 == 0 {
            valPairs.append((i, j))
        }
    }
    let evalConfigs: [(a: Int, b: Int)] = [(2, 2), (1, 1), (2, 1), (1, 2), (1, 0), (0, 1)]
    print("Eval: \(valPairs.count) held-out matchups × \(evalConfigs.count) shield configs")

    /// One battle; `netSides` says which sides the learned policy controls
    /// (the rest use the engine's built-in wouldShield heuristic).
    func play(_ i: Int, _ j: Int, _ config: (a: Int, b: Int), netSides: Set<Int>) -> (a: Int, b: Int)? {
        guard let pa = MatchupSimulator.makeBattlePokemon(
                  pool[i].combatant, stats: pool[i].stats, movesById: movesById, shields: config.a),
              let pb = MatchupSimulator.makeBattlePokemon(
                  pool[j].combatant, stats: pool[j].stats, movesById: movesById, shields: config.b)
        else { return nil }
        let battle = Battle(pa, pb)
        if !netSides.isEmpty {
            battle.shieldPolicy = { [unowned battle] d, o, move in
                guard netSides.contains(d) else { return nil }
                return net.decide(ShieldObservation.capture(
                    battle: battle, defenderIndex: d, opportunity: o, move: move))
            }
        }
        battle.simulate()
        return (battle.battleRating(forIndex: 0), battle.battleRating(forIndex: 1))
    }

    // Paired comparison per battle: same matchup + config, only the shield
    // brain differs. A "win" is rating > 500.
    var games = 0
    var winsBase = 0, winsNet = 0, winsMirror = 0
    var ratingBase = 0.0, ratingNet = 0.0, ratingMirror = 0.0
    var flipsUp = 0, flipsDown = 0

    for (i, j) in valPairs {
        for config in evalConfigs {
            // The net plays each side in turn so per-side biases cancel.
            for netSide in 0...1 {
                guard let base = play(i, j, config, netSides: []),
                      let swapped = play(i, j, config, netSides: [netSide]),
                      let mirror = play(i, j, config, netSides: [0, 1])
                else { continue }
                let baseR = netSide == 0 ? base.a : base.b
                let netR = netSide == 0 ? swapped.a : swapped.b
                let mirrorR = netSide == 0 ? mirror.a : mirror.b
                games += 1
                ratingBase += Double(baseR); ratingNet += Double(netR); ratingMirror += Double(mirrorR)
                if baseR > 500 { winsBase += 1 }
                if netR > 500 { winsNet += 1 }
                if mirrorR > 500 { winsMirror += 1 }
                if baseR <= 500 && netR > 500 { flipsUp += 1 }
                if baseR > 500 && netR <= 500 { flipsDown += 1 }
            }
        }
    }

    let n = Double(max(games, 1))
    print(String(format: "\n%d paired games (net side alternated)", games))
    print(String(format: "heuristic vs heuristic:  win rate %5.1f%%   mean rating %6.1f",
                 100 * Double(winsBase) / n, ratingBase / n))
    print(String(format: "net       vs heuristic:  win rate %5.1f%%   mean rating %6.1f",
                 100 * Double(winsNet) / n, ratingNet / n))
    print(String(format: "net       vs net:        win rate %5.1f%%   mean rating %6.1f",
                 100 * Double(winsMirror) / n, ratingMirror / n))
    print(String(format: "outcome flips: +%d won that heuristic lost, -%d lost that heuristic won",
                 flipsUp, flipsDown))
    exit(0)
}

// MARK: - Work list: every pair × shield configs

// Mixed shield counts matter: the policy must learn 1-shield discipline and
// last-shield stinginess, not just the symmetric 2-2 game.
let shieldConfigs: [(a: Int, b: Int)] = [(2, 2), (1, 1), (2, 1), (1, 2), (1, 0), (0, 1)]

var pairs: [(Int, Int)] = []
for i in 0..<pool.count { for j in (i + 1)..<pool.count { pairs.append((i, j)) } }
print("\(pairs.count) pairs × \(shieldConfigs.count) shield configs = \(pairs.count * shieldConfigs.count) oracle battles")

// MARK: - Sample records

/// One shield decision: matchup key (for leakage-free splitting), side, config,
/// features, oracle label.
struct Sample: Encodable {
    let m: String       // matchup key: "speciesA|speciesB" (config-independent)
    let sa: Int         // shields A at battle start
    let sb: Int         // shields B
    let side: Int       // which side made this decision (0 = A)
    let o: Int          // opportunity index for that side
    let x: [Double]     // ShieldObservation features
    let y: Int          // oracle decision: 1 = shield
}

func writeJSONL(_ samples: [Sample], to path: String) throws {
    let encoder = JSONEncoder()
    var lines: [String] = []
    lines.reserveCapacity(samples.count)
    for s in samples {
        lines.append(String(data: try encoder.encode(s), encoding: .utf8)!)
    }
    try (lines.joined(separator: "\n") + "\n")
        .write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
}

func printBalance(_ samples: [Sample]) {
    let positives = samples.filter { $0.y == 1 }.count
    print(String(format: "Class balance: %.1f%% shield / %.1f%% no-shield",
                 100 * Double(positives) / Double(max(samples.count, 1)),
                 100 * Double(samples.count - positives) / Double(max(samples.count, 1))))
}

// MARK: - DAgger mode: relabel the net's own visited states with the oracle

if CommandLine.arguments.contains("--dagger") {
    let net = try ShieldPolicyNet(contentsOf: URL(fileURLWithPath: "\(outDir)/shield_policy.json"))

    // Training matchups only — the val split must stay untouched by aggregation.
    let trainPairs = pairs.filter { crc32("\(pool[$0.0].id)|\(pool[$0.1].id)") % 10 != 0 }
    print("DAgger: \(trainPairs.count) train matchups × \(shieldConfigs.count) configs, net plays both sides")

    /// The oracle's decision for THIS mid-battle state: re-solve the shield game
    /// from both mons' current carried state (attacker's energy restored to
    /// pre-throw), and read whether optimal play shields the next charged move.
    func oracleLabel(_ battle: Battle, _ d: Int, _ move: BattleMove) -> Int {
        let defender = battle.pokemon[d]
        let attacker = battle.pokemon[d == 0 ? 1 : 0]
        let dc = defender.clone()
        dc.startHp = max(defender.hp, 1)
        dc.startEnergy = defender.energy
        dc.startStatBuffs = defender.statBuffs
        dc.startingShields = defender.shields          // pre-decision: includes this one
        dc.startDisguiseConsumed = dc.hasDisguise && !defender.disguiseActive
        let ac = attacker.clone()
        ac.startHp = max(attacker.hp, 1)
        ac.startEnergy = min(attacker.energy + move.energy, 100)   // pre-throw
        ac.startStatBuffs = attacker.statBuffs
        ac.startingShields = attacker.shields
        ac.startDisguiseConsumed = ac.hasDisguise && !attacker.disguiseActive
        let sol = ShieldSearch.optimalSolution(dc, ac) // defender is side A here
        return sol.policyA.contains(0) ? 1 : 0
    }

    let dCores = ProcessInfo.processInfo.activeProcessorCount
    let dChunks = dCores * 4
    nonisolated(unsafe) var daggerChunks = [[Sample]](repeating: [], count: dChunks)

    let dStart = ContinuousClock.now
    DispatchQueue.concurrentPerform(iterations: dChunks) { c in
        var local: [Sample] = []
        var k = c
        while k < trainPairs.count {
            let (i, j) = trainPairs[k]
            let a = pool[i], b = pool[j]
            for config in shieldConfigs {
                guard let pa = MatchupSimulator.makeBattlePokemon(
                          a.combatant, stats: a.stats, movesById: movesById, shields: config.a),
                      let pb = MatchupSimulator.makeBattlePokemon(
                          b.combatant, stats: b.stats, movesById: movesById, shields: config.b)
                else { continue }
                let battle = Battle(pa, pb)
                // On-policy: the current net decides both sides' shields...
                battle.shieldPolicy = { [unowned battle] d, o, move in
                    net.decide(ShieldObservation.capture(
                        battle: battle, defenderIndex: d, opportunity: o, move: move))
                }
                // ...while the oracle relabels every state the net reaches.
                let key = "\(a.id)|\(b.id)"
                battle.shieldDecisionObserver = { [unowned battle] d, o, move, _ in
                    let x = ShieldObservation.capture(battle: battle, defenderIndex: d, opportunity: o, move: move)
                    local.append(Sample(m: key, sa: config.a, sb: config.b,
                                        side: d, o: o, x: x, y: oracleLabel(battle, d, move)))
                }
                battle.simulate()
            }
            k += dChunks
        }
        daggerChunks[c] = local
    }

    let daggerSamples = daggerChunks.flatMap { $0 }
    let dElapsed = ContinuousClock.now - dStart
    print(String(format: "DAgger: %d relabeled samples in %.1fs", daggerSamples.count,
                 Double(dElapsed.components.seconds) + Double(dElapsed.components.attoseconds) / 1e18))
    printBalance(daggerSamples)
    try writeJSONL(daggerSamples, to: "\(outDir)/shield_dagger.jsonl")
    print("Wrote \(outDir)/shield_dagger.jsonl")
    exit(0)
}

// MARK: - Switch policy (RL milestone 2): shared team construction

/// Deterministic RNG so team sets are reproducible across gen/eval runs.
struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(below n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// Random valid trios (no shared species/family, shadow variants collapse).
func buildTrios(count: Int, seed: UInt64) -> [[Int]] {
    func family(_ id: String) -> String {
        id.hasSuffix("_shadow") ? String(id.dropLast("_shadow".count)) : id
    }
    var rng = SplitMix64(state: seed)
    var trios: [[Int]] = []
    var seen = Set<[Int]>()
    var attempts = 0
    while trios.count < count && attempts < count * 50 {
        attempts += 1
        var members: [Int] = []
        var families = Set<String>()
        while members.count < 3 {
            let i = rng.next(below: pool.count)
            let f = family(pool[i].id)
            if families.insert(f).inserted { members.append(i) }
        }
        members.sort()   // better-ranked mon leads, matching the finder
        if seen.insert(members).inserted { trios.append(members) }
    }
    return trios
}

func makeTrio(_ members: [Int]) -> [BattlePokemon]? {
    ThreeVThreeBattle.makeTeam(members.map { pool[$0].combatant },
                               stats: members.map { pool[$0].stats },
                               movesById: movesById)
}

func trioKey(_ members: [Int]) -> String { members.map { pool[$0].id }.joined(separator: "+") }

/// One switch decision labeled by rollout search.
struct SwitchSample: Encodable {
    let g: String       // game key "teamA vs teamB" (for leakage-free splitting)
    let side: Int
    let x: [Double]     // SwitchObservation features
    let legal: [Int]    // canonical actions that were available
    let v: [Int]        // rollout value (deciding side's final rating) per legal action
    let y: Int          // best action (argmax v; ties prefer the lower action = stay)
}

/// Plays one 3v3 with a scripted switch hook: calls < `forceAt` defer to the
/// base policy (deterministic, so they replay identically), the call at
/// `forceAt` takes `forced`, everything after is the base policy again. Pass
/// `forceAt = -1` for a pure base-policy game. `observe` fires per hook call
/// (pass 1 uses it to record decision points). `base` nil = the built-in
/// heuristics (round 1); a net's `decide` = expert iteration round 2+.
func playSwitchGame(
    _ tA: [Int], _ tB: [Int],
    forceAt: Int = -1, forced: Int = 0,
    base: ((SwitchContext) -> SwitchDecision)? = nil,
    observe: ((Int, SwitchContext) -> Void)? = nil
) -> TeamBattleResult? {
    guard let a = makeTrio(tA), let b = makeTrio(tB) else { return nil }
    var battle = ThreeVThreeBattle(teamA: a, teamB: b, voluntarySwitching: true)
    var call = 0
    battle.switchDecisionHook = { ctx in
        defer { call += 1 }
        observe?(call, ctx)
        if call == forceAt { return SwitchObservation.decision(for: forced, ctx) }
        return base?(ctx) ?? .heuristic
    }
    return battle.run()
}

// MARK: - --switch-gen: rollout-teacher labels for switch decisions

/// The integer value following a flag (e.g. `--switch-gen 40`), else a default.
func flagValue(_ flag: String, default def: Int) -> Int {
    guard let i = CommandLine.arguments.firstIndex(of: flag),
          i + 1 < CommandLine.arguments.count,
          let v = Int(CommandLine.arguments[i + 1]) else { return def }
    return v
}

/// The string value following a flag (e.g. `--weights path.json`), else nil.
func stringFlag(_ flag: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: flag),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

/// Switch-net weights path (PPO passes candidates without touching the shipped file).
let switchWeightsPath = stringFlag("--weights") ?? "\(outDir)/switch_policy.json"

if CommandLine.arguments.contains("--switch-gen") {
    let teamCount = flagValue("--switch-gen", default: 120)
    let seed = UInt64(flagValue("--seed", default: 0xBEEF))
    let trios = buildTrios(count: teamCount, seed: seed)
    // Expert iteration: --base-net makes the current switch net the base policy
    // in pass 1 AND the branch continuations, so the search improves on the
    // net's own play instead of the heuristics'.
    let baseNet: SwitchPolicyNet? = CommandLine.arguments.contains("--base-net")
        ? try SwitchPolicyNet(contentsOf: URL(fileURLWithPath: switchWeightsPath))
        : nil
    let base: ((SwitchContext) -> SwitchDecision)? = baseNet.map { net in { net.decide($0) } }
    let outName = baseNet == nil ? "switch_dataset.jsonl" : "switch_dataset_iter_seed\(seed).jsonl"
    var games: [(Int, Int)] = []
    for i in 0..<trios.count { for j in (i + 1)..<trios.count { games.append((i, j)) } }
    print("Switch-gen: \(trios.count) teams (seed \(seed)), \(games.count) games, "
          + "base policy: \(baseNet == nil ? "heuristics" : "current net")")

    let cores = ProcessInfo.processInfo.activeProcessorCount
    let chunks = cores * 4
    nonisolated(unsafe) var chunkOut = [[SwitchSample]](repeating: [], count: chunks)

    let t0 = ContinuousClock.now
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        var local: [SwitchSample] = []
        var k = c
        while k < games.count {
            let (ti, tj) = games[k]
            let key = "\(trioKey(trios[ti])) vs \(trioKey(trios[tj]))"

            // Pass 1: record every decision point the base-policy game reaches.
            struct Point { let call: Int; let side: Int; let x: [Double]; let legal: [Int] }
            var points: [Point] = []
            guard playSwitchGame(trios[ti], trios[tj], base: base, observe: { call, ctx in
                let legal = SwitchObservation.legalActions(ctx)
                guard legal.count >= 2 else { return }
                points.append(Point(call: call, side: ctx.side,
                                    x: SwitchObservation.capture(ctx), legal: legal))
            }) != nil else { k += chunks; continue }

            // Branch rollouts: replay the game once per legal action per point.
            for p in points {
                var values: [Int] = []
                values.reserveCapacity(p.legal.count)
                for action in p.legal {
                    guard let r = playSwitchGame(trios[ti], trios[tj],
                                                 forceAt: p.call, forced: action,
                                                 base: base) else { break }
                    values.append(p.side == 0 ? r.ratingA : 1000 - r.ratingA)
                }
                guard values.count == p.legal.count else { continue }
                var best = 0
                for i in values.indices where values[i] > values[best] { best = i }
                local.append(SwitchSample(g: key, side: p.side, x: p.x,
                                          legal: p.legal, v: values, y: p.legal[best]))
            }
            k += chunks
        }
        chunkOut[c] = local
    }

    let samples = chunkOut.flatMap { $0 }
    let dt = ContinuousClock.now - t0
    print(String(format: "Switch-gen: %d labeled decisions in %.1fs",
                 samples.count,
                 Double(dt.components.seconds) + Double(dt.components.attoseconds) / 1e18))
    var actionCounts = [0, 0, 0]
    for s in samples { actionCounts[s.y] += 1 }
    print("Label distribution: stay \(actionCounts[0]), backup1 \(actionCounts[1]), backup2 \(actionCounts[2])")

    let enc = JSONEncoder()
    var lines: [String] = []
    lines.reserveCapacity(samples.count)
    for s in samples { lines.append(String(data: try enc.encode(s), encoding: .utf8)!) }
    try (lines.joined(separator: "\n") + "\n")
        .write(to: URL(fileURLWithPath: "\(outDir)/\(outName)"), atomically: true, encoding: .utf8)

    struct SwitchMeta: Encodable { let featureNames: [String]; let sampleCount: Int; let teams: Int }
    let me = JSONEncoder(); me.outputFormatting = [.prettyPrinted, .sortedKeys]
    try me.encode(SwitchMeta(featureNames: SwitchObservation.featureNames,
                             sampleCount: samples.count, teams: trios.count))
        .write(to: URL(fileURLWithPath: "\(outDir)/switch_meta.json"))
    print("Wrote \(outDir)/\(outName) and switch_meta.json")
    exit(0)
}

// MARK: - --switch-eval: learned switch policy vs heuristics, held-out teams

if CommandLine.arguments.contains("--switch-eval") {
    let net = try SwitchPolicyNet(contentsOf: URL(fileURLWithPath: switchWeightsPath))
    let teamCount = flagValue("--switch-eval", default: 120)
    // A different --seed builds teams never seen in training in any pairing.
    let seed = UInt64(flagValue("--seed", default: 0xBEEF))
    let trios = buildTrios(count: teamCount, seed: seed)
    var games: [(Int, Int)] = []
    for i in 0..<trios.count {
        for j in (i + 1)..<trios.count {
            let key = "\(trioKey(trios[i])) vs \(trioKey(trios[j]))"
            if crc32(key) % 10 == 0 { games.append((i, j)) }   // held-out split
        }
    }
    print("Switch-eval: \(games.count) held-out games")

    /// One game; `netSides` = which sides the learned policy controls.
    func play(_ ti: Int, _ tj: Int, netSides: Set<Int>) -> Int? {
        guard let a = makeTrio(trios[ti]), let b = makeTrio(trios[tj]) else { return nil }
        var battle = ThreeVThreeBattle(teamA: a, teamB: b, voluntarySwitching: true)
        if !netSides.isEmpty {
            battle.switchDecisionHook = { ctx in
                netSides.contains(ctx.side) ? net.decide(ctx) : .heuristic
            }
        }
        return battle.run().ratingA
    }

    var n = 0
    var winsBase = 0, winsNet = 0, winsMirror = 0
    var ratingBase = 0.0, ratingNet = 0.0, ratingMirror = 0.0
    var flipsUp = 0, flipsDown = 0
    for (ti, tj) in games {
        for netSide in 0...1 {
            guard let base = play(ti, tj, netSides: []),
                  let swapped = play(ti, tj, netSides: [netSide]),
                  let mirror = play(ti, tj, netSides: [0, 1]) else { continue }
            let baseR = netSide == 0 ? base : 1000 - base
            let netR = netSide == 0 ? swapped : 1000 - swapped
            let mirrorR = netSide == 0 ? mirror : 1000 - mirror
            n += 1
            ratingBase += Double(baseR); ratingNet += Double(netR); ratingMirror += Double(mirrorR)
            if baseR > 500 { winsBase += 1 }
            if netR > 500 { winsNet += 1 }
            if mirrorR > 500 { winsMirror += 1 }
            if baseR <= 500 && netR > 500 { flipsUp += 1 }
            if baseR > 500 && netR <= 500 { flipsDown += 1 }
        }
    }
    let d = Double(max(n, 1))
    print(String(format: "\n%d paired games (net side alternated)", n))
    print(String(format: "heuristics vs heuristics:  win rate %5.1f%%   mean rating %6.1f",
                 100 * Double(winsBase) / d, ratingBase / d))
    print(String(format: "net switch vs heuristics:  win rate %5.1f%%   mean rating %6.1f",
                 100 * Double(winsNet) / d, ratingNet / d))
    print(String(format: "net switch vs net switch:  win rate %5.1f%%   mean rating %6.1f  (side-bias check: expect ~50%%)",
                 100 * Double(winsMirror) / d, ratingMirror / d))
    print(String(format: "outcome flips: +%d / -%d", flipsUp, flipsDown))
    exit(0)
}

// MARK: - --full-eval: the whole learned stack vs the all-heuristic engine

if CommandLine.arguments.contains("--full-eval") {
    let switchNet = try SwitchPolicyNet(contentsOf: URL(fileURLWithPath: switchWeightsPath))
    let shieldNet = try ShieldPolicyNet(contentsOf: URL(fileURLWithPath: "\(outDir)/shield_policy.json"))
    let teamCount = flagValue("--full-eval", default: 120)
    let seed = UInt64(flagValue("--seed", default: 424242))
    let trios = buildTrios(count: teamCount, seed: seed)
    var games: [(Int, Int)] = []
    for i in 0..<trios.count {
        for j in (i + 1)..<trios.count {
            let key = "\(trioKey(trios[i])) vs \(trioKey(trios[j]))"
            if crc32(key) % 10 == 0 { games.append((i, j)) }
        }
    }
    print("Full-stack eval: \(games.count) games (learned switches + shields vs heuristics)")

    // Matches the app's Team Finder fast path: greedy shields for the heuristic
    // side (optimalShields off), learned shields + switches for the AI side.
    func play(_ ti: Int, _ tj: Int, netSides: Set<Int>) -> Int? {
        guard let a = makeTrio(trios[ti]), let b = makeTrio(trios[tj]) else { return nil }
        var battle = ThreeVThreeBattle(teamA: a, teamB: b,
                                       optimalShields: false, voluntarySwitching: true)
        if !netSides.isEmpty {
            battle.switchDecisionHook = { ctx in
                netSides.contains(ctx.side) ? switchNet.decide(ctx) : .heuristic
            }
            battle.learnedShieldNet = shieldNet
            battle.learnedShieldSides = netSides
        }
        return battle.run().ratingA
    }

    var n = 0
    var winsBase = 0, winsNet = 0, winsMirror = 0
    var ratingBase = 0.0, ratingNet = 0.0
    var flipsUp = 0, flipsDown = 0
    for (ti, tj) in games {
        for netSide in 0...1 {
            guard let base = play(ti, tj, netSides: []),
                  let swapped = play(ti, tj, netSides: [netSide]),
                  let mirror = play(ti, tj, netSides: [0, 1]) else { continue }
            let baseR = netSide == 0 ? base : 1000 - base
            let netR = netSide == 0 ? swapped : 1000 - swapped
            let mirrorR = netSide == 0 ? mirror : 1000 - mirror
            n += 1
            ratingBase += Double(baseR); ratingNet += Double(netR)
            if baseR > 500 { winsBase += 1 }
            if netR > 500 { winsNet += 1 }
            if mirrorR > 500 { winsMirror += 1 }
            if baseR <= 500 && netR > 500 { flipsUp += 1 }
            if baseR > 500 && netR <= 500 { flipsDown += 1 }
        }
    }
    let d = Double(max(n, 1))
    print(String(format: "\n%d paired games (net side alternated)", n))
    print(String(format: "heuristic engine vs itself:  win rate %5.1f%%   mean rating %6.1f",
                 100 * Double(winsBase) / d, ratingBase / d))
    print(String(format: "FULL AI STACK vs heuristics: win rate %5.1f%%   mean rating %6.1f",
                 100 * Double(winsNet) / d, ratingNet / d))
    print(String(format: "AI stack mirror:             win rate %5.1f%%  (side-bias check: expect ~50%%)",
                 100 * Double(winsMirror) / d))
    print(String(format: "outcome flips: +%d / -%d", flipsUp, flipsDown))
    exit(0)
}

// MARK: - --lead-eval: is choosing your lead by expected value worth it?

// Leads are picked blind in GBL (no revealed info), so a team's best lead is
// the one maximizing expected outcome over the opponent distribution. This
// computes each team's best-expected lead by rollouts (full learned stack on
// both sides), iterates once so opponents lead intelligently too, then
// measures the payoff with the usual paired protocol.
if CommandLine.arguments.contains("--lead-eval") {
    let switchNet = try SwitchPolicyNet(contentsOf: URL(fileURLWithPath: switchWeightsPath))
    let shieldNet = try ShieldPolicyNet(contentsOf: URL(fileURLWithPath: "\(outDir)/shield_policy.json"))
    let teamCount = flagValue("--lead-eval", default: 120)
    let seed = UInt64(flagValue("--seed", default: 424242))
    let trios = buildTrios(count: teamCount, seed: seed)
    let sampleOpponents = 30

    func playLead(_ ti: Int, _ tj: Int, _ leadA: Int, _ leadB: Int) -> Int? {
        guard let a = makeTrio(trios[ti]), let b = makeTrio(trios[tj]) else { return nil }
        var battle = ThreeVThreeBattle(teamA: a, teamB: b, leadA: leadA, leadB: leadB,
                                       optimalShields: false, voluntarySwitching: true)
        battle.switchDecisionHook = { switchNet.decide($0) }
        battle.learnedShieldNet = shieldNet
        return battle.run().ratingA
    }

    // Fixed-point iteration: round 0 assumes opponents lead slot 0 (the
    // finder's rank-order default), round 1 re-solves against the round-0 leads.
    var bestLead = [Int](repeating: 0, count: trios.count)
    for iteration in 0..<2 {
        nonisolated(unsafe) var newBest = bestLead
        let current = bestLead
        DispatchQueue.concurrentPerform(iterations: trios.count) { t in
            var rng = SplitMix64(state: seed ^ UInt64(t) &* 0x9E37_79B9)
            var sums = [0.0, 0.0, 0.0]
            var counted = 0
            while counted < sampleOpponents {
                let o = rng.next(below: trios.count)
                if o == t { continue }
                counted += 1
                for lead in 0..<3 {
                    if let r = playLead(t, o, lead, current[o]) { sums[lead] += Double(r) }
                }
            }
            var best = 0
            for l in 1..<3 where sums[l] > sums[best] { best = l }
            newBest[t] = best
        }
        bestLead = newBest
        let moved = bestLead.enumerated().filter { $0.element != 0 }.count
        print("lead iteration \(iteration): \(moved)/\(trios.count) teams prefer a non-default lead")
    }

    // Paired payoff: best-expected lead vs the rank-order default.
    var games: [(Int, Int)] = []
    for i in 0..<trios.count {
        for j in (i + 1)..<trios.count {
            let key = "\(trioKey(trios[i])) vs \(trioKey(trios[j]))"
            if crc32(key) % 10 == 0 { games.append((i, j)) }
        }
    }
    var n = 0
    var winsBase = 0, winsLead = 0, winsMirror = 0
    var ratingBase = 0.0, ratingLead = 0.0
    for (i, j) in games {
        for side in 0...1 {
            guard let base = playLead(i, j, 0, 0),
                  let test = playLead(i, j, side == 0 ? bestLead[i] : 0, side == 1 ? bestLead[j] : 0),
                  let mirror = playLead(i, j, bestLead[i], bestLead[j]) else { continue }
            let baseR = side == 0 ? base : 1000 - base
            let testR = side == 0 ? test : 1000 - test
            let mirrorR = side == 0 ? mirror : 1000 - mirror
            n += 1
            ratingBase += Double(baseR); ratingLead += Double(testR)
            if baseR > 500 { winsBase += 1 }
            if testR > 500 { winsLead += 1 }
            if mirrorR > 500 { winsMirror += 1 }
        }
    }
    let d = Double(max(n, 1))
    print(String(format: "\n%d paired games (lead side alternated, full AI stack both sides)", n))
    print(String(format: "default lead vs default:   win rate %5.1f%%   mean rating %6.1f",
                 100 * Double(winsBase) / d, ratingBase / d))
    print(String(format: "expected-value lead:       win rate %5.1f%%   mean rating %6.1f",
                 100 * Double(winsLead) / d, ratingLead / d))
    print(String(format: "both sides EV leads:       win rate %5.1f%%  (side-bias check: expect ~50%%)",
                 100 * Double(winsMirror) / d))
    exit(0)
}

// MARK: - --teamrank: team rankings under heuristic vs AI play + Nash metagame

// The finder's leaderboard is only as good as the play inside the battles.
// This runs one full round robin under heuristic play and one under the full
// learned stack, compares the leaderboards, then treats the AI-play win matrix
// as a zero-sum team-selection metagame and solves it by fictitious play:
// the principled "best team" is the one with the highest win rate against the
// equilibrium meta, not the one that best farms weak teams.
if CommandLine.arguments.contains("--teamrank") {
    let switchNet = try SwitchPolicyNet(contentsOf: URL(fileURLWithPath: switchWeightsPath))
    let shieldNet = try ShieldPolicyNet(contentsOf: URL(fileURLWithPath: "\(outDir)/shield_policy.json"))
    let teamCount = flagValue("--teamrank", default: 120)
    let seed = UInt64(flagValue("--seed", default: 424242))
    let trios = buildTrios(count: teamCount, seed: seed)
    let n = trios.count
    print("Team rank: \(n) teams, \(n * (n - 1) / 2) games per config")

    func winMatrix(ai: Bool) -> [[Double]] {
        var pairs: [(Int, Int)] = []
        for i in 0..<n { for j in (i + 1)..<n { pairs.append((i, j)) } }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let chunks = cores * 4
        nonisolated(unsafe) var results = [[(Int, Int, Double)]](repeating: [], count: chunks)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            var local: [(Int, Int, Double)] = []
            var k = c
            while k < pairs.count {
                let (i, j) = pairs[k]
                k += chunks
                guard let a = makeTrio(trios[i]), let b = makeTrio(trios[j]) else { continue }
                var battle = ThreeVThreeBattle(teamA: a, teamB: b,
                                               optimalShields: false, voluntarySwitching: true)
                if ai {
                    battle.switchDecisionHook = { switchNet.decide($0) }
                    battle.learnedShieldNet = shieldNet
                }
                let r = battle.run().ratingA
                local.append((i, j, r > 500 ? 1 : (r == 500 ? 0.5 : 0)))
            }
            results[c] = local
        }
        var w = [[Double]](repeating: [Double](repeating: 0.5, count: n), count: n)
        for chunk in results {
            for (i, j, v) in chunk { w[i][j] = v; w[j][i] = 1 - v }
        }
        return w
    }

    let t0 = ContinuousClock.now
    let wH = winMatrix(ai: false)
    let tH = ContinuousClock.now - t0
    let t1 = ContinuousClock.now
    let wA = winMatrix(ai: true)
    let tA = ContinuousClock.now - t1
    func secs(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
    print(String(format: "round robin: heuristics %.1fs, AI play %.1fs (%.1fx cost)",
                 secs(tH), secs(tA), secs(tA) / max(secs(tH), 0.001)))

    func winRates(_ w: [[Double]]) -> [Double] {
        (0..<n).map { i in (0..<n).filter { $0 != i }.reduce(0.0) { $0 + w[i][$1] } / Double(n - 1) }
    }
    let rateH = winRates(wH), rateA = winRates(wA)
    func ranks(_ scores: [Double]) -> [Int] {
        var r = [Int](repeating: 0, count: n)
        for (rank, i) in (0..<n).sorted(by: { scores[$0] > scores[$1] }).enumerated() { r[i] = rank }
        return r
    }
    let rankH = ranks(rateH), rankA = ranks(rateA)

    // Spearman rank correlation.
    let dSq = (0..<n).reduce(0.0) { $0 + pow(Double(rankH[$1] - rankA[$1]), 2) }
    let spearman = 1 - 6 * dSq / Double(n * (n * n - 1))
    print(String(format: "\nSpearman rank correlation heuristic vs AI play: %.3f", spearman))
    let topH = Set((0..<n).sorted { rateH[$0] > rateH[$1] }.prefix(10))
    let topA = Set((0..<n).sorted { rateA[$0] > rateA[$1] }.prefix(10))
    print("top-10 overlap: \(topH.intersection(topA).count)/10")

    let movers = (0..<n).sorted { abs(rankH[$0] - rankA[$0]) > abs(rankH[$1] - rankA[$1]) }.prefix(5)
    print("\nbiggest movers (heuristic rank → AI rank):")
    for i in movers {
        print(String(format: "  %@: #%d → #%d", trioKey(trios[i]), rankH[i] + 1, rankA[i] + 1))
    }

    // MARK: Nash metagame on the AI-play matrix (fictitious play, symmetric game).
    var counts = [Double](repeating: 1, count: n)
    for _ in 0..<200_000 {
        let total = counts.reduce(0, +)
        var best = 0
        var bestV = -Double.infinity
        for i in 0..<n {
            var v = 0.0
            for j in 0..<n { v += wA[i][j] * counts[j] }
            v /= total
            if v > bestV { bestV = v; best = i }
        }
        counts[best] += 1
    }
    let total = counts.reduce(0, +)
    let mix = counts.map { $0 / total }
    // Each team's win rate against the equilibrium meta — the principled ranking.
    let metaScore = (0..<n).map { i in (0..<n).reduce(0.0) { $0 + wA[i][$1] * mix[$1] } }

    print("\nequilibrium meta (support ≥ 2%):")
    for i in (0..<n).sorted(by: { mix[$0] > mix[$1] }) where mix[i] >= 0.02 {
        print(String(format: "  %5.1f%%  %@", 100 * mix[i], trioKey(trios[i])))
    }
    print("\ntop 12 teams by win rate VS THE EQUILIBRIUM META (AI play):")
    for (k, i) in (0..<n).sorted(by: { metaScore[$0] > metaScore[$1] }).prefix(12).enumerated() {
        print(String(format: "  %2d. %.3f  (raw RR: #%d)  %@", k + 1, metaScore[i], rankA[i] + 1, trioKey(trios[i])))
    }
    print("\ntop 5 by raw round-robin win rate (AI play), for contrast:")
    for (k, i) in (0..<n).sorted(by: { rateA[$0] > rateA[$1] }).prefix(5).enumerated() {
        print(String(format: "  %2d. %.3f  %@", k + 1, rateA[i], trioKey(trios[i])))
    }
    exit(0)
}

// MARK: - --duel: two switch nets head-to-head (argmax play, sides alternated)

if let dIdx = CommandLine.arguments.firstIndex(of: "--duel"),
   dIdx + 2 < CommandLine.arguments.count {
    let netX = try SwitchPolicyNet(contentsOf: URL(fileURLWithPath: CommandLine.arguments[dIdx + 1]))
    let netY = try SwitchPolicyNet(contentsOf: URL(fileURLWithPath: CommandLine.arguments[dIdx + 2]))
    let shieldNet = try ShieldPolicyNet(contentsOf: URL(fileURLWithPath: "\(outDir)/shield_policy.json"))
    let seed = UInt64(flagValue("--seed", default: 424242))
    let trios = buildTrios(count: 120, seed: seed)
    var games: [(Int, Int)] = []
    for i in 0..<trios.count {
        for j in (i + 1)..<trios.count {
            let key = "\(trioKey(trios[i])) vs \(trioKey(trios[j]))"
            if crc32(key) % 10 == 0 { games.append((i, j)) }
        }
    }
    print("Duel: \(games.count) games × 2 side assignments")

    func play(_ ti: Int, _ tj: Int, xSide: Int) -> Int? {
        guard let a = makeTrio(trios[ti]), let b = makeTrio(trios[tj]) else { return nil }
        var battle = ThreeVThreeBattle(teamA: a, teamB: b,
                                       optimalShields: false, voluntarySwitching: true)
        battle.learnedShieldNet = shieldNet
        battle.switchDecisionHook = { ctx in
            (ctx.side == xSide ? netX : netY).decide(ctx)
        }
        let r = battle.run().ratingA
        return xSide == 0 ? r : 1000 - r
    }

    var n = 0, winsX = 0, ties = 0
    var ratingX = 0.0
    for (i, j) in games {
        for xSide in 0...1 {
            guard let r = play(i, j, xSide: xSide) else { continue }
            n += 1
            ratingX += Double(r)
            if r > 500 { winsX += 1 } else if r == 500 { ties += 1 }
        }
    }
    let d = Double(max(n, 1))
    print(String(format: "net X (%@) vs net Y (%@):", CommandLine.arguments[dIdx + 1], CommandLine.arguments[dIdx + 2]))
    print(String(format: "X win rate %5.1f%%  (ties %.1f%%)  mean rating %6.1f over %d games",
                 100 * Double(winsX) / d, 100 * Double(ties) / d, ratingX / d, n))
    exit(0)
}

// MARK: - --selfplay-batch: PPO rollouts (both sides sample from the policy)

// Plays N self-play games with STOCHASTIC switch decisions (softmax over legal
// actions) so PPO gets exploration, and writes one transition per decision:
// features, sampled action, its log-prob under the acting policy, legal mask,
// and the terminal reward (final rating from the deciding side, centered).
// Shields stay on the frozen learned net for both sides; moves stay on the DP.
if CommandLine.arguments.contains("--selfplay-batch") {
    let gameCount = flagValue("--selfplay-batch", default: 2000)
    let seed = UInt64(flagValue("--seed", default: 1))
    let outPath = stringFlag("--out") ?? "\(outDir)/selfplay_batch.jsonl"
    let net = try SwitchPolicyNet(contentsOf: URL(fileURLWithPath: switchWeightsPath))
    let shieldNet = try ShieldPolicyNet(contentsOf: URL(fileURLWithPath: "\(outDir)/shield_policy.json"))
    // League anchor: a frozen net (e.g. EXIT r3). When set, half the games are
    // self-play and the other half pit the learner against the anchor or the
    // heuristics — pure self-play drifts into self-referential equilibria that
    // lose to everyone else (measured: 45.7% vs the anchor after 50 iters).
    let anchor: SwitchPolicyNet? = try stringFlag("--anchor").map {
        try SwitchPolicyNet(contentsOf: URL(fileURLWithPath: $0))
    }
    // Fresh random teams every batch (seed-dependent) for coverage.
    let trios = buildTrios(count: 150, seed: 0xD1CE &+ seed)

    struct Transition: Encodable {
        let x: [Double]     // SwitchObservation features
        let a: Int          // sampled canonical action
        let lp: Double      // log π(a|x) under the acting policy
        let legal: [Int]
        let r: Double       // terminal reward: rating/1000 − 0.5 (deciding side)
    }

    let cores = ProcessInfo.processInfo.activeProcessorCount
    let chunks = cores * 4
    nonisolated(unsafe) var chunkOut = [[Transition]](repeating: [], count: chunks)

    let t0 = ContinuousClock.now
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        var local: [Transition] = []
        var rng = SplitMix64(state: seed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(c))
        var g = c
        while g < gameCount {
            g += chunks
            let ti = rng.next(below: trios.count)
            var tj = rng.next(below: trios.count)
            while tj == ti { tj = rng.next(below: trios.count) }
            guard let a = makeTrio(trios[ti]), let b = makeTrio(trios[tj]) else { continue }

            // Game modes with an anchor: 0-1 self-play, 2 vs anchor, 3 vs heuristics.
            let mode = anchor != nil ? rng.next(below: 4) : 0
            let learnerSide = Int(rng.next(below: 2))

            var battle = ThreeVThreeBattle(teamA: a, teamB: b,
                                           optimalShields: false, voluntarySwitching: true)
            battle.learnedShieldNet = shieldNet
            var episode: [(x: [Double], a: Int, lp: Double, legal: [Int], side: Int)] = []
            battle.switchDecisionHook = { ctx in
                // Frozen opposition plays deterministically and is never recorded.
                if mode >= 2 && ctx.side != learnerSide {
                    return mode == 2 ? anchor!.decide(ctx) : .heuristic
                }
                let legal = SwitchObservation.legalActions(ctx)
                guard legal.count >= 2 else {
                    return legal.first.map { SwitchObservation.decision(for: $0, ctx) } ?? .heuristic
                }
                let x = SwitchObservation.capture(ctx)
                let z = net.logits(x)
                // Masked softmax + sample.
                var maxZ = -Double.infinity
                for i in legal { maxZ = max(maxZ, z[i]) }
                var probs = [Double](repeating: 0, count: legal.count)
                var sum = 0.0
                for (k, i) in legal.enumerated() { probs[k] = exp(z[i] - maxZ); sum += probs[k] }
                var u = Double(rng.next() >> 11) * (1.0 / 9007199254740992.0) * sum
                var pick = legal.count - 1
                for k in probs.indices { if u < probs[k] { pick = k; break }; u -= probs[k] }
                let action = legal[pick]
                episode.append((x, action, log(probs[pick] / sum), legal, ctx.side))
                return SwitchObservation.decision(for: action, ctx)
            }
            let result = battle.run()
            let rA = Double(result.ratingA) / 1000.0 - 0.5
            for e in episode {
                local.append(Transition(x: e.x, a: e.a, lp: e.lp, legal: e.legal,
                                        r: e.side == 0 ? rA : -rA))
            }
        }
        chunkOut[c] = local
    }

    let transitions = chunkOut.flatMap { $0 }
    let dt = ContinuousClock.now - t0
    let enc = JSONEncoder()
    var lines: [String] = []
    lines.reserveCapacity(transitions.count)
    for t in transitions { lines.append(String(data: try enc.encode(t), encoding: .utf8)!) }
    try (lines.joined(separator: "\n") + "\n")
        .write(to: URL(fileURLWithPath: outPath), atomically: true, encoding: .utf8)
    print(String(format: "selfplay: %d games → %d transitions in %.1fs → %@",
                 gameCount, transitions.count,
                 Double(dt.components.seconds) + Double(dt.components.attoseconds) / 1e18,
                 outPath))
    exit(0)
}

// MARK: - Generation (parallel, chunked like bench)

let cores = ProcessInfo.processInfo.activeProcessorCount
let chunkCount = cores * 4
nonisolated(unsafe) var chunkSamples = [[Sample]](repeating: [], count: chunkCount)

let start = ContinuousClock.now
DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
    var local: [Sample] = []
    var k = c
    while k < pairs.count {
        let (i, j) = pairs[k]
        let a = pool[i], b = pool[j]
        for config in shieldConfigs {
            // Teacher: the game-theoretic optimum for this matchup + config.
            guard let sol = ShieldSearch.optimal(
                a.combatant, statsA: a.stats, b.combatant, statsB: b.stats,
                movesById: movesById, shieldsA: config.a, shieldsB: config.b)
            else { continue }

            // Student data: replay under the oracle policy, logging the
            // observation at every shield opportunity that actually arises.
            guard let pa = MatchupSimulator.makeBattlePokemon(
                      a.combatant, stats: a.stats, movesById: movesById, shields: config.a),
                  let pb = MatchupSimulator.makeBattlePokemon(
                      b.combatant, stats: b.stats, movesById: movesById, shields: config.b)
            else { continue }

            let battle = Battle(pa, pb)
            battle.shieldOverride = { d, o in
                d == 0 ? sol.policyA.contains(o) : sol.policyB.contains(o)
            }
            let key = "\(a.id)|\(b.id)"
            battle.shieldDecisionObserver = { [unowned battle] d, o, move, decision in
                let x = ShieldObservation.capture(battle: battle, defenderIndex: d, opportunity: o, move: move)
                local.append(Sample(m: key, sa: config.a, sb: config.b,
                                    side: d, o: o, x: x, y: decision ? 1 : 0))
            }
            battle.simulate()
        }
        k += chunkCount
    }
    chunkSamples[c] = local
}

let samples = chunkSamples.flatMap { $0 }
let elapsed = ContinuousClock.now - start
print(String(format: "Generated %d samples in %.1fs", samples.count,
             Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))

printBalance(samples)

// MARK: - Write JSONL + metadata

let datasetPath = "\(outDir)/shield_dataset.jsonl"
try writeJSONL(samples, to: datasetPath)

struct Meta: Encodable {
    let featureNames: [String]
    let sampleCount: Int
    let poolSize: Int
    let shieldConfigs: [[Int]]
}
let metaEncoder = JSONEncoder()
metaEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let meta = Meta(featureNames: ShieldObservation.featureNames,
                sampleCount: samples.count,
                poolSize: pool.count,
                shieldConfigs: shieldConfigs.map { [$0.a, $0.b] })
try metaEncoder.encode(meta).write(to: URL(fileURLWithPath: "\(outDir)/shield_meta.json"))

print("Wrote \(datasetPath) and shield_meta.json")
