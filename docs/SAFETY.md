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

A segurança **não** está nas telas. Está em três tipos do núcleo, em um pacote
que não importa SwiftUI:

| Camada | Arquivo | Responsabilidade |
|--------|---------|------------------|
| Autorização | `Safety/PathGuard.swift` | Decide quais caminhos podem ser tocados |
| Política | `Safety/SafeFileRemover.swift` | Impõe confirmação, estratégia e contabilidade |
| Contabilidade | `Models/OperationRecord.swift` | Registra o que foi feito |

A consequência prática: uma tela mal escrita, ou um `refactor` que adicione
chamada direta a `FileManager.removeItem`, **não contorna** nada. A única porta
de entrada é `AppEnvironment.performCleanup`.

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

### 3.3 Resolução antes da comparação

O `PathGuard` compara o caminho **já resolvido**, nunca o caminho bruto.

Este é o cenário que a regra previne:

```
/Users/teste/Library/Caches/atalho  ->  /System/Library/Fonts
```

O link está dentro da área autorizada, mas o destino não. Comparar antes de
resolver deixaria passar. Comparar depois barra — e barra com o motivo certo
(`.symlinkEscapesScope`), que é diferente de "o usuário não autorizou isso".

Links simbólicos legítimos do macOS (`/tmp` → `/private/tmp`, `~` →
`/Users/x`) continuam funcionando, porque as **raíces autorizadas também são
resolvidas** pelo mesmo procedimento. Sem isso, bloquear symlinks quebraria o
caminho normal do sistema.

### 3.4 Caminhos sempre recusados

A lista completa vive em `PathGuard.defaultProtectedPaths`:

| Grupo | Caminhos |
|-------|----------|
| Núcleo do sistema | `/System`, `/usr`, `/bin`, `/sbin`, `/etc`, `/dev`, `/var`, `/private/etc`, `/private/var` |
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

`/`, `/tmp`, `/Users` e qualquer outro diretório de primeiro nível são sempre
recusados (`.volumeOrTopLevelDirectory`), mesmo com escopo `["/"]`.

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

Custo: uma chamada a `resolvingSymlinksInPath` por item. Benefício: o item não
pode ser trocado entre a decisão e a ação. Para um aplicativo cuja proposta de
valor é "limpar com segurança", esse é o ponto.

---

## 7. Links simbólicos e hard links

**Links simbólicos** — resolvidos e comparados, conforme 3.3. Na exclusão
permanente, um link simbólico é sempre **ignorado** com motivo explícito: o app
não remove o link, porque isso poderia ter efeito inesperado.

**Hard links** — dois caminhos para o mesmo inode são o **mesmo arquivo**. O
`DuplicateFinder` remove-os do conjunto antes de comparar por hash
(`deduplicatingHardLinks`). Sem isso, o app ofereceria apagar "cópias" que, ao
remover a última, destruiriam o conteúdo original. Grupos que contêm hard links
são marcados com `containsHardLinks` e a interface avisa.

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
