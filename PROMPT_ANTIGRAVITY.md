# PROMPT COMPLETO — App iOS "PhotoVault iCloud Sync"
### Para colar na extensão do **Claude Code** dentro do **Antigravity**

> Copie **tudo** a partir da linha `=== INÍCIO DO PROMPT ===` até `=== FIM DO PROMPT ===`
> e cole como a sua primeira mensagem no Claude Code. Ele vai gerar o app inteiro,
> os arquivos de build e as instruções de deploy.

---

=== INÍCIO DO PROMPT ===

## Papel
Você é um **engenheiro iOS sênior**, especialista em **Swift, SwiftUI, PhotoKit e
integrações com iCloud Drive**. Escreva código de produção, com tratamento de erros
robusto e comentários abrangentes. **Responda tudo em Português (Brasil).**

## Linguagem e stack (já decididos — use exatamente isto)
- **Linguagem: Swift 5.9+** — é a linguagem nativa da Apple e a melhor escolha para
  este app, porque só ela dá acesso direto e estável a PhotoKit, iCloud (ubiquity
  container) e BackgroundTasks. (Não use React Native/Flutter: eles não expõem bem o
  acesso a `PHAssetResource` nem a gravação coordenada no iCloud Drive.)
- **UI: SwiftUI** (lifecycle `App`, sem Storyboard).
- **Alvo mínimo: iOS 16.0.**
- **Frameworks:** PhotoKit (`PHPhotoLibrary`, `PHAsset`, `PHAssetResource`),
  `FileManager` (ubiquity container), `BackgroundTasks`, `AVFoundation`, `ImageIO`,
  `UniformTypeIdentifiers`, `UserDefaults`.
- **Concorrência:** `async/await`; motor de sync e ledger como `actor`; UI em `@MainActor`.

## Objetivo do app
Um app que copia **automaticamente** todas as fotos e vídeos da galeria do iPhone para
uma **pasta do iCloud Drive definida pelo usuário**.

### Requisito CRÍTICO — backup unidirecional (one-way)
Se o usuário apagar uma foto da galeria, o app **NÃO PODE** apagá-la do iCloud Drive.
Mantenha um **livro-razão local** (um `Set<String>` de `localIdentifier` persistido)
dos assets já copiados. Assim o app: (1) ignora assets que sumiram da galeria; (2) nunca
toca na cópia do iCloud; (3) nunca reenvia duplicatas. O livro-razão **só cresce**.

## Arquitetura — gere estes arquivos

```
PhotoVaultiCloudSync/
├── App/MainApp.swift                 # @main App; registra e agenda a BG task
├── Views/ContentView.swift           # Dashboard
├── Views/SettingsView.swift          # Nome da pasta + formato de exportação
├── ViewModels/SyncViewModel.swift    # @MainActor ObservableObject (ponte UI↔motor)
├── Core/SyncModels.swift             # SyncStatus, SyncError, SyncStats, ExportFormat, SyncConfig
├── Core/PhotoTracker.swift           # Livro-razão (actor) — garante o one-way
├── Core/PhotoSyncEngine.swift        # Motor (actor)
├── Core/BackgroundSyncManager.swift  # BGTaskScheduler / BGProcessingTaskRequest
├── Resources/Info.plist
└── PhotoVaultiCloudSync.entitlements
```

### 1. `PhotoTracker.swift` (actor)
- Persistência em **arquivo JSON** (`ledger.json`) em Application Support — escala para
  dezenas de milhares de itens. Métodos: `load()`, `isSynced(_:) -> Bool`,
  `markSynced(_:) throws`, `syncedCount`. **Nunca remova IDs.** Salvamento atômico.

### 2. `PhotoSyncEngine.swift` (actor)
- `requestAuthorization()` → `PHPhotoLibrary.requestAuthorization(for: .readOnly)`;
  trata `.denied`/`.restricted` como erro.
- Localiza o iCloud: `FileManager.default.url(forUbiquityContainerIdentifier: nil)`;
  valida `ubiquityIdentityToken`; grava em `<container>/Documents/<pastaDoUsuario>/`
  (o subdiretório `Documents` fica visível no app Arquivos — ver `NSUbiquitousContainers`).
- Busca assets com `PHAsset.fetchAssets`, ordenados por `creationDate` ascendente.
- Filtra os já sincronizados via `PhotoTracker.isSynced`.
- **Dois formatos de exportação** (enum `ExportFormat`), escolhível nas Configurações:
  - **`.original`**: exporta os `PHAssetResource` brutos (HEIC/RAW, HEVC, vídeo de Live
    Photo) via `PHAssetResourceManager.writeData(for:toFile:options:)` com
    `isNetworkAccessAllowed = true`.
  - **`.compativel`**: converte para **JPEG** (fotos, via ImageIO/`CGImageDestination`,
    preservando EXIF/orientação, qualidade ~0.95) e **MP4/H.264** (vídeos, via
    `AVAssetExportSession` preferindo presets H.264 até 4K). Para abrir em qualquer
    PC/Android/navegador na resolução máxima.
- Escrita no iCloud com **`NSFileCoordinator`** (move de um arquivo temporário para o
  destino). Só chama `markSynced` **após** a gravação bem-sucedida.
- Nome de arquivo: prefixo estável derivado do `localIdentifier` para evitar colisões.
- Erros tipados (`SyncError`): permissão negada, iCloud indisponível, container não
  encontrado, **armazenamento cheio** (`NSFileWriteOutOfSpaceError`), recurso
  indisponível, escrita falhou, cancelada. Cada um com mensagem em PT-BR.
- Reporta progresso `(enviados, total)` via callback para a UI.

### 3. `BackgroundSyncManager.swift` (@MainActor)
- `registerTasks()` no launch: `BGTaskScheduler.shared.register(...)` com o identificador
  `com.photovault.sync.processing` (deve bater com o Info.plist).
- `scheduleProcessing()`: `BGProcessingTaskRequest` com `requiresExternalPower = true` e
  `requiresNetworkConnectivity = true`, `earliestBeginDate` ~ +1h.
- Handler: roda o motor, trata `expirationHandler` (cancelamento cooperativo),
  `setTaskCompleted`, e reagenda a próxima passada.

### 4. `SyncViewModel.swift` (@MainActor ObservableObject)
- `@Published`: `status: SyncStatus`, `stats: SyncStats`, `folderName`, `exportFormat`.
- `syncNow()`, `refreshCounts()` (total na galeria + total no ledger), persistência de
  `folderName`/`exportFormat` em UserDefaults.

### 5. `ContentView.swift` (dashboard)
- Cartão de status (Idle/Sincronizando/Concluído/Falha), contadores (fotos na galeria,
  backup concluído, última sincronização), botão proeminente **"Sincronizar Agora"**
  (desabilitado durante a sync), acesso às Configurações. Use apenas APIs **iOS 16**
  (evite `.symbolEffect`, `.topBarTrailing`, `onChange` de 2 parâmetros).

### 6. `SettingsView.swift`
- Campo para o nome da pasta de destino no iCloud Drive + `Picker` do formato
  (Original/Compatível) com descrição. Mudanças valem só para backups futuros.

### 7. `MainApp.swift`
- `@main`; `@StateObject` do ViewModel; registra a BG task no `init`; agenda ao ir para
  segundo plano; pede permissão de Fotos no primeiro uso.

## Info.plist — chaves exatas
- `NSPhotoLibraryUsageDescription` (texto PT-BR explicando o backup).
- `UIBackgroundModes` = `[processing]`.
- `BGTaskSchedulerPermittedIdentifiers` = `[com.photovault.sync.processing]`.
- `NSUbiquitousContainers` → `{ "iCloud.<SEU_BUNDLE_ID>": {
  NSUbiquitousContainerIsDocumentScopePublic = true,
  NSUbiquitousContainerSupportedFolderLevels = Any,
  NSUbiquitousContainerName = "PhotoVault" } }` (torna a pasta visível no app Arquivos).
- Chaves de bundle completas (`CFBundleExecutable = $(EXECUTABLE_NAME)`,
  `CFBundleIdentifier = $(PRODUCT_BUNDLE_IDENTIFIER)`, `UILaunchScreen` = dict vazio, etc.)
  para permitir build por linha de comando.

## Entitlements — chaves exatas
- `com.apple.developer.icloud-services` = `["CloudDocuments"]`.
- `com.apple.developer.icloud-container-identifiers` = `["iCloud.<SEU_BUNDLE_ID>"]`.
- `com.apple.developer.ubiquity-container-identifiers` = `["iCloud.<SEU_BUNDLE_ID>"]`.

## Regras de qualidade de código
- Type hints/tipos explícitos; `guard` para saída antecipada; sem `try!`/`as!`.
- Tratamento granular de erros; nada de "engolir" exceções silenciosamente.
- Comentários **em PT-BR** explicando o "porquê", especialmente na garantia one-way.
- Sem dependências externas (só frameworks da Apple).

## Ferramentas de build — gere também
1. **`project.yml`** para **XcodeGen** (target app, iOS 16, `PRODUCT_BUNDLE_IDENTIFIER`,
   `INFOPLIST_FILE`, `GENERATE_INFOPLIST_FILE = NO`, `CODE_SIGN_ENTITLEMENTS` apontando
   para o `.entitlements`).
2. **`build_ipa.sh`** que roda `xcodegen generate` e `xcodebuild archive`, depois exporta
   um `.ipa` (via `-exportArchive` com um `ExportOptions.plist`).
3. **`ExportOptions.plist`** (method `development`, seu Team ID, signing automático).
4. **`README.md`** com todo o passo a passo abaixo.

---

## PRÉ-REQUISITO IMPORTANTE (documente no README)
O recurso **iCloud Drive exige o Apple Developer Program pago (US$ 99/ano)**. Um Apple ID
gratuito **não consegue** provisionar o container iCloud (o Xcode bloqueia com "Personal
development teams do not support the iCloud capability"), e a assinatura gratuita da
AltStore **remove** o entitlement de iCloud. Portanto, para a versão iCloud:
1. Inscreva-se no Apple Developer Program.
2. Crie um **iCloud Container** (`iCloud.<SEU_BUNDLE_ID>`) no portal developer.apple.com.
3. Substitua `<SEU_BUNDLE_ID>` em: `project.yml`, `Info.plist` (`NSUbiquitousContainers`)
   e `.entitlements`.

> Se você NÃO quiser pagar, peça a variante de **backup LOCAL**: gravar em
> `Documents/<pasta>` do app com `UIFileSharingEnabled = YES` e
> `LSSupportsOpeningDocumentsInPlace = YES` (aparece no app Arquivos, em "No meu iPhone"),
> **sem iCloud e sem conta paga**. Roda com Apple ID grátis + AltStore.

---

## COMO COMPILAR na MACINCLOUD (documente no README)
1. Contrate um Mac na **MacinCloud** (plano *Pay-As-You-Go* serve). Acesse por VNC/RDP;
   ele já vem com **Xcode**.
2. Leve o projeto para o Mac (via **Git** — recomendado — ou upload/zip).
3. No Terminal do Mac:
   ```bash
   brew install xcodegen        # gerador do .xcodeproj
   chmod +x build_ipa.sh
   ./build_ipa.sh               # gera build/PhotoVault.ipa
   ```
4. Na versão iCloud (conta paga), configure o **Team** e o **signing** no Xcode
   (`xcodegen generate` e abra o `.xcodeproj`), pois o entitlement de iCloud precisa de um
   provisioning profile válido com o container. Exporte um `.ipa` **assinado** (Product ▸
   Archive ▸ Distribute App ▸ Development).

> Observação: a MacinCloud é um Mac **remoto** — ela **compila**, mas **não enxerga o seu
> iPhone**. A instalação no celular sai do seu **PC local** (próximo passo).

---

## COMO INSTALAR no iPhone via ALTSTORE (documente no README)
1. Baixe o `.ipa` do Mac para o seu **PC (Windows)**.
2. Instale o **AltServer** (https://altstore.io) no Windows.
3. Conecte o iPhone por **USB**, confie no computador.
4. AltServer (bandeja) ▸ **Install AltStore** ▸ selecione o iPhone ▸ faça login com seu
   **Apple ID** (para iCloud, use o Apple ID **da conta paga**).
5. No iPhone: *Ajustes ▸ Geral ▸ VPN e Gerenciamento de Dispositivos* ▸ **confie** no perfil.
6. Abra a **AltStore** ▸ **My Apps** ▸ **+** ▸ selecione o `PhotoVault.ipa`.

> ⚠️ **Caveats reais:**
> - A **AltStore PAL não instala `.ipa`** — use a **AltStore Classic** (via AltServer).
> - Assinatura com Apple ID **grátis** expira em **7 dias** (renove abrindo a AltStore com
>   o AltServer ativo) e **não suporta iCloud**.
> - Se a AltStore remover o entitlement de iCloud na reassinatura, use o **Sideloadly**
>   (Windows) com a opção de **preservar entitlements**, assinando com a conta paga.

---

## PLANO DE TESTES (documente no README e valide)
1. **One-way:** sincronize → apague uma foto da galeria → sincronize de novo → a cópia
   **permanece** no iCloud Drive.
2. **Sem duplicatas:** duas syncs seguidas → a 2ª não recria arquivos.
3. **Visibilidade:** a pasta aparece no app **Arquivos ▸ iCloud Drive**.
4. **Compatível:** com o formato "Compatível", HEIC/HEVC saem como `.jpg`/`.mp4`.

## Entregáveis
Gere **todos** os arquivos Swift, o `Info.plist`, o `.entitlements`, o `project.yml`, o
`build_ipa.sh`, o `ExportOptions.plist` e o `README.md`. Gere um arquivo por vez, com
comentários em PT-BR. Ao final, liste o que ainda depende de ação minha (Team ID, Bundle
ID, container iCloud).

=== FIM DO PROMPT ===

---

## Observações para você (fora do prompt)
- **Já existe uma implementação pronta** desta ideia nesta pasta (versão **backup local**,
  grátis). Este prompt serve para (re)gerar a **versão iCloud** do zero num projeto novo do
  Antigravity, ou para você ter o "molde" completo.
- **A melhor linguagem é Swift + SwiftUI** — a resposta objetiva à sua pergunta.
- **Decisão de custo:** iCloud Drive = conta paga (US$ 99/ano). Backup local = grátis.
