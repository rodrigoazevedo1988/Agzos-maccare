// swift-tools-version: 5.10
import PackageDescription

// MacCareCore contém a lógica determinística do aplicativo: modelos, regras de
// segurança, varredura de disco, detecção de duplicados, leitura de métricas do
// host e persistência local.
//
// Regra arquitetural deliberada: este pacote NÃO importa SwiftUI.
// Motivo direto do PRD §22 — "o módulo de limpeza não deve depender diretamente
// da interface SwiftUI". A consequência prática é que toda a superfície
// destrutiva do app é testável com `swift test`, sem servidor gráfico, sem
// sandbox e em segundos no CI.
//
// O alvo do aplicativo (App/) consome este pacote como dependência local.
let package = Package(
    name: "MacCareCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MacCareCore", targets: ["MacCareCore"])
    ],
    targets: [
        .target(
            name: "MacCareCore",
            path: "Sources/MacCareCore"
        ),
        .testTarget(
            name: "MacCareCoreTests",
            dependencies: ["MacCareCore"],
            path: "Tests/MacCareCoreTests"
        )
    ]
)
