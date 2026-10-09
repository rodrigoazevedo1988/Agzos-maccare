import Foundation

/// Persistência do histórico de operações.
public protocol OperationLogStoring: Sendable {
    func append(_ record: OperationRecord) async throws
    func all() async throws -> [OperationRecord]
    func clear() async throws
    /// Exporta o histórico como JSONL já redigido.
    func exportRedacted() async throws -> Data
}

/// ## Por que JSONL em vez de SwiftData
///
/// O PRD §20 autoriza "SwiftData ou armazenamento local apropriado". A escolha
/// aqui é deliberada e vale explicar, porque é o tipo de decisão que costuma
/// ser questionada:
///
/// - **Crash-safe por construção.** O histórico é um log *append-only*. Uma
///   linha por registro significa que um app morto no meio de uma escrita
///   perde no máximo a última linha, nunca o arquivo inteiro. Um banco com
///   transações tem garantia equivalente, mas exige schema e migração.
/// - **Sem migração de schema.** Cada registro é autocontido e versionável por
///   nome de arquivo. Nenhuma versão futura do app precisa migrar a base do
///   usuário — o histórico evolui sem migração de esquema.
/// - **Inspecionável pelo usuário.** O usuário pode abrir o arquivo e ver
///   exatamente o que o app guardou. Isso combina com a promessa de
///   transparência do produto.
/// - **Testável sem container.** A suíte de testes cria e destrói arquivos
///   temporários reais em vez de simular um framework.
///
/// O custo real: leitura completa do arquivo para listar. Para um histórico de
/// manutenção, cujo volume é de dezenas ou centenas de registros por ano, isso
/// é irrelevante. Se um dia o volume mudar, a troca fica isolada atrás deste
/// protocolo.
public actor JSONLOperationLog: OperationLogStoring {

    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Local padrão do log, dentro do container do aplicativo.
    public static func defaultLocation(container: URL = URL.applicationSupportDirectory) -> URL {
        container.appendingPathComponent("MacCare/operation-log.jsonl")
    }

    public func append(_ record: OperationRecord) throws {
        let directory = fileURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let data = try encoder.encode(record)
        guard var line = String(data: data, encoding: .utf8) else {
            throw LogError.encodingFailed
        }
        line.append("\n")

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try Data(line.utf8).write(to: fileURL, options: .atomic)
        }
    }

    public func all() throws -> [OperationRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let text = String(data: data, encoding: .utf8) ?? ""

        return text.split(separator: "\n").compactMap { line in
            // Linha truncada por um encerramento abrupto é descartada, não fatal.
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(OperationRecord.self, from: lineData)
        }
        .sorted { $0.performedAt > $1.performedAt }
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    public func exportRedacted() throws -> Data {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let records = try all().map { $0.redacted(homePath: home) }
        let payload = try records.map { try encoder.encode($0) }
        let joined = payload.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
        return Data(joined.utf8)
    }

    public enum LogError: Error, LocalizedError {
        case encodingFailed

        public var errorDescription: String? {
            "Não foi possível codificar o registro de operação."
        }
    }
}
