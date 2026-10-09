# Segurança do MacCare

Este documento descreve o que o aplicativo **promete** e o que ele **se recusa a
fazer**, e onde cada regra está implementada no código.

> **Estado de verificação:** o código descrito aqui foi escrito e revisado, mas
> **não foi compilado nem testado** — o desenvolvimento ocorreu em ambiente
> Linux, sem Xcode. A suíte de testes descrita em [`TESTING.md`](TESTING.md)
> existe e está escrita, mas ainda não foi executada. Nada aqui deve ser lido
> como "verificado em produção".

---

## 1. Princípio

A regra que organiza todo o resto:

> **O aplicativo nunca apaga nada que o usuário não tenha visto, compreendido e
> confirmado.**

Tudo o mais decorre disso. As seções seguintes são as consequências técnicas.

---

## 2. Onde a segurança é imposta

A segurança **não** está nas telas. Está em tipos do núcleo, em um pacote
que não importa SwiftUI:

| Camada | Arquivo | Responsabilidade |
|--------|---------|------------------|
| Autorização (limpeza) | `Safety/PathGuard.swift` | Decide quais caminhos podem ser tocados, por escopo |
| Autorização (desinstalação) | `Safety/AppUninstallAuthorization.swift` | Permite exatamente um bundle e seus residuais (seção 7A) |
| Política | `Safety/SafeFileRemover.swift` | Impõe confirmação, estratégia e contabilidade |
| Contabilidade | `Models/OperationRecord.swift` | Registra o que foi feito |

A consequência prática: uma tela mal escrita, ou um `refactor` que adicione
chamada direta a `FileManager.removeItem`, **não contorna** nada. A única porta
de entrada é `AppEnvironment.performCleanup` (limpeza, com `PathGuard`) ou
`AppEnvironment.performUninstall` (desinstalação, com
`AppUninstallAuthorization`). Ambas passam pelo `SafeFileRemover`, que só
conhece o protocolo `RemovalGuard`.

---

## 3. Regras do `PathGuard`

### 3.1 Falhar fechado

Um `PathGuard` construído sem raízes autorizadas **não autoriza nada**:

```swift
PathGuard.denyAll   // evaluate(_:) sempre retorna .denied
```

O caso `AppEnvironment` reforça isso: se `scope` for `nil`, `rebuildCleaningServices()`
instancia `.denyAll` em vez de um guard permissivo.

> Um estado em que "não sei o escopo" vira "posso remover tudo" é o tipo de bug
> que só aparece em produção. Aqui ele é impossível por construção.

### 3.2 Escopo explícito

Um caminho só é liberado se, **depois de resolver links simbólicos**, estiver
estritamente dentro de uma raiz autorizada.

"Estritamente dentro" significa que a própria raiz autorizada **não pode ser
removida** — apenas o conteúdo dela. Esvaziar `~/Library/Caches` é uma decisão;
apagar a pasta `~/Library/Caches` nunca é.

### 3.3 Canonicalização antes da comparação

O `PathGuard` nunca compara o caminho bruto. Todo caminho — raízes
autorizadas, caminhos protegidos e candidatos — passa pela **mesma**
canonicalização (`PathGuard.canonicalLocation(of:)`), no estilo de
`realpath(3)`:

1. Caminho relativo ou com qualquer componente `..` → recusado
   (`.pathTraversal`). Não há motivo legítimo para um candidato conter
   travessia, nem quando ela terminaria dentro do escopo. Uma raiz autorizada
   com `..` é **descartada** (nunca vira "autoriza tudo").
2. O ancestral **existente mais profundo** é resolvido com `realpath`; os
   componentes que ainda não existem são anexados literalmente. Assim
   `/tmp/novo/arquivo` e `/private/tmp/novo/arquivo` caem no mesmo prefixo
   (`/private/tmp/...`) mesmo antes de existirem. A versão anterior usava
   `URL.resolvingSymlinksInPath()`, que só remove o `/private` quando o
   caminho existe — e por isso `/private/tmp/x` era recusado com raiz
   `/private/tmp`.
3. **Candidatos não seguem o último componente.** Se o item for um link
   simbólico, a localização avaliada é a do próprio link (pai canonicalizado +
   nome do link), e o veredito vem com `isSymlink = true`. Ver seção 7.
4. **Diretórios de referência seguem o último componente**
   (`canonicalDirectory(of:)`): raízes autorizadas, caminhos protegidos, pastas
   de aplicativos e a pasta pessoal. Raiz `/tmp` significa "dentro de
   `/private/tmp`". Os caminhos protegidos entram nas duas grafias (como
   escritos e canônicos).

O cenário que a regra previne:

```
/Users/teste/Library/Caches/atalho  ->  /System/Library
candidato: /Users/teste/Library/Caches/atalho/Fonts/x.ttf
```

O pai do candidato é resolvido pelo `realpath` e vira
`/System/Library/Fonts` — recusado como `.protectedSystemPath`. Se o link
apontasse para uma pasta comum fora do escopo, a recusa seria
`.symlinkEscapesScope` (o caminho escrito parecia estar dentro), que é
diferente de "o usuário não autorizou isso" (`.outsideAllowedScope`).

### 3.4 Caminhos sempre recusados

A lista completa vive em `PathGuard.defaultProtectedPaths`:

| Grupo | Caminhos |
|-------|----------|
| Núcleo do sistema | `/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/dev`, `/var`, `/private/etc`, `/private/var`, `/private/tmp/system` |
| Rede e montagens | `/Network`, `/Volumes/Preloaded` |
| Facetas de segurança | `/Library/Keychains`, `/Library/Security`, `/Library/Extensions`, `/Library/PrivateFrameworks`, `/Library/Apple` |
| Login e sessão | `/Library/Preferences/com.apple.loginwindow.plist` |
| Aplicativos | `/Applications`, `~/Applications` (a pasta inteira, nunca) |
| Home | a pasta pessoal do usuário |
| Autoproteção | o bundle do próprio MacCare |

Não é uma lista exaustiva dos caminhos protegidos por SIP — **não existe API
pública para enumerá-los**. É a lista de recusas explícitas que o aplicativo
aplica sempre, e é por isso que a regra estrutural da seção 3.2 importa mais
do que esta lista: mesmo que um caminho protegido novo apareça no macOS, ele só
seria alcançável se alguém o adicionasse como raiz autorizada.

### 3.5 Raízes de volume e diretórios de primeiro nível

`/`, `/Users` e qualquer outro diretório de primeiro nível são sempre recusados
(`.volumeOrTopLevelDirectory`), mesmo com escopo `["/"]`.

No macOS, `/tmp`, `/var` e `/etc` são links para `/private/tmp`,
`/private/var` e `/private/etc` — três componentes, que escapariam da regra de
"primeiro nível". Por isso `PathGuard.nonRemovableRoots` lista explicitamente,
nas duas grafias, as pastas que **nunca são removíveis em si**:
`/private`, `/private/tmp`, `/private/var`, `/private/etc`, `/tmp`, `/var`,
`/etc`, `/Users`, `/Volumes`, `/Library`, `/System`. O **conteúdo** de
`/private/tmp` continua removível quando autorizado; a pasta, nunca.

Observação: `/private/var` inteiro é protegido, o que inclui o temporário por
usuário (`/private/var/folders/...`). Os testes de integração usam `/tmp` por
esse motivo.

---

## 4. Regras de confirmação

### 4.1 Confirmação é uma restrição de inicialização

Não existe um caminho de código que remova arquivos sem passar por
`ConfirmedSelection.init`, que é `throws`:

```swift
// Falha: seleção vazia
try ConfirmedSelection(items: [], kind: .standard)

// Falha: categoria de risco com confirmação padrão
try ConfirmedSelection(items: trashItems, kind: .standard)

// Falha: exclusão definitiva sem autorização separada
try RemovalPlan(selection: selection, strategy: .permanentlyDelete)
```

A política não está em um `if` dentro de uma view que alguém pode contornar.
Ela está na **assinatura de um inicializador**.

### 4.2 Confirmação reforçada

Categorias que podem conter dados do usuário exigem `ConfirmationKind.full`:

| Categoria | Por quê |
|-----------|---------|
| `trash` | Esvaziar a Lixeira é irreversível |
| `duplicates` | O usuário pode ter motivo para manter várias cópias |
| `largeFiles` | Tamanho não é evidência de lixo |
| `oldDownloads` | Pode ser o único exemplar |
| `browserData` | Contém histórico do usuário |

`ConfirmedSelection` **rejeita** a construção quando há item de categoria
arriscada com confirmação padrão. Não é um aviso — é um erro de compilação em
tempo de execução.

### 4.3 Exclusão definitiva exige duas autorizações

`.permanentlyDelete` exige `ConfirmationKind` válido **e**
`allowPermanentDeletion: true` no `RemovalPlan`. São duas decisões separadas,
porque "quero limpar isso" e "quero que não possa ser recuperado" não são a
mesma afirmação.

---

## 5. Estratégia de remoção

### 5.1 Lixeira por padrão

O padrão é `.moveToTrash`, que usa `FileManager.trashItem` — reversível pelo
usuário a qualquer momento, pelo Finder.

### 5.2 Sem fallback silencioso

Se `trashItem` falha, o item é **mantido intacto** e a falha é reportada:

> "Não foi possível mover para a Lixeira: … O arquivo foi mantido intacto."

O `catch` que apagar o arquivo direto quando a Lixeira falha é uma correção
tentadora e errada. O usuário pediu ir para a Lixeira; falhar é a resposta
correta. O teste
`testFalhaAoMoverParaLixeiraNaoApagaSilenciosamente` existe para impedir essa
mudança.

### 5.3 Simulação

`RemovalStrategy.simulate` produz o relatório completo — com tamanho medido e
destino de cada item — sem tocar em nada. É a prévia que o PRD §8 exige.

---

## 6. Revalidação no momento da execução

O `PathGuard` roda **duas** vezes: na análise e na execução.

A janela entre "analisou" e "limpou" é a janela real de ataque do sistema. É
dentro dela que um link simbólico pode ser trocado por outro processo, e é por
isso que `SafeFileRemover.process` reavalia o caminho imediatamente antes de
remover.

```
t0  análise      → PathGuard aprova ~/Caches/x
t1  outro processo troca ~/Caches/x por link para /System/Library/Fonts
t2  limpeza      → PathGuard reavalia e barra
```

Custo: um `realpath` e um `lstat` por item. Benefício: o item não
pode ser trocado entre a decisão e a ação. Para um aplicativo cuja proposta de
valor é "limpar com segurança", esse é o ponto.

---

## 7. Links simbólicos e hard links

**Política: remover o link, nunca o destino.**

- A avaliação de um candidato que é link usa a localização **do próprio
  link** (pai canonicalizado + nome). Ele só é aceito se essa localização
  estiver dentro do escopo; para onde o link aponta é irrelevante, porque o
  destino nunca é tocado.
- `SafeFileRemover` recebe essa localização e a move para a Lixeira. O
  `FileManager.trashItem` aplicado a um link move **o link** (verificado em
  macOS 27: o item na Lixeira é um link simbólico e o destino continua
  intacto). Teste: `testLinkDentroDoEscopoParaForaRemoveSoOLink`.
- Um link para um caminho protegido (ex.: `/System/Library/CoreServices`)
  segue a mesma regra: só o link sai. Teste:
  `testLinkParaCaminhoProtegidoRemoveSoOLink`.
- **Atravessar** um link (o link é um componente intermediário) é recusado
  quando o destino está fora do escopo ou é protegido — seção 3.3.
- **Exclusão definitiva de link é recusada** (item ignorado com motivo). Não
  libera espaço e é a operação irreversível; a Lixeira basta.
- **Varredura e medição nunca seguem links.** `LiveFileSystem.isDirectory` e
  `itemExists` usam `lstat` (um link para pasta não é pasta; um link quebrado
  existe); `allocatedSize` de um link é o tamanho do próprio link;
  `FileSizeMeasurer` pula links filhos; o enumerador de `descendents` não
  desce por links; `DirectoryScanner` e `DuplicateFinder` descartam links.
  Assim o espaço "liberável" nunca inclui dados que vivem em outro lugar.
  Teste: `testMedicaoNaoSegueLinks`, `testVarreduraNaoSegueLinks`.

**Hard links** — dois caminhos para o mesmo inode são o **mesmo arquivo**. O
`DuplicateFinder` remove-os do conjunto antes de comparar por hash
(`deduplicatingHardLinks`). Sem isso, o app ofereceria apagar "cópias" que, ao
remover a última, destruiriam o conteúdo original. Grupos que contêm hard links
são marcados com `containsHardLinks` e a interface avisa.

---

## 7A. Desinstalação de aplicativos

`/Applications` e `~/Applications` **continuam protegidos** para a limpeza
geral: nenhuma raiz de escopo autoriza apagar algo lá dentro. A desinstalação
usa outro guardião, `AppUninstallAuthorization`, que implementa o mesmo
protocolo `RemovalGuard` usado pelo `SafeFileRemover`.

**Criação (falha com `AppUninstallError`)** — o bundle escolhido precisa ser:

| Regra | Erro |
|-------|------|
| Item **direto** de `/Applications` ou `~/Applications` (pai canônico igual à pasta; nem a pasta, nem subpasta, nem item dentro do bundle) | `.notDirectlyInApplicationsFolder` |
| Não ser link simbólico | `.symlinkedBundle` |
| `.app` com `Contents/Info.plist` e `CFBundleIdentifier` | `.invalidBundle` |
| Não ser da Apple (`com.apple.*`; `/System/Applications` já cai na primeira regra) | `.appleApplication` |
| Não ser o próprio MacCare (caminho ou identificador) | `.ownApplication` |
| Não estar aberto (`NSRunningApplication`) | `.applicationIsRunning` |

**O que é autorizado** — por **igualdade** de caminho canônico, nunca por
prefixo (um filho do bundle ou de um residual é recusado):

- o bundle;
- em `~/Library`, nomeados pelo identificador: `Application Support/<id>`,
  `Caches/<id>`, `Preferences/<id>.plist`, `Containers/<id>`,
  `Group Containers/<id>` e `Group Containers/<TEAMID>.<id>` (TEAMID = 10
  caracteres `A-Z0-9`), `Saved Application State/<id>.savedState`,
  `Logs/<id>`, `HTTPStorages/<id>` e `<id>.binarycookies`, `WebKit/<id>`,
  `LaunchAgents/<id>.plist`.

Nada no nível do sistema (`/Library/...`) é oferecido nem autorizado. O
`Uninstaller` usa exatamente a mesma lista (`leftoverLocations`) para sugerir
residuais, então sugestão e autorização não divergem.

**Garantias mantidas**

- Só Lixeira: `permitsPermanentDeletion == false`; o `SafeFileRemover` rejeita
  um plano de exclusão definitiva com esse guardião.
- `ConfirmedSelection` continua obrigatória; a folha pede confirmação
  reforçada quando a seleção inclui `Application Support` ou `Containers`.
- Revalidação: `AppEnvironment.performUninstall` **recria** a autorização no
  momento da execução, e `evaluate` confere de novo, item a item, que o bundle
  não virou link, que o identificador é o mesmo e que o app não foi aberto.

---

## 8. Contabilidade de espaço honesta

O PRD §19 exige separar quatro números. O app apresenta exatamente quatro:

| Número | Rótulo na interface | Quando conta |
|--------|--------------------|--------------|
| `identified` | Identificado como recuperável | Total da análise |
| `selected` | Selecionado | Itens marcados pelo usuário |
| `releasedConfirmed` | Liberado (confirmado) | Diferença de espaço livre medida antes/depois |
| `releasedUnconfirmed` | Movido para a Lixeira | Itens que foram para a Lixeira |

**Mover para a Lixeira não libera espaço.** A Lixeira vive no mesmo volume, e
o macCare não a esvazia sozinho. Dizer "12 GB liberados" nesse caso seria uma
mentira verificável pelo usuário em um minuto.

Quando outro processo escreve mais dados entre as medições, o delta fica
negativo — e o resultado correto é `0`, nunca um número negativo.

---

## 9. O que o aplicativo não faz

Estas são decisões de projeto, não limitações temporárias:

- **Não usa APIs privadas do macOS.** Nenhuma leitura de sensor, nenhum frame
  privado de IOKit, nenhum `_LSCopyApplicationInformation`.
- **Não contorna TCC, SIP ou Gatekeeper.**
- **Não executa comandos de terminal.** Nenhuma instância de `Process`. Nenhum
  script. A seção "Manutenção do macOS" do PRD é implementada por orientação e
  abertura das telas do sistema, não por automação de shell.
- **Não pede Full Disk Access por padrão.** O app funciona sem ela e declara o
  que não conseguiu analisar.
- **Não pede privilégios administrativos** para tarefas que o usuário consegue
  fazer sozinho.
- **Não desativa proteção do sistema** para facilitar a limpeza.
- **Não envia dados para fora da máquina.** Sem telemetria, sem crash reporting,
  sem conta, sem rede obrigatória.
- **Não apaga automaticamente** item classificado como suspeito.
- **Não se apresenta como antivírus.** O módulo de proteção tem escopo declarado.
- **Não inventa dados.** Temperatura e pressão de memória não têm API pública:
  o app exibe "Indisponível" e explica o motivo.
- **Não declara aplicativo desatualizado** sem fonte de atualização confiável.
- **Não remove item de inicialização de terceiros.** O macOS não oferece API
  pública para isso; o app orienta onde resolver manualmente.

---

## 10. Sandbox

O aplicativo é distribuído **sem App Sandbox**, e a decisão está documentada
no arquivo de entitlements.

O motivo é o produto: varrer a pasta do usuário e ler metadados de aplicativos
instalados exige acesso amplo. Com App Sandbox ligado, a única forma de
conseguir isso seria solicitar **Full Disk Access**, e o PRD §23 proíbe pedi-lo
por padrão — seria trocar uma permissão visível por outra mais invasiva e mais
frequente.

O que a troca exige, e portanto o que foi feito:

- **Hardened Runtime ativo** — obrigatório para Developer ID e notarização.
- **Zero execuções de script** — sem `apple-events`, sem `Process`. Menos
  superfície, sem permissões relacionadas.
- **Pedidos de permissão explícitos** — quando o app precisa ler uma pasta
  específica, ele usa o seletor de arquivos do sistema, que concede acesso
  pontual, e explica o que pretende analisar.

Se a Apple exigir sandbox para distribuição no Mac App Store, esse requisito
muda a arquitetura de permissões — não é um detalhe de configuração.

---

## 11. Permissões declaradas

O aplicativo declara apenas descrições de uso que correspondem a ações reais:

| Chave | Motivo |
|-------|--------|
| `NSDocumentsFolderUsageDescription` | Analisar arquivos em Documentos quando o usuário seleciona a pasta |
| `NSDownloadsFolderUsageDescription` | Analisar Downloads, que é opt-in |
| `NSDesktopFolderUsageDescription` | Analisar a Mesa quando o usuário seleciona a pasta |

Câmera e microfone **não** são declarados: o aplicativo não os usa, e uma
descrição de uso sem uso correspondente é ruído — e é o tipo de coisa que
revela uma planilha de permissões copiada de outro app.

---

## 12. Relato de vulnerabilidade

Ver [`SECURITY.md`](../SECURITY.md) na raiz do repositório.
