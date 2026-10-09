import Foundation
import MacCareCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// ## Histórico
///
/// O histórico existe para duas coisas: permitir desfazer um engano e permitir
/// auditar o que o aplicativo fez. Por isso ele guarda **caminhos e contagens**,
/// nunca conteúdo de arquivo, e por isso a exportação é sempre a versão
/// redigida.
///
/// Um detalhe que costuma ser ignorado e aqui é regra: "espaço liberado" é um
/// número que mentiria com frequência. Mover para a Lixeira não reduz o espaço
/// do disco — a Lixeira mora no mesmo volume. Por isso o registro carrega duas
/// parcelas, `liberado confirmado` e `liberado não confirmado`, e a tela mostra
/// as duas com seus rótulos honestos em vez de somá-las em um número bonito.
@Observable
@MainActor
final class HistoryModel {

    // MARK: - Apresentação

    /// Um registro com o horário já formatado.
    ///
    /// A formatação mora no model e não na view por um motivo simples: a
    /// mesma linha aparece nesta tela, na de Ajustes e em qualquer resumo
    /// futuro, e formatar a cada vez é como as traduções divergem.
    struct Entry: Identifiable, Sendable {
        let record: OperationRecord
        let timeText: String

        var id: UUID { record.id }
    }

    /// Registros de um mesmo dia, já na ordem reversa.
    struct DayGroup: Identifiable, Sendable {
        let day: Date
        let title: String
        let entries: [Entry]

        var id: Date { day }
    }

    // MARK: - Estado

    private let environment: AppEnvironment

    private(set) var groups: [DayGroup] = []
    private(set) var isLoading = false
    private(set) var isClearing = false
    private(set) var errorMessage: String?
    private(set) var lastClearedCount: Int?

    /// Registros que tiveram seus detalhes revelados.
    var expandedEntryIDs: Set<UUID> = []

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - Leitura

    var isEmpty: Bool { groups.allSatisfy(\.entries.isEmpty) }

    var totalRecords: Int { groups.reduce(0) { $0 + $1.entries.count } }

    var totalItemsProcessed: Int {
        groups.reduce(0) { $0 + $1.entries.reduce(0) { $0 + $1.record.itemCount } }
    }

    var totalReleasedConfirmed: Int64 {
        groups.reduce(0) { $0 + $1.entries.reduce(0) { $0 + $1.record.accounting.releasedConfirmed } }
    }

    var totalReleasedUnconfirmed: Int64 {
        groups.reduce(0) { $0 + $1.entries.reduce(0) { $0 + $1.record.accounting.releasedUnconfirmed } }
    }

    /// Lê o log. O `JSONLOperationLog` é um `actor`: a leitura sai do
    /// MainActor por construção, sem nenhum wrapper necessário.
    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let records = try await environment.operationLog.all()
            groups = Self.group(records)
            errorMessage = nil
        } catch {
            groups = []
            errorMessage = "Não foi possível ler o histórico: \(error.localizedDescription)"
        }
    }

    /// Monta o documento de exportação **já redigido**.
    ///
    /// A redação acontece no núcleo (`exportRedacted`), onde o nome do usuário
    /// nos caminhos é substituído por `~`. A tela não tenta fazer isso por
    /// conta própria: uma segunda implementação de redação é uma segunda
    /// chance de vazar o nome em algum caminho.
    func makeExportDocument() async -> RedactedHistoryExport? {
        do {
            let data = try await environment.operationLog.exportRedacted()
            let count = (try? await environment.operationLog.all())?.count ?? 0
            errorMessage = nil
            return RedactedHistoryExport(data: data, recordCount: count)
        } catch {
            errorMessage = "Não foi possível gerar a exportação: \(error.localizedDescription)"
            return nil
        }
    }

    /// Apaga todo o histórico.
    ///
    /// ## Por que apagar é irreversível e ainda assim permitido
    ///
    /// O histórico é a única prova do que o aplicativo fez. Apagá-lo não
    /// desfaz nenhuma remoção já realizada — a Lixeira continua sendo o caminho
    /// de volta. Por isso a tela exige confirmação explícita e diz isso no texto
    /// do diálogo: quem apaga o histórico não recupera nada com isso, apenas
    /// perde o registro.
    func clearHistory() async {
        let previousTotal = totalRecords
        isClearing = true
        defer { isClearing = false }

        do {
            try await environment.operationLog.clear()
            groups = []
            expandedEntryIDs = []
            lastClearedCount = previousTotal
            errorMessage = nil
        } catch {
            errorMessage = "Não foi possível apagar o histórico: \(error.localizedDescription)"
        }
    }

    func isExpanded(_ entry: Entry) -> Bool {
        expandedEntryIDs.contains(entry.id)
    }

    /// A tela reporta falhas de fora do model — por exemplo, o erro devolvido
    /// pelo painel de exportação, que pertence ao SwiftUI e não ao histórico.
    func reportError(_ message: String) {
        errorMessage = message
    }

    func toggleExpansion(_ entry: Entry) {
        if expandedEntryIDs.contains(entry.id) {
            expandedEntryIDs.remove(entry.id)
        } else {
            expandedEntryIDs.insert(entry.id)
        }
    }

    // MARK: - Agrupamento e formatação

    private static let locale = Locale(identifier: "pt_BR")

    private static func group(_ records: [OperationRecord]) -> [DayGroup] {
        let calendar = Calendar.current
        var buckets: [Date: [OperationRecord]] = [:]

        for record in records {
            buckets[calendar.startOfDay(for: record.performedAt), default: []].append(record)
        }

        return buckets.keys.sorted(by: >).map { day in
            DayGroup(
                day: day,
                title: dayTitle(for: day, calendar: calendar),
                entries: (buckets[day] ?? []).map { record in
                    Entry(
                        record: record,
                        timeText: record.performedAt.formatted(
                            .dateTime.hour().minute().locale(locale)
                        )
                    )
                }
            )
        }
    }

    /// "Hoje" e "Ontem" são mais úteis que um dia da semana, e o dia da semana
    /// continua disponível para o resto.
    private static func dayTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Hoje" }
        if calendar.isDateInYesterday(day) { return "Ontem" }
        return day.formatted(
            .dateTime.weekday(.wide).day().month(.wide).year().locale(locale)
        )
    }
}

// MARK: - Documento de exportação

/// Arquivo de histórico para o usuário escolher onde salvar.
///
/// O conteúdo é JSON Lines, um registro por linha, e o tipo declarado é texto
/// puro: afirmar que um arquivo com vários objetos JSON é "JSON" seria uma
/// imprecisão pequena que o Finder e editores de texto exibiriam como arquivo
/// quebrado.
struct RedactedHistoryExport: FileDocument {

    static var readableContentTypes: [UTType] { [.macCareHistory] }

    let data: Data
    let recordCount: Int

    init(data: Data, recordCount: Int) {
        self.data = data
        self.recordCount = recordCount
    }

    /// Só existe porque `FileDocument` exige. A exportação nunca lê de volta
    /// um arquivo: ela só escreve.
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents,
              let text = String(data: contents, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = Data(text.utf8)
        self.recordCount = 0
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    /// JSON Lines. O SDK não expõe um tipo padrão para `.jsonl`, e declarar um
    /// evita gravar um arquivo que ferramentas de texto não reconhecem.
    static let macCareHistory = UTType(exportedAs: "com.agzos.maccare.history", conformingTo: .plainText)
}
