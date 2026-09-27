// swift-tools-version: 6.2
import PackageDescription

// FluidAudio'yu **trait'siz** bağlayan tek amaçlı sarmalayıcı.
//
// FluidAudio'nun varsayılan `NemoTextProcessing` trait'i önceden derlenmiş bir
// Rust kütüphanesi (dilim başına ~8 MB) bağlıyor; yalnızca metin-konuşma ve
// metin normalizasyonu kullanıyor, diarization değil. Xcode projesi bir paket
// bağımlılığının trait'lerini seçemiyor — bu manifest seçebiliyor
// (`traits: []`). ora yalnızca bu paketi görür (RESEARCH.md §39).
let package = Package(
    name: "OraDiarizationKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OraDiarizationKit", targets: ["OraDiarizationKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio",
                 .upToNextMinor(from: "0.17.4"), traits: []),
    ],
    targets: [
        .target(name: "OraDiarizationKit",
                dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
