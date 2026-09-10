@testable import AgentSessionManagerCore
import Foundation
import XCTest

final class CodexGhostRepairSnapshotOperationalGateSourceTests: XCTestCase {
    func testProductionConstructionDisclosesReadOnlyFixedCapability() {
        let source = CodexGhostRepairSnapshotOperationalGateSource.production()

        XCTAssertTrue(source.capabilities.readsProcessList)
        XCTAssertTrue(source.capabilities.readsOpenHandleMetadata)
        XCTAssertTrue(source.capabilities.readsRequiredDatabaseMetadata)
        XCTAssertTrue(source.capabilities.probesFixedManagerDestinationVolume)
        XCTAssertFalse(source.capabilities.acceptsCallerPath)
        XCTAssertFalse(source.capabilities.opensSQLite)
        XCTAssertFalse(source.capabilities.writesCodexDatabaseFiles)
        XCTAssertFalse(source.capabilities.writesManagerFilesystem)
        XCTAssertFalse(source.capabilities.snapshotAcquisitionAuthority)
        XCTAssertFalse(source.capabilities.repairMutationAuthority)
    }

    func testConstructionDoesNotResolveConfigurationOrCreateDelegate() {
        let recorder = SnapshotOperationalGateConstructionRecorder()

        _ = CodexGhostRepairSnapshotOperationalGateSource(
            configurationResolver: {
                recorder.recordResolution()
                return Self.configuration
            },
            gateFactory: { configuration in
                recorder.recordFactory(configuration)
                return SnapshotOperationalGateDelegate(gates: [.clear])
            }
        )

        XCTAssertEqual(recorder.resolutionCount, 0)
        XCTAssertEqual(recorder.factoryConfigurations, [])
    }

    func testEachExplicitGateFreshlyResolvesAndDelegatesExactEvidence()
        async throws
    {
        let recorder = SnapshotOperationalGateConstructionRecorder()
        let delegate = SnapshotOperationalGateDelegate(
            gates: [.clear, .blocked]
        )
        let source = CodexGhostRepairSnapshotOperationalGateSource(
            configurationResolver: {
                recorder.recordResolution()
                return Self.configuration
            },
            gateFactory: { configuration in
                recorder.recordFactory(configuration)
                return delegate
            }
        )

        let first = try await source.ghostRepairExecutionGate()
        let second = try await source.ghostRepairExecutionGate()

        XCTAssertEqual(first, .clear)
        XCTAssertEqual(second, .blocked)
        XCTAssertEqual(recorder.resolutionCount, 2)
        XCTAssertEqual(
            recorder.factoryConfigurations,
            [Self.configuration, Self.configuration]
        )
        let delegateCallCount = await delegate.callCount
        XCTAssertEqual(delegateCallCount, 2)
    }

    func testResolverFailureStopsBeforeDelegateConstruction() async {
        let recorder = SnapshotOperationalGateConstructionRecorder()
        let source = CodexGhostRepairSnapshotOperationalGateSource(
            configurationResolver: {
                recorder.recordResolution()
                throw SnapshotOperationalGateTestError.injected
            },
            gateFactory: { configuration in
                recorder.recordFactory(configuration)
                return SnapshotOperationalGateDelegate(gates: [.clear])
            }
        )

        do {
            _ = try await source.ghostRepairExecutionGate()
            XCTFail("Expected fixed-root resolution failure to fail closed.")
        } catch {
            XCTAssertEqual(
                error as? SnapshotOperationalGateTestError,
                .injected
            )
        }
        XCTAssertEqual(recorder.resolutionCount, 1)
        XCTAssertEqual(recorder.factoryConfigurations, [])
    }

    private static let configuration =
        CodexGhostRepairOperationalGateConfiguration(
            codexHomeURL: URL(
                fileURLWithPath: "/test-owned/.codex",
                isDirectory: true
            ),
            backupVolumeProbeURL: URL(
                fileURLWithPath: "/test-owned/Application Support/com.sean.AgentSessionManager/GhostRepair/Snapshots",
                isDirectory: true
            )
        )
}

private final class SnapshotOperationalGateConstructionRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedResolutionCount = 0
    private var storedFactoryConfigurations:
        [CodexGhostRepairOperationalGateConfiguration] = []

    var resolutionCount: Int {
        lock.withLock { storedResolutionCount }
    }

    var factoryConfigurations:
        [CodexGhostRepairOperationalGateConfiguration]
    {
        lock.withLock { storedFactoryConfigurations }
    }

    func recordResolution() {
        lock.withLock { storedResolutionCount += 1 }
    }

    func recordFactory(
        _ configuration: CodexGhostRepairOperationalGateConfiguration
    ) {
        lock.withLock { storedFactoryConfigurations.append(configuration) }
    }
}

private actor SnapshotOperationalGateDelegate:
    CodexGhostRepairExecutionGateSource
{
    private var gates: [CodexGhostRepairExecutionGate]
    private(set) var callCount = 0

    init(gates: [CodexGhostRepairExecutionGate]) {
        self.gates = gates
    }

    func ghostRepairExecutionGate() async throws
        -> CodexGhostRepairExecutionGate
    {
        guard callCount < gates.count else {
            throw SnapshotOperationalGateTestError.exhausted
        }
        defer { callCount += 1 }
        return gates[callCount]
    }
}

private extension CodexGhostRepairExecutionGate {
    static let clear = Self(
        codexFullyExited: true,
        desktopOpenHandleCount: 0,
        summariesOpenHandleCount: 0,
        historyOpenHandleCount: 0,
        capacitySufficient: true
    )

    static let blocked = Self(
        codexFullyExited: false,
        desktopOpenHandleCount: 0,
        summariesOpenHandleCount: 0,
        historyOpenHandleCount: 0,
        capacitySufficient: false
    )
}

private enum SnapshotOperationalGateTestError: Error, Equatable {
    case injected
    case exhausted
}
