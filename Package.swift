// swift-tools-version: 5.9
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let backend = root + "/.build/backend"
struct ProductConfiguration: Decodable { let executable: String }
let product = try JSONDecoder().decode(ProductConfiguration.self,
    from: Data(contentsOf: URL(fileURLWithPath: root + "/Config/Product.json")))
let package = Package(
    name: product.executable,
    platforms: [.macOS(.v14)],
    products: [.executable(name: product.executable, targets: ["ClavuneApp"])],
    targets: [
        .target(
            name: "NativeBridge",
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-I" + root + "/.build/deps/whisper.cpp/include",
                                       "-I" + root + "/.build/deps/whisper.cpp/ggml/include",
                                       "-I" + backend])],
            linkerSettings: [
                .unsafeFlags(["-L" + backend + "/src", "-L" + backend + "/ggml/src",
                              "-L" + backend + "/ggml/src/ggml-cpu",
                              "-L" + backend + "/ggml/src/ggml-blas",
                              "-L" + backend + "/ggml/src/ggml-metal"]),
                .linkedLibrary("whisper"), .linkedLibrary("ggml"),
                .linkedLibrary("ggml-cpu"), .linkedLibrary("ggml-blas"),
                .linkedLibrary("ggml-metal"), .linkedLibrary("ggml-base"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"), .linkedFramework("Metal"),
                .linkedFramework("Foundation"), .linkedFramework("MetalKit")
            ]),
        .target(name: "ClavuneCore", dependencies: ["NativeBridge"],
                resources: [.copy("Resources")],
                linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "ClavuneApp", dependencies: ["ClavuneCore"]),
        .testTarget(name: "ClavuneCoreTests", dependencies: ["ClavuneCore", "NativeBridge", "ClavuneApp"],
                    resources: [.copy("Fixtures")])
    ],
    cxxLanguageStandard: .cxx17
)
