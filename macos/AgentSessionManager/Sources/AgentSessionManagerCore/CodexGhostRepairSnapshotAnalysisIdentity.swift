import Foundation

public struct CodexGhostRepairSnapshotAnalysisRequest: Equatable, Sendable {
    public let snapshotReference: String

    public init(snapshotReference: String) {
        self.snapshotReference = snapshotReference
    }

    public var acceptsCallerPath: Bool { false }
    public var rawDatabaseReadAuthority: Bool { false }
    public var repairPreviewAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public struct CodexGhostRepairSnapshotAnalysisIdentity:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let snapshotReference: String
    public let targetThreadIDs: [String]
    public let preparedAtMilliseconds: Int64
    public let publishedAtMilliseconds: Int64
    public let sourceFingerprintHash: String
    public let destinationBindingHash: String
    public let acquisitionRecordHash: String
    public let manifestHash: String
    public let publicationReceiptHash: String
    public let observedRegularFileCount: Int
    public let actualPublishedBytes: UInt64

    public var pathRedacted: Bool { true }
    public var rawDatabaseContentsOpened: Int { 0 }
    public var writesFilesystem: Bool { false }
    public var persistsRepairPreview: Bool { false }
    public var repairPreviewAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    init(
        snapshotID: UUID,
        targetThreadIDs: [String],
        preparedAtMilliseconds: Int64,
        publishedAtMilliseconds: Int64,
        sourceFingerprintHash: String,
        destinationBindingHash: String,
        acquisitionRecordHash: String,
        manifestHash: String,
        publicationReceiptHash: String,
        observedRegularFileCount: Int,
        actualPublishedBytes: UInt64
    ) throws {
        let requiredFileCount =
            CodexGhostRepairSnapshotCanonicalFile.allCases
                .filter(\.isRequiredDatabase).count + 2
        // Snapshot publication and the one-click bulk preparation flow both
        // admit up to ten bounded witness IDs. The identity readback must
        // preserve that same bound or a valid ten-witness Snapshot becomes
        // unreadable immediately after it is published.
        guard (1...10).contains(targetThreadIDs.count),
              targetThreadIDs == targetThreadIDs.sorted(),
              Set(targetThreadIDs).count == targetThreadIDs.count,
              targetThreadIDs.allSatisfy(Self.isCanonicalUUID),
              preparedAtMilliseconds >= 0,
              publishedAtMilliseconds >= preparedAtMilliseconds,
              Self.isSHA256(sourceFingerprintHash),
              Self.isSHA256(destinationBindingHash),
              Self.isSHA256(acquisitionRecordHash),
              Self.isSHA256(manifestHash),
              Self.isSHA256(publicationReceiptHash),
              observedRegularFileCount >= requiredFileCount,
              actualPublishedBytes > 0 else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Published snapshot analysis identity is invalid."
            )
        }
        snapshotReference = snapshotID.uuidString.lowercased()
        self.targetThreadIDs = targetThreadIDs
        self.preparedAtMilliseconds = preparedAtMilliseconds
        self.publishedAtMilliseconds = publishedAtMilliseconds
        self.sourceFingerprintHash = sourceFingerprintHash
        self.destinationBindingHash = destinationBindingHash
        self.acquisitionRecordHash = acquisitionRecordHash
        self.manifestHash = manifestHash
        self.publicationReceiptHash = publicationReceiptHash
        self.observedRegularFileCount = observedRegularFileCount
        self.actualPublishedBytes = actualPublishedBytes
    }

    private enum CodingKeys: String, CodingKey {
        case snapshotReference
        case targetThreadIDs
        case preparedAtMilliseconds
        case publishedAtMilliseconds
        case sourceFingerprintHash
        case destinationBindingHash
        case acquisitionRecordHash
        case manifestHash
        case publicationReceiptHash
        case observedRegularFileCount
        case actualPublishedBytes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let reference = try values.decode(
            String.self,
            forKey: .snapshotReference
        )
        guard let snapshotID = UUID(uuidString: reference),
              snapshotID.uuidString.lowercased() == reference else {
            throw DecodingError.dataCorruptedError(
                forKey: .snapshotReference,
                in: values,
                debugDescription: "Snapshot reference is not canonical."
            )
        }
        try self.init(
            snapshotID: snapshotID,
            targetThreadIDs: try values.decode(
                [String].self,
                forKey: .targetThreadIDs
            ),
            preparedAtMilliseconds: try values.decode(
                Int64.self,
                forKey: .preparedAtMilliseconds
            ),
            publishedAtMilliseconds: try values.decode(
                Int64.self,
                forKey: .publishedAtMilliseconds
            ),
            sourceFingerprintHash: try values.decode(
                String.self,
                forKey: .sourceFingerprintHash
            ),
            destinationBindingHash: try values.decode(
                String.self,
                forKey: .destinationBindingHash
            ),
            acquisitionRecordHash: try values.decode(
                String.self,
                forKey: .acquisitionRecordHash
            ),
            manifestHash: try values.decode(
                String.self,
                forKey: .manifestHash
            ),
            publicationReceiptHash: try values.decode(
                String.self,
                forKey: .publicationReceiptHash
            ),
            observedRegularFileCount: try values.decode(
                Int.self,
                forKey: .observedRegularFileCount
            ),
            actualPublishedBytes: try values.decode(
                UInt64.self,
                forKey: .actualPublishedBytes
            )
        )
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

public enum CodexGhostRepairSnapshotAnalysisIdentityOutcome:
    Equatable,
    Sendable
{
    case resolved(CodexGhostRepairSnapshotAnalysisIdentity)
    case unavailable(message: String)
}

public struct CodexGhostRepairSnapshotAnalysisIdentityCapabilities:
    Equatable,
    Sendable
{
    public let identityResolutionAvailable: Bool

    public var acceptsCallerPath: Bool { false }
    public var opensRawDatabaseContents: Bool { false }
    public var writesFilesystem: Bool { false }
    public var persistsRepairPreview: Bool { false }
    public var automaticResolution: Bool { false }
    public var automaticRetry: Bool { false }
    public var snapshotAcquisitionAuthority: Bool { false }
    public var repairPreviewAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    public static let packagedReadOnly = Self(identityResolutionAvailable: true)
    public static let unavailable = Self(identityResolutionAvailable: false)

    private init(identityResolutionAvailable: Bool) {
        self.identityResolutionAvailable = identityResolutionAvailable
    }
}

public protocol CodexGhostRepairSnapshotAnalysisIdentityCoordinator: Sendable {
    var capabilities: CodexGhostRepairSnapshotAnalysisIdentityCapabilities {
        get
    }

    func resolve(
        request: CodexGhostRepairSnapshotAnalysisRequest
    ) async -> CodexGhostRepairSnapshotAnalysisIdentityOutcome
}

/// First M2 shipping boundary. It resolves only an exact published snapshot
/// UUID through the existing fixed, metadata-only recovery inventory. It does
/// not expose a URL, open raw database content, persist a Preview, or grant any
/// repair authority. A later fixed-statement reader must consume this frozen
/// identity and independently revalidate it before opening snapshot databases.
actor CodexGhostRepairSnapshotPackagedAnalysisIdentityCoordinator:
    CodexGhostRepairSnapshotAnalysisIdentityCoordinator
{
    nonisolated let capabilities =
        CodexGhostRepairSnapshotAnalysisIdentityCapabilities.packagedReadOnly

    private static let unavailableMessage =
        "Published snapshot analysis identity is unavailable; no repair Preview or mutation authority was created."

    private let reader: any CodexGhostRepairSnapshotRecoveryInventoryReading

    static func production() -> Self {
        Self(reader: CodexGhostRepairSnapshotRecoveryReader.production())
    }

    init(reader: any CodexGhostRepairSnapshotRecoveryInventoryReading) {
        self.reader = reader
    }

    func resolve(
        request: CodexGhostRepairSnapshotAnalysisRequest
    ) async -> CodexGhostRepairSnapshotAnalysisIdentityOutcome {
        guard let snapshotID = UUID(uuidString: request.snapshotReference),
              snapshotID.uuidString.lowercased() == request.snapshotReference else {
            return .unavailable(message: Self.unavailableMessage)
        }

        do {
            let inventory = try await reader.readbackInventory()
            let matches = inventory.snapshots.filter {
                $0.snapshotID == snapshotID
            }
            guard matches.count == 1,
                  let evidence = matches.first,
                  evidence.state == .published,
                  let published = evidence.publishedEvidence,
                  evidence.observedFileNames.count == published.regularFileCount else {
                return .unavailable(message: Self.unavailableMessage)
            }
            let identity = try CodexGhostRepairSnapshotAnalysisIdentity(
                snapshotID: snapshotID,
                targetThreadIDs: evidence.targetThreadIDs,
                preparedAtMilliseconds: evidence.preparedAtMilliseconds,
                publishedAtMilliseconds: published.publishedAtMilliseconds,
                sourceFingerprintHash: evidence.sourceFingerprintHash,
                destinationBindingHash: evidence.destinationBindingHash,
                acquisitionRecordHash: evidence.acquisitionRecordHash,
                manifestHash: published.manifestHash,
                publicationReceiptHash: published.publicationReceiptHash,
                observedRegularFileCount: evidence.observedFileNames.count,
                actualPublishedBytes: published.actualBytes
            )
            return .resolved(identity)
        } catch {
            return .unavailable(message: Self.unavailableMessage)
        }
    }
}

public enum CodexGhostRepairSnapshotAnalysisIdentityCoordinatorFactory {
    public static func packagedReadOnly()
        -> any CodexGhostRepairSnapshotAnalysisIdentityCoordinator
    {
        CodexGhostRepairSnapshotPackagedAnalysisIdentityCoordinator.production()
    }
}
