import Foundation

protocol PresetPackageArchiving: Sendable {
    func createArchive(from sourceDirectory: URL, at destinationURL: URL) throws
    func listEntries(in archiveURL: URL) throws -> [String]
    func extractArchive(at archiveURL: URL, to destinationDirectory: URL) throws
}

enum PresetPackageArchiveError: LocalizedError {
    case commandFailed(command: String, status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "\(command) failed with status \(status)."
                : "\(command) failed: \(detail)"
        }
    }
}

struct SystemPresetPackageArchive: PresetPackageArchiving {
    func createArchive(from sourceDirectory: URL, at destinationURL: URL) throws {
        _ = try run(
            executable: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--norsrc", sourceDirectory.path, destinationURL.path]
        )
    }

    func listEntries(in archiveURL: URL) throws -> [String] {
        let output = try run(
            executable: "/usr/bin/unzip",
            arguments: ["-Z1", archiveURL.path]
        )
        return output
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
    }

    func extractArchive(at archiveURL: URL, to destinationDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        _ = try run(
            executable: "/usr/bin/ditto",
            arguments: ["-x", "-k", archiveURL.path, destinationDirectory.path]
        )
    }

    private func run(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw PresetPackageArchiveError.commandFailed(
                command: URL(fileURLWithPath: executable).lastPathComponent,
                status: process.terminationStatus,
                message: String(decoding: error, as: UTF8.self)
            )
        }
        return String(decoding: output, as: UTF8.self)
    }
}
