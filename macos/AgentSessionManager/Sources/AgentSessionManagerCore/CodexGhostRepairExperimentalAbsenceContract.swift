import Foundation

public enum CodexGhostRepairExperimentalAbsenceMethod:
    String,
    Codable,
    Hashable,
    Sendable
{
    case threadRead = "thread/read"
}

public enum CodexGhostRepairExperimentalAbsenceErrorKind:
    String,
    Codable,
    Hashable,
    Sendable
{
    case rpcError = "rpc_error"
}

public struct CodexGhostRepairExperimentalDatabaseContract:
    Codable,
    Hashable,
    Sendable
{
    public let database: CodexGhostRepairSnapshotAnalysisDatabase
    public let schemaVersion: Int32
}

/// Experimental provenance is deliberately distinct from the official-only
/// lifecycle contract. It describes one exact observed runtime, method,
/// response shape, message template, and snapshot schema contract.
public struct CodexGhostRepairExperimentalAbsenceContract:
    Encodable,
    Hashable,
    Sendable
{
    public let identifier: String
    public let version: Int
    public let provider: AgentSystem
    public let runtimeVersion: String
    public let method: CodexGhostRepairExperimentalAbsenceMethod
    public let errorKind: CodexGhostRepairExperimentalAbsenceErrorKind
    public let rpcCode: Int
    public let responseShapeIdentifier: String
    public let exactMessageTemplate: String
    public let sourceLayoutIdentifier: String
    public let databases: [CodexGhostRepairExperimentalDatabaseContract]

    public var provenanceKind: String { "experimental_local_observation" }
    public var officialGuarantee: Bool { false }
    public var acceptsApproximateMessage: Bool { false }
    public var acceptsRuntimeRange: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    init(
        identifier: String,
        version: Int,
        provider: AgentSystem,
        runtimeVersion: String,
        method: CodexGhostRepairExperimentalAbsenceMethod,
        errorKind: CodexGhostRepairExperimentalAbsenceErrorKind,
        rpcCode: Int,
        responseShapeIdentifier: String,
        exactMessageTemplate: String,
        sourceLayoutIdentifier: String,
        databases: [CodexGhostRepairExperimentalDatabaseContract]
    ) throws {
        guard identifier == "codex-ghost-repair-experimental-absence",
              version > 0,
              provider == .codex,
              runtimeVersion == runtimeVersion.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              !runtimeVersion.isEmpty,
              method == .threadRead,
              errorKind == .rpcError,
              rpcCode == -32600,
              responseShapeIdentifier == "rpc-error-code-message-v1",
              Self.validMessageTemplate(exactMessageTemplate),
              sourceLayoutIdentifier
                == CodexGhostRepairSnapshotSourceLayout.identifier,
              Self.validDatabaseContract(databases) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Experimental absence contract is invalid."
            )
        }
        self.identifier = identifier
        self.version = version
        self.provider = provider
        self.runtimeVersion = runtimeVersion
        self.method = method
        self.errorKind = errorKind
        self.rpcCode = rpcCode
        self.responseShapeIdentifier = responseShapeIdentifier
        self.exactMessageTemplate = exactMessageTemplate
        self.sourceLayoutIdentifier = sourceLayoutIdentifier
        self.databases = databases
    }

    fileprivate func exactMessage(threadID: String) -> String {
        exactMessageTemplate.replacingOccurrences(
            of: Self.threadIDSlot,
            with: threadID
        )
    }

    private static let threadIDSlot = "{thread_id}"

    private static func validMessageTemplate(_ value: String) -> Bool {
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.components(separatedBy: threadIDSlot).count == 2
            && !value.contains("\n")
            && !value.contains("\r")
    }

    private static func validDatabaseContract(
        _ values: [CodexGhostRepairExperimentalDatabaseContract]
    ) -> Bool {
        guard values.map(\.database)
                == CodexGhostRepairSnapshotAnalysisDatabase.allCases,
              Set(values.map(\.database)).count == values.count else {
            return false
        }
        let versions = Dictionary(
            uniqueKeysWithValues: values.map {
                ($0.database, $0.schemaVersion)
            }
        )
        return versions[.desktop] == 32
            && versions[.summaries] == 2
            && versions[.state] == 0
            && versions[.threadHistory] == 0
    }
}

struct CodexGhostRepairExperimentalAbsenceAdmission:
    Hashable,
    Sendable
{
    let contract: CodexGhostRepairExperimentalAbsenceContract
    let compatibilityFixtureHash: String
    let packagedCanaryEvidenceHash: String
    let presentControlThreadIDHash: String
    let missingFixtureThreadIDHashes: [String]
    let presentControlVerified: Bool
    let missingFixtureVerified: Bool

    init(
        contract: CodexGhostRepairExperimentalAbsenceContract,
        compatibilityFixtureHash: String,
        packagedCanaryEvidenceHash: String,
        presentControlThreadIDHash: String,
        missingFixtureThreadIDHashes: [String],
        presentControlVerified: Bool,
        missingFixtureVerified: Bool
    ) throws {
        guard Self.isSHA256(compatibilityFixtureHash),
              Self.isSHA256(packagedCanaryEvidenceHash),
              Self.isSHA256(presentControlThreadIDHash),
              (1...2).contains(missingFixtureThreadIDHashes.count),
              missingFixtureThreadIDHashes
                == missingFixtureThreadIDHashes.sorted(),
              Set(missingFixtureThreadIDHashes).count
                == missingFixtureThreadIDHashes.count,
              missingFixtureThreadIDHashes.allSatisfy(Self.isSHA256),
              !missingFixtureThreadIDHashes.contains(
                  presentControlThreadIDHash
              ),
              presentControlVerified,
              missingFixtureVerified else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Experimental absence admission evidence is incomplete."
            )
        }
        self.contract = contract
        self.compatibilityFixtureHash = compatibilityFixtureHash
        self.packagedCanaryEvidenceHash = packagedCanaryEvidenceHash
        self.presentControlThreadIDHash = presentControlThreadIDHash
        self.missingFixtureThreadIDHashes = missingFixtureThreadIDHashes
        self.presentControlVerified = presentControlVerified
        self.missingFixtureVerified = missingFixtureVerified
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:"), value == value.lowercased() else {
            return false
        }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit)
    }
}

struct CodexGhostRepairExperimentalAbsenceObservation: Sendable {
    let provider: AgentSystem
    let requestedThreadID: String
    let runtimeVersion: String
    let method: CodexGhostRepairExperimentalAbsenceMethod
    let errorKind: CodexGhostRepairExperimentalAbsenceErrorKind
    let rpcCode: Int
    let responseShapeIdentifier: String
    let message: String
    let sourceLayoutIdentifier: String
    let databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
}

public struct CodexGhostRepairExperimentalAbsenceEvidence:
    Codable,
    Hashable,
    Sendable
{
    public let provider: AgentSystem
    public let requestedThreadID: String
    public let runtimeVersion: String
    public let method: CodexGhostRepairExperimentalAbsenceMethod
    public let rpcCode: Int
    public let contractIdentifier: String
    public let contractVersion: Int
    public let responseShapeIdentifier: String
    public let canonicalResponseHash: String
    public let compatibilityFixtureHash: String
    public let packagedCanaryEvidenceHash: String
    public let sourceLayoutIdentifier: String
    public let databases: [CodexGhostRepairExperimentalDatabaseContract]

    public var provenanceKind: String { "experimental_local_observation" }
    public var officialGuarantee: Bool { false }
    public var provesOfficialAbsence: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

public enum CodexGhostRepairExperimentalAbsenceUnavailableReason:
    String,
    Encodable,
    Hashable,
    Sendable
{
    case noAdmittedContract
    case invalidRequestedThreadID
    case responseShapeDrift
    case exactMessageDrift
    case snapshotSchemaDrift
    case freshPresentControlUnavailable
    case evidenceHashUnavailable
}

public enum CodexGhostRepairExperimentalAbsenceOutcome:
    Hashable,
    Sendable
{
    case matched(CodexGhostRepairExperimentalAbsenceEvidence)
    case unavailable(CodexGhostRepairExperimentalAbsenceUnavailableReason)

    public var officialGuarantee: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }
}

// MARK: - Version-specific packaged read-only profiles

/// One exact App Server runtime observed by the read-only compatibility probe.
/// This is deliberately separate from the Desktop source owner and DB schema.
struct CodexGhostRepairReadOnlyRuntimeProfile: Hashable, Sendable {
    let identifier: String
    let runtimeVersion: String
    let executableSHA256: String
    let generatedProtocolSHA256: String

    init(
        identifier: String,
        runtimeVersion: String,
        executableSHA256: String,
        generatedProtocolSHA256: String
    ) throws {
        guard !identifier.isEmpty,
              runtimeVersion == runtimeVersion.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !runtimeVersion.isEmpty,
              Self.isSHA256(executableSHA256),
              Self.isSHA256(generatedProtocolSHA256) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Version-specific read-only runtime evidence is invalid."
            )
        }
        self.identifier = identifier
        self.runtimeVersion = runtimeVersion
        self.executableSHA256 = executableSHA256
        self.generatedProtocolSHA256 = generatedProtocolSHA256
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }
}

struct CodexGhostRepairReadOnlySourceMember: Hashable, Sendable {
    let logicalRoot: String
    let fileName: String
    let requiredDatabase: Bool
}

/// Exact Desktop-owned source evidence. Equal file names are not enough to
/// reuse a layout across Desktop versions: owner, schema and reviewed digest
/// are all part of the identity.
struct CodexGhostRepairReadOnlySourceProfile: Hashable, Sendable {
    let identifier: String
    let ownerRuntimeProfileIdentifier: String
    let databaseSchemaProfileIdentifier: String
    let layoutSHA256: String
    let members: [CodexGhostRepairReadOnlySourceMember]

    init(
        identifier: String,
        ownerRuntimeProfileIdentifier: String,
        databaseSchemaProfileIdentifier: String,
        layoutSHA256: String,
        members: [CodexGhostRepairReadOnlySourceMember]
    ) throws {
        let isV151 = identifier
            == CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v151SourceLayoutIdentifier
            && ownerRuntimeProfileIdentifier
                == "desktop-bundled-0.151.0-alpha.7.2"
            && databaseSchemaProfileIdentifier == "desktop-v33"
        let isV152 = identifier
            == CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v152SourceLayoutIdentifier
            && ownerRuntimeProfileIdentifier == "desktop-bundled-0.152.1"
            && databaseSchemaProfileIdentifier == "desktop-v34"
        let isV153 = identifier
            == CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v153SourceLayoutIdentifier
            && ownerRuntimeProfileIdentifier == "desktop-bundled-0.153.1"
            && databaseSchemaProfileIdentifier == "desktop-v34"
        let isV1534 = identifier
            == CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v1534SourceLayoutIdentifier
            && ownerRuntimeProfileIdentifier == "desktop-bundled-0.153.4"
            && databaseSchemaProfileIdentifier == "desktop-v34"
        guard (isV151 || isV152 || isV153 || isV1534),
              layoutSHA256
                == "75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85",
              members == Self.v151Members else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "Version-specific read-only source evidence is invalid."
            )
        }
        self.identifier = identifier
        self.ownerRuntimeProfileIdentifier = ownerRuntimeProfileIdentifier
        self.databaseSchemaProfileIdentifier =
            databaseSchemaProfileIdentifier
        self.layoutSHA256 = layoutSHA256
        self.members = members
    }

    static let v151Members: [CodexGhostRepairReadOnlySourceMember] = [
        .init(logicalRoot: "sqlite", fileName: "codex-dev.db", requiredDatabase: true),
        .init(logicalRoot: "sqlite", fileName: "codex-dev.db-wal", requiredDatabase: false),
        .init(logicalRoot: "sqlite", fileName: "codex-dev.db-shm", requiredDatabase: false),
        .init(logicalRoot: "sqlite", fileName: "codex-dev.db-journal", requiredDatabase: false),
        .init(logicalRoot: "sqlite", fileName: "codex-thread-summaries-dev.db", requiredDatabase: true),
        .init(logicalRoot: "sqlite", fileName: "codex-thread-summaries-dev.db-wal", requiredDatabase: false),
        .init(logicalRoot: "sqlite", fileName: "codex-thread-summaries-dev.db-shm", requiredDatabase: false),
        .init(logicalRoot: "sqlite", fileName: "codex-thread-summaries-dev.db-journal", requiredDatabase: false),
        .init(logicalRoot: "sqlite", fileName: "codex-history-snapshots-dev.db", requiredDatabase: false),
        .init(logicalRoot: "sqlite", fileName: "codex-history-snapshots-dev.db-wal", requiredDatabase: false),
        .init(logicalRoot: "sqlite", fileName: "codex-history-snapshots-dev.db-shm", requiredDatabase: false),
        .init(logicalRoot: "sqlite", fileName: "codex-history-snapshots-dev.db-journal", requiredDatabase: false),
        .init(logicalRoot: "codex_home", fileName: "state_5.sqlite", requiredDatabase: true),
        .init(logicalRoot: "codex_home", fileName: "state_5.sqlite-wal", requiredDatabase: false),
        .init(logicalRoot: "codex_home", fileName: "state_5.sqlite-shm", requiredDatabase: false),
        .init(logicalRoot: "codex_home", fileName: "state_5.sqlite-journal", requiredDatabase: false),
        .init(logicalRoot: "codex_home", fileName: "thread_history_1.sqlite", requiredDatabase: true),
        .init(logicalRoot: "codex_home", fileName: "thread_history_1.sqlite-wal", requiredDatabase: false),
        .init(logicalRoot: "codex_home", fileName: "thread_history_1.sqlite-shm", requiredDatabase: false),
        .init(logicalRoot: "codex_home", fileName: "thread_history_1.sqlite-journal", requiredDatabase: false),
    ]
}

struct CodexGhostRepairVersionSpecificReadOnlyEvidence:
    Hashable,
    Sendable
{
    let runtimeProfileIdentifier: String
    let sourceProfileIdentifier: String
    let databaseSchemaProfileIdentifier: String
    let compatibilityFixtureSHA256: String
    let canonicalResponseHash: String

    var provenanceKind: String { "version_specific_synthetic_missing_probe" }
    var freshPresentControlRequired: Bool { true }
    var officialGuarantee: Bool { false }
    var confirmationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }
}

enum CodexGhostRepairVersionSpecificReadOnlyOutcome:
    Hashable,
    Sendable
{
    case matched(CodexGhostRepairVersionSpecificReadOnlyEvidence)
    case unavailable(CodexGhostRepairExperimentalAbsenceUnavailableReason)

    var confirmationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }
}

struct CodexGhostRepairVersionSpecificReadOnlyRegistry: Sendable {
    private struct Admission: Hashable, Sendable {
        let runtime: CodexGhostRepairReadOnlyRuntimeProfile
        let source: CodexGhostRepairReadOnlySourceProfile
        let compatibilityFixtureSHA256: String
    }

    private let admissions: [String: Admission]

    init() { admissions = [:] }

    private init(admissions: [Admission]) throws {
        var indexed: [String: Admission] = [:]
        for admission in admissions {
            let isV151 = admission.source.ownerRuntimeProfileIdentifier
                == "desktop-bundled-0.151.0-alpha.7.2"
                && admission.compatibilityFixtureSHA256
                    == "59b4669567f8c52a4dc5751a5e976cd2f28024662a950bf1964f6fc90917e2e3"
            let isV152 = admission.source.ownerRuntimeProfileIdentifier
                == "desktop-bundled-0.152.1"
                && admission.compatibilityFixtureSHA256
                    == "6021fab9b9bfcff8431f9142f9031faa8e5da07675a70404c6ce6bec6bbbaf94"
            let isV153 = admission.source.ownerRuntimeProfileIdentifier
                == "desktop-bundled-0.153.1"
                && admission.compatibilityFixtureSHA256
                    == "1fb8f8ca65485fa82e668aa9f986e1f178aa5d9d27da12ed8be0957d06a5503f"
            let isV1534 = admission.source.ownerRuntimeProfileIdentifier
                == "desktop-bundled-0.153.4"
                && admission.compatibilityFixtureSHA256
                    == "7d26dc10bca3d2063727cae204c90ea84d86ca2ba1470cf62dc6ecd5ba0fc353"
            guard (isV151 || isV152 || isV153 || isV1534),
                  indexed.updateValue(
                      admission,
                      forKey: admission.runtime.runtimeVersion
                  ) == nil else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Version-specific read-only admission is invalid."
                )
            }
        }
        self.admissions = indexed
    }

    static func packagedV151() -> Self {
        do {
            let protocolHash =
                "c4080cf0cbf540e6e52ca717185a45406ab70252862de70b60985fc0adbfd9f7"
            let desktop = try CodexGhostRepairReadOnlyRuntimeProfile(
                identifier: "desktop-bundled-0.151.0-alpha.7.2",
                runtimeVersion: "0.151.0-alpha.7.2",
                executableSHA256:
                    "a6042937174f72112dbd2d554a4af36936422e0c5ac69e353dc68994458996e9",
                generatedProtocolSHA256: protocolHash
            )
            let provider = try CodexGhostRepairReadOnlyRuntimeProfile(
                identifier: "provider-0.151.0",
                runtimeVersion: "0.151.0",
                executableSHA256:
                    "98491713ffb196061003ee148636e743997cc31d76144ba7c53462269896891d",
                generatedProtocolSHA256: protocolHash
            )
            let source = try CodexGhostRepairReadOnlySourceProfile(
                identifier:
                    CodexGhostRepairPackagedReadOnlyProfileCatalog
                        .v151SourceLayoutIdentifier,
                ownerRuntimeProfileIdentifier: desktop.identifier,
                databaseSchemaProfileIdentifier: "desktop-v33",
                layoutSHA256:
                    "75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85",
                members: CodexGhostRepairReadOnlySourceProfile.v151Members
            )
            let fixture =
                "59b4669567f8c52a4dc5751a5e976cd2f28024662a950bf1964f6fc90917e2e3"
            return try .init(admissions: [
                .init(
                    runtime: desktop,
                    source: source,
                    compatibilityFixtureSHA256: fixture
                ),
                .init(
                    runtime: provider,
                    source: source,
                    compatibilityFixtureSHA256: fixture
                ),
            ])
        } catch {
            return .init()
        }
    }

    /// Current packaged read-only evidence extends the historical v0.151
    /// admissions with one exact provider runtime bound to the independently
    /// identified Desktop v34 source owner. Equal version strings do not
    /// collapse the two executable hashes recorded by the fixture.
    static func packagedCurrent() -> Self {
        do {
            let protocolHash =
                "c4080cf0cbf540e6e52ca717185a45406ab70252862de70b60985fc0adbfd9f7"
            let desktopV151 = try CodexGhostRepairReadOnlyRuntimeProfile(
                identifier: "desktop-bundled-0.151.0-alpha.7.2",
                runtimeVersion: "0.151.0-alpha.7.2",
                executableSHA256:
                    "a6042937174f72112dbd2d554a4af36936422e0c5ac69e353dc68994458996e9",
                generatedProtocolSHA256: protocolHash
            )
            let providerV151 = try CodexGhostRepairReadOnlyRuntimeProfile(
                identifier: "provider-0.151.0",
                runtimeVersion: "0.151.0",
                executableSHA256:
                    "98491713ffb196061003ee148636e743997cc31d76144ba7c53462269896891d",
                generatedProtocolSHA256: protocolHash
            )
            let sourceV151 = try CodexGhostRepairReadOnlySourceProfile(
                identifier:
                    CodexGhostRepairPackagedReadOnlyProfileCatalog
                        .v151SourceLayoutIdentifier,
                ownerRuntimeProfileIdentifier: desktopV151.identifier,
                databaseSchemaProfileIdentifier: "desktop-v33",
                layoutSHA256:
                    "75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85",
                members: CodexGhostRepairReadOnlySourceProfile.v151Members
            )
            let providerV152 = try CodexGhostRepairReadOnlyRuntimeProfile(
                identifier: "provider-0.152.1",
                runtimeVersion: "0.152.1",
                executableSHA256:
                    "8194ea3181f330e63023b234b0b231855e5874e0331c5ef7cbc490591497a7bf",
                generatedProtocolSHA256: protocolHash
            )
            let sourceV152 = try CodexGhostRepairReadOnlySourceProfile(
                identifier:
                    CodexGhostRepairPackagedReadOnlyProfileCatalog
                        .v152SourceLayoutIdentifier,
                ownerRuntimeProfileIdentifier: "desktop-bundled-0.152.1",
                databaseSchemaProfileIdentifier: "desktop-v34",
                layoutSHA256:
                    "75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85",
                members: CodexGhostRepairReadOnlySourceProfile.v151Members
            )
            let protocolHashV153 =
                "251c80d7742dca39c0013f2b0ad11641df6582989c602fbbde6895207bd84692"
            let desktopV153 = try CodexGhostRepairReadOnlyRuntimeProfile(
                identifier: "desktop-bundled-0.153.1",
                runtimeVersion: "0.153.1",
                executableSHA256:
                    "0cf2d42e90ddd50fa5b7eedd5d72f109b68d33e5a6ce7c3fc2c87e4180edcd59",
                generatedProtocolSHA256: protocolHashV153
            )
            let providerV153 = try CodexGhostRepairReadOnlyRuntimeProfile(
                identifier: "provider-0.153.2",
                runtimeVersion: "0.153.2",
                executableSHA256:
                    "195ace4100a634a9df39147f493e730e666b5bd87795f3c9f3251d8542400424",
                generatedProtocolSHA256: protocolHashV153
            )
            let sourceV153 = try CodexGhostRepairReadOnlySourceProfile(
                identifier:
                    CodexGhostRepairPackagedReadOnlyProfileCatalog
                        .v153SourceLayoutIdentifier,
                ownerRuntimeProfileIdentifier: desktopV153.identifier,
                databaseSchemaProfileIdentifier: "desktop-v34",
                layoutSHA256:
                    "75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85",
                members: CodexGhostRepairReadOnlySourceProfile.v151Members
            )
            let providerV1534 = try CodexGhostRepairReadOnlyRuntimeProfile(
                identifier: "provider-0.153.4",
                runtimeVersion: "0.153.4",
                executableSHA256:
                    "b973d440acac501fd2594a43e7ca9ce41e0a65b9dfb28d0d7a7837c99e1261e3",
                generatedProtocolSHA256: protocolHashV153
            )
            let sourceV1534 = try CodexGhostRepairReadOnlySourceProfile(
                identifier:
                    CodexGhostRepairPackagedReadOnlyProfileCatalog
                        .v1534SourceLayoutIdentifier,
                ownerRuntimeProfileIdentifier: "desktop-bundled-0.153.4",
                databaseSchemaProfileIdentifier: "desktop-v34",
                layoutSHA256:
                    "75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85",
                members: CodexGhostRepairReadOnlySourceProfile.v151Members
            )
            return try .init(admissions: [
                .init(
                    runtime: desktopV151,
                    source: sourceV151,
                    compatibilityFixtureSHA256:
                        "59b4669567f8c52a4dc5751a5e976cd2f28024662a950bf1964f6fc90917e2e3"
                ),
                .init(
                    runtime: providerV151,
                    source: sourceV151,
                    compatibilityFixtureSHA256:
                        "59b4669567f8c52a4dc5751a5e976cd2f28024662a950bf1964f6fc90917e2e3"
                ),
                .init(
                    runtime: providerV152,
                    source: sourceV152,
                    compatibilityFixtureSHA256:
                        "6021fab9b9bfcff8431f9142f9031faa8e5da07675a70404c6ce6bec6bbbaf94"
                ),
                .init(
                    runtime: desktopV153,
                    source: sourceV153,
                    compatibilityFixtureSHA256:
                        "1fb8f8ca65485fa82e668aa9f986e1f178aa5d9d27da12ed8be0957d06a5503f"
                ),
                .init(
                    runtime: providerV153,
                    source: sourceV153,
                    compatibilityFixtureSHA256:
                        "1fb8f8ca65485fa82e668aa9f986e1f178aa5d9d27da12ed8be0957d06a5503f"
                ),
                // Both current executables report 0.153.4. The registry is
                // keyed by runtimeVersion, so only the provider observation is
                // admitted; the independently observed Desktop binary remains
                // bound as the exact source owner in sourceV1534 and the fixture.
                .init(
                    runtime: providerV1534,
                    source: sourceV1534,
                    compatibilityFixtureSHA256:
                        "7d26dc10bca3d2063727cae204c90ea84d86ca2ba1470cf62dc6ecd5ba0fc353"
                ),
            ])
        } catch {
            return .init()
        }
    }

    var admittedProfileCount: Int { admissions.count }
    var isEmpty: Bool { admissions.isEmpty }
    var confirmationAuthority: Bool { false }
    var repairMutationAuthority: Bool { false }

    func evaluate(
        _ observation: CodexGhostRepairExperimentalAbsenceObservation,
        freshPresentControlVerified: Bool
    ) -> CodexGhostRepairVersionSpecificReadOnlyOutcome {
        guard Self.isCanonicalUUID(observation.requestedThreadID) else {
            return .unavailable(.invalidRequestedThreadID)
        }
        guard freshPresentControlVerified else {
            return .unavailable(.freshPresentControlUnavailable)
        }
        guard observation.provider == .codex,
              observation.method == .threadRead,
              observation.errorKind == .rpcError,
              observation.rpcCode == -32600,
              let admission = admissions[observation.runtimeVersion] else {
            return .unavailable(.noAdmittedContract)
        }
        guard observation.responseShapeIdentifier
                == "rpc-error-code-message-v1",
              observation.sourceLayoutIdentifier
                == admission.source.identifier else {
            return .unavailable(.responseShapeDrift)
        }
        guard observation.message
                == "thread not loaded: \(observation.requestedThreadID)" else {
            return .unavailable(.exactMessageDrift)
        }
        guard let database = CodexGhostRepairDatabaseSchemaProfile.admitted(
            databases: observation.databases
        ), database.identifier
            == admission.source.databaseSchemaProfileIdentifier else {
            return .unavailable(.snapshotSchemaDrift)
        }
        do {
            let responseHash = try CodexGhostRepairHasher.hash(
                CanonicalResponse(
                    provider: observation.provider,
                    requestedThreadID: observation.requestedThreadID,
                    runtimeVersion: observation.runtimeVersion,
                    method: observation.method,
                    errorKind: observation.errorKind,
                    rpcCode: observation.rpcCode,
                    responseShapeIdentifier:
                        observation.responseShapeIdentifier,
                    message: observation.message
                )
            )
            return .matched(.init(
                runtimeProfileIdentifier: admission.runtime.identifier,
                sourceProfileIdentifier: admission.source.identifier,
                databaseSchemaProfileIdentifier:
                    admission.source.databaseSchemaProfileIdentifier,
                compatibilityFixtureSHA256:
                    admission.compatibilityFixtureSHA256,
                canonicalResponseHash: responseHash
            ))
        } catch {
            return .unavailable(.evidenceHashUnavailable)
        }
    }

    private struct CanonicalResponse: Encodable {
        let provider: AgentSystem
        let requestedThreadID: String
        let runtimeVersion: String
        let method: CodexGhostRepairExperimentalAbsenceMethod
        let errorKind: CodexGhostRepairExperimentalAbsenceErrorKind
        let rpcCode: Int
        let responseShapeIdentifier: String
        let message: String
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}

enum CodexGhostRepairPackagedReadOnlyProfileCatalog {
    static let v151SourceLayoutIdentifier =
        "codex-cli-0.151.0-alpha.7.2-desktop-v33-20-member-v1"
    static let v152SourceLayoutIdentifier =
        "codex-cli-0.152.1-desktop-v34-20-member-v1"
    static let v153SourceLayoutIdentifier =
        "codex-cli-0.153.1-desktop-v34-20-member-v1"
    static let v1534SourceLayoutIdentifier =
        "codex-cli-0.153.4-desktop-v34-20-member-v1"

    static func supportsObservationRuntime(_ runtimeVersion: String) -> Bool {
        CodexGhostRepairSnapshotSourceProfile.v149DesktopV32.supports(
            runtimeVersion: runtimeVersion
        ) || CodexGhostRepairSnapshotSourceProfile.v151DesktopV33.supports(
            runtimeVersion: runtimeVersion
        ) || CodexGhostRepairSnapshotSourceProfile.v152DesktopV34.supports(
            runtimeVersion: runtimeVersion
        ) || CodexGhostRepairSnapshotSourceProfile.v153DesktopV34.supports(
            runtimeVersion: runtimeVersion
        ) || CodexGhostRepairSnapshotSourceProfile.v1534DesktopV34.supports(
            runtimeVersion: runtimeVersion
        )
    }

    static func supportsPair(
        runtimeVersion: String,
        sourceLayoutIdentifier: String,
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    ) -> Bool {
        guard let schema = CodexGhostRepairDatabaseSchemaProfile.admitted(
            databases: databases
        ) else { return false }
        if CodexGhostRepairSnapshotSourceProfile.v149DesktopV32.supports(
            runtimeVersion: runtimeVersion
        ) {
            return sourceLayoutIdentifier
                    == CodexGhostRepairSnapshotSourceLayout.identifier
                && schema.identifier == "desktop-v32"
        }
        if runtimeVersion == "0.151.0-alpha.7.2"
            || runtimeVersion == "0.151.0" {
            return sourceLayoutIdentifier == v151SourceLayoutIdentifier
                && schema.identifier == "desktop-v33"
        }
        if runtimeVersion == "0.152.1" {
            return sourceLayoutIdentifier == v152SourceLayoutIdentifier
                && schema.identifier == "desktop-v34"
        }
        if runtimeVersion == "0.153.1"
            || runtimeVersion == "0.153.2" {
            return sourceLayoutIdentifier == v153SourceLayoutIdentifier
                && schema.identifier == "desktop-v34"
        }
        return runtimeVersion == "0.153.4"
            && sourceLayoutIdentifier == v1534SourceLayoutIdentifier
            && schema.identifier == "desktop-v34"
    }

    static func supportsSource(
        sourceLayoutIdentifier: String,
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    ) -> Bool {
        guard let schema = CodexGhostRepairDatabaseSchemaProfile.admitted(
            databases: databases
        ) else { return false }
        switch sourceLayoutIdentifier {
        case CodexGhostRepairSnapshotSourceLayout.identifier:
            // The exact packaged runtime/source pairing is enforced by
            // `supportsPair`. The builder also remains available to the
            // research-only M4f-20 disposable v33 executor fixtures, which
            // intentionally use the historical canonical source contract.
            return schema.identifier == "desktop-v32"
                || schema.identifier == "desktop-v33"
        case v151SourceLayoutIdentifier:
            return schema.identifier == "desktop-v33"
        case v152SourceLayoutIdentifier:
            return schema.identifier == "desktop-v34"
        case v153SourceLayoutIdentifier:
            return schema.identifier == "desktop-v34"
        case v1534SourceLayoutIdentifier:
            return schema.identifier == "desktop-v34"
        default:
            return false
        }
    }
}

/// The public initializer remains empty and authority-free. The single
/// non-public packaged entry is constructed only from the separately reviewed
/// M2n canary and is not visible to official lifecycle flows.
public struct CodexGhostRepairExperimentalAbsenceRegistry: Sendable {
    private struct Key: Hashable, Sendable {
        let provider: AgentSystem
        let runtimeVersion: String
        let method: CodexGhostRepairExperimentalAbsenceMethod
        let errorKind: CodexGhostRepairExperimentalAbsenceErrorKind
        let rpcCode: Int
    }

    private let admissions: [Key: CodexGhostRepairExperimentalAbsenceAdmission]

    public init() {
        admissions = [:]
    }

    /// The only shipping admission is derived from the reviewed M2n packaged
    /// canary. Raw canary session identifiers are deliberately not embedded;
    /// provenance is retained as path-free SHA-256 evidence. Any construction
    /// error fails closed to the empty registry.
    static func packagedReviewedV1() -> Self {
        do {
            let contract = try CodexGhostRepairExperimentalAbsenceContract(
                identifier: "codex-ghost-repair-experimental-absence",
                version: 1,
                provider: .codex,
                runtimeVersion: "0.149.0",
                method: .threadRead,
                errorKind: .rpcError,
                rpcCode: -32600,
                responseShapeIdentifier: "rpc-error-code-message-v1",
                exactMessageTemplate: "thread not loaded: {thread_id}",
                sourceLayoutIdentifier:
                    CodexGhostRepairSnapshotSourceLayout.identifier,
                databases: [
                    .init(database: .desktop, schemaVersion: 32),
                    .init(database: .summaries, schemaVersion: 2),
                    .init(database: .state, schemaVersion: 0),
                    .init(database: .threadHistory, schemaVersion: 0),
                ]
            )
            let admission = try CodexGhostRepairExperimentalAbsenceAdmission(
                contract: contract,
                compatibilityFixtureHash:
                    CodexGhostRepairHasher.hash(contract),
                packagedCanaryEvidenceHash:
                    "sha256:377253d50709faad062a037c16c3853bfadd2fabebfac7483799eeb571660755",
                presentControlThreadIDHash:
                    "sha256:11ad923c6105adbed3b131b186dde654200f35b102c224970ee285b0a7a3f66c",
                missingFixtureThreadIDHashes: [
                    "sha256:5c559436043180497d8ab12551bdfebe3852fbad84f9e6f242f3a7782da2cec6",
                    "sha256:c0a1ba0fc22a390686af5fe9de68773efd0687bcc511bc4fd216fa6b1f23a33c",
                ],
                presentControlVerified: true,
                missingFixtureVerified: true
            )
            return try .init(admissions: [admission])
        } catch {
            return .init()
        }
    }

    init(
        admissions: [CodexGhostRepairExperimentalAbsenceAdmission]
    ) throws {
        var indexed: [Key: CodexGhostRepairExperimentalAbsenceAdmission] = [:]
        for admission in admissions {
            let contract = admission.contract
            let key = Key(
                provider: contract.provider,
                runtimeVersion: contract.runtimeVersion,
                method: contract.method,
                errorKind: contract.errorKind,
                rpcCode: contract.rpcCode
            )
            guard indexed.updateValue(admission, forKey: key) == nil else {
                throw CodexGhostRepairError.invalidProtectionEvidence(
                    "Duplicate Experimental absence contract admission."
                )
            }
        }
        self.admissions = indexed
    }

    public var admittedContractCount: Int { admissions.count }
    public var isEmpty: Bool { admissions.isEmpty }
    public var officialLifecycleAuthority: Bool { false }
    public var confirmationAuthority: Bool { false }
    public var repairMutationAuthority: Bool { false }

    func evaluate(
        _ observation: CodexGhostRepairExperimentalAbsenceObservation
    ) -> CodexGhostRepairExperimentalAbsenceOutcome {
        guard Self.isCanonicalUUID(observation.requestedThreadID) else {
            return .unavailable(.invalidRequestedThreadID)
        }
        let key = Key(
            provider: observation.provider,
            runtimeVersion: observation.runtimeVersion,
            method: observation.method,
            errorKind: observation.errorKind,
            rpcCode: observation.rpcCode
        )
        guard let admission = admissions[key] else {
            return .unavailable(.noAdmittedContract)
        }
        let contract = admission.contract
        guard observation.responseShapeIdentifier
                == contract.responseShapeIdentifier,
              observation.sourceLayoutIdentifier
                == contract.sourceLayoutIdentifier else {
            return .unavailable(.responseShapeDrift)
        }
        guard observation.message
                == contract.exactMessage(
                    threadID: observation.requestedThreadID
                ) else {
            return .unavailable(.exactMessageDrift)
        }
        let databaseContracts = observation.databases.map {
            CodexGhostRepairExperimentalDatabaseContract(
                database: $0.database,
                schemaVersion: $0.schemaVersion
            )
        }
        guard databaseContracts == contract.databases,
              observation.databases.allSatisfy({
                  $0.integrityCheckPassed
                    && $0.foreignKeyViolationCount == 0
              }) else {
            return .unavailable(.snapshotSchemaDrift)
        }
        let canonicalResponseHash: String
        do {
            canonicalResponseHash = try CodexGhostRepairHasher.hash(
                CanonicalResponse(
                    provider: observation.provider,
                    requestedThreadID: observation.requestedThreadID,
                    runtimeVersion: observation.runtimeVersion,
                    method: observation.method,
                    errorKind: observation.errorKind,
                    rpcCode: observation.rpcCode,
                    responseShapeIdentifier:
                        observation.responseShapeIdentifier,
                    message: observation.message
                )
            )
        } catch {
            return .unavailable(.evidenceHashUnavailable)
        }
        return .matched(.init(
            provider: observation.provider,
            requestedThreadID: observation.requestedThreadID,
            runtimeVersion: observation.runtimeVersion,
            method: observation.method,
            rpcCode: observation.rpcCode,
            contractIdentifier: contract.identifier,
            contractVersion: contract.version,
            responseShapeIdentifier: contract.responseShapeIdentifier,
            canonicalResponseHash: canonicalResponseHash,
            compatibilityFixtureHash: admission.compatibilityFixtureHash,
            packagedCanaryEvidenceHash: admission.packagedCanaryEvidenceHash,
            sourceLayoutIdentifier: contract.sourceLayoutIdentifier,
            databases: contract.databases
        ))
    }

    private struct CanonicalResponse: Encodable {
        let provider: AgentSystem
        let requestedThreadID: String
        let runtimeVersion: String
        let method: CodexGhostRepairExperimentalAbsenceMethod
        let errorKind: CodexGhostRepairExperimentalAbsenceErrorKind
        let rpcCode: Int
        let responseShapeIdentifier: String
        let message: String
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}
