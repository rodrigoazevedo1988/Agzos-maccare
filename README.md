# Agzos MacCare

Aplicativo de manutenção, limpeza, diagnóstico e organização para macOS.
Swift + SwiftUI, privacidade local por padrão, sem APIs privadas.

> **Status do projeto: em desenvolvimento ativo.**
> Este README descreve o que *está escrito no código*. A tabela abaixo é
> mantida de forma explícita: nada aqui é apresentado como concluído sem que
> os critérios de aceitação do PRD tenham sido verificados.

---

## Status real de verificação

Esta seção existe porque um README que afirma mais do que o código faz é um
problema, não um recurso. Ordem de leitura recomendada: ela primeiro.

| Área | Código | Compilado | Testado |
|------|--------|-----------|---------|
| Modelos de domínio | ✅ | ❌ | ✅ |
| `PathGuard` (motor de segurança) | ✅ | ❌ | ✅ |
| `SafeFileRemover` (motor de limpeza) | ✅ | ❌ | ✅ |
| `FileSystem` + abstrações | ✅ | ❌ | ✅ |
| Persistência de histórico (JSONL) | ✅ | ❌ | ✅ |
| Leitura de métricas do host | ✅ | ❌ | ✅ |
| Varredura de disco / duplicados | ✅ | ❌ | ✅ |
| Catálogo de apps / desinstalador | ✅ | ❌ | ✅ |
| Itens de inicialização | ✅ | ❌ | ✅ |
| Análise consolidada + recomendações | ✅ | ❌ | ✅ |
| Design system (tema + componentes) | ✅ | ❌ | ❌ |
| App shell, navegação e Dashboard | ✅ | ❌ | ❌ |
| 12 telas de módulo | ✅ | ❌ | ❌ |
| `project.yml`, `Info.plist`, entitlements | ✅ | ❌ | ❌ |
| GitHub Actions | ✅ | ❌ | ❌ |
| Documentação | ✅ | — | — |

**Por que "Compilado: ❌":** este projeto foi desenvolvido em um ambiente
Linux, sem Xcode e sem toolchain Swift. O código Swift foi escrito e revisado,
mas **nenhum binário foi gerado e nenhum teste foi executado**. A validação
real acontece no macOS, via `swift test` (núcleo) e `xcodebuild` (app).

Isso é registrado de forma explícita porque o PRD §27 exige que a documentação
reflita a implementação real. Um badge de "build passou" aqui seria mentira.

---

## Requisitos

- macOS 14 (Sonoma) ou superior — definido em `Package.swift`.
- Xcode 15 ou superior.
- Swift 5.10 ou superior.

Compatibilidade com macOS 13 e anteriores **não é prometida** sem validação.
O app usa Swift Charts, Observation e APIs de SwiftUI introduzidas no Sonoma.

## Como rodar

```bash
# 1. Núcleo (testes, Swift Testing) — rápido, sem GUI.
#    Funciona só com Command Line Tools; com Xcode, `swift test` direto
#    também serve. Ver docs/TESTING.md, seção 5.
scripts/test.sh

# 2. App completo — requer macOS + XcodeGen
brew install xcodegen
xcodegen generate
open MacCare.xcodeproj
```

## Estrutura

```
Sources/MacCareCore/     Núcleo determinístico — NÃO importa SwiftUI
  Models/                Tipos de domínio
  Safety/                PathGuard, SafeFileRemover, políticas de confirmação
  Services/              Varredura, duplicados, apps, métricas
  Storage/               Histórico e configurações locais
  Platform/              Abstrações sobre o sistema de arquivos
  Diagnostics/           Orquestração de análises

App/                     Aplicativo SwiftUI (depende de MacCareCore)
  App/                   Ponto de entrada
  UI/                    Design system, componentes, navegação
  Features/              Um diretório por módulo do PRD

Tests/                   Unitários, integração e UI
docs/                    ARCHITECTURE, SAFETY, TESTING, BUILD
```

**Por que o núcleo é um pacote SPM separado:** o PRD §22 exige que o módulo de
limpeza não dependa da interface SwiftUI. A consequência prática é que toda a
superfície destrutiva do aplicativo — as regras que impedem apagar arquivos
do sistema, seguir symlinks fora de escopo, ou pular a confirmação — é testável
com `swift test`, sem servidor gráfico e em segundos.

## Princípios de segurança implementados

- Nenhuma exclusão sem confirmação explícita do usuário.
- Exclusão definitiva exige autorização separada; o padrão é a Lixeira.
- A confirmação de itens arriscados (Lixeira, duplicados, arquivos grandes,
  downloads) é mais forte e não pode ser concedida por engano.
- Caminhos são revalidados **no momento da execução**, não só na análise.
- `/System`, `/usr`, `/etc`, volumes e a pasta pessoal do usuário são recusados.
- Symlinks que saem da área autorizada são recusados.
- Operações são registradas; histórico é apagável e exportável sem dados pessoais.

Detalhes em [`docs/SAFETY.md`](docs/SAFETY.md).

## Limitações conhecidas

Estas limitações são **reais** e não serão escondidas em versões futuras:

- **Temperatura:** o macOS não oferece API pública e confiável. O app
  exibe "Indisponível" permanentemente. Não há leitura de sensores privados.
- **Pressão de memória:** não existe API pública. O app mostra os componentes
  de memória separadamente, em vez de um número único enganoso.
- **CPU por processo:** não há API pública. O app lista processos com memória
  e sinaliza CPU por processo como indisponível quando é o caso.
- **Itens de inicialização:** leitura é possível; alteração só para o próprio
  MacCare. Para os demais, o app instrui o usuário nas Configurações do Sistema.
- **Full Disk Access:** não é solicitado por padrão. O app funciona sem ele e
  declara o que não conseguiu analisar.
- **Antivírus:** não existe. O módulo de proteção tem escopo declarado e não se
  apresenta como antivírus.

## Licença

Proprietário — © Agzos. Todos os direitos reservados.
