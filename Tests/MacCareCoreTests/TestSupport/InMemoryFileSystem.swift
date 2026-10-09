import Foundation
import MacCareCore

/// Sistema de arquivos em memória para testes de segurança.
///
/// Existe para permitir algo que o PRD §25 exige explicitamente: provar que o
/// app **não apaga** as coisas erradas. Com `FileManager` real, cada teste
/// precisaria criar arquivos de verdade e destruí-los depois — o que é lento,
/// suja o disco da máquina de teste e, num teste que falha no meio do caminho,
/// deixa lixo para trás. Aqui, uma asserção que falha não tem consequência
/// nenhuma fora do processo.
final class InMemoryFileSystem: FileSystem, @unchecked Sendable {

    struct Node {
        var isDirectory: Bool
        var size: Int64
        var modified: Date?
        var identifier: String
        var readable: Bool
        var trashed: Bool = false
    }

    private var nodes: [String: Node] = [:]
    // Valores padrão de um volume folgado; testes de contabilidade de espaço
    // definem os seus com `setVolume(available:total:)`.
    private var availableBytes: Int64 = 100_000_000_000
    private var totalBytes: Int64 = 500_000_000_000

    init() {}

    /// Tudo que foi jogado na Lixeira. Nenhum teste pode assumir que remoção
    /// equivale a exclusão; esta lista é a prova.
    private(set) var trashedPaths: [String] = []
    /// Tudo que foi removido definitivamente.
    private(set) var deletedPaths: [String] = []
    /// Itens que o motor tentou apagar mas a camada de segurança recusou.
    private(set) var blockedPaths: [String] = []

    /// Cria um arquivo de `size` bytes em `path`.
    @discardableResult
    func addFile(_ path: String, size: Int64 = 1024, modified: Date? = Date(), readable: Bool = true) -> String {
        let identifier = "inode:\(nodes.count)-\(path.hashValue)"
        nodes[path] = Node(
            isDirectory: false,
            size: size,
            modified: modified,
            identifier: identifier,
            readable: readable
        )
        return identifier
    }

    @discardableResult
    func addDirectory(_ path: String, readable: Bool = true) -> String {
        let identifier = "inode:dir:\(nodes.count)-\(path.hashValue)"
        nodes[path] = Node(
            isDirectory: true,
            size: 0,
            modified: Date(),
            identifier: identifier,
            readable: readable
        )
        return identifier
    }

    /// Cria dois caminhos apontando para o mesmo inode (hard link).
    func addHardLink(_ first: String, to second: String, size: Int64 = 4096) {
        let identifier = addFile(first, size: size)
        nodes[second] = Node(
            isDirectory: false,
            size: size,
            modified: Date(),
            identifier: identifier,
            readable: true
        )
    }

    func setVolume(available: Int64, total: Int64) {
        availableBytes = available
        totalBytes = total
    }

    // MARK: - FileSystem

    func volumeAvailableCapacity() -> Int64? { availableBytes }
    func volumeTotalCapacity() -> Int64? { totalBytes }

    func itemExists(at url: URL) -> Bool { nodes[url.path] != nil }

    func isDirectory(at url: URL) -> Bool { nodes[url.path]?.isDirectory ?? false }

    func isSymbolicLink(at url: URL) -> Bool { nodes[url.path]?.identifier.hasPrefix("symlink:") ?? false }

    func isReadable(at url: URL) -> Bool { nodes[url.path]?.readable ?? false }

    func logicalSize(of url: URL) -> Int64? { nodes[url.path]?.size }

    func allocatedSize(of url: URL) -> Int64? {
        guard let node = nodes[url.path], !node.isDirectory else { return nil }
        return node.size
    }

    func modificationDate(of url: URL) -> Date? { nodes[url.path]?.modified }
    func creationDate(of url: URL) -> Date? { nodes[url.path]?.modified }

    func resourceIdentifier(of url: URL) -> FileResourceIdentifier? { nodes[url.path]?.identifier }

    func moveToTrash(_ url: URL) throws {
        guard nodes[url.path] != nil else { throw InMemoryError.notFound }
        trashedPaths.append(url.path)
        nodes[url.path]?.trashed = true
    }

    func remove(at url: URL) throws {
        guard nodes[url.path] != nil else { throw InMemoryError.notFound }
        deletedPaths.append(url.path)
        nodes.removeValue(forKey: url.path)
    }

    func contents(of directory: URL) throws -> [URL] {
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return nodes.keys
            .filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
            .map { URL(fileURLWithPath: $0) }
            .sorted { $0.path < $1.path }
    }

    func descendents(
        of root: URL,
        skipDirectories: Bool,
        maxResults: Int,
        errorHandler: @escaping (URL, any Error) -> Void
    ) -> AsyncStream<URL> {
        let snapshot = nodes
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return AsyncStream { continuation in
            let matches = snapshot.keys
                .filter { $0.hasPrefix(prefix) && $0 != root.path }
                .sorted()
                .prefix(maxResults)
            for path in matches {
                if skipDirectories, snapshot[path]?.isDirectory == true { continue }
                continuation.yield(URL(fileURLWithPath: String(path)))
            }
            continuation.finish()
        }
    }

    enum InMemoryError: Error {
        case notFound
    }
}
