import CryptoKit
import Foundation

/// ## Estratégia de detecção
///
/// O PRD §11 é categórico: "não utilizar apenas o nome do arquivo para declarar
/// duplicidade" e "não considerar arquivos com nomes semelhantes como duplicados
/// confirmados". A estratégia em quatro estágios abaixo é a que garante isso
/// com custo aceitável:
///
/// 1. **Agrupar por tamanho.** Elimina ~99% dos arquivos sem ler um byte sequer.
/// 2. **Comparar metadados** dos que sobraram (datas, inode).
/// 3. **Calcular SHA-256** apenas dos candidatos que ainda podem ser pares.
/// 4. **Confirmar por conteúdo** e agrupar.
///
/// Ler o hash de um disco inteiro seria inviável; declarar por nome seria
/// errado. O meio-termo é o que a heurística permite de forma honesta.
public struct DuplicateFinder: Sendable {

    private let fs: FileSystem
    /// Tamanho mínimo para considerar dois arquivos pares. Abaixo de 4 KiB a
    /// taxa de falso positivo de arquivos pequenos distintos sobe muito, e o
    /// ganho de espaço é irrisório.
    private let minimumSize: Int64
    private let chunkSize: Int

    public init(fs: FileSystem = .live, minimumSize: Int64 = 4_096, chunkSize: Int = 1 << 20) {
        self.fs = fs
        self.minimumSize = minimumSize
        self.chunkSize = chunkSize
    }

    /// Encontra grupos de arquivos com conteúdo idêntico.
    ///
    /// - Parameter roots: diretórios a analisar.
    /// - Returns: grupos ordenados pelo espaço recuperável, do maior para o menor.
    public func findDuplicates(
        in roots: [URL],
        progress: @Sendable @escaping (ScanProgress) -> Void = { _ in }
    ) async throws -> [DuplicateGroup] {
        let syncedRoots = SyncedFolderDetector.detect()
        var state = ScanProgress()

        // Estágio 1 e 2 — varredura e agrupamento por tamanho.
        var bySize: [Int64: [LargeFileEntry]] = [:]
        var visited = 0

        for root in roots {
            for url in fs.descendents(of: root, skipDirectories: true, maxResults: 500_000) {
                try Task.checkCancellation()
                visited += 1

                if fs.isSymbolicLink(at: url) { continue }
                guard let size = fs.allocatedSize(of: url), size >= minimumSize else { continue }
                // Partições e imagens de disco não são "duplicatas" de nada.
                guard !Self.isVirtualVolume(url) else { continue }

                let entry = LargeFileEntry(
                    url: url,
                    sizeOnDisk: size,
                    modificationDate: fs.modificationDate(of: url),
                    isDirectory: false,
                    isInSyncedFolder: syncedRoots.contains { url.path.hasPrefix($0) }
                )
                bySize[size, default: []].append(entry)

                if visited % 500 == 0 {
                    state = ScanProgress(
                        filesVisited: visited,
                        matchesFound: bySize.values.reduce(0) { $0 + $1.count },
                        currentPath: url.path,
                        fraction: Double(visited) / 500_000
                    )
                    progress(state)
                }
            }
        }

        // Só tamanhos com 2+ candidatos são hashes. O resto é descartado aqui.
        let sizeGroups = bySize.filter { $0.value.count > 1 }

        // Estágio 3 e 4 — hash e agrupamento por conteúdo.
        var byDigest: [String: [LargeFileEntry]] = [:]
        let totalToHash = sizeGroups.values.reduce(0) { $0 + $1.count }
        var hashed = 0

        for (size, entries) in sizeGroups {
            try Task.checkCancellation()

            // Hard links do mesmo inode são o MESMO arquivo, não duplicatas.
            // Sem esta checagem, o app ofereceria apagar "cópias" que, ao
            // remover a última, apaga o conteúdo original.
            let uniqueEntries = Self.deduplicatingHardLinks(entries, fs: fs)

            var byContent: [String: [LargeFileEntry]] = [:]
            for entry in uniqueEntries {
                guard let digest = await sha256(of: entry.url) else { continue }
                byContent[digest, default: []].append(entry)
                hashed += 1

                if hashed % 20 == 0 {
                    state = ScanProgress(
                        filesVisited: visited,
                        matchesFound: byDigest.values.reduce(0) { $0 + $1.count },
                        currentPath: entry.url.path,
                        fraction: totalToHash > 0 ? Double(hashed) / Double(totalToHash) : 1
                    )
                    progress(state)
                }
            }

            for (digest, matches) in byContent where matches.count > 1 {
                byDigest[digest, default: []].append(contentsOf: matches)
            }
        }

        // Todos os itens de um grupo têm o mesmo tamanho por construção:
        // a chave de `byDigest` só existe para entradas que passaram juntas
        // pelo filtro de tamanho. Por isso o tamanho sai do próprio item.
        let groups = byDigest.compactMap { digest, items -> DuplicateGroup? in
            guard let first = items.first else { return nil }
            let dates = items.compactMap(\.modificationDate)
            let identifiers = items.compactMap { fs.resourceIdentifier(of: $0.url) }
            return DuplicateGroup(
                digest: digest,
                sizeOnDisk: first.sizeOnDisk,
                items: items,
                newest: dates.max(),
                oldest: dates.min(),
                isInSyncedFolder: items.contains(where: \.isInSyncedFolder),
                // `count > 1` aqui indica hard links dentro do próprio grupo.
                containsHardLinks: Set(identifiers).count < identifiers.count
            )
        }

        progress(
            ScanProgress(
                filesVisited: visited,
                matchesFound: groups.count,
                bytesMatched: groups.reduce(0) { $0 + $1.reclaimableSize },
                currentPath: nil,
                fraction: 1,
                isFinished: true
            )
        )

        return groups.sorted { $0.reclaimableSize > $1.reclaimableSize }
    }

    // MARK: - Support

    /// SHA-256 do conteúdo, lido em blocos.
    ///
    /// Ler em blocos de 1 MiB em vez de `Data(contentsOf:)` é o que permite
    /// hashear um arquivo de 8 GB sem estourar a memória.
    ///
    /// A leitura acontece em uma `Task.detached`: hashear um arquivo grande é
    /// I/O síncrono e bloqueante, e executá-lo na thread cooperativa travaria
    /// a interface — exatamente o que o PRD §24 proíbe.
    private func sha256(of url: URL) async -> String? {
        await Task.detached(priority: .utility) { [chunkSize] in
            Self.sha256Sync(of: url, chunkSize: chunkSize)
        }.value
    }

    private static func sha256Sync(of url: URL, chunkSize: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data: Data
            do {
                data = try handle.read(upToCount: chunkSize) ?? Data()
            } catch {
                return nil
            }
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Remove entradas que apontam para o mesmo inode (hard links).
    private static func deduplicatingHardLinks(_ entries: [LargeFileEntry], fs: FileSystem) -> [LargeFileEntry] {
        var seenIdentifiers = Set<FileResourceIdentifier>()
        var result: [LargeFileEntry] = []
        var withoutIdentifier: [LargeFileEntry] = []

        for entry in entries {
            if let identifier = fs.resourceIdentifier(of: entry.url) {
                if seenIdentifiers.insert(identifier).inserted {
                    result.append(entry)
                }
            } else {
                // Sem inode legível, não dá para afirmar nada sobre hard links.
                // Mantém o item; o hash ainda confirma o conteúdo.
                withoutIdentifier.append(entry)
            }
        }
        return result + withoutIdentifier
    }

    /// Imagens de disco e pacotes: conteúdo parecido, mas remover é desastre.
    private static func isVirtualVolume(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "dmg" || ext == "sparseimage" || ext == "pkg" || ext == "mpkg"
    }
}
