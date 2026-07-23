//
//  main.swift — standalone CPU baseline benchmark for the PokeParty battle engine.
//
//  Compiles the real engine sources with -O and measures the two TeamFinder hot
//  paths exactly as the app runs them:
//    1. Seeding: pairwise 1v1s via MatchupSimulator.rate (fresh BattlePokemon per battle)
//    2. Round robin: 3v3 via ThreeVThreeBattle (.bestMatchup, greedy shields)
//
//  Usage: ./bench <data-dir>
//

import Foundation

// MARK: - Data loading (mirrors DataService's decode, minus SwiftData)

struct GameMasterFile: Decodable {
    let pokemon: [Pokemon]
    let moves: [Move]
}

struct RankEntry: Decodable {
    let speciesId: String
    let moveset: [String]
}

let dataDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "data"
let gmData = try Data(contentsOf: URL(fileURLWithPath: "\(dataDir)/gamemaster.json"))
let rankData = try Data(contentsOf: URL(fileURLWithPath: "\(dataDir)/rankings-1500.json"))
let gm = try JSONDecoder().decode(GameMasterFile.self, from: gmData)
let rankings = try JSONDecoder().decode([RankEntry].self, from: rankData)

let movesById = Dictionary(uniqueKeysWithValues: gm.moves.map { ($0.moveId, $0) })
let speciesById = Dictionary(uniqueKeysWithValues: gm.pokemon.map { ($0.speciesId, $0) })

// MARK: - Build a realistic Great League pool from the rankings

struct PoolEntry {
    let combatant: MatchupSimulator.Combatant
    let stats: BattlePokemon.Stats
}

var pool: [PoolEntry] = []
for entry in rankings {
    guard pool.count < 200 else { break }
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
    pool.append(PoolEntry(combatant: combatant, stats: stats))
}
print("Pool: \(pool.count) Great League mons (ranked order, real movesets)")

// MARK: - Timing helpers

func measure(_ name: String, battles: Int, _ block: () -> Void) -> Double {
    let start = ContinuousClock.now
    block()
    let elapsed = ContinuousClock.now - start
    let seconds = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    let perSec = Double(battles) / seconds
    let usPer = seconds * 1e6 / Double(battles)
    print(String(format: "%@: %d battles in %.2fs  →  %.0f battles/s  (%.1f µs/battle)",
                 name, battles, seconds, perSec, usPer))
    return perSec
}

// Prevent the optimizer from deleting the work.
var checksum = 0

// MARK: - Profile mode: loop battles single-threaded so `sample` can attribute time.

if CommandLine.arguments.contains("--profile") {
    let n = min(100, pool.count)
    var profPairs: [(Int, Int)] = []
    for i in 0..<n { for j in (i + 1)..<n { profPairs.append((i, j)) } }
    print("profiling pid \(ProcessInfo.processInfo.processIdentifier)…")
    let deadline = ContinuousClock.now + .seconds(12)
    while ContinuousClock.now < deadline {
        for (i, j) in profPairs {
            if let r = MatchupSimulator.rate(pool[i].combatant, statsA: pool[i].stats,
                                             pool[j].combatant, statsB: pool[j].stats,
                                             movesById: movesById, shieldsA: 1, shieldsB: 1) {
                checksum &+= r.a
            }
        }
    }
    print("checksum \(checksum)")
    exit(0)
}

// MARK: - Bench 1: 1v1 seeding path (MatchupSimulator.rate, shields 1-1)

let n1 = min(100, pool.count)
var pairs: [(Int, Int)] = []
for i in 0..<n1 { for j in (i + 1)..<n1 { pairs.append((i, j)) } }

// Warmup
for (i, j) in pairs.prefix(200) {
    if let r = MatchupSimulator.rate(pool[i].combatant, statsA: pool[i].stats,
                                     pool[j].combatant, statsB: pool[j].stats,
                                     movesById: movesById, shieldsA: 1, shieldsB: 1) {
        checksum &+= r.a
    }
}

let rate1v1Single = measure("1v1 single-thread", battles: pairs.count) {
    for (i, j) in pairs {
        if let r = MatchupSimulator.rate(pool[i].combatant, statsA: pool[i].stats,
                                         pool[j].combatant, statsB: pool[j].stats,
                                         movesById: movesById, shieldsA: 1, shieldsB: 1) {
            checksum &+= r.a
        }
    }
}

// Setup-only cost: build the BattlePokemon pair but skip simulate().
let rateSetupOnly = measure("1v1 setup only  ", battles: pairs.count) {
    for (i, j) in pairs {
        let pa = MatchupSimulator.makeBattlePokemon(pool[i].combatant, stats: pool[i].stats,
                                                    movesById: movesById, shields: 1)
        let pb = MatchupSimulator.makeBattlePokemon(pool[j].combatant, stats: pool[j].stats,
                                                    movesById: movesById, shields: 1)
        checksum &+= (pa?.stats.hp ?? 0) &+ (pb?.stats.hp ?? 0)
    }
}

// Parallel across cores, chunked like TeamFinder.
let cores = ProcessInfo.processInfo.activeProcessorCount
let chunkCount = cores * 8
var partial = [Int](repeating: 0, count: chunkCount)
let rate1v1Parallel = measure("1v1 all cores   ", battles: pairs.count) {
    DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
        var local = 0
        var k = c
        while k < pairs.count {
            let (i, j) = pairs[k]
            if let r = MatchupSimulator.rate(pool[i].combatant, statsA: pool[i].stats,
                                             pool[j].combatant, statsB: pool[j].stats,
                                             movesById: movesById, shieldsA: 1, shieldsB: 1) {
                local &+= r.a
            }
            k += chunkCount
        }
        partial[c] = local
    }
}
checksum &+= partial.reduce(0, &+)

// MARK: - Bench 2: 3v3 round-robin path (ThreeVThreeBattle, bestMatchup, greedy shields)

let teamCount = min(40, pool.count / 3)
let trios: [[PoolEntry]] = (0..<teamCount).map { t in [pool[3 * t], pool[3 * t + 1], pool[3 * t + 2]] }
var teamPairs: [(Int, Int)] = []
for i in 0..<teamCount { for j in (i + 1)..<teamCount { teamPairs.append((i, j)) } }

func makeTeam(_ members: [PoolEntry]) -> [BattlePokemon]? {
    ThreeVThreeBattle.makeTeam(members.map(\.combatant), stats: members.map(\.stats), movesById: movesById)
}

func fight3v3(_ i: Int, _ j: Int) -> Int {
    guard let a = makeTeam(trios[i]), let b = makeTeam(trios[j]) else { return 0 }
    let result = ThreeVThreeBattle(teamA: a, teamB: b,
                                   switchPolicy: .bestMatchup, optimalShields: false).run()
    return result.ratingA
}

// Warmup
for (i, j) in teamPairs.prefix(30) { checksum &+= fight3v3(i, j) }

let singleSubset = Array(teamPairs.prefix(200))
let rate3v3Single = measure("3v3 single-thread", battles: singleSubset.count) {
    for (i, j) in singleSubset { checksum &+= fight3v3(i, j) }
}

var partial3 = [Int](repeating: 0, count: chunkCount)
let rate3v3Parallel = measure("3v3 all cores   ", battles: teamPairs.count) {
    DispatchQueue.concurrentPerform(iterations: chunkCount) { c in
        var local = 0
        var k = c
        while k < teamPairs.count {
            local &+= fight3v3(teamPairs[k].0, teamPairs[k].1)
            k += chunkCount
        }
        partial3[c] = local
    }
}
checksum &+= partial3.reduce(0, &+)

// MARK: - Bench 3: 3v3 with the game-theoretic shield search per segment

func fightOptimal(_ i: Int, _ j: Int) -> Int {
    guard let a = makeTeam(trios[i]), let b = makeTeam(trios[j]) else { return 0 }
    return ThreeVThreeBattle(teamA: a, teamB: b,
                             switchPolicy: .bestMatchup, optimalShields: true).run().ratingA
}

// Warmup
for (i, j) in teamPairs.prefix(5) { checksum &+= fightOptimal(i, j) }

let optimalSubset = Array(teamPairs.prefix(40))
let rateOptimalSingle = measure("3v3 optimal shld", battles: optimalSubset.count) {
    for (i, j) in optimalSubset { checksum &+= fightOptimal(i, j) }
}

// MARK: - Extrapolation to the real TeamFinder workload

print("\n--- Extrapolated TeamFinder workload (\(cores) cores) ---")
let seedBattles = 200 * 199 / 2
print(String(format: "Seeding matrix, 200-mon pool  (%6d 1v1s): %6.1f s",
             seedBattles, Double(seedBattles) / rate1v1Parallel))
let rrBattles = 500 * 499 / 2
print(String(format: "Round robin,   500-team field (%6d 3v3s): %6.1f s",
             rrBattles, Double(rrBattles) / rate3v3Parallel))
let setupFraction = rate1v1Single > 0 ? (rate1v1Single / rateSetupOnly) : 0
print(String(format: "1v1 setup (alloc/init) share of battle time: %.0f%%", setupFraction * 100))
print("checksum \(checksum)")
