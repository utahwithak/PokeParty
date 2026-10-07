//
//  MetaPool.swift
//  PokeParty
//
//  The locally-computed "which Pokémon are eligible for this cup" pool —
//  PvPoke's `generateFilteredPokemonList` (`GameMaster.js`), ported so the
//  local Ranker doesn't need to walk PvPoke's downloaded rankings list to
//  know which species exist in a format. See docs/TeamBuilder-Plan.md §2.7.
//

import Foundation

nonisolated enum MetaPool {

    /// The minimum IV-optimal stat product (`hp·atk·def/1000`) a species must
    /// clear to be considered for a league, before any cup-specific filters.
    /// Verbatim from PvPoke's `generateFilteredPokemonList`.
    private static func minStatProduct(cpCap: Int) -> Double {
        switch cpCap {
        case 500: return 0
        case 1500: return 1370
        case 2500: return 2800
        default: return 4900
        }
    }

    /// Every Pokémon eligible for `cup` at `cpCap`, released and not banned,
    /// meeting the minimum stat-product floor (or one of its overrides) and
    /// passing the cup's `include`/`exclude` filters.
    ///
    /// Not ported: `restrictedPokemon`/`tierRules` (point-drafted cups like
    /// Battle Frontier Master — rare, degrades to plain include/exclude for
    /// those) and the Little Cup shadow-minimum-level exclusion (needs a
    /// per-instance level floor this app doesn't track). Both are documented
    /// gaps, not silent guesses.
    static func eligiblePokemon(
        for cup: Cup, cpCap: Int, allPokemon: [Pokemon], greatLeagueIneligible: [String]
    ) -> [Pokemon] {
        let minStats = minStatProduct(cpCap: cpCap)
        let bannedList = Set(greatLeagueIneligible)

        return allPokemon.filter { pokemon in
            guard pokemon.released != false else { return false }

            let stats = statProduct(for: pokemon, cpCap: cpCap)
            let clearsFloor = stats >= minStats
                || cup.includeLowStatProduct == true
                || (cpCap == 1500 && pokemon.hasTag("include1500"))
                || (cpCap == 2500 && pokemon.hasTag("include2500"))
                || (cpCap == 10000 && pokemon.hasTag("include10000"))
                || pokemon.hasTag("mega")
            guard clearsFloor else { return false }

            if cpCap < 2500, bannedList.contains(pokemon.speciesId) { return false }

            // A "duplicate1500" entry (an alternate form) is only meaningful
            // in Great League core/retro/halloween cups.
            if pokemon.hasTag("duplicate1500"),
               !(cpCap == 1500 && ["all", "retro", "halloween"].contains(cup.name)) {
                return false
            }

            return matchesFilters(pokemon, cup: cup, cpCap: cpCap)
        }
    }

    /// IV-optimal `hp·atk·def/1000`, shadow atk/def multipliers applied
    /// (shadow and non-shadow gamemaster entries share raw base stats — the
    /// multiplier only shows up here, matching how PvPoke's own `Pokemon`
    /// class applies it before computing eligibility). Shared with
    /// `MovesetSelector.probeSet`, which also needs a shadow-aware ranking
    /// of raw species strength.
    static func statProduct(for pokemon: Pokemon, cpCap: Int) -> Double {
        guard let s = IVCalculator.optimalStats(
            baseAtk: pokemon.baseStats.atk, baseDef: pokemon.baseStats.def, baseHp: pokemon.baseStats.hp,
            cpCap: cpCap
        ) else { return 0 }
        let atk = s.atk * (pokemon.isShadow ? DamageMultiplier.shadowAtk : 1)
        let def = s.def * (pokemon.isShadow ? DamageMultiplier.shadowDef : 1)
        return (Double(s.hp) * atk * def) / 1000
    }

    /// PvPoke's filter-matching algorithm: each of `include`/`exclude` is
    /// scored by summing how many of its filters a Pokémon matches, weighed
    /// against a per-list "required" count. An `id` filter match short-
    /// circuits (matches everything in its own list at once) and, on the
    /// include side, marks `includeIDFilter` so the exclude pass can't
    /// override an explicit inclusion.
    private static func matchesFilters(_ pokemon: Pokemon, cup: Cup, cpCap: Int) -> Bool {
        var allowed = false
        var includeIDFilter = false

        for (isInclude, filters) in [(true, cup.include), (false, cup.exclude)] {
            var filtersMatched = 0
            var requiredFilters = filters.count

            for filter in filters {
                if let leagues = filter.leagues, !leagues.contains(cpCap) {
                    requiredFilters -= 1
                    continue
                }

                switch filter.filterType {
                case "type":
                    if pokemon.types.contains(where: { filter.values.contains(.string($0)) }) {
                        filtersMatched += 1
                    }

                case "tag":
                    for value in filter.values where pokemon.hasTag(value.stringValue) {
                        filtersMatched += 1
                    }

                case "evolution":
                    if filter.values.contains(where: { $0.intValue == pokemon.evolutionStage }) {
                        filtersMatched += 1
                    }

                case "id":
                    if isInclude, filters.count > 1 { requiredFilters -= 1 }
                    var testId = pokemon.speciesId
                    if !isInclude || filter.includeShadows == true {
                        testId = testId.replacingOccurrences(of: "_shadow", with: "")
                            .replacingOccurrences(of: "_xs", with: "")
                    }
                    if filter.values.contains(where: { $0.stringValue == testId || $0.stringValue == pokemon.speciesId }) {
                        filtersMatched += filters.count
                        if isInclude { includeIDFilter = true }
                    }

                default:
                    // "dex"/"cost"/"distance"/"move"/"moveType" — not used by
                    // any cup in the bundled gamemaster today; no-op rather
                    // than silently mis-scoring an unrecognized filter.
                    break
                }
            }

            if isInclude, filtersMatched >= requiredFilters { allowed = true }
            if !isInclude, filtersMatched > 0, !includeIDFilter { allowed = false }
        }

        return allowed
    }
}
