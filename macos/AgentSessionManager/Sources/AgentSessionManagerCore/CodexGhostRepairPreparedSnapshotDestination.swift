import Foundation

#if AGENT_SESSION_MANAGER_RESEARCH
struct CodexGhostRepairPreparedDestinationBinding: Codable, Hashable, Sendable {
    private struct Payload: Codable, Hashable {
        let storageRootDigest: String
        let directories: [CodexGhostRepairDestinationDirectoryEvidence]
    }

    let storageRootDigest: String
    let directories: [CodexGhostRepairDestinationDirectoryEvidence]
    let bindingHash: String

    init(report: CodexGhostRepairDestinationPreparationReport) throws {
        guard report.completed,
              !report.recoveryMutationAuthority,
              report.directories.map(\.directory)
                == CodexGhostRepairDestinationDirectory.allCases,
              report.directories.allSatisfy(\.exists),
              report.directories.allSatisfy(\.permissionContractSatisfied) else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E35 requires a complete E34 destination preparation readback."
            )
        }
        let payload = Payload(
            storageRootDigest: report.storageRootDigest,
            directories: report.directories
        )
        storageRootDigest = payload.storageRootDigest
        directories = payload.directories
        bindingHash = try CodexGhostRepairHasher.hash(payload)
    }

    func validateHash() throws {
        let expected = try CodexGhostRepairHasher.hash(
            Payload(
                storageRootDigest: storageRootDigest,
                directories: directories
            )
        )
        guard expected == bindingHash else {
            throw CodexGhostRepairError.invalidProtectionEvidence(
                "E35 prepared destination binding checksum mismatch."
            )
        }
    }
}

/// E35 typed bridge from a fresh, complete E34 directory readback into the
/// existing journal-first snapshot pipeline. It is still test-owned only.
struct CodexGhostRepairPreparedSnapshotDestination: Sendable {
    typealias FreshReadback = @Sendable () throws
        -> CodexGhostRepairPreparedDestinationBinding

    let preparationBindingHash: String
    let storageRootDigest: String

    /// Internal pipeline capability; the shipping boundary rejects this type.
    let destination: CodexGhostRepairDisposableSnapshotDestination

    let liveSourceAuthority = false
    let repairMutationAuthority = false

    private let frozenBinding: CodexGhostRepairPreparedDestinationBinding
    private let freshReadback: FreshReadback

    init(
        destination: CodexGhostRepairDisposableSnapshotDestination,
        frozenBinding: CodexGhostRepairPreparedDestinationBinding,
        freshReadback: @escaping FreshReadback
    ) throws {
        try frozenBinding.validateHash()
        let fresh = try freshReadback()
        try fresh.validateHash()
        let destinationDigest = try CodexGhostRepairHasher.hash(
            destination.storageRootURL.path
        )
        guard fresh == frozenBinding,
              fresh.storageRootDigest == destinationDigest else {
            throw CodexGhostRepairError.targetDrift(
                "E35 prepared destination drifted before adapter construction."
            )
        }
        self.destination = destination
        self.frozenBinding = frozenBinding
        self.freshReadback = freshReadback
        preparationBindingHash = frozenBinding.bindingHash
        storageRootDigest = frozenBinding.storageRootDigest
    }

    func validateFresh() throws {
        try frozenBinding.validateHash()
        let fresh = try freshReadback()
        try fresh.validateHash()
        guard fresh == frozenBinding else {
            throw CodexGhostRepairError.targetDrift(
                "E35 prepared destination drifted before journal effect."
            )
        }
    }
}
#endif
