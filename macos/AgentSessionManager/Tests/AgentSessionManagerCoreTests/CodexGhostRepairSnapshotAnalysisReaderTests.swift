@testable import AgentSessionManagerCore
import CSQLite3
import CryptoKit
import Darwin
import Foundation
import XCTest

final class CodexGhostRepairSnapshotAnalysisReaderTests: XCTestCase {
    private let snapshotID = UUID(
        uuidString: "2deddc76-ba46-4eb5-b0f0-7aac17ce2790"
    )!
    private let targets = [
        "019f64d8-4be2-7c60-91ba-8687501cfd66",
        "019f64e3-ba20-7792-a7ab-1433db7ed8ec",
    ]

    func testFactoryExposesOnlyFixedQueryOnlyReadCapability() {
        let reader = CodexGhostRepairSnapshotAnalysisReaderFactory
            .packagedReadOnly()

        XCTAssertTrue(reader.capabilities.fixedPublishedSnapshotReadAvailable)
        XCTAssertFalse(reader.capabilities.acceptsCallerPath)
        XCTAssertTrue(reader.capabilities.opensOnlyRequiredDatabases)
        XCTAssertTrue(reader.capabilities.usesSQLiteReadOnly)
        XCTAssertTrue(reader.capabilities.usesNoFollowIdentityGuard)
        XCTAssertTrue(reader.capabilities.usesQueryOnly)
        XCTAssertTrue(reader.capabilities.usesAuthorizer)
        XCTAssertFalse(reader.capabilities.exposesGenericSQL)
        XCTAssertFalse(reader.capabilities.exposesDatabaseHandle)
        XCTAssertTrue(reader.capabilities.readsSessionRows)
        XCTAssertTrue(
            reader.capabilities.returnsOnlyPrivacyPreservingRowDigests
        )
        XCTAssertTrue(reader.capabilities.writesFilesystem)
        XCTAssertFalse(reader.capabilities.writesPublishedSnapshot)
        XCTAssertTrue(reader.capabilities.usesEphemeralAnalysisWorkspace)
        XCTAssertFalse(reader.capabilities.retainsAnalysisWorkspace)
        XCTAssertFalse(reader.capabilities.persistsRepairPreview)
        XCTAssertFalse(reader.capabilities.automaticRead)
        XCTAssertFalse(reader.capabilities.automaticRetry)
        XCTAssertFalse(reader.capabilities.repairPreviewAuthority)
        XCTAssertFalse(reader.capabilities.repairMutationAuthority)
    }

    func testReaderFreezesSummaryHashesAndRecognizesPausedAutomationWithoutAdmittingIt() async throws {
        let fixture = try await makeFixture(label: #function, manualResidue: true)
        let identity = try await fixture.identity(snapshotID: snapshotID, targets: targets)
        let before = try fixture.rawFileDigests(snapshotID: snapshotID)
        let outcome = await fixture.reader().read(identity: identity)
        guard case let .read(readback) = outcome else { return XCTFail("Expected readback") }
        XCTAssertEqual(readback.targets[1].rowContract, .unsupported)
        XCTAssertEqual(readback.targets[1].pausedAutomationReviewable, true)
        XCTAssertEqual(readback.targets[1].references.summaries, 1)
        XCTAssertEqual(readback.targets[1].summaryRowDigests?.count, 1)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(readback.targets), as: UTF8.self).contains("private-summary-content"))
        XCTAssertEqual(try fixture.rawFileDigests(snapshotID: snapshotID), before)
    }

    func testPublishedSnapshotReadsExactlyFourFixedDatabaseHealthContracts()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )
        let before = try fixture.rawFileDigests(snapshotID: snapshotID)
        let reader = fixture.reader()

        let outcome = await reader.read(identity: identity)

        guard case let .read(readback) = outcome else {
            return XCTFail("Expected query-only published snapshot readback")
        }
        XCTAssertEqual(readback.identity, identity)
        XCTAssertEqual(
            readback.sourceLayoutIdentifier,
            "codex-cli-0.149.0-paginated-v1"
        )
        XCTAssertEqual(
            readback.databases.map(\.database),
            CodexGhostRepairSnapshotAnalysisDatabase.allCases
        )
        XCTAssertEqual(
            readback.databases.map(\.schemaVersion),
            [32, 2, 0, 0]
        )
        XCTAssertTrue(readback.databases.allSatisfy(\.integrityCheckPassed))
        XCTAssertTrue(readback.databases.allSatisfy {
            $0.foreignKeyViolationCount == 0
                && $0.queryOnly
                && $0.fixedStatementsOnly
                && $0.statementCount == 4
        })
        XCTAssertEqual(readback.rawDatabaseContentsOpened, 4)
        XCTAssertFalse(readback.acceptsCallerPath)
        XCTAssertFalse(readback.exposesGenericSQL)
        XCTAssertFalse(readback.exposesDatabaseHandle)
        XCTAssertTrue(readback.writesFilesystem)
        XCTAssertFalse(readback.writesPublishedSnapshot)
        XCTAssertTrue(readback.usesEphemeralAnalysisWorkspace)
        XCTAssertFalse(readback.retainsAnalysisWorkspace)
        XCTAssertFalse(readback.persistsRepairPreview)
        XCTAssertFalse(readback.repairPreviewAuthority)
        XCTAssertFalse(readback.repairMutationAuthority)
        XCTAssertEqual(readback.targets.map(\.threadID), targets)
        XCTAssertEqual(readback.targets[0].displayTitle, "private 0")
        XCTAssertEqual(readback.targets[1].displayTitle, "private 1")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(readback.targets), as: UTF8.self).contains("private 0"))
        XCTAssertEqual(readback.targets[0].catalogRowCount, 1)
        XCTAssertEqual(readback.targets[0].automationRunRowCount, 0)
        XCTAssertEqual(readback.targets[0].automationDefinitionRowCount, 0)
        XCTAssertEqual(readback.targets[0].references.total, 0)
        XCTAssertEqual(readback.targets[0].rowContract, .categoryAEligible)
        XCTAssertEqual(readback.targets[1].catalogRowCount, 1)
        XCTAssertEqual(readback.targets[1].automationRunRowCount, 1)
        XCTAssertEqual(readback.targets[1].automationDefinitionRowCount, 1)
        XCTAssertEqual(readback.targets[1].references.total, 0)
        XCTAssertEqual(readback.targets[1].rowContract, .categoryBEligible)
        XCTAssertTrue(readback.targets.allSatisfy {
            !$0.exposesPrivateRowValues
                && ($0.catalogRowDigests + $0.automationRunRowDigests
                    + $0.automationDefinitionRowDigests).allSatisfy {
                        $0.hasPrefix("sha256:") && $0.count == 71
                    }
        })
        XCTAssertEqual(readback.authority.catalogRevision, 100)
        XCTAssertEqual(readback.authority.observationSequence, 200)
        XCTAssertEqual(readback.authority.watermarkUpdatedAt, 300)
        XCTAssertFalse(readback.authority.exposesPrivateRowValues)
        XCTAssertFalse(readback.authority.repairAuthority)
        XCTAssertTrue(readback.authority.metadataRowDigest.hasPrefix("sha256:"))
        XCTAssertTrue(readback.authority.localSyncRowDigest.hasPrefix("sha256:"))
        XCTAssertEqual(
            try fixture.rawFileDigests(snapshotID: snapshotID),
            before
        )
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testDesktopV33ExactSchemaAndOwnerIndexAreAdmitted() async throws {
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 33
        )
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )

        guard case let .read(readback) = await fixture.reader().read(
            identity: identity
        ) else {
            return XCTFail("Expected exact Desktop v33 readback")
        }

        XCTAssertEqual(readback.databases.map(\.schemaVersion), [33, 2, 0, 0])
        XCTAssertEqual(
            readback.sourceLayoutIdentifier,
            CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v151SourceLayoutIdentifier
        )
        XCTAssertEqual(
            readback.targets.map(\.rowContract),
            [.categoryAEligible, .categoryBEligible]
        )
        XCTAssertTrue(readback.targets[1].automationDefinitionRowDigests[0]
            .hasPrefix("sha256:"))
    }

    func testSourceAndDatabaseSchemaCrossPairFailsClosed() async throws {
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 33,
            sourceProfile: .v149DesktopV32
        )
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )

        assertUnavailable(
            await fixture.reader().read(identity: identity),
            reason: .desktopContractUnavailable
        )
    }

    func testDesktopV33MissingOwnerIndexFailsClosed() async throws {
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 33,
            omitV33OwnerIndex: true
        )
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )

        assertUnavailable(
            await fixture.reader().read(identity: identity),
            reason: .desktopContractUnavailable
        )
    }

    func testDesktopV34MissingCatalogIndexFailsClosed() async throws {
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 34,
            omitCatalogIndexes: true,
            sourceProfile: .v152DesktopV34
        )
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )

        assertUnavailable(
            await fixture.reader().read(identity: identity),
            reason: .desktopContractUnavailable
        )
    }

    func testDesktopV33WrongAutomationRRuleDefaultFailsClosed() async throws {
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 33,
            useObservedAutomationRRuleDefault: false
        )
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )

        assertUnavailable(
            await fixture.reader().read(identity: identity),
            reason: .desktopContractUnavailable
        )
    }

    func testPublishedSnapshotBulkReadEnumeratesCatalogWithoutCallerIDs()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        _ = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )
        let reference = snapshotID.uuidString.lowercased()
        let before = try fixture.rawFileDigests(snapshotID: snapshotID)

        let evidence = try await fixture.reader().readBulkCatalog(
            snapshotReference: reference
        )

        XCTAssertEqual(evidence.snapshotReference, reference)
        XCTAssertEqual(evidence.readback.targets.map(\.threadID), targets)
        XCTAssertEqual(
            evidence.readback.targets.map(\.rowContract),
            [.categoryAEligible, .categoryBEligible]
        )
        XCTAssertEqual(
            evidence.readback.databases.map(\.schemaVersion),
            [32, 2, 0, 0]
        )
        XCTAssertEqual(
            evidence.sourceFingerprintHash,
            evidence.readback.sourceFingerprintHash
        )
        XCTAssertEqual(
            try fixture.rawFileDigests(snapshotID: snapshotID),
            before
        )
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testV151PublishedSnapshotBulkReadEnumeratesExactMixed148Catalog()
        async throws
    {
        let exactTargets = (1...148).map {
            String(format: "00000000-0000-4000-8000-%012x", $0)
        }
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 33,
            targets: exactTargets
        )
        _ = try await fixture.identity(
            snapshotID: snapshotID,
            targets: Array(exactTargets.prefix(2))
        )

        let evidence = try await fixture.reader().readBulkCatalog(
            snapshotReference: snapshotID.uuidString.lowercased()
        )

        XCTAssertEqual(evidence.readback.targets.count, 148)
        XCTAssertEqual(evidence.readback.targets.map(\.threadID), exactTargets)
        XCTAssertEqual(
            evidence.sourceLayoutIdentifier,
            CodexGhostRepairPackagedReadOnlyProfileCatalog
                .v151SourceLayoutIdentifier
        )
        XCTAssertEqual(
            evidence.readback.databases.map(\.schemaVersion),
            [33, 2, 0, 0]
        )
        XCTAssertEqual(
            evidence.readback.targets.filter {
                $0.rowContract == .categoryAEligible
            }.count,
            74
        )
        XCTAssertEqual(
            evidence.readback.targets.filter {
                $0.rowContract == .categoryBEligible
            }.count,
            74
        )
        XCTAssertFalse(evidence.readback.authority.repairAuthority)
    }

    func testM4f28V151RequestBoundPublisherVerifiesBeforeExact148Publication()
        async throws
    {
        let exactTargets = (1...148).map {
            String(format: "00000000-0000-4000-8000-%012x", $0)
        }
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 33,
            targets: exactTargets
        )
        let request = try makeSnapshotRequest(
            runtimeVersion: "0.151.0-alpha.7.2",
            targetThreadIDs: Array(exactTargets.prefix(2))
        )
        let selection = try CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        )
        XCTAssertEqual(
            selection.sourceProfile,
            .v151DesktopV33
        )
        XCTAssertEqual(
            selection.expectedSchemaProfileIdentifier,
            "desktop-v33"
        )
        XCTAssertFalse(selection.runtimeAloneAdmitsSchema)
        let publisher = fixture.requestBoundPublisher(selection: selection)

        let acquisition = try await publisher.acquire(
            snapshotID: snapshotID,
            request: request
        )

        XCTAssertEqual(acquisition.snapshotID, snapshotID)
        XCTAssertTrue(fixture.markerExists(snapshotID))
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
        let identity = try await fixture.resolvedIdentity(snapshotID: snapshotID)
        let evidence = try await fixture.reader().readBulkCatalog(
            snapshotReference: identity.snapshotReference
        )
        XCTAssertEqual(evidence.readback.targets.count, 148)
        XCTAssertEqual(
            evidence.readback.targets.filter {
                $0.rowContract == .categoryAEligible
            }.count,
            74
        )
        XCTAssertEqual(
            evidence.readback.targets.filter {
                $0.rowContract == .categoryBEligible
            }.count,
            74
        )
        XCTAssertFalse(publisher.retriesAcquisition)
        XCTAssertFalse(publisher.acceptsCallerPath)
        XCTAssertFalse(publisher.repairMutationAuthority)
    }

    func testCurrentV152RequestBoundPublisherVerifiesV34Exact148Publication()
        async throws
    {
        let exactTargets = (1...148).map {
            String(format: "00000000-0000-4000-8001-%012x", $0)
        }
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 34,
            sourceProfile: .v152DesktopV34,
            targets: exactTargets
        )
        let request = try makeSnapshotRequest(
            runtimeVersion: "0.152.1",
            targetThreadIDs: Array(exactTargets.prefix(2))
        )
        let selection = try CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        )
        XCTAssertEqual(selection.sourceProfile, .v152DesktopV34)
        XCTAssertEqual(
            selection.expectedSchemaProfileIdentifier,
            "desktop-v34"
        )
        let publisher = fixture.requestBoundPublisher(selection: selection)

        let acquisition = try await publisher.acquire(
            snapshotID: snapshotID,
            request: request
        )

        XCTAssertEqual(acquisition.snapshotID, snapshotID)
        XCTAssertTrue(fixture.markerExists(snapshotID))
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
        let identity = try await fixture.resolvedIdentity(snapshotID: snapshotID)
        let evidence = try await fixture.reader().readBulkCatalog(
            snapshotReference: identity.snapshotReference
        )
        XCTAssertEqual(evidence.readback.targets.count, 148)
        XCTAssertEqual(
            evidence.readback.targets.filter {
                $0.rowContract == .categoryAEligible
            }.count,
            74
        )
        XCTAssertEqual(
            evidence.readback.targets.filter {
                $0.rowContract == .categoryBEligible
            }.count,
            74
        )
        XCTAssertEqual(
            evidence.readback.databases.map(\.schemaVersion),
            [34, 2, 0, 0]
        )
    }

    func testCurrentV153RequestBoundPublisherVerifiesV34Exact148Publication()
        async throws
    {
        let exactTargets = (1...148).map {
            String(format: "00000000-0000-4000-8002-%012x", $0)
        }
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 34,
            sourceProfile: .v153DesktopV34,
            targets: exactTargets
        )
        let request = try makeSnapshotRequest(
            runtimeVersion: "0.153.2",
            targetThreadIDs: Array(exactTargets.prefix(2))
        )
        let selection = try CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        )
        XCTAssertEqual(selection.sourceProfile, .v153DesktopV34)
        XCTAssertEqual(
            selection.expectedSchemaProfileIdentifier,
            "desktop-v34"
        )
        let publisher = fixture.requestBoundPublisher(selection: selection)

        let acquisition = try await publisher.acquire(
            snapshotID: snapshotID,
            request: request
        )

        XCTAssertEqual(acquisition.snapshotID, snapshotID)
        XCTAssertTrue(fixture.markerExists(snapshotID))
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
        let identity = try await fixture.resolvedIdentity(snapshotID: snapshotID)
        let evidence = try await fixture.reader().readBulkCatalog(
            snapshotReference: identity.snapshotReference
        )
        XCTAssertEqual(evidence.readback.targets.count, 148)
        XCTAssertEqual(
            evidence.readback.targets.filter {
                $0.rowContract == .categoryAEligible
            }.count,
            74
        )
        XCTAssertEqual(
            evidence.readback.targets.filter {
                $0.rowContract == .categoryBEligible
            }.count,
            74
        )
        XCTAssertEqual(
            evidence.readback.databases.map(\.schemaVersion),
            [34, 2, 0, 0]
        )
    }

    func testCurrentV1534RequestBoundPublisherVerifiesV34Exact148Publication()
        async throws
    {
        let exactTargets = (1...148).map {
            String(format: "00000000-0000-4000-8003-%012x", $0)
        }
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 34,
            sourceProfile: .v1534DesktopV34,
            targets: exactTargets
        )
        let request = try makeSnapshotRequest(
            runtimeVersion: "0.153.4",
            targetThreadIDs: Array(exactTargets.prefix(2))
        )
        let selection = try CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        )
        XCTAssertEqual(selection.sourceProfile, .v1534DesktopV34)
        XCTAssertEqual(
            selection.expectedSchemaProfileIdentifier,
            "desktop-v34"
        )
        let publisher = fixture.requestBoundPublisher(selection: selection)

        let acquisition = try await publisher.acquire(
            snapshotID: snapshotID,
            request: request
        )

        XCTAssertEqual(acquisition.snapshotID, snapshotID)
        XCTAssertTrue(fixture.markerExists(snapshotID))
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
        let identity = try await fixture.resolvedIdentity(snapshotID: snapshotID)
        let evidence = try await fixture.reader().readBulkCatalog(
            snapshotReference: identity.snapshotReference
        )
        XCTAssertEqual(evidence.readback.targets.count, 148)
        XCTAssertEqual(
            evidence.readback.targets.filter {
                $0.rowContract == .categoryAEligible
            }.count,
            74
        )
        XCTAssertEqual(
            evidence.readback.targets.filter {
                $0.rowContract == .categoryBEligible
            }.count,
            74
        )
        XCTAssertEqual(
            evidence.readback.databases.map(\.schemaVersion),
            [34, 2, 0, 0]
        )
    }

    func testM4f28SchemaCrossPairStopsBeforeManifestMarkerAndCannotRetry()
        async throws
    {
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 33,
            sourceProfile: .v149DesktopV32
        )
        let request = try makeSnapshotRequest(
            runtimeVersion: "0.149.0",
            targetThreadIDs: targets
        )
        let selection = try CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        )
        let publisher = fixture.requestBoundPublisher(selection: selection)

        await XCTAssertM4f28Throws(
            try await publisher.acquire(
                snapshotID: snapshotID,
                request: request
            )
        )

        XCTAssertTrue(fixture.quarantineExists(snapshotID))
        XCTAssertFalse(fixture.publishedExists(snapshotID))
        XCTAssertFalse(fixture.markerExists(snapshotID))
        XCTAssertFalse(fixture.manifestExistsInQuarantine(snapshotID))
        await XCTAssertM4f28Throws(
            try await publisher.acquire(
                snapshotID: snapshotID,
                request: request
            )
        ) { error in
            XCTAssertEqual(error as? CodexGhostRepairError, .claimAlreadyExists)
        }
    }

    func testM4f28PublisherProfileMismatchStopsBeforeSourceOpenOrJournal()
        async throws
    {
        let fixture = try await makeFixture(
            label: #function,
            desktopUserVersion: 33
        )
        let request = try makeSnapshotRequest(
            runtimeVersion: "0.149.0",
            targetThreadIDs: targets
        )
        let selection = try CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        )
        XCTAssertEqual(chmod(try XCTUnwrap(fixture.sourceFiles[.desktop]).path, 0o000), 0)
        let publisher = fixture.requestBoundPublisher(selection: selection)

        await XCTAssertM4f28Throws(
            try await publisher.acquire(
                snapshotID: snapshotID,
                request: request
            )
        ) { error in
            guard case .targetDrift? = error as? CodexGhostRepairError else {
                return XCTFail("Expected pre-I/O exact profile mismatch")
            }
        }

        XCTAssertFalse(fixture.acquisitionRecordExists(snapshotID))
        XCTAssertFalse(fixture.quarantineExists(snapshotID))
        XCTAssertFalse(fixture.publishedExists(snapshotID))
    }

    func testM4f28FrozenRequestDriftAndUnknownRuntimeFailBeforeEffects()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        let request = try makeSnapshotRequest(
            runtimeVersion: "0.149.0",
            targetThreadIDs: targets
        )
        let selection = try CodexGhostRepairSnapshotRequestBoundProfileSelection(
            request: request
        )
        let drifted = try makeSnapshotRequest(
            runtimeVersion: "0.149.0",
            targetThreadIDs: [targets[0]]
        )
        let publisher = fixture.requestBoundPublisher(selection: selection)

        await XCTAssertM4f28Throws(
            try await publisher.acquire(
                snapshotID: snapshotID,
                request: drifted
            )
        )
        XCTAssertFalse(fixture.acquisitionRecordExists(snapshotID))
        XCTAssertThrowsError(
            try CodexGhostRepairSnapshotRequestBoundProfileSelection(
                request: makeSnapshotRequest(
                    runtimeVersion: "0.152.0",
                    targetThreadIDs: targets
                )
            )
        )
        XCTAssertFalse(fixture.acquisitionRecordExists(snapshotID))
    }

    func testCanonicalSourceIsCopiedQueriedAndRemovedWithoutSQLiteLiveOpen()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        let before = try fixture.source.fingerprint()

        let result = try CodexGhostRepairCanonicalQueryOnlyReader.read(
                source: fixture.source,
                targetThreadIDs: targets,
                workspaceFactory: .init(
                    testOwnedParentURL: fixture.workspaceParent
                )
            )

        XCTAssertEqual(result.targets.map(\.threadID), targets)
        XCTAssertTrue(result.targets.allSatisfy {
            $0.rowContract != .unsupported && $0.references.total == 0
        })
        XCTAssertEqual(result.databases.map(\.schemaVersion), [32, 2, 0, 0])
        XCTAssertTrue(result.databases.allSatisfy {
            $0.integrityCheckPassed && $0.foreignKeyViolationCount == 0
        })
        XCTAssertEqual(result.authority.catalogRevision, 100)
        XCTAssertEqual(result.authority.observationSequence, 200)
        XCTAssertEqual(try fixture.source.fingerprint(), before)
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testBulkCanonicalReaderEnumeratesCompleteCatalogWithoutCallerIDs()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        let before = try fixture.source.fingerprint()

        let result = try CodexGhostRepairBulkCanonicalQueryOnlyReader.read(
            source: fixture.source,
            workspaceFactory: .init(
                testOwnedParentURL: fixture.workspaceParent
            )
        )

        XCTAssertEqual(result.targets.map(\.threadID), targets)
        XCTAssertEqual(
            result.targets.map(\.rowContract),
            [.categoryAEligible, .categoryBEligible]
        )
        XCTAssertEqual(result.databases.map(\.schemaVersion), [32, 2, 0, 0])
        XCTAssertTrue(result.databases.allSatisfy {
            $0.integrityCheckPassed && $0.foreignKeyViolationCount == 0
        })
        XCTAssertEqual(result.authority.catalogRevision, 100)
        XCTAssertEqual(result.authority.observationSequence, 200)
        XCTAssertEqual(result.sourceFingerprintHash, before.fingerprintHash)
        XCTAssertFalse(result.acceptsCallerThreadIDs)
        XCTAssertFalse(result.exposesGenericSQL)
        XCTAssertFalse(result.writesCanonicalSource)
        XCTAssertFalse(result.persistsPreview)
        XCTAssertFalse(result.repairPreviewAuthority)
        XCTAssertFalse(result.repairMutationAuthority)
        XCTAssertEqual(try fixture.source.fingerprint(), before)
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testExactCleanupScopeIncludesAbsentIDsWithoutMutatingSource() async throws {
        let fixture = try await makeFixture(label: #function)
        let before = try fixture.source.fingerprint()
        let absentID = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let ids = (targets + [absentID]).sorted()
        let result = try CodexGhostRepairBulkCanonicalQueryOnlyReader.readExactCleanupScope(
            source: fixture.source, targetThreadIDs: ids,
            workspaceFactory: .init(testOwnedParentURL: fixture.workspaceParent)
        )
        XCTAssertEqual(result.targets.map(\.threadID), ids)
        let absent = try XCTUnwrap(result.targets.first { $0.threadID == absentID })
        XCTAssertTrue(absent.catalogRowDigests.isEmpty)
        XCTAssertTrue(absent.automationRunRowDigests.isEmpty)
        XCTAssertTrue(absent.automationDefinitionRowDigests.isEmpty)
        XCTAssertEqual(absent.references.total, 0)
        XCTAssertEqual(absent.rowContract, .unsupported) // absence is not a deletable ghost
        XCTAssertTrue(absent.hasNoResidue)
        let inventory = try CodexGhostRepairBulkInventoryBuilder.build(input: .init(
            snapshotReference: UUID().uuidString.lowercased(),
            sourceLayoutIdentifier: fixture.source.profile.identifier,
            sourceFingerprintHash: result.sourceFingerprintHash,
            manifestHash: "sha256:" + String(repeating: "a", count: 64),
            databases: result.databases, targets: result.targets,
            protectionEvidence: ids.map {
                .init(threadID: $0, inventoryComplete: true,
                      activeInventoryPresent: false, archivedInventoryPresent: false,
                      exactReadNotLoaded: true, exactReadErrorCode: -32600,
                      pinned: false, descendantCount: 0)
            }, authority: result.authority
        ))
        let preview = try CodexGhostRepairBulkPreviewFactory.buildAuthorityFree(
            inventory: inventory, selectedThreadIDs: ids,
            generatedAtMilliseconds: 1_000, lifetimeMilliseconds: 9_000
        )
        let source = try CodexGhostRepairBulkFrozenPlanSourceBuilder.build(inventory: inventory, preview: preview)
        XCTAssertEqual(preview.selectedItems.map(\.threadID), ids)
        XCTAssertEqual(preview.selectedItems.filter { $0.initiallyAbsent == true }.map(\.threadID), [absentID])
        XCTAssertNil(source.selectedItems.first { $0.threadID == absentID }?.catalogRowDigest)
        try source.validate(preview: preview)
        XCTAssertEqual(try fixture.source.fingerprint(), before)
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
        for invalid in [[], [absentID, absentID], ["not-an-id"]] {
            XCTAssertThrowsError(try CodexGhostRepairBulkCanonicalQueryOnlyReader.readExactCleanupScope(
                source: fixture.source, targetThreadIDs: invalid,
                workspaceFactory: .init(testOwnedParentURL: fixture.workspaceParent)
            ))
        }
    }

    func testInitialWitnessCanonicalReaderReturnsOnlyCatalogIdentities()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        let before = try fixture.source.fingerprint()

        let result = try CodexGhostRepairInitialWitnessCanonicalQueryOnlyReader
            .read(
                source: fixture.source,
                workspaceFactory: .init(
                    testOwnedParentURL: fixture.workspaceParent
                )
            )

        XCTAssertEqual(result.threadIDs, targets)
        XCTAssertEqual(result.databases.map(\.schemaVersion), [32, 2, 0, 0])
        XCTAssertEqual(result.sourceLayoutIdentifier, fixture.source.profile.identifier)
        XCTAssertEqual(result.sourceFingerprintHash, before.fingerprintHash)
        XCTAssertFalse(result.exposesPrivateRowEvidence)
        XCTAssertFalse(result.acceptsCallerThreadIDs)
        XCTAssertFalse(result.exposesGenericSQL)
        XCTAssertFalse(result.writesCanonicalSource)
        XCTAssertTrue(result.usesTemporaryWorkspace)
        XCTAssertTrue(result.writesTemporaryWorkspace)
        XCTAssertFalse(result.publishesSnapshot)
        XCTAssertFalse(result.persistsPreview)
        XCTAssertFalse(result.repairMutationAuthority)
        XCTAssertEqual(try fixture.source.fingerprint(), before)
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testWALAndSharedMemoryAreOpenedOnlyFromCleanedWorkingCopy()
        async throws
    {
        let fixture = try await makeFixture(
            label: #function,
            withWALSidecars: true
        )
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )
        let before = try fixture.rawFileDigests(snapshotID: snapshotID)
        XCTAssertTrue(before.keys.contains { $0.hasSuffix("-wal") })
        XCTAssertTrue(before.keys.contains { $0.hasSuffix("-shm") })

        let outcome = await fixture.reader().read(identity: identity)

        guard case let .read(readback) = outcome else {
            return XCTFail("Expected isolated WAL snapshot readback")
        }
        XCTAssertEqual(readback.targets.map(\.threadID), targets)
        XCTAssertEqual(
            try fixture.rawFileDigests(snapshotID: snapshotID),
            before
        )
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testWorkingCopyAllowsSQLiteToCreateMissingSharedMemorySidecars()
        async throws
    {
        let fixture = try await makeFixture(
            label: #function,
            withWALSidecars: true,
            omitSharedMemoryFor: [.state, .threadHistory]
        )
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )
        let before = try fixture.rawFileDigests(snapshotID: snapshotID)
        XCTAssertEqual(before.count, 10)
        XCTAssertFalse(before.keys.contains("state_5.sqlite-shm"))
        XCTAssertFalse(before.keys.contains("thread_history_1.sqlite-shm"))

        let outcome = await fixture.reader().read(identity: identity)

        guard case let .read(readback) = outcome else {
            return XCTFail("Expected isolated WAL snapshot readback with generated SHM")
        }
        XCTAssertEqual(readback.targets.map(\.threadID), targets)
        XCTAssertEqual(
            try fixture.rawFileDigests(snapshotID: snapshotID),
            before
        )
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testUnconfirmedDesktopColumnShapeFailsClosed() async throws {
        let fixture = try await makeFixture(
            label: #function,
            addUnconfirmedDesktopColumn: true
        )
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )

        let outcome = await fixture.reader().read(identity: identity)

        assertUnavailable(outcome, reason: .desktopContractUnavailable)
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testUnsupportedAutomationStateIsClassifiedWithoutExposingValues()
        async throws
    {
        let fixture = try await makeFixture(
            label: #function,
            automationStatus: "ARCHIVED"
        )
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )

        let outcome = await fixture.reader().read(identity: identity)

        guard case let .read(readback) = outcome else {
            return XCTFail("Expected privacy-safe unsupported row evidence")
        }
        XCTAssertEqual(readback.targets[1].rowContract, .unsupported)
        XCTAssertFalse(readback.targets[1].exposesPrivateRowValues)
    }

    func testManifestHashDriftFailsClosedWithoutPreviewAuthority()
        async throws
    {
        let fixture = try await makeFixture(label: #function)
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )
        let desktop = fixture.snapshotRoot(snapshotID).appendingPathComponent(
            CodexGhostRepairSnapshotCanonicalFile.desktop.rawValue
        )
        var bytes = try Data(contentsOf: desktop)
        bytes[bytes.startIndex] ^= 0xff
        try bytes.write(to: desktop, options: .atomic)
        XCTAssertEqual(chmod(desktop.path, 0o600), 0)

        let outcome = await fixture.reader().read(identity: identity)

        assertUnavailable(outcome, reason: .publishedSourcePreflightUnavailable)
    }

    func testIdentityDriftStopsBeforeOpeningSnapshotDatabases() async throws {
        let fixture = try await makeFixture(label: #function)
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )
        let staleResolver = AnalysisIdentityOutcomeFake(
            outcome: .unavailable(message: "stale")
        )
        let access = AnalysisAccessResolverSpy(
            access: try await fixture.accessSource.access(for: identity)
        )
        let reader = CodexGhostRepairSnapshotPackagedAnalysisReader(
            identityResolver: staleResolver,
            accessResolver: access
        )

        let outcome = await reader.read(identity: identity)

        assertUnavailable(outcome, reason: .freshIdentityUnavailable)
        let accessCalls = await access.callCount()
        XCTAssertEqual(accessCalls, 0)
    }

    func testAccessPreflightFailureStopsBeforeCreatingWorkspace() async throws {
        let fixture = try await makeFixture(label: #function)
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )
        let access = AnalysisAccessSequenceSource(steps: [.failure])
        let reader = CodexGhostRepairSnapshotPackagedAnalysisReader(
            identityResolver: AnalysisIdentityOutcomeFake(
                outcome: .resolved(identity)
            ),
            accessResolver: access,
            workspaceFactory: .init(
                testOwnedParentURL: fixture.workspaceParent
            )
        )

        let outcome = await reader.read(identity: identity)

        assertUnavailable(
            outcome,
            reason: .publishedAccessPreflightUnavailable
        )
        let accessCalls = await access.callCount()
        XCTAssertEqual(accessCalls, 1)
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testAccessPostflightFailureOccursAfterWorkspaceCleanup() async throws {
        let fixture = try await makeFixture(label: #function)
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )
        let initial = try await fixture.accessSource.access(for: identity)
        let access = AnalysisAccessSequenceSource(steps: [
            .value(initial), .failure,
        ])
        let reader = CodexGhostRepairSnapshotPackagedAnalysisReader(
            identityResolver: AnalysisIdentityOutcomeFake(
                outcome: .resolved(identity)
            ),
            accessResolver: access,
            workspaceFactory: .init(
                testOwnedParentURL: fixture.workspaceParent
            )
        )

        let outcome = await reader.read(identity: identity)

        assertUnavailable(
            outcome,
            reason: .publishedAccessPostflightUnavailable
        )
        let accessCalls = await access.callCount()
        XCTAssertEqual(accessCalls, 2)
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testAccessPostflightDriftHasDistinctFailureReason() async throws {
        let fixture = try await makeFixture(label: #function)
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )
        let initial = try await fixture.accessSource.access(for: identity)
        let drifted = CodexGhostRepairSnapshotPublishedInventoryCollector
            .AnalysisAccess(
                snapshotRootURL: initial.snapshotRootURL.appendingPathComponent(
                    "drifted",
                    isDirectory: true
                ),
                manifest: initial.manifest,
                publishedEvidence: initial.publishedEvidence
            )
        let access = AnalysisAccessSequenceSource(steps: [
            .value(initial), .value(drifted),
        ])
        let reader = CodexGhostRepairSnapshotPackagedAnalysisReader(
            identityResolver: AnalysisIdentityOutcomeFake(
                outcome: .resolved(identity)
            ),
            accessResolver: access,
            workspaceFactory: .init(
                testOwnedParentURL: fixture.workspaceParent
            )
        )

        let outcome = await reader.read(identity: identity)

        assertUnavailable(outcome, reason: .publishedAccessDrift)
        let accessCalls = await access.callCount()
        XCTAssertEqual(accessCalls, 2)
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testUnsafeWorkspaceParentMapsToCreationFailure() async throws {
        let fixture = try await makeFixture(label: #function)
        let identity = try await fixture.identity(
            snapshotID: snapshotID,
            targets: targets
        )
        XCTAssertEqual(chmod(fixture.workspaceParent.path, 0o722), 0)
        defer { XCTAssertEqual(chmod(fixture.workspaceParent.path, 0o700), 0) }

        let outcome = await fixture.reader().read(identity: identity)

        assertUnavailable(outcome, reason: .workspaceCreationUnavailable)
        XCTAssertTrue(try fixture.analysisWorkspaceEntries().isEmpty)
    }

    func testAuthorizerAllowsOnlyFixedReadPragmasAndRejectsMutation() {
        XCTAssertEqual(decision(SQLITE_SELECT), SQLITE_OK)
        XCTAssertEqual(
            decision(SQLITE_READ, "any_table", "any_column"),
            SQLITE_DENY
        )
        for pragma in [
            "query_only", "user_version", "integrity_check",
            "foreign_key_check",
        ] {
            XCTAssertEqual(decision(SQLITE_PRAGMA, pragma, nil), SQLITE_OK)
        }
        XCTAssertEqual(
            decision(SQLITE_PRAGMA, "query_only", "OFF"),
            SQLITE_DENY
        )
        XCTAssertEqual(decision(SQLITE_PRAGMA, "journal_mode", nil), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_UPDATE), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_INSERT), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_DELETE), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_ATTACH), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_DETACH), SQLITE_DENY)
        XCTAssertEqual(decision(SQLITE_TRANSACTION), SQLITE_DENY)
        XCTAssertEqual(
            decision(SQLITE_READ, "local_thread_catalog", "thread_id"),
            SQLITE_OK
        )
        XCTAssertEqual(
            decision(SQLITE_READ, "unknown_table", "thread_id"),
            SQLITE_DENY
        )
        XCTAssertEqual(
            decision(SQLITE_PRAGMA, "table_info", "local_thread_catalog"),
            SQLITE_OK
        )
        XCTAssertEqual(
            decision(SQLITE_PRAGMA, "table_info", "unknown_table"),
            SQLITE_DENY
        )
        XCTAssertEqual(
            decision(
                SQLITE_PRAGMA,
                "index_info",
                "local_thread_catalog_updated_idx"
            ),
            SQLITE_OK
        )
        XCTAssertEqual(
            decision(SQLITE_PRAGMA, "index_info", "unknown_index"),
            SQLITE_DENY
        )
    }

    func testFailureReasonsAreFixedPathRedactedAndAuthorityFree() {
        let reasons = CodexGhostRepairSnapshotAnalysisFailureReason.allCases
        let expected: [CodexGhostRepairSnapshotAnalysisFailureReason] = [
            .freshIdentityUnavailable,
            .publishedAccessPreflightUnavailable,
            .publishedSourcePreflightUnavailable,
            .workspaceCreationUnavailable,
            .workspaceCopyUnavailable,
            .workspacePreflightUnavailable,
            .desktopOpenUnavailable,
            .summariesOpenUnavailable,
            .stateOpenUnavailable,
            .threadHistoryOpenUnavailable,
            .desktopContractUnavailable,
            .summariesContractUnavailable,
            .stateContractUnavailable,
            .threadHistoryContractUnavailable,
            .targetEvidenceUnavailable,
            .authorityEvidenceUnavailable,
            .databaseCloseUnavailable,
            .workspacePostflightUnavailable,
            .publishedSourcePostflightUnavailable,
            .workspaceCleanupUnavailable,
            .publishedAccessPostflightUnavailable,
            .publishedAccessDrift,
            .unexpected,
        ]
        let points = CodexGhostRepairSnapshotAnalysisFailurePoint.allCases
        XCTAssertEqual(reasons, expected)
        XCTAssertEqual(points.map(\.failureReason), expected)
        XCTAssertEqual(Set(reasons.map(\.rawValue)).count, reasons.count)
        for reason in reasons {
            XCTAssertTrue(reason.pathRedacted)
            XCTAssertFalse(reason.rawErrorIncluded)
            XCTAssertFalse(reason.retryAuthority)
            XCTAssertFalse(reason.repairAuthority)
            XCTAssertFalse(reason.rawValue.contains("/"))
            XCTAssertFalse(reason.rawValue.contains(".sqlite"))
        }
    }

    private func decision(
        _ action: Int32,
        _ first: String? = nil,
        _ second: String? = nil
    ) -> Int32 {
        CodexGhostRepairSnapshotAnalysisAuthorizer.decision(
            actionCode: action,
            parameterOne: first,
            parameterTwo: second
        )
    }

    private func assertUnavailable(
        _ outcome: CodexGhostRepairSnapshotAnalysisReadOutcome,
        reason expectedReason: CodexGhostRepairSnapshotAnalysisFailureReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(reason) = outcome else {
            return XCTFail("Expected unavailable", file: file, line: line)
        }
        XCTAssertEqual(reason, expectedReason, file: file, line: line)
        XCTAssertTrue(reason.pathRedacted, file: file, line: line)
        XCTAssertFalse(reason.rawErrorIncluded, file: file, line: line)
        XCTAssertFalse(reason.retryAuthority, file: file, line: line)
        XCTAssertFalse(reason.repairAuthority, file: file, line: line)
        XCTAssertFalse(reason.rawValue.contains("/"), file: file, line: line)
        XCTAssertFalse(reason.rawValue.contains(".sqlite"), file: file, line: line)
    }

    private func makeSnapshotRequest(
        runtimeVersion: String,
        targetThreadIDs: [String]
    ) throws -> CodexGhostRepairSnapshotActionRequest {
        let sorted = targetThreadIDs.sorted()
        return try CodexGhostRepairSnapshotActionRequest(
            review: CodexGhostRepairReadOnlyReview(
                targetThreadIDs: sorted,
                runtimeVersion: runtimeVersion,
                inventoryHash: "m4f28-inventory",
                observedAt: Date(timeIntervalSince1970: 1),
                protectionEvidence: [],
                snapshotProtectionEvidence: sorted.map {
                    CodexGhostRepairSnapshotProtectionEvidence(
                        threadID: $0,
                        inventoryComplete: true,
                        activeInventoryPresent: false,
                        archivedInventoryPresent: false,
                        pinned: false,
                        descendantCount: 0
                    )
                },
                exactReadbacks: [],
                executionGate: .init(
                    codexFullyExited: true,
                    desktopOpenHandleCount: 0,
                    summariesOpenHandleCount: 0,
                    historyOpenHandleCount: 0,
                    capacitySufficient: true
                )
            )
        )
    }

    private func makeFixture(
        label: String,
        desktopUserVersion: Int32 = 32,
        omitV33OwnerIndex: Bool = false,
        omitCatalogIndexes: Bool = false,
        addUnconfirmedDesktopColumn: Bool = false,
        automationStatus: String = "ACCEPTED",
        withWALSidecars: Bool = false,
        omitSharedMemoryFor: Set<CodexGhostRepairSnapshotCanonicalFile> = [],
        sourceProfile: CodexGhostRepairSnapshotSourceProfile? = nil,
        targets requestedTargets: [String]? = nil,
        useObservedAutomationRRuleDefault: Bool = true,
        manualResidue: Bool = false
    ) async throws -> Fixture {
        let fixtureTargets = requestedTargets ?? targets
        let safe = label.replacingOccurrences(
            of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression
        )
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-session-manager-m2b-\(safe)-\(UUID().uuidString)",
            isDirectory: true
        )
        let codexHome = parent.appendingPathComponent(".codex", isDirectory: true)
        let sqliteRoot = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        let appSupport = parent.appendingPathComponent(
            "Application Support", isDirectory: true
        )
        let workspaceParent = parent.appendingPathComponent(
            "Analysis Workspaces", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sqliteRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: workspaceParent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        for directory in [
            parent, codexHome, sqliteRoot, appSupport, workspaceParent,
        ] {
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
        }
        try writePrivate(
            Data(
                CodexGhostRepairSnapshotCanonicalSource
                    .testMirrorMarkerContents.utf8
            ),
            to: codexHome.appendingPathComponent(
                CodexGhostRepairSnapshotCanonicalSource.testMirrorMarkerFileName
            )
        )
        let versions: [CodexGhostRepairSnapshotCanonicalFile: Int32] = [
            .desktop: desktopUserVersion,
            .summaries: 2,
            .state: 0,
            .threadHistory: 0,
        ]
        for (file, version) in versions {
            try createSQLite(
                at: file.sourceURL(
                    codexHomeURL: codexHome,
                    sqliteRootURL: sqliteRoot
                ),
                file: file,
                userVersion: version,
                targets: fixtureTargets,
                addUnconfirmedDesktopColumn:
                    addUnconfirmedDesktopColumn,
                automationStatus: automationStatus,
                omitV33OwnerIndex: omitV33OwnerIndex,
                omitCatalogIndexes: omitCatalogIndexes,
                useObservedAutomationRRuleDefault:
                    useObservedAutomationRRuleDefault
            )
            if withWALSidecars {
                try materializeWALBundle(at: file.sourceURL(
                    codexHomeURL: codexHome,
                    sqliteRootURL: sqliteRoot
                ))
                if omitSharedMemoryFor.contains(file) {
                    try FileManager.default.removeItem(at: URL(
                        fileURLWithPath: file.sourceURL(
                            codexHomeURL: codexHome,
                            sqliteRootURL: sqliteRoot
                        ).path + "-shm"
                    ))
                }
            }
        }
        try writePrivate(
            Data(
                CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                    .testRootMarkerContents.utf8
            ),
            to: parent.appendingPathComponent(
                CodexGhostRepairDestinationCanaryInspectOnlyCoordinator
                    .testRootMarkerFileName
            )
        )
        if manualResidue {
            let desktop = try CodexGhostRepairProductionSQLite(
                url: CodexGhostRepairSnapshotCanonicalFile.desktop.sourceURL(codexHomeURL: codexHome, sqliteRootURL: sqliteRoot), readOnly: false)
            try desktop.execute("UPDATE automations SET status = 'PAUSED'")
            desktop.close()
            let summaries = try CodexGhostRepairProductionSQLite(
                url: CodexGhostRepairSnapshotCanonicalFile.summaries.sourceURL(codexHomeURL: codexHome, sqliteRootURL: sqliteRoot), readOnly: false)
            try summaries.execute("INSERT INTO thread_turn_summaries VALUES ('principal','local',?,'private-summary-content',NULL,NULL,1,1)", bindings: [.text(fixtureTargets[1])])
            summaries.close()
        }
        let entries = CodexGhostRepairDestinationCanaryFixedLayout.entries(
            applicationSupport: appSupport
        )
        for entry in entries {
            let mode: mode_t = entry.directory == .applicationBundleRoot
                ? 0o755 : 0o700
            try FileManager.default.createDirectory(
                at: entry.url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: mode)]
            )
            XCTAssertEqual(chmod(entry.url.path, mode), 0)
        }
        let locations = Dictionary(
            uniqueKeysWithValues: entries.map { ($0.directory, $0.url) }
        )
        let destination = CodexGhostRepairSnapshotPreparedDestination(
            testOwnedApplicationSupportDirectory: appSupport,
            testOwnedAllowedParentURL: parent,
            capacityProbe: M2bCapacityProbe()
        )
        let binding = try await destination.bindPrepared()
        let defaultProfile: CodexGhostRepairSnapshotSourceProfile = switch desktopUserVersion {
        case 34: .v152DesktopV34
        case 33: .v151DesktopV33
        default: .v149DesktopV32
        }
        let source = CodexGhostRepairSnapshotCanonicalSource(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: parent,
            profile: sourceProfile ?? defaultProfile
        )
        let fingerprint = try source.fingerprint()
        let journal = CodexGhostRepairSnapshotAcquisitionJournal(
            destination: destination,
            clock: { Date(timeIntervalSince1970: 1) }
        )
        return Fixture(
            source: source,
            destination: destination,
            binding: binding,
            journal: journal,
            fingerprint: fingerprint,
            snapshotsRoot: try XCTUnwrap(locations[.snapshots]),
            quarantineRoot: try XCTUnwrap(locations[.quarantine]),
            journalRoot: try XCTUnwrap(locations[.journal]),
            workspaceParent: workspaceParent,
            sourceFiles: Dictionary(uniqueKeysWithValues:
                CodexGhostRepairSnapshotCanonicalFile.allCases.map {
                ($0, $0.sourceURL(
                    codexHomeURL: codexHome,
                    sqliteRootURL: sqliteRoot
                ))
                })
        )
    }

    private struct Fixture {
        let source: CodexGhostRepairSnapshotCanonicalSource
        let destination: CodexGhostRepairSnapshotPreparedDestination
        let binding: CodexGhostRepairSnapshotPreparedDestinationBinding
        let journal: CodexGhostRepairSnapshotAcquisitionJournal
        let fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint
        let snapshotsRoot: URL
        let quarantineRoot: URL
        let journalRoot: URL
        let workspaceParent: URL
        let sourceFiles: [CodexGhostRepairSnapshotCanonicalFile: URL]

        var accessSource: CodexGhostRepairSnapshotPublishedAnalysisSource {
            .init(destination: destination, journal: journal)
        }

        func snapshotRoot(_ snapshotID: UUID) -> URL {
            snapshotsRoot.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(snapshotID),
                isDirectory: true
            )
        }

        func identity(
            snapshotID: UUID,
            targets: [String]
        ) async throws -> CodexGhostRepairSnapshotAnalysisIdentity {
            try await publish(snapshotID: snapshotID, targets: targets)
            return try await resolvedIdentity(snapshotID: snapshotID)
        }

        func resolvedIdentity(
            snapshotID: UUID
        ) async throws -> CodexGhostRepairSnapshotAnalysisIdentity {
            let recovery = recoveryReader()
            let resolver =
                CodexGhostRepairSnapshotPackagedAnalysisIdentityCoordinator(
                    reader: recovery
                )
            let outcome = await resolver.resolve(request: .init(
                snapshotReference: snapshotID.uuidString.lowercased()
            ))
            guard case let .resolved(identity) = outcome else {
                throw M2bTestError.identityUnavailable
            }
            return identity
        }

        func requestBoundPublisher(
            selection: CodexGhostRepairSnapshotRequestBoundProfileSelection
        ) -> CodexGhostRepairSnapshotRequestBoundPublisher {
            let inventory = CodexGhostRepairSnapshotPublishedInventoryCollector(
                destination: destination,
                journal: journal
            )
            return .init(
                selection: selection,
                publisher: CodexGhostRepairSnapshotQuarantinePublisher(
                    source: source,
                    destination: destination,
                    journal: journal,
                    inventory: inventory,
                    gateSource: M4f28ClearGateSource(),
                    clock: { Date(timeIntervalSince1970: 2) }
                ),
                workspaceFactory: .init(
                    testOwnedParentURL: workspaceParent
                )
            )
        }

        func quarantineSnapshotRoot(_ id: UUID) -> URL {
            quarantineRoot.appendingPathComponent(
                CodexGhostRepairSnapshotPublishedInventoryCollector
                    .snapshotDirectoryName(id),
                isDirectory: true
            )
        }

        func quarantineExists(_ id: UUID) -> Bool {
            FileManager.default.fileExists(atPath: quarantineSnapshotRoot(id).path)
        }

        func publishedExists(_ id: UUID) -> Bool {
            FileManager.default.fileExists(atPath: snapshotRoot(id).path)
        }

        func markerExists(_ id: UUID) -> Bool {
            FileManager.default.fileExists(atPath: snapshotRoot(id)
                .appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedFormat.markerFileName
                ).path)
        }

        func manifestExistsInQuarantine(_ id: UUID) -> Bool {
            FileManager.default.fileExists(atPath: quarantineSnapshotRoot(id)
                .appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedFormat.manifestFileName
                ).path)
        }

        func acquisitionRecordExists(_ id: UUID) -> Bool {
            FileManager.default.fileExists(atPath: journalRoot
                .appendingPathComponent(
                    CodexGhostRepairSnapshotAcquisitionJournal.recordPrefix
                        + id.uuidString.lowercased()
                        + CodexGhostRepairSnapshotAcquisitionJournal.recordSuffix
                ).path)
        }

        func reader() -> CodexGhostRepairSnapshotPackagedAnalysisReader {
            .init(
                identityResolver:
                    CodexGhostRepairSnapshotPackagedAnalysisIdentityCoordinator(
                        reader: recoveryReader()
                    ),
                accessResolver: accessSource,
                workspaceFactory: .init(
                    testOwnedParentURL: workspaceParent
                )
            )
        }

        func analysisWorkspaceEntries() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: workspaceParent,
                includingPropertiesForKeys: nil
            )
        }

        func recoveryReader() -> CodexGhostRepairSnapshotRecoveryReader {
            let collector = CodexGhostRepairSnapshotPublishedInventoryCollector(
                destination: destination,
                journal: journal
            )
            return CodexGhostRepairSnapshotRecoveryReader(
                destination: destination,
                journal: journal,
                publishedInventory: collector
            )
        }

        func publish(snapshotID: UUID, targets: [String]) async throws {
            let acquisition = try await journal.prepare(
                snapshotID: snapshotID,
                targetThreadIDs: targets,
                sourceFingerprint: fingerprint,
                destinationBinding: binding
            )
            let root = snapshotRoot(snapshotID)
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(root.path, 0o700) == 0 else {
                throw M2bTestError.chmodFailed
            }
            for file in fingerprint.files where file.exists {
                guard let canonical = CodexGhostRepairSnapshotCanonicalFile(
                    rawValue: file.fileName
                ), let source = sourceFiles[canonical] else {
                    throw M2bTestError.sourceUnavailable
                }
                try writePrivate(
                    Data(contentsOf: source),
                    to: root.appendingPathComponent(file.fileName)
                )
            }
            let manifest = try CodexGhostRepairSnapshotPublishedManifest(
                snapshotID: snapshotID,
                sourceFingerprint: fingerprint,
                destinationBinding: binding,
                acquiredAtMilliseconds: acquisition.preparedAtMilliseconds
            )
            try writeJSON(
                manifest,
                to: root.appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedFormat.manifestFileName
                )
            )
            let receipt = try CodexGhostRepairSnapshotPublicationReceipt(
                snapshotID: snapshotID,
                acquisitionRecordHash: acquisition.recordHash,
                manifestHash: manifest.manifestHash,
                destinationBindingHash: binding.bindingHash,
                publishedAtMilliseconds: 2_000
            )
            try writeJSON(
                receipt,
                to: journalRoot.appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedInventoryCollector
                        .publicationReceiptName(snapshotID)
                )
            )
            try writePrivate(
                Data(CodexGhostRepairSnapshotPublishedFormat.markerContents.utf8),
                to: root.appendingPathComponent(
                    CodexGhostRepairSnapshotPublishedFormat.markerFileName
                )
            )
        }

        func rawFileDigests(snapshotID: UUID) throws -> [String: String] {
            let root = snapshotRoot(snapshotID)
            return try Dictionary(uniqueKeysWithValues: fingerprint.files
                .filter(\.exists)
                .map { file in
                    let data = try Data(contentsOf: root.appendingPathComponent(
                        file.fileName
                    ))
                    let digest = SHA256.hash(data: data).map {
                        String(format: "%02x", $0)
                    }.joined()
                    return (file.fileName, digest)
                })
        }
    }
}

private actor M4f28ClearGateSource: CodexGhostRepairExecutionGateSource {
    func ghostRepairExecutionGate() async throws
        -> CodexGhostRepairExecutionGate
    {
        .init(
            codexFullyExited: true,
            desktopOpenHandleCount: 0,
            summariesOpenHandleCount: 0,
            historyOpenHandleCount: 0,
            capacitySufficient: true
        )
    }
}

private func XCTAssertM4f28Throws<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected M4f-28 operation to fail closed")
    } catch {
        handler(error)
    }
}

private actor AnalysisIdentityOutcomeFake:
    CodexGhostRepairSnapshotAnalysisIdentityCoordinator
{
    nonisolated let capabilities =
        CodexGhostRepairSnapshotAnalysisIdentityCapabilities.packagedReadOnly
    private let outcome: CodexGhostRepairSnapshotAnalysisIdentityOutcome

    init(outcome: CodexGhostRepairSnapshotAnalysisIdentityOutcome) {
        self.outcome = outcome
    }

    func resolve(request _: CodexGhostRepairSnapshotAnalysisRequest) async
        -> CodexGhostRepairSnapshotAnalysisIdentityOutcome
    {
        outcome
    }
}

private actor AnalysisAccessResolverSpy:
    CodexGhostRepairSnapshotPublishedAnalysisAccessResolving
{
    private let value:
        CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess
    private var calls = 0

    init(
        access:
            CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess
    ) {
        value = access
    }

    func access(for _: CodexGhostRepairSnapshotAnalysisIdentity) async throws
        -> CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess
    {
        calls += 1
        return value
    }

    func callCount() -> Int { calls }
}

private actor AnalysisAccessSequenceSource:
    CodexGhostRepairSnapshotPublishedAnalysisAccessResolving
{
    enum Step: Sendable {
        case value(
            CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess
        )
        case failure
    }

    private var steps: [Step]
    private var calls = 0

    init(steps: [Step]) {
        self.steps = steps
    }

    func access(for _: CodexGhostRepairSnapshotAnalysisIdentity) async throws
        -> CodexGhostRepairSnapshotPublishedInventoryCollector.AnalysisAccess
    {
        calls += 1
        guard !steps.isEmpty else {
            throw M2bTestError.sourceUnavailable
        }
        switch steps.removeFirst() {
        case let .value(value): return value
        case .failure: throw M2bTestError.sourceUnavailable
        }
    }

    func callCount() -> Int { calls }
}

private struct M2bCapacityProbe:
    CodexGhostRepairSnapshotDestinationCapacityProbing
{
    func availableCapacity(at _: URL) async throws -> UInt64 { .max }
}

private enum M2bTestError: Error {
    case chmodFailed
    case identityUnavailable
    case sourceUnavailable
    case sqlite(Int32)
}

private func createSQLite(
    at url: URL,
    file: CodexGhostRepairSnapshotCanonicalFile,
    userVersion: Int32,
    targets: [String],
    addUnconfirmedDesktopColumn: Bool,
    automationStatus: String,
    omitV33OwnerIndex: Bool,
    omitCatalogIndexes: Bool,
    useObservedAutomationRRuleDefault: Bool
) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
        nil
    )
    guard openResult == SQLITE_OK, let database else {
        if let database { sqlite3_close_v2(database) }
        throw M2bTestError.sqlite(openResult)
    }
    defer { sqlite3_close_v2(database) }
    let sql: String
    switch file {
    case .desktop:
        guard !targets.isEmpty else { throw M2bTestError.sourceUnavailable }
        let usesV33Structure = userVersion == 33 || userVersion == 34
        let v33Columns = usesV33Structure ? """
          ,kind TEXT NOT NULL DEFAULT 'cron'
          ,target_thread_id TEXT
          ,execution_environment TEXT
          ,local_environment_config_path TEXT
          ,plugin_template_id TEXT
          ,notification_policy TEXT
          ,account_id TEXT
          ,user_id TEXT
          ,installation_id TEXT
          ,legacy_automation_id TEXT
        """ : ""
        let v33Index = usesV33Structure && !omitV33OwnerIndex
            ? "CREATE INDEX automations_owner_idx ON automations (account_id, user_id, installation_id);"
            : ""
        let catalogIndexes = omitCatalogIndexes ? "" : """
        CREATE INDEX local_thread_catalog_created_idx
          ON local_thread_catalog (
            host_id, source_created_at DESC, source_updated_at DESC, thread_id
          ) WHERE missing_candidate = 0;
        CREATE INDEX local_thread_catalog_cwd_created_idx
          ON local_thread_catalog (
            host_id, cwd, source_created_at DESC, source_updated_at DESC,
            thread_id
          ) WHERE missing_candidate = 0;
        CREATE INDEX local_thread_catalog_cwd_updated_idx
          ON local_thread_catalog (
            host_id, cwd, source_recency_at DESC, source_created_at DESC,
            thread_id
          ) WHERE missing_candidate = 0;
        CREATE INDEX local_thread_catalog_origin_updated_idx
          ON local_thread_catalog (
            host_id, conversation_origin, source_recency_at DESC,
            source_created_at DESC, thread_id
          ) WHERE missing_candidate = 0;
        CREATE INDEX local_thread_catalog_project_updated_idx
          ON local_thread_catalog (
            host_id, project_id, source_recency_at DESC,
            source_created_at DESC, thread_id
          ) WHERE missing_candidate = 0;
        CREATE INDEX local_thread_catalog_thread_lookup_idx
          ON local_thread_catalog (
            thread_id, source_recency_at DESC, source_created_at DESC, host_id
          ) WHERE missing_candidate = 0;
        CREATE INDEX local_thread_catalog_updated_idx
          ON local_thread_catalog (
            host_id, source_recency_at DESC, source_created_at DESC, thread_id
          ) WHERE missing_candidate = 0;
        """
        let rruleColumn = useObservedAutomationRRuleDefault
            ? "rrule TEXT NOT NULL DEFAULT 'FREQ=HOURLY;INTERVAL=24;BYMINUTE=0'"
            : "rrule TEXT NOT NULL"
        let catalogRows = targets.enumerated().map { index, target in
            "('local','\(target)','private \(index)',\(index + 1),\(index + 2),'/private/\(index)','codex',NULL,'openai',NULL,\(index + 10),0,NULL,\(index + 2),0,NULL,NULL)"
        }.joined(separator: ",\n          ")
        let automationTargets = targets.enumerated().filter {
            $0.offset.isMultiple(of: 2) == false
        }
        let automationRunRows = automationTargets.map { index, target in
            "('\(target)','automation-\(index)','\(automationStatus)',NULL,'private run','/private/\(index)','private inbox','private summary',5,6,NULL,NULL,NULL)"
        }.joined(separator: ",\n          ")
        let automationRows = automationTargets.map { index, _ in
            let v33Values = usesV33Structure
                ? ",'cron',NULL,NULL,NULL,NULL,NULL,'account-\(index)','user','installation',NULL"
                : ""
            return "('automation-\(index)','private name','private prompt','ACTIVE',NULL,NULL,'[]','FREQ=DAILY',NULL,NULL,7,8,NULL,NULL\(v33Values))"
        }.joined(separator: ",\n          ")
        let automationInserts = automationTargets.isEmpty ? "" : """
        INSERT INTO automation_runs VALUES
          \(automationRunRows);
        INSERT INTO automations VALUES
          \(automationRows);
        """
        sql = """
        PRAGMA user_version=\(userVersion);
        PRAGMA foreign_keys=ON;
        CREATE TABLE local_thread_catalog (
          host_id TEXT NOT NULL,
          thread_id TEXT NOT NULL,
          display_title TEXT NOT NULL,
          source_created_at REAL NOT NULL,
          source_updated_at REAL NOT NULL,
          cwd TEXT,
          source_kind TEXT NOT NULL,
          source_detail TEXT,
          model_provider TEXT,
          git_branch TEXT,
          observation_sequence INTEGER NOT NULL,
          missing_candidate INTEGER NOT NULL DEFAULT 0,
          thread_source TEXT,
          source_recency_at REAL NOT NULL DEFAULT 0,
          pending_observed_title INTEGER NOT NULL DEFAULT 0,
          project_id TEXT,
          conversation_origin TEXT,
          PRIMARY KEY (host_id, thread_id)
        );
        \(catalogIndexes)
        CREATE TABLE automation_runs (
          thread_id TEXT PRIMARY KEY,
          automation_id TEXT NOT NULL,
          status TEXT NOT NULL,
          read_at INTEGER,
          thread_title TEXT,
          source_cwd TEXT,
          inbox_title TEXT,
          inbox_summary TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          archived_user_message TEXT,
          archived_assistant_message TEXT,
          archived_reason TEXT
        );
        CREATE TABLE automations (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          prompt TEXT NOT NULL,
          status TEXT NOT NULL DEFAULT 'ACTIVE',
          next_run_at INTEGER,
          last_run_at INTEGER,
          cwds TEXT NOT NULL DEFAULT '[]',
          \(rruleColumn),
          model TEXT,
          reasoning_effort TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          target_type TEXT,
          project_id TEXT
          \(v33Columns)
        );
        \(v33Index)
        CREATE TABLE inbox_items (
          id TEXT PRIMARY KEY,
          title TEXT,
          description TEXT,
          thread_id TEXT,
          read_at INTEGER,
          created_at INTEGER
        );
        CREATE TABLE thread_timeline_ledger (
          host_id TEXT NOT NULL,
          thread_id TEXT NOT NULL,
          sequence INTEGER NOT NULL,
          record_id TEXT NOT NULL,
          payload_json TEXT NOT NULL,
          PRIMARY KEY (host_id, thread_id, sequence),
          UNIQUE (host_id, thread_id, record_id)
        ) WITHOUT ROWID;
        CREATE TABLE local_thread_catalog_metadata (
          id INTEGER PRIMARY KEY,
          catalog_revision INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE local_thread_catalog_sync_state (
          host_id TEXT PRIMARY KEY,
          watermark_updated_at REAL,
          initial_build_complete INTEGER NOT NULL DEFAULT 0,
          observation_sequence INTEGER NOT NULL DEFAULT 0,
          last_full_reconciled_at INTEGER
        );
        INSERT INTO local_thread_catalog VALUES
          \(catalogRows);
        \(automationInserts)
        INSERT INTO local_thread_catalog_metadata VALUES (1,100);
        INSERT INTO local_thread_catalog_sync_state VALUES
          ('local',300,1,200,400);
        \(addUnconfirmedDesktopColumn
            ? "ALTER TABLE local_thread_catalog ADD COLUMN unconfirmed_private_value TEXT;"
            : "")
        """
    case .summaries:
        sql = """
        PRAGMA user_version=\(userVersion);
        PRAGMA foreign_keys=ON;
        CREATE TABLE thread_turn_summaries (
          principal_key TEXT NOT NULL,
          host_key TEXT NOT NULL,
          thread_id TEXT NOT NULL,
          summary TEXT NOT NULL,
          compact_summary TEXT,
          compact_summary_turn_key TEXT,
          revision INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          PRIMARY KEY (principal_key, host_key, thread_id)
        );
        """
    case .state:
        sql = """
        PRAGMA user_version=\(userVersion);
        PRAGMA foreign_keys=ON;
        CREATE TABLE threads (id TEXT PRIMARY KEY);
        """
    case .threadHistory:
        sql = """
        PRAGMA user_version=\(userVersion);
        PRAGMA foreign_keys=ON;
        CREATE TABLE thread_turns (
          thread_id TEXT NOT NULL,
          turn_id TEXT NOT NULL,
          rollout_ordinal INTEGER NOT NULL,
          status TEXT NOT NULL,
          error_json TEXT,
          started_at INTEGER,
          completed_at INTEGER,
          duration_ms INTEGER,
          first_user_item_id TEXT,
          final_agent_item_id TEXT,
          rollout_byte_offset INTEGER,
          rollout_end_ordinal INTEGER,
          rollout_end_byte_offset INTEGER,
          PRIMARY KEY (thread_id, turn_id)
        );
        CREATE TABLE thread_items (
          thread_id TEXT NOT NULL,
          turn_id TEXT NOT NULL,
          item_id TEXT NOT NULL,
          rollout_ordinal INTEGER NOT NULL,
          created_at_ms INTEGER NOT NULL,
          item_json TEXT NOT NULL,
          item_type TEXT NOT NULL DEFAULT '',
          updated_at_ordinal INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (thread_id, turn_id, item_id)
        );
        CREATE TABLE thread_history_projection_state (
          thread_id TEXT PRIMARY KEY,
          next_rollout_byte_offset INTEGER NOT NULL,
          next_rollout_ordinal INTEGER NOT NULL
        );
        """
    default:
        throw M2bTestError.sourceUnavailable
    }
    let result = sqlite3_exec(database, sql, nil, nil, nil)
    guard result == SQLITE_OK else { throw M2bTestError.sqlite(result) }
    guard chmod(url.path, 0o600) == 0 else {
        throw M2bTestError.chmodFailed
    }
}

private func materializeWALBundle(at url: URL) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READWRITE,
        nil
    )
    guard openResult == SQLITE_OK, let database else {
        if let database { sqlite3_close_v2(database) }
        throw M2bTestError.sqlite(openResult)
    }
    let sql = """
    PRAGMA journal_mode=WAL;
    PRAGMA wal_autocheckpoint=0;
    CREATE TABLE m2n_wal_fixture (value TEXT NOT NULL);
    INSERT INTO m2n_wal_fixture VALUES ('working-copy-only');
    """
    let result = sqlite3_exec(database, sql, nil, nil, nil)
    guard result == SQLITE_OK else {
        sqlite3_close_v2(database)
        throw M2bTestError.sqlite(result)
    }
    let walURL = URL(fileURLWithPath: url.path + "-wal")
    let shmURL = URL(fileURLWithPath: url.path + "-shm")
    let main = try Data(contentsOf: url)
    let wal = try Data(contentsOf: walURL)
    let shm = try Data(contentsOf: shmURL)
    let closeResult = sqlite3_close_v2(database)
    guard closeResult == SQLITE_OK else {
        throw M2bTestError.sqlite(closeResult)
    }
    for (data, destination) in [
        (main, url), (wal, walURL), (shm, shmURL),
    ] {
        try data.write(to: destination, options: .atomic)
        guard chmod(destination.path, 0o600) == 0 else {
            throw M2bTestError.chmodFailed
        }
    }
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try writePrivate(try encoder.encode(value), to: url)
}

private func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .withoutOverwriting)
    guard chmod(url.path, 0o600) == 0 else {
        throw M2bTestError.chmodFailed
    }
}
