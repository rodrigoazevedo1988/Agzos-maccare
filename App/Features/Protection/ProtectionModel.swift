import Foundation
import MacCareCore
import Observation
import Security
import SwiftUI

/// ## Proteção: verificação com escopo declarado
///
/// O PRD §18 é categórico: o MacCare **não é antivírus**. Não há varredura de
/// malware, não há detecção de ameaças, não há tempo real, e a ausência de
/// nenhum achado **não** é garantia de segurança. Se esta tela escondesse esse
/// fato, ela seria exatamente o tipo de promessa que um app de manutenção não
/// pode fazer.
///
/// O que ela faz é verificável e reproduzível: para cada aplicativo
/// instalado, o framework Security valida a assinatura do código e consulta a
/// notarização. Cada resultado vem acompanhado da **regra** que o produziu, e as
/// regras são finitas, documentadas e mostradas ao usuário.
///
/// Nenhuma regra remove, move ou altera nada. A tela não tem botão de remoção
/// e não altera configuração de segurança do macOS — existem duas razões, e as
/// duas são concretas: uma assinatura ausente não prova malware, e apagar um
/// aplicativo por causa de uma assinatura ausente seria uma decisão automatizada
/// e irreversível tomada com base em indício.
@Observable
@MainActor
final class ProtectionModel {

    // MARK: - Classificação

    /// Os quatro estados possíveis de um aplicativo.
    ///
    /// São quatro e não três de propósito. "Não verificado" e "sem indicadores"
    /// são coisas diferentes: a primeira significa que faltou informação, a
    /// segunda significa que a informação existiu e não apontou nada. Colapsar
    /// as duas em um "OK" seria dizer que o MacCare tem certeza onde ele não
    /// tem.
    enum Verdict: String, CaseIterable, Identifiable, Sendable {
        case suspicious
        case unverified
        case noIndicators
        case confirmed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .confirmed: return "Confirmado"
            case .suspicious: return "Suspeito"
            case .unverified: return "Não verificado"
            case .noIndicators: return "Sem indicadores"
            }
        }

        /// Rótulo mais longo, usado no resumo do topo da lista.
        var longTitle: String {
            switch self {
            case .confirmed: return "Confirmado por fonte confiável"
            case .suspicious: return "Com regra suspeita disparada"
            case .unverified: return "Não foi possível verificar por completo"
            case .noIndicators: return "Nenhuma regra disparou"
            }
        }

        /// Legenda curta do cartão numérico. O texto completo vive em
        /// `explanation`, exibido na legenda abaixo dos cartões — um cartão
        /// truncado em duas linhas seria uma DEFINIÇÃO truncada.
        var tileCaption: String {
            switch self {
            case .confirmed: return "Assinatura válida, com equipe e registro na Apple"
            case .suspicious: return "Uma regra de assinatura disparou"
            case .unverified: return "Faltou informação para fechar o veredito"
            case .noIndicators: return "Nenhuma regra declarada disparou"
            }
        }

        var color: Color {
            switch self {
            case .confirmed: return Theme.Palette.success
            case .suspicious: return Theme.Palette.danger
            case .unverified: return Theme.Palette.unavailable
            case .noIndicators: return Theme.Palette.secondaryText
            }
        }

        var symbolName: String {
            switch self {
            case .confirmed: return "checkmark.seal.fill"
            case .suspicious: return "exclamationmark.triangle.fill"
            case .unverified: return "questionmark.circle"
            case .noIndicators: return "circle"
            }
        }

        var explanation: String {
            switch self {
            case .confirmed:
                return "A assinatura do código foi validada pelo macOS, há identidade de desenvolvedor identificável e o código está registrado no serviço de notarização da Apple."
            case .suspicious:
                return "Uma regra de assinatura disparou. Isso é um indício para você investigar, não uma conclusão: muitos aplicativos legítimos falham na validação por detalhes de empacotamento."
            case .unverified:
                return "Faltou informação para fechar o veredito — por exemplo, a notarização não pôde ser confirmada. Não é o mesmo que estar limpo."
            case .noIndicators:
                return "Nenhuma das regras declaradas disparou para este aplicativo entre as que o MacCare consegue verificar."
            }
        }
    }

    /// O que uma regra faz com o veredito.
    ///
    /// `informative` existe para separar “isso merece sua atenção” de “isso
    /// muda o veredito”. Localização incoma é informação; assinatura ausente é
    /// indício. Misturar as duas coisas transformaria um detalhe administrativo
    /// em alarme.
    enum RuleEffect: String, Sendable {
        case suspicious
        case unverified
        case confirming
        case informative

        var title: String {
            switch self {
            case .suspicious: return "Puxa para suspeito"
            case .unverified: return "Impede confirmar"
            case .confirming: return "Sustenta confirmado"
            case .informative: return "Apenas informação"
            }
        }

        var color: Color {
            switch self {
            case .suspicious: return Theme.Palette.danger
            case .unverified: return Theme.Palette.unavailable
            case .confirming: return Theme.Palette.success
            case .informative: return Theme.Palette.accent
            }
        }
    }

    /// Regra declarada, com o código que o usuário pode citar.
    ///
    /// `summary` descreve a regra em geral e aparece no catálogo; `detail`
    /// descreve o que aconteceu **neste** aplicativo e é onde os códigos
    /// retornados pelo macOS são mostrados. Separar os dois textos permite
    /// exibir o catálogo completo sem que um código de erro fique preso na
    /// descrição de uma regra que não disparou.
    struct Rule: Identifiable, Sendable {
        let code: String
        let title: String
        let summary: String
        let detail: String
        let effect: RuleEffect

        var id: String { code }
    }

    /// Relatório de um aplicativo.
    struct Report: Identifiable, Sendable {
        let name: String
        let url: URL
        let bundleIdentifier: String?
        let version: String
        let location: ApplicationLocation
        let isAppleProvided: Bool
        let isInSyncedFolder: Bool
        let facts: SignatureInspector.Facts
        let rules: [Rule]

        var id: String { url.path }

        /// Prioridade fixa e documentada: indício vence lacuna, lacuna vence
        /// confirmação, e a ausência total de regras é um estado próprio.
        var verdict: Verdict {
            if rules.contains(where: { $0.effect == .suspicious }) { return .suspicious }
            if rules.contains(where: { $0.effect == .unverified }) { return .unverified }
            if rules.contains(where: { $0.effect == .confirming }) { return .confirmed }
            return .noIndicators
        }

        var teamSummary: String {
            if let team = facts.teamIdentifier, !team.isEmpty {
                return "Equipe \(team)"
            }
            return facts.hasCertificateChain
                ? "Certificado presente, sem identificador de equipe"
                : "Sem certificado e sem identificador de equipe"
        }

        var notarizationSummary: String {
            switch facts.notarization {
            case .notarized:
                return "Notarização confirmada pelo macOS"
            case .notConfirmed(let status):
                return "Notarização não confirmada (código \(status))"
            case .notApplicable:
                return "Não se aplica: o código não tem assinatura válida"
            }
        }
    }

    /// Filtro da lista.
    enum ReportFilter: String, CaseIterable, Identifiable, Sendable {
        case all
        case suspicious
        case unverified
        case noIndicators
        case confirmed

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "Todos"
            case .suspicious: return "Suspeitos"
            case .unverified: return "Não verificados"
            case .noIndicators: return "Sem indicadores"
            case .confirmed: return "Confirmados"
            }
        }
    }

    // MARK: - Estado

    private let environment: AppEnvironment

    private(set) var reports: [Report] = []
    private(set) var isAnalyzing = false
    private(set) var analyzedCount = 0
    private(set) var totalCount = 0
    private(set) var analyzedAt: Date?
    private(set) var wasInterrupted = false
    private(set) var errorMessage: String?

    var filter: ReportFilter = .all
    var expandedReportIDs: Set<String> = []

    private var analysisTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: - Contagens

    var totalReports: Int { reports.count }

    func count(of verdict: Verdict) -> Int {
        reports.reduce(into: 0) { total, report in
            if report.verdict == verdict { total += 1 }
        }
    }

    var visibleReports: [Report] {
        switch filter {
        case .all: return reports
        case .suspicious, .unverified, .noIndicators, .confirmed:
            return reports.filter { $0.verdict == filter }
        }
    }

    /// Progresso real: um aplicativo verificado por evento, não um número de
    /// convite.
    var progress: Double? {
        guard totalCount > 0 else { return nil }
        return Double(analyzedCount) / Double(totalCount)
    }

    func isExpanded(_ report: Report) -> Bool {
        expandedReportIDs.contains(report.id)
    }

    func toggleExpansion(_ report: Report) {
        if expandedReportIDs.contains(report.id) {
            expandedReportIDs.remove(report.id)
        } else {
            expandedReportIDs.insert(report.id)
        }
    }

    // MARK: - Execução

    func startAnalysis() {
        analysisTask?.cancel()
        analysisTask = Task { [weak self] in
            await self?.analyze()
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    /// Verifica a assinatura de cada aplicativo instalado.
    ///
    /// A enumeração acontece em uma tarefa destacada; a validação acontece uma
    /// por vez, em tarefas destacadas individuais. Isso é o que torna "Parar"
    /// real: a cada iteração a tarefa observa o cancelamento e interrompe, sem
    /// deixar uma varredura inteira rodando em segundo plano.
    private func analyze() async {
        isAnalyzing = true
        wasInterrupted = false
        errorMessage = nil
        analyzedCount = 0
        defer { isAnalyzing = false }

        // `~/Downloads` só entra quando o usuário autorizou essa pasta nos
        // Ajustes. Uma tela que varresse fora do escopo declarado quebraria a
        // promessa feita lá — e a promessa é o produto.
        var extraRoots: [URL] = []
        if environment.scope?.includeDownloads == true {
            let home = FileManager.default.homeDirectoryForCurrentUser
            extraRoots.append(home.appendingPathComponent("Downloads", isDirectory: true))
        }

        let catalog = ApplicationCatalog(additionalRoots: extraRoots)

        let entries = await Task.detached(priority: .userInitiated) {
            catalog.listApplications(includeSizes: false)
        }.value

        if Task.isCancelled { wasInterrupted = true; return }

        guard !entries.isEmpty else {
            totalCount = 0
            reports = []
            errorMessage = "Nenhum aplicativo foi encontrado em /Applications nem em ~/Applications. Verifique se há aplicativos instalados neste Mac."
            return
        }

        totalCount = entries.count

        var collected: [Report] = []
        collected.reserveCapacity(entries.count)

        for entry in entries {
            if Task.isCancelled {
                wasInterrupted = true
                break
            }
            let report = await Task.detached(priority: .userInitiated) {
                ProtectionModel.makeReport(for: entry)
            }.value
            collected.append(report)
            analyzedCount += 1
        }

        reports = Self.sorted(collected)
        analyzedAt = Date()
    }

    private static func sorted(_ reports: [Report]) -> [Report] {
        let priority: [Verdict: Int] = [.suspicious: 0, .unverified: 1, .noIndicators: 2, .confirmed: 3]
        return reports.sorted { lhs, rhs in
            let left = priority[lhs.verdict] ?? 4
            let right = priority[rhs.verdict] ?? 4
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Regras

    /// Aplica as regras declaradas a um aplicativo.
    ///
    /// Não há heurística escondida aqui: cada `Rule` corresponde a um fato
    /// verificável, e o texto exibido descreve exatamente o que foi observado.
    nonisolated static func makeReport(for entry: ApplicationEntry) -> Report {
        let facts = SignatureInspector.inspect(entry.url)
        var rules: [Rule] = []

        // R-01 — assinatura. Executável sem assinatura e assinatura recusada
        // são casos reais e diferentes, com textos diferentes.
        if !facts.isValid {
            let base = facts.isSigned ? ProtectionRule.signatureInvalid : ProtectionRule.signatureMissing
            rules.append(Rule(
                code: base.code,
                title: base.title,
                summary: base.summary,
                detail: "\(base.detail) (código \(facts.statusCode))",
                effect: base.effect
            ))
        }

        // R-02 — identidade. Sem certificado e sem equipe, não há quem
        // responda por este código.
        if !facts.hasDeveloperIdentity {
            rules.append(ProtectionRule.withoutIdentity)
        }

        // R-03 — notarização.
        if case .notConfirmed(let status) = facts.notarization {
            let base = ProtectionRule.notarizationUnconfirmed
            rules.append(Rule(
                code: base.code,
                title: base.title,
                summary: base.summary,
                detail: "\(base.detail) (código \(status))",
                effect: base.effect
            ))
        }

        // R-04 — localização. Informação, não veredito: um aplicativo
        // assinado e notarizado continua assinado onde quer que esteja.
        if entry.location == .additional {
            rules.append(ProtectionRule.unusualLocation)
        }

        // R-05 — sincronização.
        if entry.isInSyncedFolder {
            rules.append(ProtectionRule.syncedFolder)
        }

        // R-06 — identificador do bundle.
        if entry.bundleIdentifier == nil {
            rules.append(ProtectionRule.missingBundleIdentifier)
        }

        // R-07 — confirmação. Só entra quando assinatura, identidade e
        // notarização passaram.
        if facts.isValid, facts.hasDeveloperIdentity, facts.isNotarized {
            let base = ProtectionRule.signedAndNotarized
            rules.append(Rule(
                code: base.code,
                title: base.title,
                summary: base.summary,
                detail: facts.teamIdentifier.map { "Equipe \($0). \(base.detail)" } ?? base.detail,
                effect: base.effect
            ))
        }

        return Report(
            name: entry.name,
            url: entry.url,
            bundleIdentifier: entry.bundleIdentifier,
            version: entry.versionSummary,
            location: entry.location,
            isAppleProvided: entry.isAppleProvided,
            isInSyncedFolder: entry.isInSyncedFolder,
            facts: facts,
            rules: rules
        )
    }
}

// MARK: - Leitura da assinatura

/// Leitura de assinatura e notarização pelo framework Security.
///
/// Existe como tipo separado porque cada função aqui é uma pergunta feita ao
/// sistema, e não um palpite: o que o `OSStatus` devolve é repassado para a
/// interface em vez de ser traduzido em "provavelmente bom".
enum SignatureInspector {

    /// Fatos verificados pelo macOS. Nada aqui tem valor padrão: um campo
    /// ausente é ausência de informação, não ausência do problema.
    struct Facts: Sendable {
        let isValid: Bool
        let isSigned: Bool
        /// Código retornado por `SecStaticCodeCheckValidity`, exibido na tela.
        let statusCode: Int32
        let teamIdentifier: String?
        let hasCertificateChain: Bool
        let notarization: Notarization

        var hasDeveloperIdentity: Bool {
            (teamIdentifier?.isEmpty == false) || hasCertificateChain
        }

        var isNotarized: Bool {
            if case .notarized = notarization { return true }
            return false
        }
    }

    /// Estado da notarização.
    enum Notarization: Sendable {
        /// O Gatekeeper confirma que o código foi registrado pela Apple.
        case notarized
        /// A verificação não passou. O código é repassado porque a causa exata
        /// depende da versão do macOS — e inventar a causa seria pior que
        /// mostrar o número.
        case notConfirmed(statusCode: Int32)
        /// Não há assinatura válida, então a pergunta não se aplica.
        case notApplicable
    }

    /// Lê assinatura, identidade e notarização de um bundle.
    ///
    /// Não toca em rede, não altera nada e não depende de API privada: são
    /// apenas as chamadas públicas do Security framework, as mesmas usadas pelo
    /// Gatekeeper.
    static func inspect(_ url: URL) -> Facts {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, nil, &staticCode)

        guard createStatus == errSecSuccess, let code = staticCode else {
            return Facts(
                isValid: false,
                isSigned: false,
                statusCode: createStatus,
                teamIdentifier: nil,
                hasCertificateChain: false,
                notarization: .notApplicable
            )
        }

        // `errSecCSUnsigned` é o único código que significa "não há
        // assinatura". Qualquer outro erro significa que existe uma assinatura
        // e ela não foi aceita — distinção que muda o texto exibido.
        let validityStatus = SecStaticCodeCheckValidity(code, 0, nil)
        let isValid = validityStatus == errSecSuccess
        let isSigned = validityStatus != errSecCSUnsigned

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information)
        let details = informationStatus == errSecSuccess ? information as? [String: Any] : nil
        let teamIdentifier = details?[kSecCodeInfoTeamIdentifier as String] as? String
        let certificates = details?[kSecCodeInfoCertificates as String] as? [Any]
        let hasCertificateChain = certificates?.isEmpty == false

        let notarization: Notarization
        if !isValid {
            notarization = .notApplicable
        } else {
            // Flag que exige o registro no serviço de notarização da Apple.
            // A conversão é explícita porque `SecCSFlags` é um `UInt32` e a
            // forma como as constantes de `SecStaticCode.h` são importadas
            // variou entre versões do SDK.
            let requiresNotarization: SecCSFlags = SecCSFlags(SecCSCheckNotarized)
            let notarizationStatus = SecStaticCodeCheckValidity(code, requiresNotarization, nil)
            notarization = notarizationStatus == errSecSuccess
                ? .notarized
                : .notConfirmed(statusCode: notarizationStatus)
        }

        return Facts(
            isValid: isValid,
            isSigned: isSigned,
            statusCode: validityStatus,
            teamIdentifier: teamIdentifier,
            hasCertificateChain: hasCertificateChain,
            notarization: notarization
        )
    }
}

// MARK: - Catálogo de regras

/// ## Regras declaradas do módulo de proteção
///
/// Este é o conjunto **fechado** do que o MacCare sabe avaliar. Ele existe em
/// forma de código, e não de texto solto em uma tela, por uma razão prática:
/// o catálogo que o usuário lê e a regra que decide o veredito precisam ser a
/// mesma coisa. Um painel de segurança que documenta cinco regras e executa
/// outras sete é pior do que um painel silencioso, porque parece auditável.
///
/// As regras vivem no escopo do arquivo — e não dentro de `ProtectionModel` —
/// porque a aplicação delas acontece em uma função `nonisolated`, executada
/// fora do MainActor. Uma constante de tipo isolado não poderia ser lida de lá.
enum ProtectionRule {

    static let signatureInvalid = ProtectionModel.Rule(
        code: "R-01a",
        title: "Assinatura presente, mas inválida",
        summary: "O código tem assinatura, mas a validação foi recusada.",
        detail: "O framework Security recusou a assinatura deste código. Conteúdo do pacote modificado depois da assinatura e certificado revogado produzem exatamente este resultado.",
        effect: .suspicious
    )

    static let signatureMissing = ProtectionModel.Rule(
        code: "R-01b",
        title: "Executável sem assinatura",
        summary: "O macOS informa que o código não possui assinatura.",
        detail: "O macOS informa que este código não possui assinatura. Um aplicativo distribuído pela Apple sempre tem.",
        effect: .suspicious
    )

    static let withoutIdentity = ProtectionModel.Rule(
        code: "R-02",
        title: "Sem identidade de desenvolvedor",
        summary: "A assinatura não traz certificado nem identificador de equipe.",
        detail: "A assinatura não apresenta certificado na cadeia nem identificador de equipe. Esse é o padrão de compilação local e de executáveis montados à mão, e também de muitos aplicativos legítimos de código aberto.",
        effect: .suspicious
    )

    static let notarizationUnconfirmed = ProtectionModel.Rule(
        code: "R-03",
        title: "Notarização não confirmada",
        summary: "A consulta de registro no serviço de notarização não passou.",
        detail: "A verificação de notarização não passou. Pode significar código não distribuído pelo canal da Apple ou uma limitação desta versão do macOS — por isso o estado é “não verificado”, nunca “seguro”.",
        effect: .unverified
    )

    static let unusualLocation = ProtectionModel.Rule(
        code: "R-04",
        title: "Instalado fora dos locais usuais",
        summary: "O aplicativo não está em /Applications nem em ~/Applications.",
        detail: "Este aplicativo está em uma pasta que o MacCare só leu porque ela faz parte do escopo que você autorizou. O local não altera a assinatura nem prova nada sobre o código.",
        effect: .informative
    )

    static let syncedFolder = ProtectionModel.Rule(
        code: "R-05",
        title: "Executável em pasta sincronizada",
        summary: "O pacote está em diretório sincronizado com iCloud ou outro serviço.",
        detail: "A sincronização pode propagar este aplicativo para outros Macs sem que você perceba. Não afeta a assinatura.",
        effect: .informative
    )

    static let missingBundleIdentifier = ProtectionModel.Rule(
        code: "R-06",
        title: "Pacote sem identificador",
        summary: "O Info.plist não declara CFBundleIdentifier.",
        detail: "O Info.plist não declara CFBundleIdentifier. Todo aplicativo distribuído normalmente o declara, e é por ele que permissões e integrações são concedidas.",
        effect: .informative
    )

    static let signedAndNotarized = ProtectionModel.Rule(
        code: "R-07",
        title: "Assinatura válida e código notarizado",
        summary: "Assinatura validada, com identidade de equipe e registro na Apple.",
        detail: "O macOS validou a assinatura e confirmou o registro no serviço de notarização da Apple. Ainda assim, isto não é uma análise de malware: é a procedência declarada do código.",
        effect: .confirming
    )

    /// Ordem de apresentação: primeiro as que mudam o veredito por indício,
    /// depois as que deixam o veredito incompleto, depois as informativas, e por
    /// fim a que sustenta a confirmação.
    static let catalogue: [ProtectionModel.Rule] = [
        signatureInvalid,
        signatureMissing,
        withoutIdentity,
        notarizationUnconfirmed,
        unusualLocation,
        syncedFolder,
        missingBundleIdentifier,
        signedAndNotarized
    ]
}
