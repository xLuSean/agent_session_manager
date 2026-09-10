import Darwin
import Foundation

/// Shared private-data and network boundary for interface and behavioral checks.
enum CodexCompatibilitySandbox {
    static func canonicalPath(_ url: URL) throws -> String {
        guard let path = realpath(url.path, nil) else { throw CodexCompatibilityInspector.CheckError.unavailable }
        defer { free(path) }
        return String(cString: path)
    }

    static func profile(executable: URL, work: URL) throws -> String {
        func quote(_ path: String) -> String {
            path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let runtimePath = try canonicalPath(executable)
        let workPath = try canonicalPath(work)
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-read*)
        (allow file-read* (literal "/"))
        (allow file-read* (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/dev")
          (subpath "/Library/Apple") (subpath "/private/var/db/dyld")
          (subpath "\(quote(workPath))") (literal "\(quote(runtimePath))"))
        (allow file-read-metadata)
        (deny file-write*)
        (allow file-write* (subpath "\(quote(workPath))") (literal "/dev/null"))
        (deny appleevent-send)
        (deny mach-lookup (global-name "com.apple.securityd") (global-name "com.apple.securityd.system")
          (global-name "com.apple.security.agent"))
        """
    }

    static func environment(work: URL) -> [String: String] {
        ["HOME": work.path, "CODEX_HOME": work.appendingPathComponent("codex").path,
         "TMPDIR": work.path, "XDG_CONFIG_HOME": work.appendingPathComponent("config").path,
         "XDG_DATA_HOME": work.appendingPathComponent("data").path,
         "XDG_CACHE_HOME": work.appendingPathComponent("cache").path,
         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C.UTF-8"]
    }
}
