import Foundation
import XCTest

/// Pure metadata checks; these do not require renderer opt-ins or a Mac window.
final class QAContentEvidenceContractTests: XCTestCase {
    func testRawByteHashHasKnownSHA256Vector() {
        XCTAssertEqual(QAContentSourceBinding.sha256(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(QAContentSourceBinding.isSHA256(String(repeating: "a", count: 64)))
        XCTAssertFalse(QAContentSourceBinding.isSHA256(String(repeating: "A", count: 64)))
        XCTAssertFalse(QAContentSourceBinding.isSHA256("not-a-hash"))
    }

    func testSourcePathsRejectTraversalAndUnrelatedPrivateLocations() {
        for path in ["Package.swift", "Sources/ClavuneApp/Presentation.swift", "Tests/Übung.swift", "Config/Product.json"] {
            XCTAssertTrue(QAContentSourceBinding.sourcePathIsAllowed(path), path)
        }
        for path in ["/etc/passwd", "../Sources/x", "Sources/../x", "Sources//x", "Sources/./x",
                     "Sources/\\x", "Sources/x\n", "Sources/.env", "Docs/private.txt", "C:/x", ""] {
            XCTAssertFalse(QAContentSourceBinding.sourcePathIsAllowed(path), path)
        }
    }

    func testCanonicalComponentContainmentRejectsPrefixLookalikes() throws {
        let root = "/private/tmp/candidate"
        XCTAssertEqual(try QAContentSourceBinding.sourceRelativePath(
            canonicalFilePath: root + "/Tests/Übung.swift", canonicalRootPath: root), "Tests/Übung.swift")
        for file in ["/private/tmp/candidate-other/Sources/Main.swift", root,
                     "/private/tmp/other/Sources/Main.swift"] {
            XCTAssertThrowsError(try QAContentSourceBinding.sourceRelativePath(
                canonicalFilePath: file, canonicalRootPath: root))
        }
    }

    func testTemporaryRootAliasesYieldExactManifestRelativePaths() throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("Clavune-source-binding-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try manager.createDirectory(at: sources, withIntermediateDirectories: false)
        let file = sources.appendingPathComponent("Generated.swift")
        try Data("// wholly synthetic path fixture\n".utf8).write(to: file, options: .withoutOverwriting)
        let physicalRoot = try QAContentSourceBinding.canonicalFileSystemPath(root)
        let physicalFile = try QAContentSourceBinding.canonicalFileSystemPath(file)
        XCTAssertEqual(try QAContentSourceBinding.canonicalFileSystemPath(
            URL(fileURLWithPath: physicalRoot, isDirectory: true)), physicalRoot)
        XCTAssertEqual(try QAContentSourceBinding.sourceRelativePath(
            canonicalFilePath: physicalFile, canonicalRootPath: physicalRoot), "Sources/Generated.swift")
        let verified = try QAContentSourceBinding.sourceFileURL("Sources/Generated.swift",
                                                               canonicalRootPath: physicalRoot)
        XCTAssertEqual(try QAContentSourceBinding.canonicalFileSystemPath(verified), physicalFile)

        // Normalizing the trusted /tmp root must not permit source-relative
        // aliases, including links whose destination remains in the same root.
        let alias = sources.appendingPathComponent("Alias.swift")
        try manager.createSymbolicLink(at: alias, withDestinationURL: file)
        XCTAssertThrowsError(try QAContentSourceBinding.sourceFileURL("Sources/Alias.swift",
                                                                      canonicalRootPath: physicalRoot))
        let directoryAlias = sources.appendingPathComponent("Linked", isDirectory: true)
        try manager.createSymbolicLink(at: directoryAlias, withDestinationURL: sources)
        XCTAssertThrowsError(try QAContentSourceBinding.sourceFileURL("Sources/Linked/Generated.swift",
                                                                      canonicalRootPath: physicalRoot))
    }

    func testOutputNamespaceUsesPhysicalTemporaryRootAndNeverOverwrites() throws {
        let run = "binding-" + UUID().uuidString
        let requested = "/tmp/clavune-offscreen-evidence/" + run
        let output = try QAContentEvidenceOutput(path: requested)
        // Only this test's freshly allocated run is removed; the shared owned
        // namespace and any other captures are never cleanup candidates.
        defer { try? FileManager.default.removeItem(at: output.directory) }
        let physicalTemporaryRoot = try QAContentSourceBinding.canonicalFileSystemPath(
            URL(fileURLWithPath: "/tmp", isDirectory: true))
        XCTAssertEqual(try QAContentSourceBinding.canonicalFileSystemPath(output.directory),
                       physicalTemporaryRoot + "/clavune-offscreen-evidence/" + run)
        let bytes = Data("wholly synthetic output fixture\n".utf8)
        try output.write(bytes, name: "sample.txt")
        XCTAssertThrowsError(try output.write(Data("replacement".utf8), name: "sample.txt"))
        XCTAssertThrowsError(try QAContentEvidenceOutput(path: requested))
        XCTAssertEqual(try Data(contentsOf: output.directory.appendingPathComponent("sample.txt")), bytes)
    }

    func testEvidenceCannotMistakeStaticImagesForMotionOrBuildCertification() throws {
        let binding = QAContentSourceBinding(sourceManifestSHA256: String(repeating: "a", count: 64),
            candidateSourceTreeSHA256: String(repeating: "c", count: 64),
            verifiedSourceFileCount: 1, testBundleExecutableSHA256: String(repeating: "b", count: 64),
            sourceToBinaryBinding: "pending-independent-clean-build-receipt")
        let evidence = QAContentRenderEvidence(source: binding, forbiddenBoundaryCalls: [], images: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any])
        XCTAssertEqual(json["motionCapture"] as? String, "notCaptured")
        XCTAssertEqual(json["animationCalibration"] as? String, "notRun-endpoint-only-evidence")
        XCTAssertEqual(json["realWindowAndAccessibilityAcceptance"] as? String, "pending-local-review")
        XCTAssertEqual(json["testResult"] as? String, "not-encoded-consult-matching-xcresult")
        XCTAssertEqual(json["syntheticDataOnly"] as? Bool, true)
        let source = try XCTUnwrap(json["source"] as? [String: Any])
        XCTAssertEqual(source["sourceToBinaryBinding"] as? String, "pending-independent-clean-build-receipt")
    }
}
