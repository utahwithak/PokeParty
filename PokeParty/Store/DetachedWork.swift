//
//  DetachedWork.swift
//  PokeParty
//
//  `Task.detached` doesn't inherit its parent's cancellation, so awaiting
//  `Task.detached { … }.value` from a cancelled task leaves the detached work
//  running to completion — and every `Task.isCancelled` check inside the
//  engine (Ranker, MidGameCoach, BattleReviewer…) never fires. This forwards
//  cancellation to the detached task.
//

import Foundation

/// Runs `work` off the caller's actor (like `Task.detached`) and returns its
/// result, cancelling the detached task if the calling task is cancelled.
nonisolated func runDetached<T: Sendable>(
    priority: TaskPriority? = nil,
    _ work: @escaping @concurrent @Sendable () async -> T
) async -> T {
    let task = Task<T, Never>.detached(priority: priority, operation: work)
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}
