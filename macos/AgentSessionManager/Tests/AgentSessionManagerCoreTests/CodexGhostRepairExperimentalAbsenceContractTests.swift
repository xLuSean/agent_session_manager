@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairExperimentalAbsenceContractTests:
    XCTestCase
{
    private let missingID = "019f64d8-4be2-7c60-91ba-8687501cfd66"
    private let presentID = "019f64e3-ba20-7792-a7ab-1433db7ed8ec"

    func testShippingRegistryIsEmptyAndAuthorityFree() {
        let registry = CodexGhostRepairExperimentalAbsenceRegistry()

        XCTAssertTrue(registry.isEmpty)
        XCTAssertEqual(registry.admittedContractCount, 0)
        XCTAssertFalse(registry.officialLifecycleAuthority)
        XCTAssertFalse(registry.confirmationAuthority)
        XCTAssertFalse(registry.repairMutationAuthority)
        XCTAssertEqual(
            registry.evaluate(makeObservation()),
            .unavailable(.noAdmittedContract)
        )
    }

    func testPackagedReviewedRegistryAdmitsOnlyTheExactM2nContract() {
        let registry = CodexGhostRepairExperimentalAbsenceRegistry
            .packagedReviewedV1()

        XCTAssertFalse(registry.isEmpty)
        XCTAssertEqual(registry.admittedContractCount, 1)
        guard case let .matched(evidence) = registry.evaluate(
            makeObservation()
        ) else {
            return XCTFail("Expected the reviewed M2n contract to match")
        }
        XCTAssertEqual(evidence.runtimeVersion, "0.149.0")
        XCTAssertEqual(evidence.method, .threadRead)
        XCTAssertEqual(evidence.rpcCode, -32600)
        XCTAssertEqual(
            evidence.packagedCanaryEvidenceHash,
            "sha256:377253d50709faad062a037c16c3853bfadd2fabebfac7483799eeb571660755"
        )
        XCTAssertFalse(evidence.officialGuarantee)
        XCTAssertFalse(evidence.provesOfficialAbsence)
        XCTAssertFalse(evidence.confirmationAuthority)
        XCTAssertFalse(evidence.repairMutationAuthority)

        XCTAssertEqual(
            registry.evaluate(makeObservation(runtimeVersion: "0.149.1")),
            .unavailable(.noAdmittedContract)
        )
    }

    func testPackagedV151RegistryAdmitsBothExactRuntimeSourcePairs() {
        let registry = CodexGhostRepairVersionSpecificReadOnlyRegistry
            .packagedV151()

        XCTAssertFalse(registry.isEmpty)
        XCTAssertEqual(registry.admittedProfileCount, 2)
        for (runtime, profile) in [
            (
                "0.151.0-alpha.7.2",
                "desktop-bundled-0.151.0-alpha.7.2"
            ),
            ("0.151.0", "provider-0.151.0"),
        ] {
            guard case let .matched(evidence) = registry.evaluate(
                makeV151Observation(runtimeVersion: runtime),
                freshPresentControlVerified: true
            ) else {
                return XCTFail("Expected exact v0.151 profile \(runtime)")
            }
            XCTAssertEqual(evidence.runtimeProfileIdentifier, profile)
            XCTAssertEqual(
                evidence.sourceProfileIdentifier,
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v151SourceLayoutIdentifier
            )
            XCTAssertEqual(
                evidence.databaseSchemaProfileIdentifier,
                "desktop-v33"
            )
            XCTAssertEqual(
                evidence.compatibilityFixtureSHA256,
                "59b4669567f8c52a4dc5751a5e976cd2f28024662a950bf1964f6fc90917e2e3"
            )
            XCTAssertTrue(evidence.freshPresentControlRequired)
            XCTAssertFalse(evidence.officialGuarantee)
            XCTAssertFalse(evidence.confirmationAuthority)
            XCTAssertFalse(evidence.repairMutationAuthority)
        }
        XCTAssertFalse(registry.confirmationAuthority)
        XCTAssertFalse(registry.repairMutationAuthority)
    }

    func testPackagedV151RegistryRequiresFreshPresentControlAndExactPair() {
        let registry = CodexGhostRepairVersionSpecificReadOnlyRegistry
            .packagedV151()

        XCTAssertEqual(
            registry.evaluate(
                makeV151Observation(),
                freshPresentControlVerified: false
            ),
            .unavailable(.freshPresentControlUnavailable)
        )
        XCTAssertEqual(
            registry.evaluate(
                makeV151Observation(runtimeVersion: "0.151.1"),
                freshPresentControlVerified: true
            ),
            .unavailable(.noAdmittedContract)
        )
        XCTAssertEqual(
            registry.evaluate(
                makeV151Observation(
                    sourceLayoutIdentifier:
                        CodexGhostRepairSnapshotSourceLayout.identifier
                ),
                freshPresentControlVerified: true
            ),
            .unavailable(.responseShapeDrift)
        )
        XCTAssertEqual(
            registry.evaluate(
                makeV151Observation(desktopSchemaVersion: 32),
                freshPresentControlVerified: true
            ),
            .unavailable(.snapshotSchemaDrift)
        )
        XCTAssertEqual(
            registry.evaluate(
                makeV151Observation(message: "thread not loaded"),
                freshPresentControlVerified: true
            ),
            .unavailable(.exactMessageDrift)
        )
    }

    func testCurrentRegistryAdmitsExactV152ProviderAndDesktopV34Pair() {
        let registry = CodexGhostRepairVersionSpecificReadOnlyRegistry
            .packagedCurrent()

        XCTAssertEqual(registry.admittedProfileCount, 6)
        guard case let .matched(evidence) = registry.evaluate(
            makeV151Observation(
                runtimeVersion: "0.152.1",
                sourceLayoutIdentifier:
                    CodexGhostRepairPackagedReadOnlyProfileCatalog
                        .v152SourceLayoutIdentifier,
                desktopSchemaVersion: 34
            ),
            freshPresentControlVerified: true
        ) else {
            return XCTFail("Expected exact v0.152.1/v34 pair")
        }
        XCTAssertEqual(evidence.runtimeProfileIdentifier, "provider-0.152.1")
        XCTAssertEqual(
            evidence.sourceProfileIdentifier,
            CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v152SourceLayoutIdentifier
        )
        XCTAssertEqual(evidence.databaseSchemaProfileIdentifier, "desktop-v34")
        XCTAssertEqual(
            evidence.compatibilityFixtureSHA256,
            "6021fab9b9bfcff8431f9142f9031faa8e5da07675a70404c6ce6bec6bbbaf94"
        )
        XCTAssertFalse(evidence.confirmationAuthority)
        XCTAssertFalse(evidence.repairMutationAuthority)

        XCTAssertEqual(
            registry.evaluate(
                makeV151Observation(
                    runtimeVersion: "0.152.1",
                    sourceLayoutIdentifier:
                        CodexGhostRepairPackagedReadOnlyProfileCatalog
                            .v151SourceLayoutIdentifier,
                    desktopSchemaVersion: 33
                ),
                freshPresentControlVerified: true
            ),
            .unavailable(.responseShapeDrift)
        )
    }

    func testCurrentRegistryAdmitsExactV153DesktopProviderAndV34Pair() {
        let registry = CodexGhostRepairVersionSpecificReadOnlyRegistry
            .packagedCurrent()

        XCTAssertEqual(registry.admittedProfileCount, 6)
        for (runtime, profile) in [
            ("0.153.1", "desktop-bundled-0.153.1"),
            ("0.153.2", "provider-0.153.2"),
        ] {
            guard case let .matched(evidence) = registry.evaluate(
                makeV151Observation(
                    runtimeVersion: runtime,
                    sourceLayoutIdentifier:
                        CodexGhostRepairPackagedReadOnlyProfileCatalog
                            .v153SourceLayoutIdentifier,
                    desktopSchemaVersion: 34
                ),
                freshPresentControlVerified: true
            ) else {
                return XCTFail("Expected exact current v0.153 pair \(runtime)")
            }
            XCTAssertEqual(evidence.runtimeProfileIdentifier, profile)
            XCTAssertEqual(
                evidence.sourceProfileIdentifier,
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v153SourceLayoutIdentifier
            )
            XCTAssertEqual(
                evidence.databaseSchemaProfileIdentifier,
                "desktop-v34"
            )
            XCTAssertEqual(
                evidence.compatibilityFixtureSHA256,
                "1fb8f8ca65485fa82e668aa9f986e1f178aa5d9d27da12ed8be0957d06a5503f"
            )
            XCTAssertFalse(evidence.confirmationAuthority)
            XCTAssertFalse(evidence.repairMutationAuthority)
        }

        XCTAssertEqual(
            registry.evaluate(
                makeV151Observation(
                    runtimeVersion: "0.153.2",
                    sourceLayoutIdentifier:
                        CodexGhostRepairPackagedReadOnlyProfileCatalog
                            .v152SourceLayoutIdentifier,
                    desktopSchemaVersion: 34
                ),
                freshPresentControlVerified: true
            ),
            .unavailable(.responseShapeDrift)
        )
    }

    func testCurrentRegistryAdmitsOnlyProviderV1534ForExactDesktopV34Source() {
        let registry = CodexGhostRepairVersionSpecificReadOnlyRegistry
            .packagedCurrent()

        XCTAssertEqual(registry.admittedProfileCount, 6)
        guard case let .matched(evidence) = registry.evaluate(
            makeV151Observation(
                runtimeVersion: "0.153.4",
                sourceLayoutIdentifier:
                    CodexGhostRepairPackagedReadOnlyProfileCatalog
                        .v1534SourceLayoutIdentifier,
                desktopSchemaVersion: 34
            ),
            freshPresentControlVerified: true
        ) else {
            return XCTFail("Expected exact provider v0.153.4/Desktop v34 pair")
        }
        XCTAssertEqual(evidence.runtimeProfileIdentifier, "provider-0.153.4")
        XCTAssertEqual(
            evidence.sourceProfileIdentifier,
            CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v1534SourceLayoutIdentifier
        )
        XCTAssertEqual(evidence.databaseSchemaProfileIdentifier, "desktop-v34")
        XCTAssertEqual(
            evidence.compatibilityFixtureSHA256,
            "7d26dc10bca3d2063727cae204c90ea84d86ca2ba1470cf62dc6ecd5ba0fc353"
        )
        XCTAssertFalse(evidence.confirmationAuthority)
        XCTAssertFalse(evidence.repairMutationAuthority)
    }

    func testV1534RejectsHistoricalSourceAdjacentRuntimeAndMissingControl() {
        let registry = CodexGhostRepairVersionSpecificReadOnlyRegistry
            .packagedCurrent()
        let current = makeV151Observation(
            runtimeVersion: "0.153.4",
            sourceLayoutIdentifier:
                CodexGhostRepairPackagedReadOnlyProfileCatalog
                    .v1534SourceLayoutIdentifier,
            desktopSchemaVersion: 34
        )

        XCTAssertEqual(
            registry.evaluate(
                makeV151Observation(
                    runtimeVersion: "0.153.4",
                    sourceLayoutIdentifier:
                        CodexGhostRepairPackagedReadOnlyProfileCatalog
                            .v153SourceLayoutIdentifier,
                    desktopSchemaVersion: 34
                ),
                freshPresentControlVerified: true
            ),
            .unavailable(.responseShapeDrift)
        )
        for runtime in ["0.153.3", "0.153.5"] {
            XCTAssertEqual(
                registry.evaluate(
                    makeV151Observation(
                        runtimeVersion: runtime,
                        sourceLayoutIdentifier:
                            CodexGhostRepairPackagedReadOnlyProfileCatalog
                                .v1534SourceLayoutIdentifier,
                        desktopSchemaVersion: 34
                    ),
                    freshPresentControlVerified: true
                ),
                .unavailable(.noAdmittedContract)
            )
        }
        XCTAssertEqual(
            registry.evaluate(current, freshPresentControlVerified: false),
            .unavailable(.freshPresentControlUnavailable)
        )
    }

    func testRuntimeProfileRejectsMalformedBinaryDigest() {
        XCTAssertThrowsError(try CodexGhostRepairReadOnlyRuntimeProfile(
            identifier: "provider-0.153.4",
            runtimeVersion: "0.153.4",
            executableSHA256: "not-a-sha256",
            generatedProtocolSHA256:
                "251c80d7742dca39c0013f2b0ad11641df6582989c602fbbde6895207bd84692"
        ))
    }

    func testSameVersionDesktopBinaryIsNotDuplicatedAsRuntimeAdmission() {
        let registry = CodexGhostRepairVersionSpecificReadOnlyRegistry
            .packagedCurrent()

        XCTAssertEqual(registry.admittedProfileCount, 6)
        guard case let .matched(evidence) = registry.evaluate(
            makeV151Observation(
                runtimeVersion: "0.153.4",
                sourceLayoutIdentifier:
                    CodexGhostRepairPackagedReadOnlyProfileCatalog
                        .v1534SourceLayoutIdentifier,
                desktopSchemaVersion: 34
            ),
            freshPresentControlVerified: true
        ) else {
            return XCTFail("Expected the single provider-keyed admission")
        }
        XCTAssertEqual(evidence.runtimeProfileIdentifier, "provider-0.153.4")
        XCTAssertNotEqual(
            evidence.runtimeProfileIdentifier,
            "desktop-bundled-0.153.4"
        )
    }

    func testV151SourceProfileRejectsMemberOrDigestDrift() {
        XCTAssertThrowsError(
            try CodexGhostRepairReadOnlySourceProfile(
                identifier:
                    CodexGhostRepairPackagedReadOnlyProfileCatalog
                        .v151SourceLayoutIdentifier,
                ownerRuntimeProfileIdentifier:
                    "desktop-bundled-0.151.0-alpha.7.2",
                databaseSchemaProfileIdentifier: "desktop-v33",
                layoutSHA256:
                    "75ed09dfd0b221361f0d915f96d49b15991ffb5e3d308d300fc5b62bf9ef9c85",
                members: Array(
                    CodexGhostRepairReadOnlySourceProfile.v151Members
                        .dropLast()
                )
            )
        )
        XCTAssertThrowsError(
            try CodexGhostRepairReadOnlySourceProfile(
                identifier:
                    CodexGhostRepairPackagedReadOnlyProfileCatalog
                        .v151SourceLayoutIdentifier,
                ownerRuntimeProfileIdentifier:
                    "desktop-bundled-0.151.0-alpha.7.2",
                databaseSchemaProfileIdentifier: "desktop-v33",
                layoutSHA256: String(repeating: "0", count: 64),
                members:
                    CodexGhostRepairReadOnlySourceProfile.v151Members
            )
        )
    }

    func testExactAdmittedFixtureProducesExperimentalEvidence() throws {
        let registry = try makeRegistry()

        let outcome = registry.evaluate(makeObservation())

        guard case let .matched(evidence) = outcome else {
            return XCTFail("Expected exact Experimental absence evidence")
        }
        XCTAssertEqual(evidence.provider, .codex)
        XCTAssertEqual(evidence.requestedThreadID, missingID)
        XCTAssertEqual(evidence.runtimeVersion, "0.149.0")
        XCTAssertEqual(evidence.method, .threadRead)
        XCTAssertEqual(evidence.rpcCode, -32600)
        XCTAssertEqual(
            evidence.contractIdentifier,
            "codex-ghost-repair-experimental-absence"
        )
        XCTAssertEqual(evidence.contractVersion, 1)
        XCTAssertTrue(evidence.canonicalResponseHash.hasPrefix("sha256:"))
        XCTAssertEqual(evidence.provenanceKind, "experimental_local_observation")
        XCTAssertFalse(evidence.officialGuarantee)
        XCTAssertFalse(evidence.provesOfficialAbsence)
        XCTAssertFalse(evidence.confirmationAuthority)
        XCTAssertFalse(evidence.repairMutationAuthority)
        XCTAssertFalse(outcome.officialGuarantee)
        XCTAssertFalse(outcome.confirmationAuthority)
        XCTAssertFalse(outcome.repairMutationAuthority)
    }

    func testRuntimeMethodKindCodeAndProviderDriftAreUnavailable() throws {
        let registry = try makeRegistry()

        XCTAssertEqual(
            registry.evaluate(makeObservation(runtimeVersion: "0.149.1")),
            .unavailable(.noAdmittedContract)
        )
        XCTAssertEqual(
            registry.evaluate(makeObservation(rpcCode: -32601)),
            .unavailable(.noAdmittedContract)
        )
        XCTAssertEqual(
            registry.evaluate(makeObservation(provider: .claudeCode)),
            .unavailable(.noAdmittedContract)
        )
    }

    func testResponseShapeAndSourceLayoutDriftAreUnavailable() throws {
        let registry = try makeRegistry()

        XCTAssertEqual(
            registry.evaluate(makeObservation(
                responseShapeIdentifier: "rpc-error-code-only-v2"
            )),
            .unavailable(.responseShapeDrift)
        )
        XCTAssertEqual(
            registry.evaluate(makeObservation(
                sourceLayoutIdentifier: "different-layout"
            )),
            .unavailable(.responseShapeDrift)
        )
    }

    func testMessageRequiresExactRequestBoundTemplate() throws {
        let registry = try makeRegistry()

        XCTAssertEqual(
            registry.evaluate(makeObservation(message: "thread not loaded")),
            .unavailable(.exactMessageDrift)
        )
        XCTAssertEqual(
            registry.evaluate(makeObservation(
                message: "thread not loaded: \(presentID)"
            )),
            .unavailable(.exactMessageDrift)
        )
        XCTAssertEqual(
            registry.evaluate(makeObservation(
                message: "Thread not loaded: \(missingID)"
            )),
            .unavailable(.exactMessageDrift)
        )
        XCTAssertEqual(
            registry.evaluate(makeObservation(
                message: "prefix thread not loaded: \(missingID) suffix"
            )),
            .unavailable(.exactMessageDrift)
        )
    }

    func testSchemaOrderVersionAndHealthDriftAreUnavailable() throws {
        let registry = try makeRegistry()
        var wrongVersion = makeDatabases()
        wrongVersion[0] = .init(
            database: .desktop,
            schemaVersion: 31,
            integrityCheckPassed: true,
            foreignKeyViolationCount: 0
        )
        var unhealthy = makeDatabases()
        unhealthy[1] = .init(
            database: .summaries,
            schemaVersion: 2,
            integrityCheckPassed: false,
            foreignKeyViolationCount: 0
        )

        XCTAssertEqual(
            registry.evaluate(makeObservation(databases: wrongVersion)),
            .unavailable(.snapshotSchemaDrift)
        )
        XCTAssertEqual(
            registry.evaluate(makeObservation(
                databases: Array(makeDatabases().reversed())
            )),
            .unavailable(.snapshotSchemaDrift)
        )
        XCTAssertEqual(
            registry.evaluate(makeObservation(databases: unhealthy)),
            .unavailable(.snapshotSchemaDrift)
        )
    }

    func testInvalidOrAmbiguousMessageTemplatesAreRejected() throws {
        XCTAssertThrowsError(try makeContract(
            exactMessageTemplate: "thread not loaded"
        ))
        XCTAssertThrowsError(try makeContract(
            exactMessageTemplate:
                "thread {thread_id} not loaded: {thread_id}"
        ))
        XCTAssertThrowsError(try makeContract(
            exactMessageTemplate: " thread not loaded: {thread_id}"
        ))
        XCTAssertThrowsError(try makeContract(
            exactMessageTemplate: "thread not loaded: {thread_id}\n"
        ))
    }

    func testContractRejectsRuntimeSchemaAndIdentityExpansion() throws {
        XCTAssertThrowsError(try makeContract(runtimeVersion: ""))
        XCTAssertThrowsError(try makeContract(runtimeVersion: " 0.149.0"))
        XCTAssertThrowsError(try makeContract(rpcCode: -32000))
        XCTAssertThrowsError(try makeContract(provider: .claudeCode))
        XCTAssertThrowsError(try makeContract(
            sourceLayoutIdentifier: "caller-layout"
        ))
        XCTAssertThrowsError(try makeContract(
            databases: Array(makeDatabaseContracts().dropLast())
        ))
    }

    func testAdmissionRequiresDistinctControlAndTargetHashes()
        throws
    {
        let contract = try makeContract()
        XCTAssertThrowsError(try makeAdmission(
            contract: contract,
            compatibilityFixtureHash: "sha256:bad"
        ))
        XCTAssertThrowsError(try makeAdmission(
            contract: contract,
            packagedCanaryEvidenceHash: "sha256:bad"
        ))
        XCTAssertThrowsError(try makeAdmission(
            contract: contract,
            presentControlThreadIDHash:
                "sha256:" + String(repeating: "c", count: 64),
            missingFixtureThreadIDHashes: [
                "sha256:" + String(repeating: "c", count: 64),
            ]
        ))
        XCTAssertThrowsError(try makeAdmission(
            contract: contract,
            missingFixtureThreadIDHashes: []
        ))
        XCTAssertThrowsError(try makeAdmission(
            contract: contract,
            presentControlVerified: false
        ))
        XCTAssertThrowsError(try makeAdmission(
            contract: contract,
            missingFixtureVerified: false
        ))
    }

    func testDuplicateAdmissionForSameExactRuntimeShapeIsRejected()
        throws
    {
        let admission = try makeAdmission(contract: makeContract())

        XCTAssertThrowsError(
            try CodexGhostRepairExperimentalAbsenceRegistry(
                admissions: [admission, admission]
            )
        )
    }

    func testInvalidRequestedIDCannotUseExactMessageMatch() throws {
        let registry = try makeRegistry()
        let observation = CodexGhostRepairExperimentalAbsenceObservation(
            provider: .codex,
            requestedThreadID: "not-a-canonical-id",
            runtimeVersion: "0.149.0",
            method: .threadRead,
            errorKind: .rpcError,
            rpcCode: -32600,
            responseShapeIdentifier: "rpc-error-code-message-v1",
            message: "thread not loaded: not-a-canonical-id",
            sourceLayoutIdentifier:
                CodexGhostRepairSnapshotSourceLayout.identifier,
            databases: makeDatabases()
        )

        XCTAssertEqual(
            registry.evaluate(observation),
            .unavailable(.invalidRequestedThreadID)
        )
    }

    private func makeRegistry()
        throws -> CodexGhostRepairExperimentalAbsenceRegistry
    {
        try .init(admissions: [makeAdmission(contract: makeContract())])
    }

    private func makeContract(
        runtimeVersion: String = "0.149.0",
        rpcCode: Int = -32600,
        provider: AgentSystem = .codex,
        exactMessageTemplate: String = "thread not loaded: {thread_id}",
        sourceLayoutIdentifier: String =
            CodexGhostRepairSnapshotSourceLayout.identifier,
        databases: [CodexGhostRepairExperimentalDatabaseContract]? = nil
    ) throws -> CodexGhostRepairExperimentalAbsenceContract {
        try .init(
            identifier: "codex-ghost-repair-experimental-absence",
            version: 1,
            provider: provider,
            runtimeVersion: runtimeVersion,
            method: .threadRead,
            errorKind: .rpcError,
            rpcCode: rpcCode,
            responseShapeIdentifier: "rpc-error-code-message-v1",
            exactMessageTemplate: exactMessageTemplate,
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            databases: databases ?? makeDatabaseContracts()
        )
    }

    private func makeAdmission(
        contract: CodexGhostRepairExperimentalAbsenceContract,
        compatibilityFixtureHash: String =
            "sha256:" + String(repeating: "a", count: 64),
        packagedCanaryEvidenceHash: String =
            "sha256:" + String(repeating: "b", count: 64),
        presentControlThreadIDHash: String =
            "sha256:" + String(repeating: "c", count: 64),
        missingFixtureThreadIDHashes: [String] = [
            "sha256:" + String(repeating: "d", count: 64),
        ],
        presentControlVerified: Bool = true,
        missingFixtureVerified: Bool = true
    ) throws -> CodexGhostRepairExperimentalAbsenceAdmission {
        try .init(
            contract: contract,
            compatibilityFixtureHash: compatibilityFixtureHash,
            packagedCanaryEvidenceHash: packagedCanaryEvidenceHash,
            presentControlThreadIDHash: presentControlThreadIDHash,
            missingFixtureThreadIDHashes: missingFixtureThreadIDHashes,
            presentControlVerified: presentControlVerified,
            missingFixtureVerified: missingFixtureVerified
        )
    }

    private func makeObservation(
        provider: AgentSystem = .codex,
        runtimeVersion: String = "0.149.0",
        rpcCode: Int = -32600,
        responseShapeIdentifier: String = "rpc-error-code-message-v1",
        message: String? = nil,
        sourceLayoutIdentifier: String =
            CodexGhostRepairSnapshotSourceLayout.identifier,
        databases: [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]? = nil
    ) -> CodexGhostRepairExperimentalAbsenceObservation {
        .init(
            provider: provider,
            requestedThreadID: missingID,
            runtimeVersion: runtimeVersion,
            method: .threadRead,
            errorKind: .rpcError,
            rpcCode: rpcCode,
            responseShapeIdentifier: responseShapeIdentifier,
            message: message ?? "thread not loaded: \(missingID)",
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            databases: databases ?? makeDatabases()
        )
    }

    private func makeV151Observation(
        runtimeVersion: String = "0.151.0",
        message: String? = nil,
        sourceLayoutIdentifier: String =
            CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v151SourceLayoutIdentifier,
        desktopSchemaVersion: Int32 = 33
    ) -> CodexGhostRepairExperimentalAbsenceObservation {
        .init(
            provider: .codex,
            requestedThreadID: missingID,
            runtimeVersion: runtimeVersion,
            method: .threadRead,
            errorKind: .rpcError,
            rpcCode: -32600,
            responseShapeIdentifier: "rpc-error-code-message-v1",
            message: message ?? "thread not loaded: \(missingID)",
            sourceLayoutIdentifier: sourceLayoutIdentifier,
            databases: makeDatabaseContracts(
                desktopSchemaVersion: desktopSchemaVersion
            ).map {
                .init(
                    database: $0.database,
                    schemaVersion: $0.schemaVersion,
                    integrityCheckPassed: true,
                    foreignKeyViolationCount: 0
                )
            }
        )
    }

    private func makeDatabaseContracts()
        -> [CodexGhostRepairExperimentalDatabaseContract]
    {
        makeDatabaseContracts(desktopSchemaVersion: 32)
    }

    private func makeDatabaseContracts(
        desktopSchemaVersion: Int32
    ) -> [CodexGhostRepairExperimentalDatabaseContract] {
        [
            .init(
                database: .desktop,
                schemaVersion: desktopSchemaVersion
            ),
            .init(database: .summaries, schemaVersion: 2),
            .init(database: .state, schemaVersion: 0),
            .init(database: .threadHistory, schemaVersion: 0),
        ]
    }

    private func makeDatabases()
        -> [CodexGhostRepairSnapshotAnalysisDatabaseEvidence]
    {
        makeDatabaseContracts().map {
            .init(
                database: $0.database,
                schemaVersion: $0.schemaVersion,
                integrityCheckPassed: true,
                foreignKeyViolationCount: 0
            )
        }
    }
}
