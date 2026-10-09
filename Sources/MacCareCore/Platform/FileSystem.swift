import Foundation

/// Identificador de recurso (inode no APFS) de um arquivo.
///
/// Usado para detectar *hard links*: dois caminhos apontando para o mesmo inode
/// não são duplicatas, são o mesmo dado. Sem essa checagem, o detector de
/// duplicados apagaria "cópias" que na verdade são o mesmo arquivo — e o
/// usuário perderia o arquivo inteiro.
public typealias FileResourceIdentifier = String

/// Abstração sobre o sistema de arquivos.
///
/// Existe por dois motivos, ambos práticos:
///
/// 1. **Testabilidade.** O PRD §25 exige testes de segurança que provem que
///    nada é apagado sem confirmação e que nada fora de escopo é tocado.
///    Com `FileManager` real isso exigiria criar e destruir arquivos de verdade
///    em todo teste. Com um dublê em memória, o mesmo conjunto de asserções
///    roda em milissegundos e sem risco.
/// 2. **Isolamento de concorrência.** `FileManager` não é `Sendable`.
///    Encapsulá-lo permite que cada operação concorrente use a sua própria
///    instância, em vez de compartilhar uma não segura.
public protocol FileSystem: Sendable {

    /// Espaço livre do volume que contém a pasta pessoal, em bytes.
    /// `nil` quando o valor não pode ser determinado.
    func volumeAvailableCapacity() -> Int64?

    /// Tamanho total do volume que contém a pasta pessoal, em bytes.
    func volumeTotalCapacity() -> Int64?

    func itemExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func isSymbolicLink(at url: URL) -> Bool
    func isReadable(at url: URL) -> Bool

    /// Tamanho lógico (bytes do conteúdo) de um arquivo.
    func logicalSize(of url: URL) -> Int64?

    /// Tamanho efetivamente ocupado no disco, considerando blocos.
    /// Para diretórios, soma o conteúdo. `nil` quando ilegível.
    func allocatedSize(of url: URL) -> Int64?

    func modificationDate(of url: URL) -> Date?
    func creationDate(of url: URL) -> Date?
    func resourceIdentifier(of url: URL) -> FileResourceIdentifier?

    /// Move para a Lixeira. Lança em caso de falha — nunca apaga em silêncio.
    func moveToTrash(_ url: URL) throws

    /// Remove definitivamente. Só é chamado com autorização explícita.
    func remove(at url: URL) throws

    /// Lista o conteúdo imediato de um diretório.
    func contents(of directory: URL) throws -> [URL]

    /// URLs de arquivos descendentes, sem seguir links simbólicos de diretório.
    /// `skipDirectories` e `maxResults` limitam varreduras massivas.
    func descendents(
        of root: URL,
        skipDirectories: Bool,
        maxResults: Int,
        errorHandler: @escaping (URL, any Error) -> Void
    ) -> AsyncStream<URL>
}

/// Implementação sobre `FileManager`.
public struct LiveFileSystem: FileSystem {

    private let manager: FileManager

    public init(manager: FileManager = .default) {
        self.manager = manager
    }

    public func volumeAvailableCapacity() -> Int64? {
        let home = manager.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage { return important }
        if let plain = values?.volumeAvailableCapacity { return Int64(plain) }
        return nil
    }

    public func volumeTotalCapacity() -> Int64? {
        let home = manager.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey])
        if let total = values?.volumeTotalCapacity { return Int64(total) }
        return nil
    }

    public func itemExists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    public func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = manager.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    public func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }

    public func isReadable(at url: URL) -> Bool {
        manager.isReadableFile(atPath: url.path)
    }

    public func logicalSize(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize { return Int64(size) }
        // Diretórios não têm fileSize; somamos o conteúdo sob demanda.
        if isDirectory(at: url) { return allocatedSize(of: url) }
        return nil
    }

    public func allocatedSize(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        if let allocated = values?.totalFileAllocatedSize { return Int64(allocated) }
        if isDirectory(at: url) { return FileSizeMeasurer.directorySize(of: url, fs: self) }
        if let size = values?.fileSize { return Int64(size) }
        return nil
    }

    public func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }

    public func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? nil
    }

    public func resourceIdentifier(of url: URL) -> FileResourceIdentifier? {
        (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
            .map { String(describing: $0) }
    }

    public func moveToTrash(_ url: URL) throws {
        var resulting: NSURL?
        try manager.trashItem(at: url, resultingItemURL: &resulting)
    }

    public func remove(at url: URL) throws {
        try manager.removeItem(at: url)
    }

    public func contents(of directory: URL) throws -> [URL] {
        try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
    }

    public func descendents(
        of root: URL,
        skipDirectories: Bool,
        maxResults: Int,
        errorHandler: @escaping (URL, any Error) -> Void
    ) -> AsyncStream<URL> {
        let manager = self.manager
        return AsyncStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            let task = Task.detached(priority: .utility) {
                var emitted = 0
                guard let enumerator = manager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [],
                    errorHandler: { url, error in
                        errorHandler(url, error)
                        // Item ilegível não interrompe a varredura do resto.
                        return true
                    }
                ) else {
                    continuation.finish()
                    return
                }
                for case let url as URL in enumerator {
                    if Task.isCancelled { break }
                    guard emitted < maxResults else { break }
                    if skipDirectories {
                        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        if isDir { continue }
                    }
                    continuation.yield(url)
                    emitted += 1
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Cálculo de tamanho de diretórios de forma incremental e tolerante a falha.
///
/// A tolerância a falha é o ponto: em um Mac real sempre haverá itens que o
/// usuário não pode ler. Somar o que der e ignorar o resto é correto para uma
/// *estimativa* — desde que o número exibido seja rotulado como estimativa, o
/// que o app faz.
public enum FileSizeMeasurer {

    public static func directorySize(of url: URL, fs: FileSystem) -> Int64? {
        var total: Int64 = 0
        var found = false
        var stack: [URL] = [url]
        var visited = 0
        let maxVisits = 200_000

        while let current = stack.popLast() {
            guard visited < maxVisits else { return nil }
            visited += 1

            guard let children = try? fs.contents(of: current) else { continue }
            for child in children {
                if fs.isSymbolicLink(at: child) { continue }
                if fs.isDirectory(at: child) {
                    stack.append(child)
                } else if let size = fs.allocatedSize(of: child) {
                    total += size
                    found = true
                }
            }
        }
        return found ? total : nil
    }
}
