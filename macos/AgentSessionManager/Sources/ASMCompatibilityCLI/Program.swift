import AgentSessionManagerCore
import Darwin
import Foundation

@main
struct CompatibilityProgram {
    static func main() async {
        do {
            let options = try CompatibilityOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            if options.help { print(CompatibilityOptions.usage); return }
            let provider = CodexAppServerClient(configuration: .init(executableURL: options.executable))
            let executable = try await provider.compatibilityExecutableURL()
            let directory = try CompatibilityCommand.createRunDirectory(outputRoot: options.outputRoot, codexHome: options.home)
            print("Report directory: \(directory.path)")
            let environment = ProcessInfo.processInfo.environment
            let result = try await CompatibilityCommand.run(
                request: .init(providerExecutable: executable, codexHome: options.home, diagnosticRunID: UUID()),
                inspectOnly: options.inspectOnly, homeSource: options.homeSource,
                source: .init(asmVersion: environment["ASM_COMPATIBILITY_SOURCE_VERSION"] ?? "unknown (direct Swift invocation)",
                              revision: environment["ASM_COMPATIBILITY_SOURCE_REVISION"] ?? "unknown (direct Swift invocation)"),
                directory: directory,
                progress: { message in
                    try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
                })
            print(result.summary, terminator: "")
            print("JSON report: \(directory.appendingPathComponent("report.json").path)")
            exit(result.exitCode)
        } catch let error as UsageError {
            fputs("\(error)\n\(CompatibilityOptions.usage)\n", stderr)
            exit(64)
        } catch {
            let fields = CodexCompatibilityDiagnosticError.metadata(error)
            fputs("Compatibility run could not complete: \(fields)\nNo App compatibility status was updated.\n", stderr)
            exit(1)
        }
    }
}
