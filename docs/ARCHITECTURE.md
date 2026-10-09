# Arquitetura

> **Estado de verificação:** escrito e revisado, **não compilado nem testado**.
> O desenvolvimento ocorreu em ambiente Linux, sem Xcode. Ver
> [`../README.md`](../README.md) para a matriz de status.

---

## 1. A divisão que importa

O projeto tem duas camadas, e a fronteira entre elas é o desenho mais
importante do código:

```
┌──────────────────────────────────────────────────────────┐
│  App/            SwiftUI                                 │
│  MacCareApp · Theme · Components · Features/*             │
│                        ↓ lê estado, nunca apaga          │
├──────────────────────────────────────────────────────────┤
│  Sources/MacCareCore/     SPM · NÃO importa SwiftUI      │
│  Models · Safety · Services · Storage · Platform         │
│  Diagnostics · Utilities                                  │
│                        ↓                                   │
│  macOS público: FileManager · mach · IOKit · CryptoKit   │
└──────────────────────────────────────────────────────────┘
```

**O núcleo não importa SwiftUI.** Isso é exigência do PRD §22, e a consequência
prática é que toda a superfície destrutiva do aplicativo — as regras que
impedem apagar o sistema, seguir symlink fora de escopo, ou pular a
confirmação — é testável com `swift test`, sem servidor gráfico, sem sandbox e
em segundos.

Uma tela SwiftUI nunca chama `FileManager.removeItem`. A única porta de entrada
é `AppEnvironment.performCleanup`.

---

## 2. Por que o núcleo é um pacote SPM separado

Alternativa descartada: um único target Xcode com todos os arquivos.

| Aspecto | Núcleo separado | Target único |
|---------|-----------------|--------------|
| Testes do motor de segurança | `swift test`, ~1 s | Precisa de `xcodebuild test` + simulador |
| CI | Roda em qualquer runner; só a etapa de app precisa de macOS | Falha inteira se o Xcode não estiver disponível |
| Regressão de segurança | Barato e frequente | Caro e raro |
| Acoplamento | Compilação falha se a UI vazar para o núcleo | Mistura silenciosa |

Para um produto cuja proposta é "seguro por construção", a economia é que a
regra de segurança pode ser exercitada em toda alteração de código relevante.

---

## 3. Módulos do núcleo

### Models
Tipos de domínio, sem comportamento. `CleanupCandidate`, `SystemSnapshot`,
`ApplicationEntry`, `DuplicateGroup`, `StartupItem`, `OperationRecord`.

O caso especial é `Measurement<T>`:

```swift
enum Measurement<Value: Sendable> {
    case available(Value)
    case unavailable(UnavailableReason)
}
```

Existe porque o PRD §15 exige que a falta de dado seja um *estado
indisponível*, e `T?` + `Bool` não carrega o motivo. Usar `Measurement` força o
chamador a tratar o caso "não existe" **na compilação**, e leva a explicação
até a interface.

### Safety
`PathGuard` (autorização) e `SafeFileRemover` (execução). Detalhamento em
[`SAFETY.md`](SAFETY.md).

### Services
`HostMetricsCollector`, `DirectoryScanner`, `DuplicateFinder`,
`ApplicationCatalog`, `Uninstaller`, `StartupItemScanner`.

### Storage
`JSONLOperationLog` — histórico append-only.

### Diagnostics
`SmartScanCoordinator` (análise consolidada) e `RecommendationEngine`
(recomendações com critérios).

### Platform
`FileSystem` — protocolo sobre o sistema de arquivos, com `LiveFileSystem` e
um dublê em memória nos testes.

---

## 4. Decisões de projeto e o porquê

### 4.1 Por que JSONL e não SwiftData

O PRD §20 autoriza "SwiftData ou armazenamento local apropriado". A escolha é
JSONL, e a justificativa é concreta:

- **Crash-safe por construção.** Log append-only: um encerramento abrupto
  perde no máximo a última linha, nunca o arquivo inteiro.
- **Sem migração de schema.** Cada registro é autocontido. Nenhuma versão
  futura precisa migrar a base do usuário.
- **Inspecionável.** O usuário pode abrir o arquivo e ver exatamente o que o
  app guardou — o que combina com a promessa de transparência.
- **Testável sem container.** Os testes criam arquivos temporários reais em vez
  de simular um framework de persistência.

O custo real é leitura completa para listar. Para um histórico de manutenção
— dezenas ou centenas de registros por ano — é irrelevante. Se o volume mudar,
a troca fica isolada atrás do protocolo `OperationLogStoring`.

### 4.2 Por que `FileSystem` é um protocolo

Duas razões, ambas práticas:

1. **Testabilidade.** O PRD §25 exige provar que o app *não* apaga as coisas
   erradas. Com `FileManager` real, cada teste criaria e destruiria arquivos de
   verdade. Com o dublê em memória, o mesmo conjunto de asserções roda em
   milissegundos e uma falha não deixa lixo.
2. **Concorrência.** `FileManager` não é `Sendable`. Encapsulá-lo permite que
   cada operação concorrente use a sua própria instância.

### 4.3 Por que o `PathGuard` é reconstruído quando o escopo muda

Em `AppEnvironment.rebuildCleaningServices()`:

```swift
let guardrail = (scope?.makePathGuard(ownBundle:)) ?? .denyAll
```

O `PathGuard` é **recriado junto com o escopo**. Se o usuário reduz o escopo,
as autorizações antigas morrem — não existe estado obsoleto capaz de autorizar
uma remoção que ele já revogou.

### 4.4 Por que não existe "nota de saúde"

O PRD §6 proíbe inventar pontuação sem critérios documentados. Um número de 0 a
100 comprime coisas incomparáveis — disco cheio e uso de CPU — em uma escala
que parece objetiva e não é.

A alternativa é mais verbosa e mais honesta. Cada `Insight` carrega a
**evidência** ("restam 82 GB de 994 GB") e o **critério** ("abaixo de 10% de
espaço livre"). O usuário pode concordar ou discordar do limiar, que é o que
torna a recomendação auditável em vez de autoritária.

Os limiares vivem em `InsightThresholds`, em um só lugar, justamente para que
mudar um critério seja uma alteração visível de política.

### 4.5 Por que CPU por processo é `nil`

O macOS não expõe CPU por processo em API pública documentada.
`proc_pid_rusage` existe em `<libproc.h>`, mas pertence à superfície não
documentada e responde de forma inconsistente sob App Sandbox.

Usá-la produziria um número que às vezes funciona e às vezes não, sem que o
usuário pudesse saber qual dos dois está olhando. O app prefere dizer
"indisponível". O campo `cpuFraction` existe na API para quando uma fonte
confiável surgir.

---

## 5. APIs nativas usadas

Todas públicas. Nenhuma privada.

| Necessidade | API | Observação |
|-------------|-----|-----------|
| Modelo / chip / versão | `sysctlbyname` | `hw.model`, `machdep.cpu.brand_string`, `kern.osversion` |
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)` | Ticks acumulados desde o boot |
| Memória | `host_statistics64(HOST_VM_INFO64)` + `os_proc_available_memory()` | Componentes separados, nunca um total |
| Swap | `sysctlbyname("vm.swapusage")` | |
| Volume | `URL.resourceValues(.volumeTotalCapacityKey, …)` | |
| Bateria | `IOPSCopyPowerSourcesInfo` (IOKit.ps) | Lista vazia em Mac de mesa = sem bateria |
| Processos | `sysctl(KERN_PROC_ALL)` | Nome, PID e memória residente |
| Integridade | `SecStaticCodeCreateWithPath` (Security.framework) | Na tela de proteção |
| Hash | `CryptoKit.SHA256` | Leitura em blocos de 1 MiB |
| Lixeira | `FileManager.trashItem` | Reversível |
| Módulos | `PropertyListSerialization` | `Info.plist` e `LaunchAgents` |

### O que não existe e por isso aparece como "Indisponível"

| Dado | Por quê |
|------|---------|
| Temperatura | Nenhuma API pública. Bibliotecas que fazem isso usam frames privados de IOKit. |
| Pressão de memória | Nenhuma API pública. |
| CPU por processo | API não documentada e inconsistente. |
| Saúde da bateria | A Apple não expõe por API pública. |
| Nome comercial do Mac | Não há API. O app mostra o identificador (`hw.model`). |
| Permissões de apps instaladas | O macOS não expõe. Tela de privacidade é orientação. |
| Alterar itens de login de terceiros | Só `SMAppService` para o próprio app. |

Cada uma dessas ausências é uma linha no modelo, não um `0`.

---

## 6. Concorrência e desempenho

O PRD §24 exige responsividade e cancelamento.

- **Varreduras**: `DirectoryScanner` é um `actor`; emite `AsyncStream<URL>` com
  `bufferingNewest(512)`. Uma varredura de disco não pode encher a fila de URLs
  e estourar a memória.
- **Cota de concorrência**: `SafeFileRemover` processa em janelas de 4 itens —
  alta o bastante para I/O não bloquear, baixa o bastante para não saturar o
  disco.
- **Hash fora da thread cooperativa**: hashear um arquivo grande é I/O
  síncrono. `DuplicateFinder.sha256` roda em `Task.detached` — na thread
  cooperativa, travaria a interface.
- **`ScanLimits`**: teto de arquivos, profundidade e duração. Existes para que o
  app não fique indistinguível de um processo pendurado num disco lento.
- **Nada automático ao abrir**: o app lê métricas do host na abertura (barato e
  instantâneo). Varreduras de disco só acontecem quando o usuário pede.
- **Medição antes da remoção**: o tamanho é lido antes do `unlink`; depois já
  não existe.

---

## 7. Fluxo de uma limpeza

```
Usuário clica em "Analisar"
   └─ SmartScanCoordinator.run(scope:)
        ├─ varre caches e logs          → candidatos .certain
        ├─ Lixeira (categoria isolada)  → candidato .certain
        ├─ Downloads antigos            → .uncertain, nunca pré-selecionado
        ├─ Dados de desenvolvimento     → .likely, nunca pré-selecionado
        └─ deduplica por caminho        → SmartScanResult

Usuário revisa, marca, e confirma
   └─ AppEnvironment.performCleanup(candidates:strategy:kind:)
        ├─ escolhe ConfirmationKind pelo risco das categorias
        ├─ ConfirmedSelection.init(items:kind:)      ← throws se insuficiente
        ├─ RemovalPlan(selection:strategy:)           ← throws se não autorizado
        └─ SafeFileRemover.execute(plan)              ← actor
             ├─ PathGuard revalida CADA caminho agora
             ├─ mede o tamanho antes de remover
             ├─ moveToTrash / remove / skip
             └─ monta RemovalReport + SpaceAccounting
                  └─ OperationLog.append(_:)          ← JSONL
```

A tela não participa de nenhuma etapa destrutiva. Ela monta a lista e chama
`performCleanup`.

---

## 8. Estrutura de arquivos

```
Sources/MacCareCore/
  Models/        Measurement · CleanupCandidate · SystemSnapshot
                 ApplicationEntry · FileEntries · OperationRecord
  Safety/        PathGuard · SafeFileRemover
  Services/      HostMetricsCollector · DirectoryScanner · DuplicateFinder
                 ApplicationCatalog · StartupItemScanner
  Storage/       JSONLOperationLog
  Diagnostics/   SmartScanCoordinator · RecommendationEngine
  Platform/      FileSystem (protocol) · LiveFileSystem · FileSizeMeasurer
  Utilities/     ByteSizeFormatter

App/
  App/           MacCareApp · AppEnvironment
  UI/Theme/      Theme
  UI/Components/ CoreComponents
  UI/Navigation/ AppModel (Feature · sidebar · roteamento)
  Features/      Dashboard · SmartCare · StorageAnalyzer · LargeFiles
                 Duplicates · Applications · Performance · StartupItems
                 Privacy · Protection · History · Settings

Tests/
  MacCareCoreTests/          unitários + segurança (InMemoryFileSystem)
  MacCareIntegrationTests/   núcleo contra FS real, só em temporários
  MacCareUITests/            navegação, cancelamento, temas
```

---

## 9. O que ainda não existe

Para que ninguém suponha o que não foi feito:

- **Nenhuma verificação de build.** O código não foi compilado.
- **Nenhum teste executado.** A suíta está escrita, não rodada.
- **Sem `Info.plist`.** O `project.yml` referencia `Resources/Info.plist`, que
  ainda precisa ser criado.
- **Sem assinatura nem notarização.** Exige conta de desenvolvedor Apple e
  credenciais que não existem neste repositório.
- **Sem módulo de IA.** O PRD §21 é sobre *preparar a arquitetura*; nada foi
  implementado, e nada foi simulado.
- **Sem detecção de imagens visualmente semelhantes.** O PRD §11 marca isso
  como módulo futuro, separado de duplicados exatos.
