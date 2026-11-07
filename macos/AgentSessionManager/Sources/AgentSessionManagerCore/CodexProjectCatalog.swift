import Foundation

struct CodexProjectPage: Decodable {
    struct Project: Decodable {
        struct Root: Decodable { let path: String }
        let id: String
        let name: String
        let roots: [Root]
        let position: Int
    }
    let data: [Project]
    let nextCursor: String?
}

/// Bounded official project metadata. An incomplete page set never replaces a
/// complete catalog; explicit project IDs are not guessed from working folders.
enum CodexProjectCatalog {
    static func collect(read: (String?) throws -> CodexProjectPage) throws -> [CodexDesktopProject] {
        var cursor: String?
        var seenCursors = Set<String>()
        var ids = Set<String>()
        var projects: [CodexDesktopProject] = []
        for _ in 0..<20 {
            let page = try read(cursor)
            guard page.data.count <= 100 else { throw invalid }
            for project in page.data {
                guard UUID(uuidString: project.id) != nil, ids.insert(project.id).inserted,
                      !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      project.roots.count <= 100,
                      project.roots.allSatisfy({ $0.path.hasPrefix("/") && !$0.path.contains("\0") }) else { throw invalid }
                projects.append(.init(id: project.id, name: project.name, rootPaths: project.roots.map(\.path), order: project.position))
            }
            guard let next = page.nextCursor else { return projects }
            guard !next.isEmpty, seenCursors.insert(next).inserted else { throw invalid }
            cursor = next
        }
        throw invalid
    }

    private static var invalid: CodexAppServerError {
        .malformedResponse("Official project inventory is incomplete or inconsistent.")
    }
}
