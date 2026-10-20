import CryptoKit
import Foundation

public struct ModelCandidate: Codable, Identifiable, Sendable {
    public var id: String { fileName }
    public let fileName: String
    public let sizeBytes: Int64
    public let sha256: String
    public let role: String
    public let license: String
    public let qualityGate: String
}
private struct ModelManifest: Decodable { let models: [ModelCandidate] }

public enum ModelStore {
    public struct Installed: Sendable {
        public let url: URL
        public let candidate: ModelCandidate
    }
    public static func importModel(_ source: URL, into directory: URL, candidates: [ModelCandidate]) throws -> Installed {
        try Task.checkCancellation()
        let attrs = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true,
              let size = attrs.fileSize, candidates.contains(where: { $0.sizeBytes == Int64(size) })
        else { throw DictationError.modelMismatch }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw DictationError.modelInvalid
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        do {
            defer { try? input.close(); try? output.close() }
            var copied = 0
            while let data = try input.read(upToCount: min(1024 * 1024, size - copied + 1)), !data.isEmpty {
                try Task.checkCancellation()
                copied += data.count
                guard copied <= size else { throw DictationError.modelMismatch }
                try output.write(contentsOf: data)
            }
            guard copied == size else { throw DictationError.modelMismatch }
        }
        // Verify the actual private copy, not an earlier snapshot of a mutable external file.
        let candidate = try verify(temporary, candidates: candidates)
        let destination = directory.appendingPathComponent(candidate.sha256 + ".bin")
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try verify(destination, candidates: [candidate])
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
        return Installed(url: destination, candidate: candidate)
    }
    public static func candidates() throws -> [ModelCandidate] {
        guard let url = Bundle.module.url(forResource: "candidates", withExtension: "json", subdirectory: "Resources")
        else { throw DictationError.configuration }
        return try JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: url)).models
    }
    /// Streaming hash off the UI thread; original models are never modified.
    public static func verify(_ url: URL, candidates: [ModelCandidate]) throws -> ModelCandidate {
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard resource.isRegularFile == true, resource.isSymbolicLink != true,
              let size = resource.fileSize else { throw DictationError.modelInvalid }
        let matching = candidates.filter { $0.sizeBytes == Int64(size) }
        guard !matching.isEmpty else { throw DictationError.modelMismatch }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        var bytes = 0
        while let block = try file.read(upToCount: 1024 * 1024), !block.isEmpty {
            try Task.checkCancellation()
            bytes += block.count
            guard bytes <= size else { throw DictationError.modelMismatch }
            hasher.update(data: block)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard bytes == size, let candidate = matching.first(where: { $0.sha256 == hash })
        else { throw DictationError.modelMismatch }
        return candidate
    }
}
