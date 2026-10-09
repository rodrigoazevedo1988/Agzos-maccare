# Testes

> **Estado:** a suíte usa **Swift Testing** (`import Testing`) e roda com
> `swift test` em macOS — inclusive só com as Command Line Tools, sem Xcode
> (ver seção 5). Última execução (9 out. 2026, macOS 27.0.1, Swift 6.3.2 CLT):
> **90 testes em 6 suítes, todos passando**, sem testes pulados nem falhas
> conhecidas. Os testes de interface (`Tests/MacCareUITests`) continuam em
> XCTest/XCUITest, exigem Xcode e **nunca foram executados**.
>
> | Suíte | Arquivo | Testes |
> |-------|---------|--------|
> | Segurança — PathGuard | `PathGuardTests.swift` | 24 (um parametrizado com 7 casos) |
> | Segurança — desinstalação de aplicativos | `AppUninstallAuthorizationTests.swift` | 20 |
> | Segurança — SafeFileRemover | `SafeFileRemoverTests.swift` | 11 |
> | Formatação e histórico | `CoreSupportTests.swift` | 11 |
> | Planejamento da limpeza | `CleanupPlanningTests.swift` | 7 |
> | Integração do núcleo | `CoreIntegrationTests.swift` | 17 |

---

## 1. O que a suíte precisa provar

O PRD §25 lista quatro grupos. O critério que realmente importa é o terceiro:
**segurança**. Um app de manutenção que apaga o arquivo errado não tem bug — tem
incidente.

| Grupo | O que valida | Onde |
|-------|--------------|------|
| Unitários | Cálculo, dedup, filtros, ordenação, formatação, regras | `Tests/MacCareCoreTests/` |
| Integração | Descoberta de apps, `Info.plist`, varredura, hash, Lixeira | `Tests/MacCareIntegrationTests/` |
| Segurança | Nada é apagado sem confirmação, nada fora de escopo, symlinks, desinstalação | `Tests/MacCareCoreTests/PathGuardTests.swift`, `SafeFileRemoverTests.swift`, `AppUninstallAuthorizationTests.swift` |
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
| `testRecusaSymlinkQueSaiDoEscopo` | Atravessar um link **real** do escopo para `/System/Library` |
| `testRecusaCaminhoAtravesDeSymlinkParaForaDoEscopo` | Atravessar um link real para pasta comum fora do escopo (`.symlinkEscapesScope`) |
| `testLinkNoEscopoResolveParaOProprioLink` | Veredito apontando para o destino de um link em vez do próprio link |
| `testPermiteSymlinkResolvidoDentroDoEscopo` | Quebrar symlinks legítimos: todas as grafias `/tmp` ↔ `/private/tmp`, inclusive caminhos inexistentes |
| `testRecusaRaizesDeSistemaEmPrivate` (7 casos) | Remover `/private`, `/private/tmp`, `/private/var`, `/private/etc`, `/tmp`, `/var`, `/etc` |
| `testRecusaTravessiaAcimaDaRaizAutorizada` | `../` escapando do escopo (`.pathTraversal`) |
| `testRecusaTravessiaMesmoQuandoTerminariaNoEscopo` | Aceitar `..` só porque o resultado cai dentro |
| `testRaizComTravessiaEDescartada` | Raiz com `..` virar autorização ampla |
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

### `AppUninstallAuthorizationTests`

Tudo em `InMemoryFileSystem`; leitor de identificador e "está aberto?" são
injetados.

| Teste | O que impede |
|-------|--------------|
| `testBundleValidoEResiduaisSaoAceitos` | Bloquear a desinstalação legítima (bundle + 10 locais de residuais) |
| `testCaminhoAninhadoEmApplicationsERecusado` | `/Applications/Pasta/App.app` |
| `testItemDentroDoBundleERecusado` | Autorizar um arquivo dentro do bundle como se fosse o app |
| `testPastaApplicationsElaMesmaERecusada` | Apagar `/Applications` |
| `testAppDoSistemaERecusado` / `testAppDaAppleEmApplicationsERecusado` | Desinstalar app do sistema ou da Apple |
| `testProprioBundleERecusado` | O MacCare desinstalar a si mesmo (caminho ou identificador) |
| `testBundleQueELinkSimbolicoERecusado` | `/Applications/X.app` que é link para outro lugar |
| `testAppAbertoERecusado` | Desinstalar app em uso |
| `testSoOsCaminhosExatosSaoAceitos` | Autorização por prefixo (filhos, pastas-mãe, outro id, nível de sistema, `..`) |
| `testAppAbertoDepoisDaAutorizacaoERecusadoNaExecucao` / `testBundleTrocadoPorLinkDepoisDaAutorizacaoERecusado` | TOCTOU entre a folha e a execução |
| `testDesinstalacaoMoveSoBundleEResiduaisParaLixeira` | Remover item não autorizado na mesma seleção |
| `testDesinstalacaoNuncaExcluiDefinitivamente` | Exclusão definitiva pela desinstalação |
| `testLimpezaGeralContinuaRecusandoApplications` | A desinstalação "abrir" `/Applications` para a limpeza geral |

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
| `testLinkDentroDoEscopoParaForaRemoveSoOLink` | Link real no escopo → só o link vai para a Lixeira; destino de 50 KB intacto e não contado |
| `testLinkParaCaminhoProtegidoRemoveSoOLink` | Link real para `/System/Library/CoreServices` → só o link sai; atravessá-lo é recusado |
| `testMedicaoNaoSegueLinks` | Medir (e anunciar) o espaço do destino de um link |
| `testVarreduraNaoSegueLinks` | Varredura entrar em pasta por meio de link |
| `testLinkQuebradoExiste` | Link quebrado "sumir" para o motor |

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

`testRemocaoUsaLixeiraPorPadrao` e os dois testes de link movem um item de
verdade para a Lixeira do usuário (é o que eles testam). O item tem nome único
(UUID), o teste confere que ele está em `~/.Trash` e, num `defer`, apaga
exatamente esse item de lá. Os testes de `PathGuard` com links reais criam e
apagam a própria pasta em `/tmp`.

Nenhum teste escreve em `/Users` (fora o item único na Lixeira), `/Library` ou
`/Applications`; os testes de desinstalação usam `InMemoryFileSystem`. As asserções de
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

- **Os testes de UI (XCUITest) não rodam sem Xcode** e não foram executados.
- **Não há teste de concorrência** para as janelas de 4 operações do
  `SafeFileRemover`. O `InMemoryFileSystem` agora é protegido por trava, o
  que torna esse teste possível, mas ele não foi escrito.
- **A integração da folha de desinstalação** (`UninstallerSheet` →
  `performUninstall`) compila e o app abre, mas não foi exercitada com um app
  real; a regra de segurança está coberta no núcleo.
- **`HostMetricsCollector`, `StartupItemScanner` e `RecommendationEngine`**
  não têm teste.
- **Não há teste de PerformanceView** com amostragem de CPU.

Antes de qualquer commit, rode `scripts/test.sh`; o CI faz o mesmo e falha se
a contagem de testes executados for zero. Os testes de segurança são a prioridade: eles definem
o que o produto não pode fazer.
