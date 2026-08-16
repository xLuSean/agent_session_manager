import CryptoKit
import Foundation

public enum PersistentArchiveBatchStatus: String, Codable, Hashable, Sendable {
    case prepared
    case executing
    case consumed
    case cancelled
}

public struct PersistentArchiveBatchItemIdentity: Codable, Hashable, Sendable {
    public let managerKey: String
    public let nativeSessionID: String
}

public struct PersistentArchiveBatchUnit: Codable, Hashable, Sendable {
    public let ordinal: Int
    public let previewID: UUID
    public let selectedRootManagerKey: String
    public let selectedRootNativeSessionID: String
    public let affectedSetHash: String
    public let items: [PersistentArchiveBatchItemIdentity]
}

public struct PersistentArchiveBatchPlan: Codable, Hashable, Sendable {
    public let id: UUID
    public let provider: AgentSystem
    public let status: PersistentArchiveBatchStatus
    public let providerInventoryHash: String
    public let confirmationTokenHash: String
    public let manifestHash: String
    public let createdAt: Date
    public let expiresAt: Date
    public let units: [PersistentArchiveBatchUnit]

    public var itemCount: Int { units.reduce(0) { $0 + $1.items.count } }
}

public struct PersistentArchiveBatchReport: Codable, Hashable, Sendable {
    public let id: UUID
    public let batchID: UUID
    public let startedAt: Date
    public let completedAt: Date
    public let errorCode: String?
    public let errorMessage: String?
    public let finalization: ArchiveBatchFinalization

    public init(
        id: UUID,
        batchID: UUID,
        startedAt: Date,
        completedAt: Date,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        finalization: ArchiveBatchFinalization
    ) {
        self.id = id
        self.batchID = batchID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.finalization = finalization
    }
}

public enum ArchiveBatchPersistenceFactory {
    public static func makePreparedPlan(
        id: UUID,
        previews: [PersistentOperationPreview],
        confirmationToken: String,
        createdAt: Date,
        expiresAt: Date
    ) throws -> PersistentArchiveBatchPlan {
        guard !previews.isEmpty else {
            throw PersistentStateError.invalidRecord("Archive batch Preview set is empty.")
        }
        let inventoryHashes = Set(previews.map(\.providerInventoryHash))
        guard inventoryHashes.count == 1, let inventoryHash = inventoryHashes.first else {
            throw PersistentStateError.invalidRecord(
                "Archive batch Previews must share one frozen provider checkpoint."
            )
        }

        let tokenHash = ArchiveExecutionHasher.confirmationTokenHash(confirmationToken)
        var units: [PersistentArchiveBatchUnit] = []
        var previewIDs: Set<UUID> = []
        var managerKeys: Set<String> = []
        for preview in previews {
            guard preview.provider == .codex,
                  preview.operation == .archive,
                  preview.status == .prepared,
                  preview.confirmationTokenHash == tokenHash,
                  previewIDs.insert(preview.id).inserted,
                  let affectedSetHash = preview.affectedSetHash,
                  !affectedSetHash.isEmpty else {
                throw PersistentStateError.invalidRecord(
                    "Archive batch requires unique prepared Codex affected-set Previews."
                )
            }
            let roots = preview.items.filter { $0.archiveAffectedRole == .selectedRoot }
            guard roots.count == 1 else {
                throw PersistentStateError.invalidRecord(
                    "Archive batch unit requires exactly one selected root."
                )
            }
            for item in preview.items where !managerKeys.insert(item.managerKey).inserted {
                throw PersistentStateError.duplicateManagerKey(item.managerKey)
            }
            let root = roots[0]
            units.append(PersistentArchiveBatchUnit(
                ordinal: 0,
                previewID: preview.id,
                selectedRootManagerKey: root.managerKey,
                selectedRootNativeSessionID: root.nativeSessionID,
                affectedSetHash: affectedSetHash,
                items: preview.items.map {
                    PersistentArchiveBatchItemIdentity(
                        managerKey: $0.managerKey,
                        nativeSessionID: $0.nativeSessionID
                    )
                }
            ))
        }
        units.sort { $0.selectedRootManagerKey < $1.selectedRootManagerKey }
        units = units.enumerated().map { index, unit in
            PersistentArchiveBatchUnit(
                ordinal: index,
                previewID: unit.previewID,
                selectedRootManagerKey: unit.selectedRootManagerKey,
                selectedRootNativeSessionID: unit.selectedRootNativeSessionID,
                affectedSetHash: unit.affectedSetHash,
                items: unit.items
            )
        }

        let manifestHash = try ArchiveBatchPersistenceHasher.manifestHash(
            id: id,
            provider: .codex,
            providerInventoryHash: inventoryHash,
            confirmationTokenHash: tokenHash,
            createdAt: createdAt,
            expiresAt: expiresAt,
            units: units
        )
        return PersistentArchiveBatchPlan(
            id: id,
            provider: .codex,
            status: .prepared,
            providerInventoryHash: inventoryHash,
            confirmationTokenHash: tokenHash,
            manifestHash: manifestHash,
            createdAt: createdAt,
            expiresAt: expiresAt,
            units: units
        )
    }
}

enum ArchiveBatchPersistenceHasher {
    static func manifestHash(
        id: UUID,
        provider: AgentSystem,
        providerInventoryHash: String,
        confirmationTokenHash: String,
        createdAt: Date,
        expiresAt: Date,
        units: [PersistentArchiveBatchUnit]
    ) throws -> String {
        let payload = Payload(
            id: id,
            provider: provider,
            providerInventoryHash: providerInventoryHash,
            confirmationTokenHash: confirmationTokenHash,
            createdAt: createdAt,
            expiresAt: expiresAt,
            units: units
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let digest = SHA256.hash(data: try encoder.encode(payload))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private struct Payload: Encodable {
        let id: UUID
        let provider: AgentSystem
        let providerInventoryHash: String
        let confirmationTokenHash: String
        let createdAt: Date
        let expiresAt: Date
        let units: [PersistentArchiveBatchUnit]
    }
}
