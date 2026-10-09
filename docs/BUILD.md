# Build, assinatura e distribuição

> **Estado real desta página: nada aqui foi executado ainda.**
> O MacCare foi escrito e revisado em um ambiente Linux, sem Xcode e sem
> toolchain Swift. Nenhum binário foi gerado, nenhum teste foi executado, e
> nenhum certificado foi criado ou usado. Tudo abaixo é um **requisito a ser
> cumprido**, não um relato do que já foi feito. Ao concluir uma etapa, o
> responsible deve atualizar o status no [README](../README.md).

---

## 1. Pré-requisitos

| Item | Versão | Observação |
|------|---------|------------|
| macOS | 14.0 (Sonoma) ou superior | Deployment target do projeto. |
| Xcode | 15.0 ou superior | O projeto declara formato `xcode16_3`. |
| Swift | 5.10 ou superior | Exigido por `swift-tools-version:5.10` e verificado no CI. |
| XcodeGen | 2.46.0 | Versão fixada no CI; gere localmente a mesma versão. |
| Conta Apple Developer | Program membership ativo | **Obrigatória apenas para assinar e distribuir.** Custo anual da Apple, pago pela Agzos. |

Ferramentas de linha de comando:

```bash
xcode-select --install
```

O XcodeGen é instalado por uma action dedicada no CI. Para uso local, a via mais
simples é o Homebrew, **fixando a versão** para não divergir do CI:

```bash
brew install xcodegen          # se já tiver uma versão instalada, atualize antes
xcodegen --version             # precisa reportar 2.46.0
```

Instalar uma versão diferente do XcodeGen muda o formato do `.xcodeproj` gerado e
produz diferenças que não têm relação com o código.

---

## 2. Pendências que bloqueiam o primeiro build

Estas três precisam ser resolvidas antes que `xcodebuild` funcione. Nenhuma
delas é opcional e nenhuma está resolvida hoje.

1. **`Resources/Info.plist` ainda não existe.**
   `project.yml` já aponta `INFOPLIST_FILE` para esse caminho. Sem o arquivo, o
   Xcode falha ao ler o conteúdo do plist. Ele precisa conter, no mínimo:
   `CFBundleName`, `CFBundleIdentifier`, `CFBundleShortVersionString`,
   `CFBundleVersion`, `CFBundlePackageType` (`APPL`), `LSMinimumSystemVersion`
   (`14.0`), `NSPrincipalClass` (`NSApplication`), `LSApplicationCategoryType` e
   `NSHumanReadableCopyright`.

2. **Descrições de uso de pasta.** O app lê a pasta do usuário, então o plist
   precisa declarar:
   - `NSDocumentsFolderUsageDescription`
   - `NSDownloadsFolderUsageDescription`
   - `NSDesktopFolderUsageDescription`

   O app **não** acessa câmera nem microfone. `NSCameraUsageDescription` e
   `NSMicrophoneUsageDescription` não devem ser declaradas: incluir uma
   descrição que o app nunca usa é afirmar ao sistema operacional algo falso e
   cria a expectativa de um prompt que nunca aparecerá.

3. **`Tests/MacCareUnitTests` e `Tests/MacCareUITests`.** Os caminhos estão
   declarados em `project.yml`; o primeiro diretório ainda não existe e o
   segundo está vazio. O XcodeGen gera os alvos assim que os diretórios
   existirem.

---

## 3. Gerar o projeto

O `.xcodeproj` é **gerado** e não é versionado (`.gitignore` cobre
`*.xcodeproj/`). `project.yml` é a fonte única do projeto.

```bash
xcodegen generate
open MacCare.xcodeproj
```

Regere o projeto sempre que `project.yml` mudar. Editar o `.xcodeproj` à mão é
perda de trabalho: a próxima geração sobrescreve a alteração.

---

## 4. Núcleo (`MacCareCore`) — o que dá para testar sem Xcode

O núcleo é um pacote SPM independente, sem SwiftUI. Ele cobre toda a superfície
destrutiva do aplicativo: regras de caminho, confirmação, exclusão segura.

```bash
swift build          # compila o núcleo
swift test           # executa a suíte do núcleo
```

Essa é a iteração rápida: sem GUI, sem assinatura, poucos segundos. Requer
apenas o toolchain Swift; o Xcode completo não é necessário.

Cobertura, quando for útil:

```bash
swift test --enable-code-coverage
```

---

## 5. Aplicativo (`MacCare`) — build e testes

Os testes de interface sobem o app de verdade. Eles exigem uma sessão gráfica
(funcional em um runner macOS, funcional em um Mac com usuário logado).

```bash
# Compilar
xcodebuild build \
  -project MacCare.xcodeproj \
  -scheme MacCare \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-"

# Testes unitários do bundle de testes
xcodebuild test \
  -project MacCare.xcodeproj \
  -scheme MacCare \
  -destination 'platform=macOS' \
  -only-testing:MacCareUnitTests

# Testes de interface
xcodebuild test \
  -project MacCare.xcodeproj \
  -scheme MacCare \
  -destination 'platform=macOS' \
  -only-testing:MacCareUITests
```

A identidade `-` é assinatura ad-hoc ("sign to run locally"). Ela permite
executar o app com os entitlements aplicados, mas **não produz um binário
distribuível**: o Gatekeeper de outra máquina rejeita um app assinado ad-hoc.

### 5.1 Conferir os entitlements no binário

O `get-task-allow` é interpolado em `Resources/MacCare.entitlements` a partir
da build setting `MACCARE_GET_TASK_ALLOW`, que é `true` em Debug e `false` em
Release. Essa substituição precisa ser conferida no binário final — é a única
forma de provar que um build de distribuição não está depurável:

```bash
codesign -d --entitlements :- "build/Release/MacCare.app"
```

Esperado em Release: apenas `com.apple.security.get-task-allow` com o valor
`false` (ou ausente). Em Debug: `true`.

Se a build setting chegar vazia ou não for expandida, o plist vira XML inválido e
a assinatura falha com erro. Nesse caso, o contorno é manter dois arquivos de
entitlements — um por configuração — em vez da variável. **Esse desvio ainda
não foi testado em macOS**; trate-o como hipótese a verificar, não como receita.

---

## 6. Produzir o `.app`

```bash
xcodebuild archive \
  -project MacCare.xcodeproj \
  -scheme MacCare \
  -configuration Release \
  -archivePath build/MacCare.xcarchive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="<TEAM_ID>"

xcodebuild -exportArchive \
  -archivePath build/MacCare.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist exportOptions.plist
```

`exportOptions.plist` precisa ser criado e **não** é versionado (o `.gitignore`
cobre o nome). Conteúdo mínimo para distribuição fora da Mac App Store:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>destination</key>
  <string>export</string>
  <key>signingCertificate</key>
  <string>Developer ID Application</string>
</dict>
</plist>
```

O resultado é `build/export/MacCare.app`.

---

## 7. Produzir o `.pkg`

O instalador precisa de um certificado **diferente** do app: o
"Developer ID Installer".

Primeiro, um pacote de componentes:

```bash
pkgbuild \
  --root "build/export" \
  --install-location /Applications \
  --identifier com.agzos.MacCare \
  --version "0.1.0" \
  build/MacCare-unsigned.pkg
```

Depois, assinado. O `--requirements` exige um arquivo `requirements.plist` que
também precisa ser criado. Mantenha-o dentro de `build/`, que já está no
`.gitignore`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>anchor</key>
  <string>com.agzos.MacCare</string>
  <key>certificateRules</key>
  <array>
    <dict>
      <key>certificate</key>
      <string>Developer ID Installer: Agzos</string>
      <key>identifier</key>
      <string>anchor</string>
    </dict>
  </array>
</dict>
</plist>
```

O bundle ID tem que bater exatamente com o do app, ou a regra de certificado
não casa e o instalador fica sem assinatura válida.

```bash
productbuild \
  --sign "Developer ID Installer: Agzos" \
  --requirements build/requirements.plist \
  build/MacCare-unsigned.pkg \
  build/MacCare.pkg
```

---

## 8. Assinatura

Duas identidades são necessárias, ambas da conta Apple Developer da Agzos:

| Certificado | Uso |
|---|---|
| `Developer ID Application` | assina `MacCare.app` |
| `Developer ID Installer` | assina `MacCare.pkg` |

Instalação no keychain local:

```bash
security import maccare-developer-id.p12 \
  -k ~/Library/Keychains/login.keychain-db \
  -T /usr/bin/codesign \
  -T /usr/bin/productbuild

security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "$SUA_SENHA_DO_KEYCHAIN" \
  ~/Library/Keychains/login.keychain-db
```

Verificação:

```bash
codesign --verify --deep --strict --verbose=2 build/MacCare.pkg
spctl --assess --type install --verbose=4 build/MacCare.pkg
```

O arquivo `.p12` e a senha do keychain **nunca** entram no repositório. O
`.gitignore` já bloqueia `*.p12` e `.env`; a verificação de segredos no CI é a
segunda camada.

---

## 9. Notarização

A Apple exige notarização de qualquer app distribuído fora da Mac App Store. A
conta de desenvolvedor é o que habilita o serviço; o custo é a assinatura anual
do programa.

Credencial do `notarytool` (chave de API do App Store Connect, criada por uma
pessoa com acesso ao portal):

```bash
xcrun notarytool store-credentials maccare-notary \
  --apple-id "<apple-id>@agzos.com.br" \
  --team-id "<TEAM_ID>" \
  --password "<app-specific-password>"
```

Envio:

```bash
xcrun notarytool submit build/MacCare.pkg \
  --keychain-profile maccare-notary \
  --wait
```

Anexar o ticket (staple) depois da aprovação:

```bash
xcrun stapler staple build/MacCare.pkg
xcrun stapler validate build/MacCare.pkg
```

Só distribua depois de `stapler validate` responder com sucesso. Um binário
notarizado sem ticket anexado ainda abre com um aviso do Gatekeeper na primeira
execução.

### Por que o CI deste repositório não faz nada disso

Falta certificado, chave de API e senha de app no repositório, e o plano é
mantê-los fora dele. Um certificado de distribuição commitado é uma credencial
de vida inteira da empresa. A consequência é assumida de forma explícita: **um
build verde neste CI não é evidência de que o app está pronto para
distribuição.** O caminho de release acima é manual e local.

---

## 10. Diagnóstico

| Sintoma | Causa provável |
|---|---|
| `unable to read contents of Info.plist` | `Resources/Info.plist` não foi criado (seção 2). |
| `The workspace named "MacCare" is not opened` ou `not configured` | `xcodegen generate` não foi rodado depois da última alteração em `project.yml`. |
| `Signing for "MacCare" requires a development team` | `DEVELOPMENT_TEAM` está vazio. Preencha com o Team ID. |
| `errSecInternalComponent` ao assinar | O chaveiro não liberou o codesign. Repita o `set-key-partition-list`. |
| `Gatekeeper bloqueia o app em outra máquina` | Binário assinado ad-hoc ou sem ticket de notarização anexado. |
| O build falha em `$(MACCARE_GET_TASK_ALLOW)` | A build setting não chegou ao passo de entitlements. Ver 5.1. |
| Teste de interface não abre o app | A sessão gráfica não está disponível. Verifique se há usuário logado. |
