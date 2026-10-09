# Testes

> **Estado:** a suíte está **escrita, não executada**. O desenvolvimento
> ocorreu em ambiente Linux, sem toolchain Swift, então nenhum teste rodou.
> Qualquer afirmação sobre testes "passando" neste repositório seria falsa.
> O que existe é a intenção de teste, verificável ao rodar `swift test` em macOS.

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

Os testes de integração criam a própria árvore em
`FileManager.default.temporaryDirectory` e a removem em `tearDownWithError` —
**inclusive quando o teste falha**, porque a remoção está em teardown, não no
final do corpo do teste.

Nenhum teste toca `/Users`, `/Library` ou `/Applications`. As asserções de
caminho usam strings com estrutura de Mac (`/Users/teste/...`) porque o que está
sob teste é a **decisão**, não o disco.

---

## 5. Como executar

```bash
# Núcleo: unitários + segurança. Rápido, sem GUI.
swift test

# Só um arquivo
swift test --filter PathGuardTests

# Só segurança
swift test --filter "PathGuard|SafeFileRemover"

# Diagnóstico detalhado
swift test --verbose
```

Integração (usa o sistema de arquivos real, ainda em temporários):

```bash
swift test --filter CoreIntegrationTests
```

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

- **A suíte nunca foi executada.** Não há registro de que qualquer um destes
  testes passe — podem conter erros de compilação, e provavelmente contêm até
  alguém executar.
- **Não há testes de UI escritos ainda.** O diretório existe; o conteúdo está
  pendente.
- **Não há teste de concorrência** para as janelas de 4 operações do
  `SafeFileRemover`.
- **Não há teste de PerformanceView** com amostragem de CPU.
- **Falta o `Info.plist`**, então o alvo do app ainda não é construível.

O primeiro passo ao receber o repositório em um Mac é rodar `swift test` e
corrigir o que aparecer. Os testes de segurança são a prioridade: eles definem
o que o produto não pode fazer.
