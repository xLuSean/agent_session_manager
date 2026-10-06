import Foundation

/// Supplements the list's fork relationships without replacing its identity,
/// lifecycle state, pin observations, or subagent graph. No missing/failed read
/// can be interpreted as proof that a conversation has no forks.
enum CodexForkHistoryInventory {
    static func hydrate(
        records: [CodexThreadRecord],
        maximumReads: Int = 20_000,
        deadline: Date,
        now: () -> Date = Date.init,
        read: (String) throws -> CodexThreadRecord
    ) -> [CodexThreadRecord] {
        var reads = 0
        return records.map { listed in
            var result = listed
            result.forkHistoryReadComplete = false
            guard reads < maximumReads, now() < deadline, !Task.isCancelled else { return result }
            reads += 1
            guard let exact = try? read(listed.id), exact.id == listed.id,
                  exact.sessionId == listed.sessionId, !exact.ephemeral,
                  exact.forkHistoryReadComplete,
                  listed.forkedFromId == nil || listed.forkedFromId == exact.forkedFromId else { return result }
            result.forkedFromId = exact.forkedFromId
            result.forkHistoryReadComplete = true
            return result
        }
    }
}
