//
//  BoundedParallel.swift
//  PokeParty
//
//  Throttled fan-out for the local ranking computation. A plain task group
//  that adds one child per Pokémon lets the cooperative pool run on every
//  core at once, which starves the rest of the system during the startup
//  ranking build. This caps in-flight work at half the available cores.
//

import Foundation

nonisolated enum BoundedParallel {

    /// Half the logical cores (at least 1).
    static let maxWorkers = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)

    /// Runs `work(i)` for each index in `0..<count` with at most `maxWorkers`
    /// in flight, passing each result to `consume` as it completes.
    static func run<T: Sendable>(
        count: Int, of type: T.Type,
        work: @escaping @Sendable (Int) -> T,
        consume: (T) -> Void
    ) async {
        await withTaskGroup(of: T.self) { group in
            var next = 0
            while next < min(maxWorkers, count) {
                let i = next
                group.addTask { work(i) }
                next += 1
            }
            while let result = await group.next() {
                consume(result)
                if next < count {
                    let i = next
                    group.addTask { work(i) }
                    next += 1
                }
            }
        }
    }
}
