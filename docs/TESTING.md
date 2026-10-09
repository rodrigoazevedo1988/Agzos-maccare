# Testes

> **Estado:** a suíte usa **Swift Testing** (`import Testing`) e roda com
> `swift test` em macOS — inclusive só com as Command Line Tools, sem Xcode
> (ver seção 5). Última execução: 58 testes em 5 suítes, 57 passando e 1 falha
> conhecida (`PathGuardTests.testPermiteSymlinkResolvidoDentroDoEscopo`, ver
> seção 7). Os testes de interface (`Tests/MacCareUITests`) continuam em
> XCTest/XCUITest e exigem Xcode.

---

## 1. O que a suíte precisa provar

O PRD §25 lista quatro grupos. O critério que realmente importa é o terceiro:
**segurança**. Um app de manutenção que apaga o arquivo errado não tem bug — tem
incidente.

| Grupo | O que valida | Onde |
|-------|--------------|------|
| Unitários | Cálculo, dedup, filtros, ordenação, formatação, regras | `Tests/MacCareCoreTests/` |
| Integração | Descoberta de apps, `Info.plist`, varredura, hash, Lixeira | `Tests/MacCareIntegrationTests/` |
| Segurança | Nada é apagado sem confirmação, nada fora de escopo, symlinks | `Tests/MacCareCoreTests/PathGuardTests.swift`, `SafeFileRemoverTests.swift` |
| Interface | Navegação, cancelamento, estados vazios, temas | `Tests/MacCareUITests/` |

---

## 2. Por que `InMemoryFileSystem`

O requisito do PRD §25 é provar que o app **não** apaga as coisas erradas. Com
`FileManager` real, cada teste criaria arquivos de verdade — e um teste que
falha no meio deixa lixo no disco da máquina de quem roda.

`Tests/MacCareCoreTests/TestSupport/InMemoryFileSystem.swift` implementa o
protocolo `FileSystem` em memória e registra explicitamente:

```swift
fs.trashedPaths   // tudo que foi para a Lixeira
fs.deletedPaths   // tudo que foi removido definitivamente
```

O teste passa quando `deletedPaths` está **vazio** depois de uma operação cujo
padrão é a Lixeira. Essa é a forma de provar a regra, em vez de confiar nela.

---

## 3. Casos de segurança (os que não podem quebrar)

### `PathGuardTests`

| Teste | O que impede |
|-------|--------------|
| `testSemEscopoAutorizadoNaoPermiteNada` | Um `PathGuard` vazio virar "posso remover tudo" |
| `testRecusaRaizDoSistema` | Remoção em `/System` mesmo com escopo `["/"]` |
| `testRecusaDescendenteDeCaminhoProtegido` | Bypass por caminho aninhado (`/usr/local/lib`) |
| `testRecusaSymlinkQueSaiDoEscopo` | Link autorizado apontando para `/System` |
| `testPermiteSymlinkResolvidoDentroDoEscopo` | Quebrar symlinks legítimos (`/tmp` → `/private/tmp`) |
| `testRecusaTravessiaAcimaDaRaizAutorizada` | `../` escapando do escopo |
| `testRecusaARaizAutorizadaElaMesma` | Apagar a pasta que o usuário autorizou |
| `testRecusaRemocaoDoProprioBundle` | Auto-destruição |

### `SafeFileRemoverTests`

| Teste | O que impede |
|-------|--------------|
| `testSelecaoVaziaERecusada` | Plano executável sem seleção |
| `testCategoriaArriscadaExigeConfirmacaoReforcada` | Esvaziar a Lixeira com confirmação padrão |
| `testExclusaoDefinitivaExigeAutorizacao` | `permanentlyDelete` sem a segunda autorização |
| `testExecucaoPadraoUsaLixeira` | Qualquer remoção permanente no fluxo normal |
| `testFalhaAoMoverParaLixeiraNaoApagaSilenciosamente` | O `catch` que apaga direto quando a Lixeira falha |
| `testItemProtegidoEIgnoradoComMotivo` | Falhar em silêncio em vez de explicar a recusa |
| `testEspacoDaLixeiraNaoECountadoComoLiberado` | Anunciar "12 GB liberados" ao mover para a Lixeira |
| `testEspacoConfirmadoRespeitaMedicao` | Afirmar liberação maior que a soma medida |
| `testRevalidaCaminhoNoMomentoDaExecucao` | TOCTOU entre análise e execução |

`testFalhaAoMoverParaLixeiraNaoApagaSilenciosamente` merece nota: ele existe
para impedir a "correção" mais tentadora do código — o `catch` que apaga o
arquivo direto quando `trashItem` falha. É uma mudança de duas linhas que
passaria em revisão apressada e violaria o princípio central do produto.

### Integração

| Teste | O que cobre |
|-------|-------------|
| `testRemocaoUsaLixeiraPorPadrao` | `FileManager.trashItem` real |
| `testCaminhoForaDoEscopoEIgnoradoNaIntegracao` | Escopo real com candidato externo |
| `testDetectaArquivosComConteudoIdentico` | SHA-256 real, 4 arquivos |
| `testNomesParecidosNaoSaoDuplicatas` | Impede atalho por nome + tamanho |
| `testHardLinksNaoViramGrupoDeDuplicatas` | Dois caminhos, um inode, zero cópias |
| `testVarreduraRespeitaCancelamento` | `Task.isCancelled` durante varredura |
| `testPastaSemInfoPlistNaoEReconhecidaComoApp` | `.app` falso na lista de aplicativos |

---

## 4. Regra de isolamento

O PRD §25: *"nunca executar testes destrutivos em diretórios reais do usuário,
usar diretórios temporários e fixtures dedicadas"*.

Os testes de integração criam a própria árvore em `/tmp` e a removem no
`deinit` da suíte — **inclusive quando o teste falha**. A suíte é uma `class`
e o Swift Testing cria uma instância por teste, então cada teste tem o próprio
diretório e o `deinit` roda ao fim de cada um.

Por que `/tmp` e não `FileManager.default.temporaryDirectory`: no macOS o
temporário por usuário fica em `/private/var/folders/...`, e `/private/var` é
caminho protegido do `PathGuard`. Os testes de remoção seriam recusados pela
proteção em vez de exercitar a Lixeira.

`testRemocaoUsaLixeiraPorPadrao` move um arquivo de verdade para a Lixeira do
usuário (é o que ele testa). O arquivo tem nome único, o teste confere que ele
está em `~/.Trash` e depois apaga exatamente esse item de lá.

Nenhum teste toca `/Users`, `/Library` ou `/Applications`. As asserções de
caminho usam strings com estrutura de Mac (`/Users/teste/...`) porque o que está
sob teste é a **decisão**, não o disco.

---

## 5. Como executar

`scripts/test.sh` é `swift test` com os caminhos do Swift Testing quando só as
Command Line Tools estão instaladas; com Xcode selecionado, ele chama
`swift test` puro. Todos os argumentos são repassados.

```bash
# Núcleo + integração: unitários, segurança e sistema de arquivos real.
scripts/test.sh

# Só um arquivo
scripts/test.sh --filter PathGuardTests

# Só segurança
scripts/test.sh --filter "PathGuard|SafeFileRemover"

# Diagnóstico detalhado
scripts/test.sh --verbose

# Integração (usa o sistema de arquivos real, ainda em temporários)
scripts/test.sh --filter CoreIntegrationTests
```

Com Xcode, `swift test` direto funciona igual.

**Por que o script existe.** Com apenas as Command Line Tools, o
`Testing.framework` fica em
`/Library/Developer/CommandLineTools/Library/Developer/Frameworks`, mas o
SwiftPM não passa esse caminho ao compilador nem ao linker. `swift test` puro
falha com `no such module 'Testing'`. Colocar o caminho no `Package.swift` não
basta: o runner que o SwiftPM gera não recebe o flag, compila sem
`import Testing` e termina "verde" sem executar **nenhum** teste. Um verde falso
é pior que um erro, então o caminho fica no script, que vale para todos os
alvos.

Via Xcode, incluindo interface:

```bash
xcodegen generate
xcodebuild test -scheme MacCare -destination 'platform=macOS'
```

---

## 6. Cobertura de interface

`Tests/MacCareUITests/` cobre o que só aparece na tela:

- Navegação entre módulos pelo menu lateral
- Estado vazio de cada tela que pode ficar vazia
- Diálogo de confirmação **aparece** e **não executa** ao cancelar
- Progresso visível durante varredura longa
- Botão de cancelar interrompe a operação
- Tema claro e escuro sem texto ilegível
- Redimensionamento da janela sem truncar conteúdo
- Navegação por teclado nos controles principais

---

## 7. O que ainda falta testar

Honestidade sobre o buraco:

- **Falha conhecida em aberto:** `testPermiteSymlinkResolvidoDentroDoEscopo`.
  `PathGuard.resolve` usa `resolvingSymlinksInPath()`, que remove o prefixo
  `/private` só quando o caminho existe: a raiz `/private/tmp` vira `/tmp`, e
  um arquivo ainda inexistente continua `/private/tmp/...`. A falha é sempre
  para o lado da recusa, então é segura, mas contradiz o comentário do código.
  Corrigir é decisão de produto e fica pendente.
- **Os testes de UI (XCUITest) não rodam sem Xcode** e não foram executados.
- **Não há teste de concorrência** para as janelas de 4 operações do
  `SafeFileRemover`.
- **Não há teste de PerformanceView** com amostragem de CPU.

O primeiro passo ao receber o repositório em um Mac é rodar `scripts/test.sh` e
corrigir o que aparecer. Os testes de segurança são a prioridade: eles definem
o que o produto não pode fazer.
