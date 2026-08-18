//
//  IVCalculator.swift
//  PokeParty
//
//  Pure stat / IV ranking math, ported from PvPoke's Pokemon.js.
//  Given a base stat line and a CP cap, ranks all IV combinations by stat
//  product — the same computation behind PvPoke's "Rank Checker".
//

import Foundation

/// A set of individual values (0–15 each).
nonisolated struct IVs: Hashable, Codable {
    var atk: Int
    var def: Int
    var hp: Int
}

/// A league/format for IV ranking, identified by its CP cap.
nonisolated enum CheckLeague: Int, CaseIterable, Identifiable {
    case little = 500
    case great = 1500
    case ultra = 2500
    case master = 10000

    var id: Int { rawValue }
    var cap: Int { rawValue }

    /// Short label used in the results grid header.
    var short: String {
        switch self {
        case .little: "LL"
        case .great: "GL"
        case .ultra: "UL"
        case .master: "ML"
        }
    }

    var title: String {
        switch self {
        case .little: "Little"
        case .great: "Great"
        case .ultra: "Ultra"
        case .master: "Master"
        }
    }
}

nonisolated enum IVCalculator {

    /// Combat Power Multipliers indexed by `(level - 1) * 2`, i.e. half-level
    /// steps from level 1 to 54.5. Verbatim from PvPoke's Pokemon.js.
    static let cpms: [Double] = [
        0.0939999967813491, 0.135137430784308, 0.166397869586944, 0.192650914456886,
        0.215732470154762, 0.236572655026622, 0.255720049142837, 0.273530381100769,
        0.290249884128570, 0.306057381335773, 0.321087598800659, 0.335445032295077,
        0.349212676286697, 0.362457748778790, 0.375235587358474, 0.387592411085168,
        0.399567276239395, 0.411193549517250, 0.422500014305114, 0.432926413410414,
        0.443107545375824, 0.453059953871985, 0.462798386812210, 0.472336077786704,
        0.481684952974319, 0.490855810259008, 0.499858438968658, 0.508701756943992,
        0.517393946647644, 0.525942508771329, 0.534354329109191, 0.542635762230353,
        0.550792694091796, 0.558830599438087, 0.566754519939422, 0.574569148039264,
        0.582278907299041, 0.589887911977272, 0.597400009632110, 0.604823657502073,
        0.612157285213470, 0.619404110566050, 0.626567125320434, 0.633649181622743,
        0.640652954578399, 0.647580963301656, 0.654435634613037, 0.661219263506722,
        0.667934000492096, 0.674581899290818, 0.681164920330047, 0.687684905887771,
        0.694143652915954, 0.700542893277978, 0.706884205341339, 0.713169102333341,
        0.719399094581604, 0.725575616972598, 0.731700003147125, 0.734741011137376,
        0.737769484519958, 0.740785574597326, 0.743789434432983, 0.746781208702482,
        0.749761044979095, 0.752729105305821, 0.755685508251190, 0.758630366519684,
        0.761563837528228, 0.764486065255226, 0.767397165298461, 0.770297273971590,
        0.773186504840850, 0.776064945942412, 0.778932750225067, 0.781790064808426,
        0.784636974334716, 0.787473583646825, 0.790300011634826, 0.792803950958807,
        0.795300006866455, 0.797803921486970, 0.800300002098083, 0.802803892322847,
        0.805299997329711, 0.807803863460723, 0.810299992561340, 0.812803834895026,
        0.815299987792968, 0.817803806620319, 0.820299983024597, 0.822803778631297,
        0.825299978256225, 0.827803750922782, 0.830299973487854, 0.832803753381377,
        0.835300028324127, 0.837803755931569, 0.840300023555755, 0.842803729034748,
        0.845300018787384, 0.847803702398935, 0.850300014019012, 0.852803676019539,
        0.855300009250640, 0.857803649892077, 0.860300004482269, 0.862803624012168,
        0.865299999713897,
    ]

    /// The default maximum level (no Best Buddy boost).
    static let defaultLevelCap: Double = 50

    /// A single IV combination realized at its optimal level under a CP cap.
    struct Combo: Hashable {
        let ivs: IVs
        let level: Double
        let cp: Int
        let statProduct: Double
    }

    /// The ranking of one IV combination within a league.
    struct RankResult {
        let rank: Int            // 1-based
        let total: Int           // number of valid combinations
        let percent: Double      // stat product as % of the #1 combination
        let combo: Combo         // the queried combination
        let best: Combo          // the #1 (highest stat product) combination
    }

    // MARK: - CP / stat product

    static func cpm(forLevel level: Double) -> Double? {
        let index = Int((level - 1) * 2)
        guard index >= 0, index < cpms.count else { return nil }
        return cpms[index]
    }

    /// PvPoke's CP formula. Minimum CP is 10.
    static func cp(baseAtk: Int, baseDef: Int, baseHp: Int, ivs: IVs, cpm: Double) -> Int {
        let a = Double(baseAtk + ivs.atk)
        let d = Double(baseDef + ivs.def)
        let h = Double(baseHp + ivs.hp)
        let value = (a * d.squareRoot() * h.squareRoot() * cpm * cpm) / 10
        return max(Int(value.rounded(.down)), 10)
    }

    // MARK: - Optimal stats (fast path)

    /// The IV-optimal effective stats for a base line under a CP cap.
    struct OptimalStats {
        let atk: Double
        let def: Double
        let hp: Int
        let level: Double
        let cp: Int
    }

    /// Finds the single highest-stat-product IV combination under `cpCap` without
    /// allocating or sorting (binary-searches the level for each of the 4096 IV
    /// spreads). Equivalent to `rankedCombos(...).first` but ~10× faster.
    static func optimalStats(
        baseAtk: Int, baseDef: Int, baseHp: Int,
        cpCap: Int, levelCap: Double = defaultLevelCap
    ) -> OptimalStats? {
        let maxJ = Int((levelCap - 1) * 2)            // cpms index for `levelCap`
        guard maxJ >= 0, maxJ < cpms.count else { return nil }

        var bestProduct = -1.0
        var best: OptimalStats?

        for hpIV in 0...15 {
            for defIV in 0...15 {
                for atkIV in 0...15 {
                    let ivs = IVs(atk: atkIV, def: defIV, hp: hpIV)

                    // Largest level index whose CP stays within the cap (CP is
                    // monotonic in level), via binary search.
                    var lo = 0, hi = maxJ, bestJ = -1
                    while lo <= hi {
                        let mid = (lo + hi) / 2
                        if cp(baseAtk: baseAtk, baseDef: baseDef, baseHp: baseHp, ivs: ivs, cpm: cpms[mid]) <= cpCap {
                            bestJ = mid; lo = mid + 1
                        } else {
                            hi = mid - 1
                        }
                    }
                    guard bestJ >= 0 else { continue }

                    let m = cpms[bestJ]
                    let atk = m * Double(baseAtk + atkIV)
                    let def = m * Double(baseDef + defIV)
                    let hp = (m * Double(baseHp + hpIV)).rounded(.down)
                    let product = hp * atk * def
                    if product > bestProduct {
                        bestProduct = product
                        best = OptimalStats(
                            atk: atk, def: def, hp: max(Int(hp), 10),
                            level: 1 + Double(bestJ) * 0.5,
                            cp: cp(baseAtk: baseAtk, baseDef: baseDef, baseHp: baseHp, ivs: ivs, cpm: m)
                        )
                    }
                }
            }
        }
        return best
    }

    /// The highest CP achievable for a specific IV combination under `cpCap`.
    /// Returns nil if the Pokémon exceeds the cap at every level.
    static func maxCP(
        baseAtk: Int, baseDef: Int, baseHp: Int,
        ivs: IVs, cpCap: Int, levelCap: Double = defaultLevelCap
    ) -> Int? {
        let maxJ = Int((levelCap - 1) * 2)
        guard maxJ >= 0, maxJ < cpms.count else { return nil }
        var lo = 0, hi = maxJ, bestJ = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cp(baseAtk: baseAtk, baseDef: baseDef, baseHp: baseHp, ivs: ivs, cpm: cpms[mid]) <= cpCap {
                bestJ = mid; lo = mid + 1
            } else { hi = mid - 1 }
        }
        guard bestJ >= 0 else { return nil }
        return cp(baseAtk: baseAtk, baseDef: baseDef, baseHp: baseHp, ivs: ivs, cpm: cpms[bestJ])
    }

    /// The level (in 0.5 steps) whose CP for `ivs` is closest to `targetCP`.
    /// CP increases monotonically with level for fixed IVs, so this is a
    /// straightforward closest-match scan. Used to let a user-entered CP
    /// imply a level for a chosen IV spread — a quick sanity check that the
    /// spread is plausible (e.g. does the implied level roughly match what
    /// was read off the Pokémon's actual level on screen).
    static func level(
        baseAtk: Int, baseDef: Int, baseHp: Int,
        ivs: IVs, targetCP: Int, levelCap: Double = defaultLevelCap
    ) -> Double? {
        let maxJ = Int((levelCap - 1) * 2)
        guard maxJ >= 0, maxJ < cpms.count else { return nil }
        var bestJ = 0
        var bestDiff = Int.max
        for j in 0...maxJ {
            let diff = abs(cp(baseAtk: baseAtk, baseDef: baseDef, baseHp: baseHp, ivs: ivs, cpm: cpms[j]) - targetCP)
            if diff < bestDiff {
                bestDiff = diff
                bestJ = j
            }
        }
        return 1 + Double(bestJ) * 0.5
    }

    /// The effective battle stats for a specific IV combination at the highest
    /// legal level under `cpCap`. Returns nil if the Pokémon exceeds the cap at
    /// every level (e.g. a high-IV Mewtwo in Great League).
    static func stats(
        baseAtk: Int, baseDef: Int, baseHp: Int,
        ivs: IVs, cpCap: Int, levelCap: Double = defaultLevelCap
    ) -> (atk: Double, def: Double, hp: Int, level: Double)? {
        let maxJ = Int((levelCap - 1) * 2)
        guard maxJ >= 0, maxJ < cpms.count else { return nil }

        var lo = 0, hi = maxJ, bestJ = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cp(baseAtk: baseAtk, baseDef: baseDef, baseHp: baseHp, ivs: ivs, cpm: cpms[mid]) <= cpCap {
                bestJ = mid; lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard bestJ >= 0 else { return nil }

        let m = cpms[bestJ]
        return (
            atk: m * Double(baseAtk + ivs.atk),
            def: m * Double(baseDef + ivs.def),
            hp: max(Int((m * Double(baseHp + ivs.hp)).rounded(.down)), 10),
            level: 1 + Double(bestJ) * 0.5
        )
    }

    // MARK: - Ranking

    /// Every valid IV combination for a base stat line under `cpCap`, each
    /// raised to the highest level that stays within the cap, sorted by stat
    /// product (best first).
    static func rankedCombos(
        baseAtk: Int,
        baseDef: Int,
        baseHp: Int,
        cpCap: Int,
        floor: Int = 0,
        levelCap: Double = defaultLevelCap
    ) -> [Combo] {
        var combos: [Combo] = []
        combos.reserveCapacity(16 * 16 * 16)

        var hpIV = 15
        while hpIV >= floor {
            var defIV = 15
            while defIV >= floor {
                var atkIV = 15
                while atkIV >= floor {
                    let ivs = IVs(atk: atkIV, def: defIV, hp: hpIV)

                    // Climb levels until adding more would exceed the cap.
                    var level: Double = cpCap > 500 ? 1.0 : 0.5
                    var calcCP = 0
                    while level < levelCap, calcCP < cpCap {
                        level += 0.5
                        if let m = cpm(forLevel: level) {
                            calcCP = cp(baseAtk: baseAtk, baseDef: baseDef, baseHp: baseHp, ivs: ivs, cpm: m)
                        }
                    }
                    if calcCP > cpCap {
                        level -= 0.5
                    }

                    if let m = cpm(forLevel: level) {
                        let finalCP = cp(baseAtk: baseAtk, baseDef: baseDef, baseHp: baseHp, ivs: ivs, cpm: m)
                        if finalCP <= cpCap {
                            let atk = m * Double(baseAtk + atkIV)
                            let def = m * Double(baseDef + defIV)
                            let hp = (m * Double(baseHp + hpIV)).rounded(.down)
                            combos.append(Combo(
                                ivs: ivs,
                                level: level,
                                cp: finalCP,
                                statProduct: hp * atk * def
                            ))
                        }
                    }

                    atkIV -= 1
                }
                defIV -= 1
            }
            hpIV -= 1
        }

        combos.sort { $0.statProduct > $1.statProduct }
        return combos
    }

    /// Rank a specific IV combination within a league. Returns `nil` if the
    /// combination can't legally exist under the cap (e.g. too strong for Little League).
    static func rank(
        baseAtk: Int,
        baseDef: Int,
        baseHp: Int,
        cpCap: Int,
        ivs: IVs,
        levelCap: Double = defaultLevelCap
    ) -> RankResult? {
        let combos = rankedCombos(baseAtk: baseAtk, baseDef: baseDef, baseHp: baseHp, cpCap: cpCap, levelCap: levelCap)
        guard let best = combos.first,
              let index = combos.firstIndex(where: { $0.ivs == ivs }) else {
            return nil
        }
        let combo = combos[index]
        return RankResult(
            rank: index + 1,
            total: combos.count,
            percent: combo.statProduct / best.statProduct * 100,
            combo: combo,
            best: best
        )
    }
}
