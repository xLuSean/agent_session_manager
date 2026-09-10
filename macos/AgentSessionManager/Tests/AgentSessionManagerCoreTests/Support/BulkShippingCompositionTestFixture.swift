@testable import AgentSessionManagerCore
import CSQLite3
import Darwin
import Foundation
import XCTest

enum BulkShippingCompositionTestFixture {
    struct Value {
        let parent: URL
        let codexHome: URL
        let source: CodexGhostRepairSnapshotCanonicalSource
        let profile: CodexGhostRepairSnapshotSourceProfile
        let bundle: CodexGhostRepairProductionRepairBundle
        let desktopURL: URL
        let stateURL: URL
        let managerStateURL: URL
        let inventory: CodexGhostRepairBulkInventory
        let storedPreview: CodexGhostRepairBulkStoredPreview
        let bulkResolution: CodexGhostRepairBulkProductionBundle.Resolution
        let preBackupMaintenance: CodexGhostRepairBulkMaintenanceEvidence
        let postBackupMaintenance: CodexGhostRepairBulkMaintenanceEvidence
        let draft: CodexGhostRepairBulkProductionExecutionDraft
#if AGENT_SESSION_MANAGER_RESEARCH
        let claim: CodexGhostRepairBulkProductionClaim
        let attempt: CodexGhostRepairBulkProductionAttempt
#endif
        let livePlan: CodexGhostRepairBulkBackupBoundOperationPlan
        let confirmationReceipt: CodexGhostRepairBulkConfirmationReceipt
        let liveClaim: CodexGhostRepairBulkLiveMixedClaim
        let liveAttempt: CodexGhostRepairBulkLiveMixedAttempt

        func liveCoordinator(
            fault: CodexGhostRepairBulkLiveOneShotFault = .none
        ) -> CodexGhostRepairBulkLiveOneShotCoordinator {
            let journal = CodexGhostRepairBulkLivePackagedExecutionJournal {
                try SQLiteStateStore(databaseURL: managerStateURL)
            }
            return CodexGhostRepairBulkLiveOneShotCoordinator(
                journal: journal,
                mutator: liveMutator(),
                nowMilliseconds: { 1_600 },
                makeUUID: {
                    UUID(uuidString: "91000000-0000-4000-8000-000000000001")!
                },
                fault: fault
            )
        }

        func liveMutator(
            fault: CodexGhostRepairBulkLiveMixedMutationFault = .none,
            backupFails: Bool = false
        ) -> CodexGhostRepairBulkLiveMixedMutator {
            CodexGhostRepairBulkLiveMixedMutator(
                testOwnedCodexHomeURL: codexHome,
                testOwnedAllowedParentURL: parent,
                profile: profile,
                gateSource: AlwaysClearBulkRepairGate(),
                backupReader: FixedBulkLiveBackupReadback(
                    value: livePlan.backup,
                    fails: backupFails
                ),
                fault: fault
            )
        }

#if AGENT_SESSION_MANAGER_RESEARCH
        func mutator(
            fault: CodexGhostRepairBulkProductionMutationFault = .none
        ) throws -> CodexGhostRepairBulkProductionMutator {
            try .init(
                bundle: bundle,
                source: source,
                gateSource: AlwaysClearBulkRepairGate(),
                backupResolver: FixedBulkBackupReadback(value: draft.backup),
                fault: fault
            )
        }

        func composition() throws
            -> CodexGhostRepairBulkProductionComposition
        {
            let backup = FixedBulkBackupReadback(value: draft.backup)
            let journal = CodexGhostRepairBulkPackagedExecutionJournal {
                try SQLiteStateStore(databaseURL: managerStateURL)
            }
            return try CodexGhostRepairBulkProductionComposition(
                planCollector: FixedBulkPlanCollector(value: draft.plan),
                maintenanceCollector: FixedBulkMaintenanceCollector(
                    before: preBackupMaintenance,
                    after: postBackupMaintenance
                ),
                backupTransport: backup,
                journal: journal,
                source: source,
                databaseBundle: bundle,
                gateSource: AlwaysClearBulkRepairGate(),
                nowMilliseconds: { 1_600 },
                makeUUID: {
                    UUID(uuidString: "90000000-0000-4000-8000-000000000001")!
                }
            )
        }
#endif
    }

    static func make(
        itemCount: Int,
        desktopSchema: Int32 = 32,
        alreadyAbsentIndices: Set<Int> = [],
        initiallyAbsentIndices: Set<Int> = [],
        profile: CodexGhostRepairSnapshotSourceProfile = .v149DesktopV32,
        runtimeVersion: String = "0.149.0",
        reviewedResidue: Bool = false
    ) throws -> Value {
        precondition(alreadyAbsentIndices.allSatisfy((0..<itemCount).contains))
        precondition(initiallyAbsentIndices.allSatisfy { (0..<itemCount).contains($0) && $0.isMultiple(of: 2) })
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bulk-production-mutator-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let codexHome = parent.appendingPathComponent("source/.codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexHome, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(#"{"pinned-thread-ids":[]}"#.utf8).write(
            to: codexHome.appendingPathComponent(".codex-global-state.json")
        )
        let sqliteRoot = codexHome.appendingPathComponent("sqlite", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sqliteRoot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let marker = codexHome.appendingPathComponent(
            CodexGhostRepairSnapshotCanonicalSource.testMirrorMarkerFileName
        )
        try Data(
            CodexGhostRepairSnapshotCanonicalSource.testMirrorMarkerContents.utf8
        ).write(to: marker)
        XCTAssertEqual(chmod(marker.path, 0o600), 0)

        let desktopURL = CodexGhostRepairSnapshotCanonicalFile.desktop.sourceURL(
            codexHomeURL: codexHome, sqliteRootURL: sqliteRoot
        )
        let summariesURL = CodexGhostRepairSnapshotCanonicalFile.summaries.sourceURL(
            codexHomeURL: codexHome, sqliteRootURL: sqliteRoot
        )
        let stateURL = CodexGhostRepairSnapshotCanonicalFile.state.sourceURL(
            codexHomeURL: codexHome, sqliteRootURL: sqliteRoot
        )
        let threadHistoryURL = CodexGhostRepairSnapshotCanonicalFile.threadHistory.sourceURL(
            codexHomeURL: codexHome, sqliteRootURL: sqliteRoot
        )
        let legacyURL = CodexGhostRepairSnapshotCanonicalFile.history.sourceURL(
            codexHomeURL: codexHome, sqliteRootURL: sqliteRoot
        )
        try createDesktop(
            at: desktopURL,
            itemCount: itemCount,
            schema: desktopSchema
        )
        try createSideDatabase(
            at: summariesURL, schema: 2,
            tables: [reviewedResidue
                ? "CREATE TABLE thread_turn_summaries(principal_key TEXT, host_key TEXT, thread_id TEXT, summary TEXT)"
                : "CREATE TABLE thread_turn_summaries(thread_id TEXT)"]
        )
        try createSideDatabase(
            at: stateURL, schema: 0,
            tables: [
                "CREATE TABLE threads(id TEXT)",
                "CREATE TABLE sentinel(id INTEGER PRIMARY KEY, value TEXT)",
                "INSERT INTO sentinel VALUES(1, 'stable')",
            ]
        )
        try createSideDatabase(
            at: threadHistoryURL, schema: 0,
            tables: [
                "CREATE TABLE thread_turns(thread_id TEXT)",
                "CREATE TABLE thread_items(thread_id TEXT)",
                "CREATE TABLE thread_history_projection_state(thread_id TEXT)",
            ]
        )
        try createSideDatabase(
            at: legacyURL, schema: 0,
            tables: ["CREATE TABLE legacy_sentinel(id INTEGER)"]
        )
        for url in [desktopURL, summariesURL, stateURL, threadHistoryURL, legacyURL] {
            XCTAssertEqual(chmod(url.path, 0o644), 0)
        }

        let source = CodexGhostRepairSnapshotCanonicalSource(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: parent,
            profile: profile
        )
        let bundle = CodexGhostRepairProductionRepairBundle(
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: parent
        )
        let fingerprint = try source.fingerprint()
        let frozen = try frozenInput(
            itemCount: itemCount,
            fingerprint: fingerprint,
            desktopURL: desktopURL,
            desktopSchema: desktopSchema,
            profile: profile
        )
        var inventory = try CodexGhostRepairBulkInventoryBuilder.build(input: frozen)
        let preview = try CodexGhostRepairBulkPreviewBuilder.build(
            inventory: inventory,
            selectedThreadIDs: inventory.eligibleThreadIDs,
            previewID: UUID(),
            generatedAtMilliseconds: 1_000,
            expiresAtMilliseconds: 10_000
        )
        let managerStateURL = parent.appendingPathComponent(
            "manager-state.sqlite"
        )
        let managerStore = try SQLiteStateStore(databaseURL: managerStateURL)
        let savedPreviewRequestID = UUID()
        var storedPreview = try managerStore.saveCodexGhostRepairBulkPreview(
            requestID: savedPreviewRequestID,
            preview: preview,
            inventory: inventory
        )
        let challenge = try managerStore.prepareCodexGhostRepairBulkChallenge(
            savedPreviewRequestID: savedPreviewRequestID,
            generatedAtMilliseconds: 1_100
        )
        var receipt = try managerStore.consumeCodexGhostRepairBulkConfirmation(
            savedPreviewRequestID: savedPreviewRequestID,
            exactConfirmationPhrase: challenge.confirmationPhrase,
            confirmedAtMilliseconds: 1_200
        ).receipt
        managerStore.close()
        let plan = try CodexGhostRepairBulkExecutionPlan.prepare(
            operationID: challenge.operationID,
            preview: preview,
            challenge: challenge,
            receipt: receipt,
            frozenInventoryInput: frozen,
            plannedAtMilliseconds: 1_300
        )
        let maintenance = try CodexGhostRepairBulkMaintenanceEvidence(
            runtimeVersion: runtimeVersion,
            executionGate: AlwaysClearBulkRepairGate.gate,
            sourceFingerprintHash: fingerprint.fingerprintHash,
            authorityDigest: hash(6),
            observedAtMilliseconds: 1_350
        )
        let backup = try CodexGhostRepairBulkExecutionBackupReceipt(
            operationID: plan.operationID,
            planDigest: plan.planDigest,
            selectedThreadIDs: plan.selectedThreadIDs,
            sourceFingerprintHash: fingerprint.fingerprintHash,
            files: fingerprint.files.map {
                .init(
                    fileName: $0.fileName,
                    present: $0.exists,
                    byteCount: $0.size,
                    contentHash: $0.sha256
                )
            },
            capturedAtMilliseconds: 1_400
        )
        let post = try CodexGhostRepairBulkMaintenanceEvidence(
            runtimeVersion: runtimeVersion,
            executionGate: AlwaysClearBulkRepairGate.gate,
            sourceFingerprintHash: fingerprint.fingerprintHash,
            authorityDigest: hash(6),
            observedAtMilliseconds: 1_450
        )
        let draft = try CodexGhostRepairBulkProductionExecutionDraft.prepare(
            plan: plan, preBackupMaintenance: maintenance, backup: backup,
            postBackupMaintenance: post, preparedAtMilliseconds: 1_500
        )
#if AGENT_SESSION_MANAGER_RESEARCH
        let claim = try CodexGhostRepairBulkProductionClaim(
            claimID: UUID(), draft: draft, claimedAtMilliseconds: 1_600
        )
        let attempt = try CodexGhostRepairBulkProductionAttempt(
            claim: claim, attemptedAtMilliseconds: 1_700
        )
#endif

        let absentIndices = alreadyAbsentIndices.union(initiallyAbsentIndices)
        for index in absentIndices.sorted() {
            try execute(
                "DELETE FROM local_thread_catalog WHERE thread_id = '"
                    + "\(identifier(index))'",
                at: desktopURL
            )
        }
        if !absentIndices.isEmpty {
            try execute(
                "UPDATE local_thread_catalog_metadata "
                    + "SET catalog_revision = catalog_revision "
                    + "+ \(absentIndices.count) WHERE id = 1",
                at: desktopURL
            )
            try execute(
                "UPDATE local_thread_catalog_sync_state "
                    + "SET observation_sequence = observation_sequence "
                    + "+ \(absentIndices.count) WHERE host_id = 'local'",
                at: desktopURL
            )
        }

        if !initiallyAbsentIndices.isEmpty {
            // This deliberately minimal mutation fixture is not an admitted
            // full Desktop schema. Re-read its exact test-owned rows; complete
            // schema/copy admission is covered by SnapshotAnalysisReaderTests.
            let freshInput = try frozenInput(
                itemCount: itemCount, fingerprint: source.fingerprint(),
                desktopURL: desktopURL, desktopSchema: desktopSchema, profile: profile,
                initiallyAbsentIndices: initiallyAbsentIndices,
                initialCounterIncrement: absentIndices.count
            )
            inventory = try CodexGhostRepairBulkInventoryBuilder.build(input: freshInput)
            let freshPreview = try CodexGhostRepairBulkPreviewFactory.buildAuthorityFree(
                inventory: inventory, selectedThreadIDs: frozen.targets.map(\.threadID),
                generatedAtMilliseconds: 1_000, lifetimeMilliseconds: 9_000
            )
            let freshStore = try SQLiteStateStore(databaseURL: managerStateURL)
            defer { freshStore.close() }
            let freshRequestID = UUID()
            storedPreview = try freshStore.saveCodexGhostRepairBulkPreview(
                requestID: freshRequestID, preview: freshPreview, inventory: inventory
            )
            let freshChallenge = try freshStore.prepareCodexGhostRepairBulkChallenge(
                savedPreviewRequestID: freshRequestID, generatedAtMilliseconds: 1_100
            )
            receipt = try freshStore.consumeCodexGhostRepairBulkConfirmation(
                savedPreviewRequestID: freshRequestID, exactConfirmationPhrase: freshChallenge.confirmationPhrase,
                confirmedAtMilliseconds: 1_200
            ).receipt
            XCTAssertEqual(try freshStore.codexGhostRepairBulkPreview(requestID: freshRequestID), storedPreview)
        }

        if reviewedResidue {
            precondition(itemCount == 2 && absentIndices.isEmpty)
            try execute("UPDATE automations SET status = 'PAUSED' WHERE id = 'automation-1'", at: desktopURL)
            for index in 0...2 {
                try execute("INSERT INTO thread_turn_summaries VALUES ('principal','local','\(identifier(index))','summary-\(index)')", at: summariesURL)
            }
            let base = try frozenInput(itemCount: itemCount, fingerprint: source.fingerprint(),
                                       desktopURL: desktopURL, desktopSchema: desktopSchema, profile: profile)
            let summaryDB = try CodexGhostRepairProductionSQLite(url: summariesURL, readOnly: true)
            defer { summaryDB.close() }
            let targets = try base.targets.enumerated().map { index, target in
                var value = CodexGhostRepairSnapshotAnalysisTargetEvidence(
                    threadID: target.threadID, catalogRowDigests: target.catalogRowDigests,
                    automationRunRowDigests: target.automationRunRowDigests,
                    automationStableFieldsDigests: target.automationStableFieldsDigests,
                    automationDefinitionRowDigests: target.automationDefinitionRowDigests,
                    references: .init(inbox: 0, timeline: 0, summaries: 1, canonicalState: 0,
                                      threadTurns: 0, threadItems: 0, historyProjection: 0),
                    rowContract: index == 1 ? .unsupported : .categoryAEligible
                )
                value.summaryRowDigests = try summaryDB.query(
                    "SELECT * FROM thread_turn_summaries WHERE thread_id = ? ORDER BY principal_key, host_key",
                    bindings: [.text(target.threadID)], maximumRows: 100
                ).map { try CodexGhostRepairHasher.hash($0) }.sorted()
                value.pausedAutomationReviewable = index == 1 ? true : nil
                return value
            }
            let input = CodexGhostRepairBulkInventoryInput(
                snapshotReference: base.snapshotReference, sourceLayoutIdentifier: base.sourceLayoutIdentifier,
                sourceFingerprintHash: base.sourceFingerprintHash, manifestHash: base.manifestHash,
                databases: base.databases, targets: targets, protectionEvidence: base.protectionEvidence,
                authority: base.authority
            )
            let ordinaryScan = try CodexGhostRepairBulkInventoryBuilder.build(input: input)
            XCTAssertEqual(ordinaryScan.eligibleItemCount, 0)
            inventory = try ordinaryScan.reviewingKnownResidue(true)
            XCTAssertEqual(inventory.eligibleItemCount, 2)
            let reviewedPreview = try CodexGhostRepairBulkPreviewFactory.buildAuthorityFree(
                inventory: inventory, selectedThreadIDs: inventory.eligibleThreadIDs,
                generatedAtMilliseconds: 1_000, lifetimeMilliseconds: 9_000
            )
            let store = try SQLiteStateStore(databaseURL: managerStateURL)
            defer { store.close() }
            let request = UUID()
            storedPreview = try store.saveCodexGhostRepairBulkPreview(requestID: request, preview: reviewedPreview, inventory: inventory)
            let challenge = try store.prepareCodexGhostRepairBulkChallenge(savedPreviewRequestID: request, generatedAtMilliseconds: 1_100)
            receipt = try store.consumeCodexGhostRepairBulkConfirmation(savedPreviewRequestID: request,
                exactConfirmationPhrase: challenge.confirmationPhrase, confirmedAtMilliseconds: 1_200).receipt
            XCTAssertEqual(try store.codexGhostRepairBulkPreview(requestID: request), storedPreview)
        }

        let resolution = try CodexGhostRepairBulkProductionBundle(
            coldReadback: storedPreview,
            testOwnedCodexHomeURL: codexHome,
            testOwnedAllowedParentURL: parent
        ).resolveForTestOwnedAdoption()
        let liveFingerprint = try source.fingerprint()
        let liveMaintenance = try CodexGhostRepairBulkMaintenanceEvidence(
            runtimeVersion: runtimeVersion,
            executionGate: AlwaysClearBulkRepairGate.gate,
            sourceFingerprintHash: liveFingerprint.fingerprintHash,
            authorityDigest: hash(6),
            observedAtMilliseconds: 1_350
        )
        let livePost = try CodexGhostRepairBulkMaintenanceEvidence(
            runtimeVersion: runtimeVersion,
            executionGate: AlwaysClearBulkRepairGate.gate,
            sourceFingerprintHash: liveFingerprint.fingerprintHash,
            authorityDigest: hash(6),
            observedAtMilliseconds: 1_450
        )
        let beforeReadback = try CodexGhostRepairBulkFreshMaintenanceReadback(
            collectionID: UUID(), phase: .beforeBackup,
            resolution: resolution, maintenance: liveMaintenance
        )
        let afterReadback = try CodexGhostRepairBulkFreshMaintenanceReadback(
            collectionID: UUID(), phase: .afterBackup,
            resolution: resolution, maintenance: livePost
        )
        let window = try CodexGhostRepairBulkMaintenanceWindow(
            before: beforeReadback, after: afterReadback
        )
        let destination = try CodexGhostRepairBulkFixedBackupDestinationRecord(
            resolution: resolution,
            maintenanceWindow: window,
            storageRootDigest: hash(900_001)
        )
        let liveBackup = try CodexGhostRepairBulkLiveBackupReceipt(
            destination: destination,
            sourceFingerprint: liveFingerprint,
            capturedAtMilliseconds: 1_400
        )
        let frozenSource = try XCTUnwrap(storedPreview.frozenSource)
        let observed = try CodexGhostRepairBulkLiveMixedMutator.inspect(
            selectedItems: frozenSource.selectedItems.map {
                CodexGhostRepairBulkBackupBoundOperationItem(frozen: $0)
            },
            resolution: bundle.resolveForPreflight()
        )
        let alreadyAbsentThreadIDs = absentIndices.sorted().map(
            identifier
        )
        let liveRevalidation = try CodexGhostRepairBulkLiveTargetRevalidation(
            source: frozenSource,
            backup: liveBackup,
            databaseEvidence: observed.databases,
            authority: observed.authority,
            alreadyAbsentThreadIDs: alreadyAbsentThreadIDs,
            observedAtMilliseconds: 1_500
        )
        let livePlan = try CodexGhostRepairBulkBackupBoundOperationPlan.prepare(
            coldReadback: storedPreview,
            resolution: resolution,
            destination: destination,
            verifiedBackup: liveBackup,
            liveRevalidation: liveRevalidation,
            plannedAtMilliseconds: 1_500
        )
        let liveClaim = try CodexGhostRepairBulkLiveMixedClaim(
            claimID: UUID(), plan: livePlan, claimedAtMilliseconds: 1_600
        )
        let liveAttempt = try CodexGhostRepairBulkLiveMixedAttempt(
            claim: liveClaim, attemptedAtMilliseconds: 1_700
        )
#if AGENT_SESSION_MANAGER_RESEARCH
        return .init(
            parent: parent, codexHome: codexHome,
            source: source, profile: profile, bundle: bundle,
            desktopURL: desktopURL, stateURL: stateURL,
            managerStateURL: managerStateURL,
            inventory: inventory,
            storedPreview: storedPreview,
            bulkResolution: resolution,
            preBackupMaintenance: maintenance,
            postBackupMaintenance: post,
            draft: draft,
            claim: claim, attempt: attempt,
            livePlan: livePlan, confirmationReceipt: receipt,
            liveClaim: liveClaim,
            liveAttempt: liveAttempt
        )
#else
        return .init(
            parent: parent, codexHome: codexHome,
            source: source, profile: profile, bundle: bundle,
            desktopURL: desktopURL, stateURL: stateURL,
            managerStateURL: managerStateURL,
            inventory: inventory,
            storedPreview: storedPreview,
            bulkResolution: resolution,
            preBackupMaintenance: maintenance,
            postBackupMaintenance: post,
            draft: draft,
            livePlan: livePlan, confirmationReceipt: receipt,
            liveClaim: liveClaim,
            liveAttempt: liveAttempt
        )
#endif
    }

    static func frozenInput(
        itemCount: Int,
        fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint,
        desktopURL: URL,
        desktopSchema: Int32,
        profile: CodexGhostRepairSnapshotSourceProfile,
        initiallyAbsentIndices: Set<Int> = [],
        initialCounterIncrement: Int = 0
    ) throws -> CodexGhostRepairBulkInventoryInput {
        let database = try CodexGhostRepairProductionSQLite(
            url: desktopURL, readOnly: true
        )
        defer { database.close() }
        let metadata = try database.query(
            "SELECT * FROM local_thread_catalog_metadata WHERE id = 1",
            maximumRows: 1
        )[0].privacyPreserving(
            cleartextFields: CodexGhostRepairPrivacyContract.metadata
        )
        let sync = try database.query(
            "SELECT * FROM local_thread_catalog_sync_state WHERE host_id = 'local'",
            maximumRows: 1
        )[0].privacyPreserving(
            cleartextFields: CodexGhostRepairPrivacyContract.localSync
        )
        let targets = try (0..<itemCount).map { index in
            let threadID = identifier(index)
            let catalogRows = try database.query(
                "SELECT * FROM local_thread_catalog WHERE thread_id = ?",
                bindings: [.text(threadID)], maximumRows: 1
            )
            if initiallyAbsentIndices.contains(index) {
                XCTAssertTrue(catalogRows.isEmpty)
                return CodexGhostRepairSnapshotAnalysisTargetEvidence(
                    threadID: threadID, catalogRowDigests: [], automationRunRowDigests: [],
                    automationStableFieldsDigests: [], automationDefinitionRowDigests: [],
                    references: .init(inbox: 0, timeline: 0, summaries: 0, canonicalState: 0,
                                      threadTurns: 0, threadItems: 0, historyProjection: 0),
                    rowContract: .unsupported
                )
            }
            let catalog = try XCTUnwrap(catalogRows.first)
            if index.isMultiple(of: 2) {
                return CodexGhostRepairSnapshotAnalysisTargetEvidence(
                    threadID: threadID,
                    catalogRowDigests: [
                        try CodexGhostRepairBulkTargetEvidenceContract
                            .catalogAuthorizationDigest(catalog)
                    ],
                    automationRunRowDigests: [],
                    automationStableFieldsDigests: [],
                    automationDefinitionRowDigests: [],
                    references: .init(
                        inbox: 0, timeline: 0, summaries: 0,
                        canonicalState: 0, threadTurns: 0,
                        threadItems: 0, historyProjection: 0
                    ),
                    rowContract: .categoryAEligible
                )
            }
            let run = try database.query(
                "SELECT * FROM automation_runs WHERE thread_id = ?",
                bindings: [.text(threadID)], maximumRows: 1
            )[0]
            let definition = try database.query(
                "SELECT * FROM automations WHERE id = ?",
                bindings: [.text("automation-\(index)")], maximumRows: 1
            )[0]
            return CodexGhostRepairSnapshotAnalysisTargetEvidence(
                threadID: threadID,
                catalogRowDigests: [
                    try CodexGhostRepairBulkTargetEvidenceContract
                        .catalogAuthorizationDigest(catalog)
                ],
                automationRunRowDigests: [try CodexGhostRepairHasher.hash(run)],
                automationStableFieldsDigests: [
                    try CodexGhostRepairBulkTargetEvidenceContract
                        .automationIdentityDigest(run)
                ],
                automationDefinitionRowDigests: [
                    try CodexGhostRepairBulkTargetEvidenceContract
                        .automationDefinitionAuthorizationDigest(definition)
                ],
                references: .init(
                    inbox: 0, timeline: 0, summaries: 0,
                    canonicalState: 0, threadTurns: 0,
                    threadItems: 0, historyProjection: 0
                ),
                rowContract: .categoryBEligible
            )
        }
        return .init(
            snapshotReference: UUID().uuidString.lowercased(),
            sourceLayoutIdentifier: profile.identifier,
            sourceFingerprintHash: fingerprint.fingerprintHash,
            manifestHash: hash(4),
            databases: [
                .init(database: .desktop, schemaVersion: desktopSchema,
                      integrityCheckPassed: true, foreignKeyViolationCount: 0),
                .init(database: .summaries, schemaVersion: 2,
                      integrityCheckPassed: true, foreignKeyViolationCount: 0),
                .init(database: .state, schemaVersion: 0,
                      integrityCheckPassed: true, foreignKeyViolationCount: 0),
                .init(database: .threadHistory, schemaVersion: 0,
                      integrityCheckPassed: true, foreignKeyViolationCount: 0),
            ],
            targets: targets,
            protectionEvidence: targets.map {
                .init(
                    threadID: $0.threadID, inventoryComplete: true,
                    activeInventoryPresent: false,
                    archivedInventoryPresent: false,
                    exactReadNotLoaded: true, exactReadErrorCode: -32600,
                    pinned: false, descendantCount: 0
                )
            },
            authority: .init(
                catalogRevision: Int64(1_000 + initialCounterIncrement),
                observationSequence: Int64(2_000 + initialCounterIncrement),
                watermarkUpdatedAt: 3_000,
                metadataRowDigest: try CodexGhostRepairHasher.hash(metadata),
                localSyncRowDigest: try CodexGhostRepairHasher.hash(sync)
            )
        )
    }

    static func replacingFingerprintMember(
        _ member: CodexGhostRepairSnapshotCanonicalFile,
        in fingerprint: CodexGhostRepairSnapshotCanonicalFingerprint,
        seed: Int
    ) throws -> CodexGhostRepairSnapshotCanonicalFingerprint {
        let files = fingerprint.files.map { evidence in
            guard evidence.fileName == member.rawValue else { return evidence }
            return CodexGhostRepairSnapshotCanonicalFileEvidence(
                fileName: evidence.fileName,
                exists: true,
                device: evidence.device ?? 1,
                inode: evidence.inode ?? UInt64(seed),
                mode: evidence.mode ?? 0o600,
                size: (evidence.size ?? 0) + 1,
                modificationSeconds: evidence.modificationSeconds ?? 1,
                modificationNanoseconds:
                    (evidence.modificationNanoseconds ?? 0) + 1,
                sha256: Self.hash(seed)
            )
        }
        let profile = try XCTUnwrap(
            CodexGhostRepairSnapshotSourceProfile.admitted(
                sourceLayoutIdentifier: fingerprint.sourceLayoutIdentifier
            )
        )
        return try CodexGhostRepairSnapshotCanonicalFingerprint(
            profile: profile,
            sourceRootDigest: fingerprint.sourceRootDigest,
            files: files
        )
    }

    static func createDesktop(
        at url: URL,
        itemCount: Int,
        schema: Int32
    ) throws {
        try execute("PRAGMA user_version = \(schema)", at: url)
        try execute(
            "CREATE TABLE local_thread_catalog(host_id TEXT, thread_id TEXT, "
                + "missing_candidate INTEGER, title TEXT)", at: url
        )
        try execute(
            "CREATE TABLE automation_runs(thread_id TEXT, automation_id TEXT, "
                + "status TEXT, archived_reason TEXT, updated_at INTEGER, "
                + "archived_user_message TEXT, archived_assistant_message TEXT)",
            at: url
        )
        if schema == 33 || schema == 34 {
            try execute(
                "CREATE TABLE automations(id TEXT, status TEXT, "
                    + "kind TEXT NOT NULL DEFAULT 'cron', target_thread_id TEXT, "
                    + "execution_environment TEXT, local_environment_config_path TEXT, "
                    + "plugin_template_id TEXT, notification_policy TEXT, "
                    + "account_id TEXT, user_id TEXT, installation_id TEXT, "
                    + "legacy_automation_id TEXT)",
                at: url
            )
            try execute(
                "CREATE INDEX automations_owner_idx ON automations "
                    + "(account_id, user_id, installation_id)",
                at: url
            )
        } else {
            try execute("CREATE TABLE automations(id TEXT, status TEXT)", at: url)
        }
        try execute("CREATE TABLE inbox_items(thread_id TEXT)", at: url)
        try execute("CREATE TABLE thread_timeline_ledger(thread_id TEXT)", at: url)
        try execute(
            "CREATE TABLE local_thread_catalog_metadata(id INTEGER PRIMARY KEY, "
                + "catalog_revision INTEGER)", at: url
        )
        try execute(
            "INSERT INTO local_thread_catalog_metadata VALUES(1, 1000)", at: url
        )
        try execute(
            "CREATE TABLE local_thread_catalog_sync_state(host_id TEXT, "
                + "observation_sequence INTEGER, watermark_updated_at REAL)", at: url
        )
        try execute(
            "INSERT INTO local_thread_catalog_sync_state VALUES('local', 2000, 3000)",
            at: url
        )
        for index in 0..<itemCount {
            let threadID = identifier(index)
            try execute(
                "INSERT INTO local_thread_catalog VALUES('local', '\(threadID)', 1, "
                    + "'private-title-\(index)')", at: url
            )
            if !index.isMultiple(of: 2) {
                try execute(
                    "INSERT INTO automation_runs VALUES('\(threadID)', "
                        + "'automation-\(index)', 'ACCEPTED', NULL, 100, NULL, NULL)",
                    at: url
                )
                if schema == 33 || schema == 34 {
                    try execute(
                        "INSERT INTO automations(id, status, account_id, user_id, "
                            + "installation_id) VALUES('automation-\(index)', "
                            + "'ACTIVE', 'account', 'user', 'installation')",
                        at: url
                    )
                } else {
                    try execute(
                        "INSERT INTO automations VALUES('automation-\(index)', 'ACTIVE')",
                        at: url
                    )
                }
            }
        }
    }

    static func createSideDatabase(
        at url: URL, schema: Int, tables: [String]
    ) throws {
        try execute("PRAGMA user_version = \(schema)", at: url)
        for statement in tables { try execute(statement, at: url) }
    }

    static func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        ) == SQLITE_OK, let database else { throw TestError.sqlite }
        defer { sqlite3_close_v2(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestError.sqlite
        }
    }

    static func scalar(_ sql: String, at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
                == SQLITE_OK, let database else { throw TestError.sqlite }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK, let statement else { throw TestError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw TestError.sqlite
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    static func identifier(_ index: Int) -> String {
        String(format: "20000000-0000-4000-8000-%012d", index + 1)
    }

    static func hash(_ seed: Int) -> String {
        "sha256:" + String(format: "%064x", seed)
    }

    enum TestError: Error { case sqlite }

}

#if AGENT_SESSION_MANAGER_RESEARCH
struct FixedBulkBackupReadback:
    CodexGhostRepairBulkProductionBackupReadbackResolving,
    CodexGhostRepairBulkOperationBoundBackupCreating,
    CodexGhostRepairBulkOperationBoundBackupReading,
    Sendable
{
    let value: CodexGhostRepairBulkExecutionBackupReceipt

    func exactBackup(
        draft _: CodexGhostRepairBulkProductionExecutionDraft
    ) -> CodexGhostRepairBulkExecutionBackupReceipt { value }

    func createOrReadExactBackup(
        plan _: CodexGhostRepairBulkExecutionPlan,
        maintenance _: CodexGhostRepairBulkMaintenanceEvidence
    ) -> CodexGhostRepairBulkExecutionBackupReceipt { value }

    func readExactBackup(
        draft _: CodexGhostRepairBulkProductionExecutionDraft
    ) -> CodexGhostRepairBulkExecutionBackupReceipt { value }
}
#endif

struct FixedBulkLiveBackupReadback:
    CodexGhostRepairBulkLiveMixedBackupReading,
    Sendable
{
    let value: CodexGhostRepairBulkLiveBackupReceipt
    var fails = false

    func readExactBackup(
        plan _: CodexGhostRepairBulkBackupBoundOperationPlan
    ) throws -> CodexGhostRepairBulkLiveBackupReceipt {
        if fails {
            throw CodexGhostRepairError.backupFailed(
                "Deterministic M4f-17 backup readback failure."
            )
        }
        return value
    }
}

actor FixedBulkPackagedPlanPreparer:
    CodexGhostRepairBulkPackagedPlanPreparing
{
    let value: CodexGhostRepairBulkPackagedPreparedOperation

    init(value: CodexGhostRepairBulkPackagedPreparedOperation) {
        self.value = value
    }

    func prepare(
        confirmationReceiptID: UUID
    ) throws -> CodexGhostRepairBulkPackagedPreparedOperation {
        guard value.receipt.receiptID == confirmationReceiptID else {
            throw CodexGhostRepairError.authorityDrift
        }
        return value
    }

    func receipt(
        confirmationReceiptID: UUID
    ) throws -> CodexGhostRepairBulkConfirmationReceipt {
        guard value.receipt.receiptID == confirmationReceiptID else {
            throw CodexGhostRepairError.authorityDrift
        }
        return value.receipt
    }
}

actor FailingBulkPackagedPlanPreparer:
    CodexGhostRepairBulkPackagedPlanPreparing
{
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func prepare(
        confirmationReceiptID _: UUID
    ) throws -> CodexGhostRepairBulkPackagedPreparedOperation {
        throw error
    }

    func receipt(
        confirmationReceiptID _: UUID
    ) throws -> CodexGhostRepairBulkConfirmationReceipt {
        throw error
    }
}

struct FixedBulkPlanCollector:
    CodexGhostRepairBulkProductionPlanCollecting,
    Sendable
{
    let value: CodexGhostRepairBulkExecutionPlan

    func collectPlan(
        confirmationReceiptID: UUID
    ) throws -> CodexGhostRepairBulkExecutionPlan {
        guard value.confirmationReceiptID == confirmationReceiptID else {
            throw CodexGhostRepairError.authorityDrift
        }
        return value
    }
}

struct FixedBulkMaintenanceCollector:
    CodexGhostRepairBulkMaintenanceCollecting,
    Sendable
{
    let before: CodexGhostRepairBulkMaintenanceEvidence
    let after: CodexGhostRepairBulkMaintenanceEvidence

    func collectMaintenance(
        plan _: CodexGhostRepairBulkExecutionPlan,
        phase: CodexGhostRepairBulkMaintenanceCollectionPhase
    ) -> CodexGhostRepairBulkMaintenanceEvidence {
        phase == .beforeBackup ? before : after
    }
}

struct AlwaysClearBulkRepairGate:
    CodexGhostRepairExecutionGateSource,
    Sendable
{
    static let gate = CodexGhostRepairExecutionGate(
        codexFullyExited: true,
        desktopOpenHandleCount: 0,
        summariesOpenHandleCount: 0,
        historyOpenHandleCount: 0,
        stateOpenHandleCount: 0,
        threadHistoryOpenHandleCount: 0,
        capacitySufficient: true,
        desktopProcessEvidence: [],
        openHandleOwnerEvidence: []
    )

    func ghostRepairExecutionGate() -> CodexGhostRepairExecutionGate {
        Self.gate
    }
}

final class SequentialBulkFingerprintReader: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CodexGhostRepairSnapshotCanonicalFingerprint]

    init(_ values: [CodexGhostRepairSnapshotCanonicalFingerprint]) {
        self.values = values
    }

    func next() throws -> CodexGhostRepairSnapshotCanonicalFingerprint {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else {
            throw CodexGhostRepairError.authorityDrift
        }
        return values.removeFirst()
    }
}
