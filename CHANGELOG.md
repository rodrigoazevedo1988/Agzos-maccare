# Changelog

Todas as mudanças relevantes deste projeto são registradas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/), e
o versionamento segue [SemVer](https://semver.org/lang/pt-BR/).

---

## [Não publicado]

### Adicionado

**Núcleo de segurança**
- `PathGuard` — autorização de caminhos por escopo explícito, com lista de
  caminhos protegidos, resolução de links simbólicos antes da comparação e
  falha fechada quando não há escopo autorizado.
- `SafeFileRemover` — `actor` que executa remoções validadas, revalidando cada
  caminho no momento da execução (fecha a janela TOCTOU entre análise e ação).
- Confirmação como **restrição de inicialização**: `ConfirmedSelection.init`
  e `RemovalPlan.init` são `throws`, e não existe caminho de código que remova
  arquivos sem passar por eles.
- Confirmação reforçada obrigatória para Lixeira, duplicados, arquivos grandes,
  downloads antigos e dados de navegação.
- Exclusão definitiva exige uma segunda autorização explícita, separada da
  confirmação.

**Serviços de sistema**
- `HostMetricsCollector` — CPU, memória (componentes separados), volume,
  bateria e processos, todos via API pública. Sem APIs privadas.
- `DirectoryScanner` — varredura com cancelamento, progresso real, limites
  configuráveis e tolerância a erro de leitura.
- `DuplicateFinder` — detecção em quatro estágios: tamanho, metadados, SHA-256
  em blocos e confirmação por conteúdo. Detecta e exclui hard links antes de
  comparar, para não tratar o mesmo inode como duplicata.
- `ApplicationCatalog` e `Uninstaller` — descoberta de aplicativos e
  classificação de residuais por nível de confiança da associação.
- `StartupItemScanner` — leitura de `LaunchAgents`/`LaunchDaemons`, com
  distinção explícita entre item do sistema e item do usuário.

**Diagnóstico**
- `SmartScanCoordinator` — análise consolidada, com deduplicação por caminho
  antes de somar, para que o espaço estimado não conte o mesmo arquivo duas
  vezes.
- `RecommendationEngine` — recomendações com **evidência** e **critério**
  explícitos. Não existe "nota de saúde" inventada.

**Persistência**
- `JSONLOperationLog` — histórico append-only, crash-safe, sem migração de
  schema, com exportação redigida.

**Aplicativo**
- Design system completo em `Theme` — cores dinâmicas (claro/escuro sem catálogo
  de assets), escala fechada de espaçamento, tipografia, raios e movimento.
- Componentes reutilizáveis: `Card`, `SectionHeader`, `StatTile`, `EmptyStateView`,
  `Badge`, `PathLabel`, `ProgressRing`, `PrimaryActionButton`, `LimitationNotice`.
- `AppEnvironment` como contêiner de dependências; o `PathGuard` é reconstruído
  junto com o escopo, de modo que reduzir o escopo revoga autorizações antigas.
- Visão geral com medidas reais, tiles de estado indisponível e ações rápidas.
- Navegação dirigida por dados (`Feature`): adicionar um módulo é um `case`.

**Infraestrutura**
- Núcleo em pacote SPM separado, sem SwiftUI — permite testar toda a superfície
  destrutiva com `swift test`, sem GUI e em segundos.
- `project.yml` (XcodeGen) — o `.xcodeproj` é gerado e não é versionado.
- GitHub Actions: `swift build`, `swift test`, geração do projeto, `xcodebuild
  build` e `xcodebuild test`, com verificação de segredos no diff e checagem de
  invariantes dos entitlements.
- Documentação: `README`, `docs/ARCHITECTURE.md`, `docs/SAFETY.md`,
  `docs/TESTING.md`, `docs/BUILD.md`, `SECURITY.md`.

### Decisões que valem registro

- **Sem App Sandbox.** Documentado em `Resources/MacCare.entitlements`. Com
  sandbox, a única forma de varrer a pasta do usuário seria pedir Full Disk
  Access, que o PRD proíbe por padrão. Em troca: Hardened Runtime ativo, zero
  execução de script, e seleção de pasta via diálogo do sistema.
- **JSONL em vez de SwiftData** para o histórico. Crash-safe por construção, sem
  migração de schema, inspecionável pelo usuário e testável sem container.
- **Sem "nota de saúde".** Um número de 0 a 100 comprime coisas incomparáveis
  em uma escala que parece objetiva e não é. Cada recomendação carrega a
  evidência medida e o limiar que a disparou.
- **CPU por processo é `nil` por decisão.** Não existe API pública confiável;
  o app diz "indisponível" em vez de mostrar um número que às vezes funciona.

---

## [0.1.0] — não publicado

Ainda não existe versão publicada. A primeira release exigirá, no mínimo:

- `swift test` passando em macOS com Swift 5.10 ou superior
- `xcodebuild build` sem erros
- `Resources/Info.plist` validado
- Conta de desenvolvedor Apple com certificado `Developer ID Application`
- Notarização concluída e validada
- `CHANGELOG.md` e `README.md` revisados contra o binário real

Nada disso foi feito. Um badge de "build passou" neste repositório seria uma
afirmação falsa.

[Não publicado]: https://github.com/rodrigoazevedo1988/Agzos-maccare/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rodrigoazevedo1988/Agzos-maccare/releases/tag/v0.1.0
