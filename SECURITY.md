# Segurança do Agzos MacCare

Este documento descreve o modelo de segurança do aplicativo, o que ele
deliberadamente não faz, e como reportar uma vulnerabilidade.

**Escopo:** cobre o aplicativo MacCare distribuído pela Agzos e o código deste
repositório. Não cobre o macOS, nem o Xcode, nem a App Store.

---

## 1. Modelo de segurança

O MacCare é uma ferramenta de manutenção que roda localmente, na conta do
próprio usuário, com a confiança que o usuário já tem no Terminal e no Finder.
Essa é a decisão de produto que organiza todo o resto.

| | |
|---|---|
| Ativo protegido | Os arquivos do usuário e a confiança que ele deposita no app. |
| Superfície de ataque | Um binário assinado que roda com as permissões do usuário, em um sistema sem sandbox. |
| Fronteira | A máquina do usuário. Não há fronteira de rede porque não há rede. |
| Postura | Nenhum item é confiável até o momento da execução, não apenas da análise. |

### 1.1 O app não tem sandbox, e isso é uma decisão

O app precisa varrer a pasta do usuário e ler permissões de aplicativos
instalados. Com App Sandbox ligado, a única forma de fazer isso seria pedir
Full Disk Access ao usuário, e o PRD proibe exatamente isso: não solicitar Full
Disk Access por padrão.

A consequência é assumida de forma explícita: um defeito no app pode causar dano
real, e a proteção não vem do isolamento do sistema, vem do código. Por isso
todo o trabalho de segurança está concentrado em um lugar auditável
(`Sources/MacCareCore/Safety/`) em vez de espalhado pela interface.

Regras que valem para qualquer operação destrutiva:

- Nenhuma exclusão sem confirmação explícita do usuário.
- O padrão é a Lixeira, que é reversível. Exclusão definitiva exige
  autorização separada no plano de remoção.
- Categorias que podem conter dados do usuário (Lixeira, duplicados, arquivos
  grandes, Downloads) exigem confirmação reforçada, e essa confirmação não
  pode ser concedida por engano.
- Caminhos são revalidados no momento da execução, não apenas durante a
  análise. A análise acontece antes; a decisão de segurança acontece na hora de
  apagar.
- `/System`, `/usr`, `/etc`, `/dev`, `/var`, chaves, extensões e frameworks
  privados são recusados sempre, sem exceção.
- A pasta pessoal do usuário e a pasta `/Applications` não são removíveis em
  bloco.
- Links simbólicos são resolvidos antes da comparação, e um link que sai da
  área autorizada é recusado. Sem isso, um link dentro de `~/Downloads`
  apontando para `/System` passaria pela checagem de prefixo.
- As operações ficam registradas em histórico local, apagável e exportável.

Um item recusado não é um defeito. É uma proteção funcionando, e o app mostra o
motivo da recusa em vez de esconder a falha.

### 1.2 Entitlements

`Resources/MacCare.entitlements` é deliberadamente quase vazio, e
`com.apple.security.app-sandbox` está ausente de propósito. A justificativa
completa está no próprio arquivo.

O que ele contém:

- **Hardened Runtime**, ligado. Nenhuma exceção de runtime é pedida: sem JIT,
  sem memória executável não assinada, sem `DYLD_INSERT_LIBRARIES`, sem
  `disable-library-validation`. Cada uma dessas exceções reduz a proteção, e
  nenhuma é necessária para este aplicativo.
- **`get-task-allow`**, condicionado à configuração Debug. Um binário
  distribuído com esse entitlement ligado aceita attach de depurador por
  qualquer processo do usuário, o que equivale a permitir injeção de código.

O que ele não contém, e por quê:

- `com.apple.security.automation.apple-events`: o app não executa scripts de
  terminal nem automatiza outros aplicativos. Sem esse entitlement o macOS nem
  exibe o pedido de autorização de Automação, o que elimina uma classe inteira
  de permissão enganosa.
- `com.apple.security.device.camera` e `device.microphone`: não há esse uso.
- `com.apple.security.network.client` e `network.server`: o app não fala com a
  rede.

Uma etapa do CI falha o build se qualquer uma dessas chaves for introduzida de
volta de forma ativa.

---

## 2. O que o app deliberadamente não faz

Esta lista é um compromisso, não uma descrição. Se o comportamento real divergir
dela, isso é um defeito com severidade de segurança.

1. **Não usa APIs privadas.** Só são usadas Foundation, SwiftUI, Swift Charts,
   ServiceManagement e os frameworks públicos do macOS. Não há carregamento
   dinâmico de framework privado, não há leitura direta de IOKit, não há acesso
   a estruturas internas. Um app que depende de API privada quebra em qualquer
   atualização do sistema e não é aceito em revisão.
2. **Não contorna TCC, SIP nem Gatekeeper.** O app não pede Full Disk Access
   por padrão, não altera configurações do sistema, não instala perfis de
   sistema, não modifica o SIP e não engana o Gatekeeper. Quando uma área exige
   permissão, ele pede a permissão ao usuário ou simplesmente não analisa.
3. **Não executa comandos de shell.** Não há `Process`, `NSTask`, `system()`,
   `popen` nem `posix_spawn` no aplicativo. Não roda scripts, não desinstala
   aplicativos por shell, não escreve preferências por baixo dos panos. Toda
   alteração de estado passa pelas APIs do sistema e pelo motor de segurança.
4. **Não envia dados para fora da máquina.** Não há telemetria, analytics,
   relatórios de falha, verificação de atualização remota nem sincronização em
   nuvem. Não há nenhuma conexão de rede no aplicativo. O histórico de
   operações é local e apagável, e o app funciona com a rede desconectada.
5. **Não se apresenta como antivírus.** O módulo de proteção tem escopo
   declarado (limpeza, itens de inicialização, organização). Ele não varre
   malware e não deve ser usado como se varresse.
6. **Não inventa métricas.** Temperatura e pressão de memória não têm API
   pública confiável no macOS, então o app exibe "Indisponível" em vez de um
   número inventado. Ausência de dado é apresentada como ausência de dado.
7. **Não remove arquivos do sistema nem a pasta de aplicativos inteira.**
   Desinstalar um aplicativo é uma operação separada, item a item.

---

## 3. Superfície de ataque

Onde um atacante pode tentar entrar, e o que existe a respeito.

| Vetor | Tratamento |
|---|---|
| Link simbólico escapando da área autorizada | Resolvido antes da comparação; o escape é recusado com um código de motivo observável. |
| Corrida entre análise e execução (TOCTOU) | O caminho é revalidado no momento da operação, não só no plano. |
| Confirmação concedida por engano | A confirmação é um tipo de inicialização lançadora: não existe plano executável sem ela. |
| Item perigoso na seleção padrão | Categorias sensíveis exigem confirmação reforçada, e a autorização de exclusão definitiva é separada da seleção. |
| Injeção pela interface | O app é nativo: sem WebView, sem carregamento remoto de conteúdo, sem automação de scripts. |
| Persistência maliciosa | Itens de inicialização de terceiros são apenas lidos. A alteração só é oferecida para o próprio MacCare. |
| Binário adulterado | Hardened Runtime sem exceções, assinatura com Developer ID e notarização. |
| Atualização maliciosa | O app não se atualiza sozinho; a atualização passa pelo mecanismo do sistema. |
| Abuso de permissões do macOS | O app solicita apenas o acesso de que precisa, item a item, e declara na interface o que não conseguiu ler. |
| Vazamento de dados pelo histórico | O histórico registra o que foi feito, sem o conteúdo dos arquivos. É local, apagável e exportável. |
| Dependência comprometida | O pacote SPM não tem dependência externa hoje. A verificação de segredos no CI impede credencial versionada. |
| Roubo do certificado de assinatura | O certificado não está neste repositório e não deve estar. O CI não assina para distribuição. |

O risco residual mais relevante é o usuário executar um binário local não
assinado. Nesse caso o Gatekeeper não oferece proteção e o app herda a confiança
do usuário sem que ninguém tenha verificando a origem. É a razão de assinatura
e notarização serem requisito de lançamento, e não recomendação.

---

## 4. Reporte de vulnerabilidade

Não abra um issue público para reportar uma falha de segurança.

### Canal

**E-mail:** `seguranca@agzos.com.br`

Esse endereço precisa ser criado antes da publicação. Enquanto não existir, o
canal válido é o contato comercial já publicado no site da Agzos.

O canal é lido por pessoa responsável designada pela Agzos. Issues, pull
requests e mensagens em canais públicos não substituem o e-mail: um issue
público entrega o detalhe da falha a quem quiser explorá-la.

O que enviar na primeira mensagem:

- O tipo da falha: execução arbitrária, escalonamento de privilégio, leitura
  não autorizada, negação de serviço ou distribuição maliciosa.
- Versão do MacCare, versão do macOS e modelo da máquina.
- Passos para reproduzir, de forma determinística.
- O que o atacante ganha com isso, isto é, o escopo real da falha.
- Qualquer prova de conceito ou arquivo anexado.

### O que esperar

| Etapa | Compromisso da Agzos |
|---|---|
| Resposta inicial | 3 dias úteis |
| Avaliação de severidade | 7 dias úteis |
| Correção e versão publicada | 90 dias para severidade alta ou crítica; prazo menor acordado caso a caso |
| Divulgação | Junto com a correção, com crédito ao relatante se ele quiser |

São prazos que a Agzos se compromete a cumprir, e que ainda não têm histórico
de medição porque o produto não foi lançado.

### Divulgação coordenada

- A Agzos não trata relato de forma punitiva e não ameaça quem reporta.
- Há salvaguarda: quem seguir este processo não sofre ação legal em razão da
  pesquisa.
- O fim do prazo de correção não é usado como motivo para omitir de um usuário
  uma falha que já se sabe existir.
- Uma falha com exploração ativa em disco é tratada como urgência, e o usuário
  pode ser avisado antes de a correção estar disponível.

### Versões suportadas

| Versão | Recebe correções de segurança |
|---|---|
| 0.1.x (lançamento) | Sim, a partir do lançamento |
| 0.0.x (pré-lançamento) | Não |
| Abaixo de 0.1.0 | Não |

A tabela precisa ser atualizada no lançamento. Hoje nenhuma versão foi
publicada, e nenhuma vulnerabilidade foi corrigida ou reportada até o momento.

---

## 5. O que ainda não está verificado

Esta seção existe para que ninguém leia o resto do documento e conclua que as
declarações acima já foram testadas.

- O código foi escrito e revisado, mas não foi compilado e não foi testado em
  macOS. Nenhum binário foi gerado e nenhuma suíte de testes foi executada.
- Nenhum certificado foi criado. Nada foi assinado nem notarizado.
- A verificação de segredos do CI está escrita, mas ainda não rodou em nenhuma
  execução real.
- A análise de superfície de ataque acima foi derivada da leitura do código, e
  não de uma auditoria independente. Ela não substitui uma revisão de segurança
  por terceiros, que ainda não foi contratada.
