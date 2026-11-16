import Foundation
import OrganizerCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private func terminate(_ code: Int32) -> Never {
#if canImport(Darwin)
    Darwin.exit(code)
#elseif canImport(Glibc)
    Glibc.exit(code)
#elseif canImport(Musl)
    Musl.exit(code)
#else
    fatalError("exit \(code)")
#endif
}

@main
struct ChanwuCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let command = try CLIParser.parse(arguments)
            let result = CLIRunner.run(command, store: LocalFileStore())
            if !result.stdout.isEmpty {
                print(result.stdout)
            }
            if !result.stderr.isEmpty {
                FileHandle.standardError.write(Data((result.stderr + "\n").utf8))
            }
            terminate(result.exitCode)
        } catch {
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            FileHandle.standardError.write(Data((CLIParser.helpText + "\n").utf8))
            terminate(2)
        }
    }
}
