import Foundation

/// Limites de uma varredura de disco.
///
/// O PRD §24 exige "limites configuráveis para varreduras extensas" e
/// "proteção contra varreduras recursivas excessivas". Estes limites não são
/// arbitrários: eles existem para que o app não fique indistinguível de um
/// processo pendurado quando encontra um disco lento ou um diretório
/// patológico.
public struct ScanLimits: Sendable, Equatable {
    /// Número máximo de arquivos visitados antes de parar.
    public var maxFileCount: Int
    /// Profundidade máxima a partir da raiz.
    public var maxDepth: Int
    /// Tempo máximo de execução.
    public var maxDuration: TimeInterval
    /// Seguir links simbólicos de diretório. Padrão `false` de propósito:
    /// seguir um link pode sair da área autorizada e gerar laço infinito.
    public var followSymlinks: Bool
    /// Ignorar diretórios ocultos (`.git`, `.Trash` interno, caches).
    public var skipHidden: Bool

    public init(
        maxFileCount: Int = 400_000,
        maxDepth: Int = 12,
        maxDuration: TimeInterval = 90,
        followSymlinks: Bool = false,
        skipHidden: Bool = true
    ) {
        self.maxFileCount = maxFileCount
        self.maxDepth = maxDepth
        self.maxDuration = maxDuration
        self.followSymlinks = followSymlinks
        self.skipHidden = skipHidden
    }

    /// Perfil conservador, para uso interativo e em código-fonte.
    public static let quick = ScanLimits(
        maxFileCount: 50_000,
        maxDepth: 6,
        maxDuration: 15
    )

    /// Perfil de varredura profunda, para a tela de armazenamento.
    public static let thorough = ScanLimits()
}

/// Filtros da busca por arquivos grandes e antigos.
public struct FileQuery: Sendable, Equatable {
    /// Tamanho mínimo, em bytes. `nil` = sem filtro.
    public var minimumSize: Int64?
    /// Extensões aceitas, em minúsculas e **sem** o ponto. `nil` = todas.
    public var allowedExtensions: Set<String>?
    /// Data mínima da última modificação. `nil` = sem filtro.
    public var modifiedAfter: Date?
    /// Incluir diretórios como resultado (ex.: para ver "pastas volumosas").
    public var includeDirectories: Bool

    public init(
        minimumSize: Int64? = nil,
        allowedExtensions: Set<String>? = nil,
        modifiedAfter: Date? = nil,
        includeDirectories: Bool = false
    ) {
        self.minimumSize = minimumSize
        self.allowedExtensions = allowedExtensions
        self.modifiedAfter = modifiedAfter
        self.includeDirectories = includeDirectories
    }

    public static let all = FileQuery()
}

/// Progresso de uma varredura em andamento.
public struct ScanProgress: Sendable, Equatable {
    public var filesVisited: Int
    public var matchesFound: Int
    public var bytesMatched: Int64
    public var currentPath: String?
    public var fraction: Double
    public var isFinished: Bool
    public var wasTruncated: Bool

    public init(
        filesVisited: Int = 0,
        matchesFound: Int = 0,
        bytesMatched: Int64 = 0,
        currentPath: String? = nil,
        fraction: Double = 0,
        isFinished: Bool = false,
        wasTruncated: Bool = false
    ) {
        self.filesVisited = filesVisited
        self.matchesFound = matchesFound
        self.bytesMatched = bytesMatched
        self.currentPath = currentPath
        self.fraction = fraction
        self.isFinished = isFinished
        self.wasTruncated = wasTruncated
    }
}

/// Resultado completo de uma varredura.
public struct LargeFileScanResult: Sendable {
    public let files: [LargeFileEntry]
    public let progress: ScanProgress
    /// Caminhos que não puderam ser lidos. A interface mostra isso, em vez de
    /// apresentar o resultado como completo quando não é.
    public let inaccessiblePaths: [String]
}

/// Varredor de diretórios com cancelamento, progresso e tolerância a falha.
public actor DirectoryScanner {

    private let fs: FileSystem
    private let limits: ScanLimits

    public init(fs: FileSystem = LiveFileSystem(), limits: ScanLimits = .thorough) {
        self.fs = fs
        self.limits = limits
    }

    /// Procura arquivos que atendem aos filtros, nas raízes informadas.
    ///
    /// - Throws: `CancellationError` quando o usuário cancela.
    public func scanLargeFiles(
        roots: [URL],
        query: FileQuery = .all,
        limits: ScanLimits? = nil,
        progress: @Sendable @escaping (ScanProgress) -> Void = { _ in }
    ) async throws -> LargeFileScanResult {
        let effectiveLimits = limits ?? self.limits
        let deadline = Date().addingTimeInterval(effectiveLimits.maxDuration)
        let syncedRoots = SyncedFolderDetector.detect()

        var matches: [LargeFileEntry] = []
        var inaccessible: [String] = []
        var visited = 0
        var truncated = false
        var state = ScanProgress()

        outer: for root in roots {
            for await fileURL in fs.descendents(
                of: root,
                skipDirectories: true,
                maxResults: effectiveLimits.maxFileCount,
                errorHandler: { url, _ in inaccessible.append(url.path) }
            ) {
                try Task.checkCancellation()
                visited += 1

                if visited > effectiveLimits.maxFileCount || Date() > deadline {
                    truncated = true
                    break outer
                }

                // Pula links simbólicos: seguir um pode sair da área autorizada.
                if fs.isSymbolicLink(at: fileURL) { continue }

                guard let entry = Self.evaluate(fileURL, query: query, fs: fs) else { continue }
                let synced = syncedRoots.contains { fileURL.path.hasPrefix($0) }

                matches.append(
                    LargeFileEntry(
                        url: entry.url,
                        sizeOnDisk: entry.sizeOnDisk,
                        modificationDate: entry.modificationDate,
                        isDirectory: entry.isDirectory,
                        isInSyncedFolder: synced
                    )
                )

                if visited % 200 == 0 {
                    state = ScanProgress(
                        filesVisited: visited,
                        matchesFound: matches.count,
                        bytesMatched: matches.reduce(0) { $0 + $1.sizeOnDisk },
                        currentPath: fileURL.path,
                        fraction: Double(visited) / Double(effectiveLimits.maxFileCount)
                    )
                    progress(state)
                }
            }
        }

        matches.sort { $0.sizeOnDisk > $1.sizeOnDisk }

        let finalProgress = ScanProgress(
            filesVisited: visited,
            matchesFound: matches.count,
            bytesMatched: matches.reduce(0) { $0 + $1.sizeOnDisk },
            currentPath: nil,
            fraction: 1,
            isFinished: true,
            wasTruncated: truncated
        )
        progress(finalProgress)

        return LargeFileScanResult(files: matches, progress: finalProgress, inaccessiblePaths: inaccessible)
    }

    /// Monta uma árvore de tamanhos até `maxDepth`, para o mapa de armazenamento.
    public func buildStorageTree(
        root: URL,
        maxDepth: Int = 3,
        limits: ScanLimits? = nil
    ) async -> StorageNode {
        // Os valores sao capturados ANTES de entrar na tarefa: `DirectoryScanner`
        // e um actor, e ler `self.limits` de dentro de um closure nao isolado
        // seria acesso ConcurrencyChecker proibido em tempo de compilacao.
        let effectiveLimits = limits ?? self.limits
        let fileSystem = self.fs

        return await Task.detached(priority: .utility) {
            Self.tree(at: root, depth: 0, maxDepth: maxDepth, limits: effectiveLimits, fs: fileSystem)
        }.value
    }

    private static func tree(
        at url: URL,
        depth: Int,
        maxDepth: Int,
        limits: ScanLimits,
        fs: FileSystem
    ) -> StorageNode {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent

        guard depth < maxDepth else {
            return StorageNode.leaf(url: url, sizeOnDisk: fs.allocatedSize(of: url) ?? 0, isPartial: true)
        }

        guard let children = try? fs.contents(of: url) else {
            return StorageNode.leaf(url: url, sizeOnDisk: 0, isPartial: true)
        }

        var built: [StorageNode] = []
        var total: Int64 = 0
        var incomplete = false
        var visited = 0

        for child in children {
            guard visited < limits.maxFileCount else { incomplete = true; break }
            visited += 1

            if fs.isSymbolicLink(at: child) { continue }
            if limits.skipHidden && child.lastPathComponent.hasPrefix(".") { continue }

            if fs.isDirectory(at: child) {
                let node = tree(at: child, depth: depth + 1, maxDepth: maxDepth, limits: limits, fs: fs)
                if node.isPartial { incomplete = true }
                total += node.sizeOnDisk
                built.append(node)
            } else if let size = fs.allocatedSize(of: child) {
                total += size
                built.append(.leaf(url: child, sizeOnDisk: size))
            } else {
                incomplete = true
            }
        }

        return StorageNode(
            url: url,
            name: name,
            sizeOnDisk: total,
            isPartial: incomplete,
            children: built.sorted { $0.sizeOnDisk > $1.sizeOnDisk }
        )
    }

    // MARK: - Filtro

    /// Avalia um arquivo contra o filtro. `nil` = não passou.
    private static func evaluate(_ url: URL, query: FileQuery, fs: FileSystem) -> LargeFileEntry? {
        let isDirectory = fs.isDirectory(at: url)
        if isDirectory && !query.includeDirectories { return nil }

        if let extensions = query.allowedExtensions {
            let ext = url.pathExtension.lowercased()
            if !extensions.contains(ext) { return nil }
        }

        if let minimum = query.minimumSize {
            guard let size = fs.allocatedSize(of: url), size >= minimum else { return nil }
        }

        let modified = fs.modificationDate(of: url)
        if let after = query.modifiedAfter {
            // Item sem data de modificação é aceito: o filtro diz "a partir
            // de", e um item sem data não é antigo o suficiente para ser
            // excluído por esse critério.
            if let modified, modified < after { return nil }
        }

        return LargeFileEntry(
            url: url,
            sizeOnDisk: fs.allocatedSize(of: url) ?? 0,
            modificationDate: modified,
            isDirectory: isDirectory
        )
    }
}

/// Detecta pastas sincronizadas em nuvem.
///
/// O PRD §11 exige alertar sobre diretórios sincronizados antes de remover
/// duplicatas: apagar o lado local de um arquivo sincronizado pode propagar a
/// exclusão para todos os outros dispositivos do usuário.
public enum SyncedFolderDetector {

    public static func detect(fileManager: FileManager = .default) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Mobile Documents").path,
            home.appendingPathComponent("Dropbox").path,
            home.appendingPathComponent("Google Drive").path,
            home.appendingPathComponent("OneDrive").path,
            home.appendingPathComponent("iCloud Drive").path,
            home.appendingPathComponent("Box").path
        ]
    }

    public static func isSynced(_ path: String, roots: [String] = detect()) -> Bool {
        roots.contains { path.hasPrefix($0) }
    }
}
