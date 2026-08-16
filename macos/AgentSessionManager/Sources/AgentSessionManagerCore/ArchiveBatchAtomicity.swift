import Foundation

/// A provider request may archive one selected root and its complete affected
/// set. Multiple roots are separate execution units because Codex currently
/// exposes no transaction that can atomically archive all of them together.
public struct ArchiveBatchExecutionUnit: Codable, Hashable, Sendable {
    public let selectedRootManagerKey: String
    public let selectedRootNativeSessionID: String
    public let affectedItems: [ArchiveAffectedItem]

    public var affectedManagerKeys: [String] {
        affectedItems.map(\.managerKey)
    }
}

public struct ArchiveBatchExecutionPlan: Codable, Hashable, Sendable {
    public let units: [ArchiveBatchExecutionUnit]
    public let providerAtomicity: ArchiveBatchProviderAtomicity

    /// The only safe policy for a provider without a native batch transaction:
    /// validate every unit against one frozen checkpoint before the first
    /// request, then execute deterministically and stop after failure/unknown.
    public let requiresAllUnitsPreflightBeforeFirstRequest: Bool
    public let stopsAfterFirstNonSuccess: Bool

    public var affectedItemCount: Int {
        units.reduce(0) { $0 + $1.affectedItems.count }
    }
}

public enum ArchiveBatchProviderAtomicity: String, Codable, Hashable, Sendable {
    /// Each selected root is a separate provider request. Earlier successes
    /// cannot be rolled back if a later unit fails or becomes unknown.
    case perRootSequential = "per_root_sequential"
}

public enum ArchiveBatchAtomicityError: Error, Equatable, LocalizedError {
    case emptyBatch
    case invalidAffectedSet(String)
    case overlappingAffectedItem(String)
    case unexpectedAttempt(expectedRoot: String, foundRoot: String)
    case executionStoppedWithoutTerminalOutcome
    case attemptAfterTerminalOutcome(String)

    public var errorDescription: String? {
        switch self {
        case .emptyBatch:
            "Archive batch must contain at least one complete affected set."
        case let .invalidAffectedSet(message):
            "Invalid Archive batch affected set: \(message)"
        case let .overlappingAffectedItem(managerKey):
            "Archive batch affected sets overlap at \(managerKey)."
        case let .unexpectedAttempt(expectedRoot, foundRoot):
            "Archive batch attempt order changed: expected \(expectedRoot), found \(foundRoot)."
        case .executionStoppedWithoutTerminalOutcome:
            "Archive batch stopped after a successful unit without a failure or unknown outcome."
        case let .attemptAfterTerminalOutcome(root):
            "Archive batch attempted \(root) after a failure or unknown outcome."
        }
    }
}

public enum ArchiveBatchAttemptOutcome: String, Codable, Hashable, Sendable {
    case success
    case failure
    case partial
    case unknown
}

public enum ArchiveBatchAttemptItemOutcome: String, Codable, Hashable, Sendable {
    case success
    case failure
    case unknown
}

public struct ArchiveBatchAttemptItem: Codable, Hashable, Sendable {
    public let managerKey: String
    public let outcome: ArchiveBatchAttemptItemOutcome
    public let observedNativeState: NativeSessionState
    public let errorCode: String?
    public let message: String?
    public let evidenceAt: Date

    public init(
        managerKey: String,
        outcome: ArchiveBatchAttemptItemOutcome,
        observedNativeState: NativeSessionState,
        errorCode: String? = nil,
        message: String? = nil,
        evidenceAt: Date
    ) {
        self.managerKey = managerKey
        self.outcome = outcome
        self.observedNativeState = observedNativeState
        self.errorCode = errorCode
        self.message = message
        self.evidenceAt = evidenceAt
    }
}

public struct ArchiveBatchAttempt: Codable, Hashable, Sendable {
    public let selectedRootManagerKey: String
    public let outcome: ArchiveBatchAttemptOutcome
    public let errorCode: String?
    public let message: String?
    public let items: [ArchiveBatchAttemptItem]

    public init(
        selectedRootManagerKey: String,
        outcome: ArchiveBatchAttemptOutcome,
        errorCode: String? = nil,
        message: String? = nil,
        items: [ArchiveBatchAttemptItem]
    ) {
        self.selectedRootManagerKey = selectedRootManagerKey
        self.outcome = outcome
        self.errorCode = errorCode
        self.message = message
        self.items = items
    }
}

public enum ArchiveBatchUnitDisposition: String, Codable, Hashable, Sendable {
    case success
    case failure
    case partial
    case unknown
    case notAttempted = "not_attempted"
}

public struct ArchiveBatchFinalizedUnit: Codable, Hashable, Sendable {
    public let selectedRootManagerKey: String
    public let affectedManagerKeys: [String]
    public let disposition: ArchiveBatchUnitDisposition
    public let errorCode: String?
    public let message: String?
    public let items: [ArchiveBatchFinalizedItem]
}

public struct ArchiveBatchFinalizedItem: Codable, Hashable, Sendable {
    public let managerKey: String
    public let disposition: ArchiveBatchUnitDisposition
    public let observedNativeState: NativeSessionState
    public let errorCode: String?
    public let message: String?
    public let evidenceAt: Date?
}

public struct ArchiveBatchFinalization: Codable, Hashable, Sendable {
    public let outcome: PersistentReportOutcome
    public let units: [ArchiveBatchFinalizedUnit]

    public var attemptedUnitCount: Int {
        units.filter { $0.disposition != .notAttempted }.count
    }

    public var notAttemptedUnitCount: Int {
        units.filter { $0.disposition == .notAttempted }.count
    }
}

/// Pure policy only. This type owns no lifecycle transport and cannot archive.
public enum ArchiveBatchAtomicityPolicy {
    public static func plan(
        affectedSets: [ArchiveAffectedSet]
    ) throws -> ArchiveBatchExecutionPlan {
        guard !affectedSets.isEmpty else { throw ArchiveBatchAtomicityError.emptyBatch }

        var allManagerKeys: Set<String> = []
        var units: [ArchiveBatchExecutionUnit] = []
        for affectedSet in affectedSets {
            let rootItems = affectedSet.items.filter { $0.role == .selectedRoot }
            guard rootItems.count == 1,
                  let root = rootItems.first,
                  root.nativeSessionID == affectedSet.selectedRootNativeSessionID,
                  root.depth == 0,
                  root.parentNativeSessionID == nil,
                  !affectedSet.items.isEmpty else {
                throw ArchiveBatchAtomicityError.invalidAffectedSet(
                    "the selected root identity or structure is incomplete"
                )
            }

            let itemIDs = Set(affectedSet.items.map(\.nativeSessionID))
            var itemsByID: [String: ArchiveAffectedItem] = [:]
            for item in affectedSet.items {
                guard itemsByID.updateValue(item, forKey: item.nativeSessionID) == nil else {
                    throw ArchiveBatchAtomicityError.invalidAffectedSet(
                        "native identity is duplicated"
                    )
                }
            }
            var localManagerKeys: Set<String> = []
            for item in affectedSet.items {
                guard item.managerKey == "\(AgentSystem.codex.rawValue):\(item.nativeSessionID)",
                      localManagerKeys.insert(item.managerKey).inserted else {
                    throw ArchiveBatchAtomicityError.invalidAffectedSet(
                        "manager identity is invalid or duplicated"
                    )
                }
                if item.role == .descendant {
                    guard item.depth > 0,
                          let parentID = item.parentNativeSessionID,
                          itemIDs.contains(parentID),
                          let parent = itemsByID[parentID],
                          parent.depth == item.depth - 1 else {
                        throw ArchiveBatchAtomicityError.invalidAffectedSet(
                            "a descendant has no depth-consistent parent inside its affected set"
                        )
                    }
                } else if item.nativeSessionID != root.nativeSessionID {
                    throw ArchiveBatchAtomicityError.invalidAffectedSet(
                        "an affected set contains more than one selected root"
                    )
                }
                guard allManagerKeys.insert(item.managerKey).inserted else {
                    throw ArchiveBatchAtomicityError.overlappingAffectedItem(item.managerKey)
                }
            }

            units.append(ArchiveBatchExecutionUnit(
                selectedRootManagerKey: root.managerKey,
                selectedRootNativeSessionID: root.nativeSessionID,
                affectedItems: affectedSet.items
            ))
        }

        units.sort { $0.selectedRootManagerKey < $1.selectedRootManagerKey }
        return ArchiveBatchExecutionPlan(
            units: units,
            providerAtomicity: .perRootSequential,
            requiresAllUnitsPreflightBeforeFirstRequest: true,
            stopsAfterFirstNonSuccess: true
        )
    }

    /// Finalizes an execution prefix. A failure/unknown is terminal and all
    /// remaining frozen units are explicitly `notAttempted`; they are never
    /// mislabeled as provider failures and are never silently omitted.
    public static func finalize(
        plan: ArchiveBatchExecutionPlan,
        attempts: [ArchiveBatchAttempt]
    ) throws -> ArchiveBatchFinalization {
        guard !attempts.isEmpty else {
            throw ArchiveBatchAtomicityError.executionStoppedWithoutTerminalOutcome
        }
        guard attempts.count <= plan.units.count else {
            let found = attempts[plan.units.count].selectedRootManagerKey
            throw ArchiveBatchAtomicityError.attemptAfterTerminalOutcome(found)
        }

        var terminalIndex: Int?
        for (index, attempt) in attempts.enumerated() {
            let expected = plan.units[index].selectedRootManagerKey
            guard attempt.selectedRootManagerKey == expected else {
                throw ArchiveBatchAtomicityError.unexpectedAttempt(
                    expectedRoot: expected,
                    foundRoot: attempt.selectedRootManagerKey
                )
            }
            if terminalIndex != nil {
                throw ArchiveBatchAtomicityError.attemptAfterTerminalOutcome(
                    attempt.selectedRootManagerKey
                )
            }
            if attempt.outcome != .success {
                terminalIndex = index
            }
            try validate(attempt: attempt, for: plan.units[index])
        }

        if attempts.count < plan.units.count, terminalIndex == nil {
            throw ArchiveBatchAtomicityError.executionStoppedWithoutTerminalOutcome
        }

        let attemptedByRoot = Dictionary(uniqueKeysWithValues: attempts.map {
            ($0.selectedRootManagerKey, $0)
        })
        let units = plan.units.map { unit -> ArchiveBatchFinalizedUnit in
            guard let attempt = attemptedByRoot[unit.selectedRootManagerKey] else {
                return ArchiveBatchFinalizedUnit(
                    selectedRootManagerKey: unit.selectedRootManagerKey,
                    affectedManagerKeys: unit.affectedManagerKeys,
                    disposition: .notAttempted,
                    errorCode: "batch_stopped_before_attempt",
                    message: "Not attempted because an earlier execution unit failed or became unknown.",
                    items: unit.affectedManagerKeys.map {
                        ArchiveBatchFinalizedItem(
                            managerKey: $0,
                            disposition: .notAttempted,
                            observedNativeState: .unavailable,
                            errorCode: "batch_stopped_before_attempt",
                            message: "No provider request or readback was attempted for this frozen item.",
                            evidenceAt: nil
                        )
                    }
                )
            }
            let attemptItems = Dictionary(uniqueKeysWithValues: attempt.items.map {
                ($0.managerKey, $0)
            })
            return ArchiveBatchFinalizedUnit(
                selectedRootManagerKey: unit.selectedRootManagerKey,
                affectedManagerKeys: unit.affectedManagerKeys,
                disposition: disposition(for: attempt.outcome),
                errorCode: attempt.errorCode,
                message: attempt.message,
                items: unit.affectedManagerKeys.compactMap { managerKey in
                    guard let item = attemptItems[managerKey] else { return nil }
                    return ArchiveBatchFinalizedItem(
                        managerKey: item.managerKey,
                        disposition: disposition(for: item.outcome),
                        observedNativeState: item.observedNativeState,
                        errorCode: item.errorCode,
                        message: item.message,
                        evidenceAt: item.evidenceAt
                    )
                }
            )
        }

        let outcome: PersistentReportOutcome
        if attempts.contains(where: { $0.outcome == .unknown }) {
            outcome = .unknown
        } else if attempts.allSatisfy({ $0.outcome == .success })
                    && attempts.count == plan.units.count {
            outcome = .success
        } else if attempts.first?.outcome == .failure {
            outcome = .failure
        } else {
            outcome = .partial
        }
        return ArchiveBatchFinalization(outcome: outcome, units: units)
    }

    /// All-unit preflight failure happens before any provider request. Every
    /// unit remains known-not-attempted rather than unknown.
    public static func preflightRejected(
        plan: ArchiveBatchExecutionPlan,
        errorCode: String,
        message: String
    ) -> ArchiveBatchFinalization {
        ArchiveBatchFinalization(
            outcome: .failure,
            units: plan.units.map { unit in
                ArchiveBatchFinalizedUnit(
                    selectedRootManagerKey: unit.selectedRootManagerKey,
                    affectedManagerKeys: unit.affectedManagerKeys,
                    disposition: .notAttempted,
                    errorCode: errorCode,
                    message: message,
                    items: unit.affectedManagerKeys.map {
                        ArchiveBatchFinalizedItem(
                            managerKey: $0,
                            disposition: .notAttempted,
                            observedNativeState: .unavailable,
                            errorCode: errorCode,
                            message: message,
                            evidenceAt: nil
                        )
                    }
                )
            }
        )
    }

    private static func disposition(
        for outcome: ArchiveBatchAttemptOutcome
    ) -> ArchiveBatchUnitDisposition {
        switch outcome {
        case .success: .success
        case .failure: .failure
        case .partial: .partial
        case .unknown: .unknown
        }
    }

    private static func disposition(
        for outcome: ArchiveBatchAttemptItemOutcome
    ) -> ArchiveBatchUnitDisposition {
        switch outcome {
        case .success: .success
        case .failure: .failure
        case .unknown: .unknown
        }
    }

    private static func validate(
        attempt: ArchiveBatchAttempt,
        for unit: ArchiveBatchExecutionUnit
    ) throws {
        guard attempt.items.count == unit.affectedItems.count else {
            throw ArchiveBatchAtomicityError.invalidAffectedSet(
                "attempt readback does not cover every frozen affected item"
            )
        }
        let expectedKeys = Set(unit.affectedManagerKeys)
        let itemKeys = attempt.items.map(\.managerKey)
        guard Set(itemKeys) == expectedKeys, Set(itemKeys).count == itemKeys.count else {
            throw ArchiveBatchAtomicityError.invalidAffectedSet(
                "attempt readback item identities do not match the frozen affected set"
            )
        }

        let itemOutcomes = attempt.items.map(\.outcome)
        let expectedOutcome: ArchiveBatchAttemptOutcome
        if itemOutcomes.contains(.unknown) {
            expectedOutcome = .unknown
        } else if itemOutcomes.allSatisfy({ $0 == .success }) {
            expectedOutcome = .success
        } else if itemOutcomes.allSatisfy({ $0 == .failure }) {
            expectedOutcome = .failure
        } else {
            expectedOutcome = .partial
        }
        guard attempt.outcome == expectedOutcome else {
            throw ArchiveBatchAtomicityError.invalidAffectedSet(
                "unit outcome does not match its itemized readback outcomes"
            )
        }
    }
}
