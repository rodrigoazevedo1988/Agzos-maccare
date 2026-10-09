import Foundation

/// ## O que este scanner faz — e o que ele não pode fazer
///
/// O macOS **não** expõe uma API pública que permita listar *e alterar* itens
/// de inicialização de terceiros. `SMAppService` só funciona para o próprio
/// aplicativo. Tudo o que existe para o resto do sistema é leitura de arquivos
/// em `LaunchAgents`/`LaunchDaemons` e a tela "Itens de login" das
/// Configurações do Sistema.
///
/// Este tipo, portanto, faz três coisas e é explícito sobre a quarta:
///
/// 1. Lista os itens legíveis, com origem e função.
/// 2. Marca os que são do sistema, que não devem ser tocados.
/// 3. Diz ao usuário onde resolver manualmente os que não são dele.
///
/// O que ele **não** faz: apagar arquivos de `LaunchAgents`/`LaunchDaemons`,
/// prometer impedir a execução de algo, ou fingir que alterou um item que
/// continua ativo.
public struct StartupItemScanner: Sendable {

    private let fs: FileSystem

    public init(fs: FileSystem = .live) {
        self.fs = fs
    }

    /// Diretórios monitorados, em ordem de precedência.
    private static var monitoredDirectories: [(url: URL, kind: StartupItem.Kind, source: StartupItem.Source)] {
        var directories: [(URL, StartupItem.Kind, StartupItem.Source)] = [
            (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), .launchDaemon, .systemLibrary),
            (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), .launchAgent, .systemLibrary)
        ]
        if let home = FileManager.default.homeDirectoryForCurrentUser {
            directories.append((home.appendingPathComponent("Library/LaunchAgents", isDirectory: true), .launchAgent, .userLibrary))
            directories.append((home.appendingPathComponent("Library/LaunchDaemons", isDirectory: true), .launchDaemon, .userLibrary))
        }
        return directories.map { (url: $0.0, kind: $0.1, source: $0.2) }
    }

    /// Lista os itens de inicialização legíveis.
    ///
    /// ## Por que `isEnabled` quase sempre é `nil`
    ///
    /// Um `LaunchAgent` carregado pode ter sido desabilitado no login de forma
    /// que o macOS não expõe por API pública. Reportar `false` nesse caso
    /// seria afirmar algo que não sabemos. `nil` significa "o macOS não
    /// informa", e a interface diz exatamente isso.
    public func scan(runningIdentifiers: Set<String> = []) -> [StartupItem] {
        var items: [StartupItem] = []
        var seenPaths = Set<String>()

        for (directory, kind, source) in Self.monitoredDirectories {
            guard let plists = try? fs.contents(of: directory) else { continue }

            for plistURL in plists where plistURL.pathExtension.lowercased() == "plist" {
                guard !seenPaths.contains(plistURL.path) else { continue }
                seenPaths.insert(plistURL.path)

                guard let dict = Self.readPlist(at: plistURL) else { continue }
                let label = (dict["Label"] as? String) ?? plistURL.deletingPathExtension().lastPathComponent

                // Itens da Apple nunca são apresentados como removíveis.
                let isSystem = label.hasPrefix("com.apple.")
                    || directory.path.hasPrefix("/Library/")
                    || (dict["com.apple.system"] as? Bool) == true

                items.append(
                    StartupItem(
                        label: label,
                        isSystemProvided: isSystem,
                        kind: kind,
                        source: source,
                        url: plistURL,
                        bundleIdentifier: dict["Label"] as? String,
                        isEnabled: nil,
                        summary: Self.summary(from: dict, label: label),
                        isCurrentlyRunning: runningIdentifiers.contains(label)
                    )
                )
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.isSystemProvided != rhs.isSystemProvided { return !lhs.isSystemProvided }
            return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
        }
    }

    /// Traduz o `ProgramArguments` em algo legível.
    private static func summary(from dict: [String: Any], label: String) -> String? {
        if let summary = dict["ServiceDescription"] as? String { return summary }
        if let comment = dict["Description"] as? String { return comment }

        let arguments = dict["ProgramArguments"] as? [String]
        guard let executable = arguments?.first else { return nil }
        return executable
    }

    /// Lê um plist em qualquer formato (binário ou XML).
    private static func readPlist(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return nil
        }
        return plist as? [String: Any]
    }
}

/// ## Guia de ação manual
///
/// Quando o app não pode alterar um item, ele entrega a instrução exata em vez
/// de um botão que não faz nada. Um botão inativo é pior que uma frase clara.
public enum StartupItemGuidance {

    public static func instruction(for item: StartupItem) -> String {
        if item.isSystemProvided {
            return "Item do sistema macOS. O MacCare não altera itens do sistema — e não é recomendável hacerlo."
        }
        return "Para desativar \(item.label): Configurações do Sistema › Geral › Itens de login & extensões. Desmarque o item e reinicie."
    }

    /// URL de sistema para abrir a tela correta diretamente.
    public static func settingsURL(for item: StartupItem) -> URL? {
        guard !item.isSystemProvided else { return nil }
        return URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }
}
