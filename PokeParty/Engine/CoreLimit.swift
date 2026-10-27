//
//  CoreLimit.swift
//  PokeParty
//
//  User-adjustable cap on how many cores a team search may occupy. The finders
//  fan out into task groups that would otherwise spread across every core and
//  starve the rest of the system. Running a search under
//  `withTaskExecutorPreference(CoreLimit.executor)` makes every child task run
//  on a width-limited queue instead of the shared cooperative pool.
//

import Foundation

nonisolated final class CoreLimitedExecutor: TaskExecutor, @unchecked Sendable {
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "PokeParty.CoreLimitedExecutor"
        // Utility QoS keeps a long background search from competing with the UI.
        q.qualityOfService = .utility
        return q
    }()

    init(workers: Int) { queue.maxConcurrentOperationCount = max(1, workers) }

    /// Takes effect for jobs not yet started, so the slider works mid-run.
    var workers: Int {
        get { queue.maxConcurrentOperationCount }
        set { queue.maxConcurrentOperationCount = max(1, newValue) }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.addOperation { [self] in
            unowned.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}

nonisolated enum CoreLimit {
    static let totalCores = max(1, ProcessInfo.processInfo.activeProcessorCount)
    static let defaultWorkers = max(1, totalCores / 2)
    static let executor = CoreLimitedExecutor(workers: defaultWorkers)
}
