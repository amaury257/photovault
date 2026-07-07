# PhotoVault — Backup local de fotos (sem iCloud)

App iOS nativo (Swift + SwiftUI) que faz **backup unidirecional** de todas as fotos e vídeos da galeria para uma **pasta do próprio app**, visível no app **Arquivos** (em *No meu iPhone ▸ PhotoVault*). De lá você copia para PC, Google Drive, HD externo, o que quiser.

> ✅ **Roda com Apple ID GRÁTIS + AltStore Classic.** Esta versão **não usa iCloud**, então **não exige** a conta paga (US$ 99/ano) do Apple Developer Program.

> ⚠️ **Backup unidirecional (one-way):** apagar uma foto da galeria **nunca** apaga a cópia já feita na pasta de backup. O app mantém um livro-razão local dos `localIdentifier` já copiados, ignora assets ausentes e evita duplicatas.

---

## 🔭 Visão geral do fluxo (Windows → Mac na nuvem → iPhone)

```
┌─────────────────────────┐   1. sobe o código
│  Seu PC (Windows)       │──────────────────────────┐
│  C:\dell\Python\Apple   │                           ▼
└─────────────────────────┘              ┌────────────────────────────┐
            ▲                             │  Mac na nuvem (MacinCloud) │
            │  3. baixa PhotoVault.ipa    │  Xcode + XcodeGen          │
            └─────────────────────────────│  ./build_ipa.sh → .ipa     │
                                          └────────────────────────────┘
┌─────────────────────────┐   4. AltServer assina c/ seu Apple ID
│  Seu PC (Windows)       │──────────────────────────┐
│  AltServer + AltStore   │                           ▼
└─────────────────────────┘                 ┌───────────────────┐
                                            │  iPhone (AltStore) │  app instalado
                                            └───────────────────┘
```

O Mac na nuvem **só compila** (ele não enxerga seu iPhone). Quem instala no celular é o **AltServer no seu PC Windows**, com o iPhone por **cabo USB** ou no **mesmo Wi-Fi**.

---

## 📁 Estrutura do projeto

```
C:\dell\Python\Apple\
├── project.yml                     # XcodeGen: gera o .xcodeproj
├── build_ipa.sh                    # Gera o PhotoVault.ipa (não assinado)
├── README.md
└── PhotoVaultiCloudSync\
    ├── App\MainApp.swift           # @main; registra + agenda a BG task
    ├── Views\ContentView.swift     # Dashboard (status, contadores, botão)
    ├── Views\SettingsView.swift    # Nome da pasta + formato de exportação
    ├── ViewModels\SyncViewModel.swift
    ├── Core\
    │   ├── SyncModels.swift         # SyncStatus / SyncError / ExportFormat
    │   ├── PhotoTracker.swift       # Livro-razão (garante o one-way)
    │   ├── PhotoSyncEngine.swift    # Permissão, pasta local, extração, escrita
    │   └── BackgroundSyncManager.swift
    ├── Resources\Info.plist         # Privacidade + Arquivos + Background
    └── PhotoVaultiCloudSync.entitlements   # vazio (versão local não usa)
```

Alvo mínimo: **iOS 16.0**.

---

## 🚀 Passo a passo

### Etapa A — Subir o código para o Mac na nuvem

1. Contrate um **[MacinCloud](https://www.macincloud.com/)** (plano *Pay-As-You-Go* já serve). Você recebe acesso a um Mac com **Xcode** por VNC/RDP.
2. Leve a pasta `C:\dell\Python\Apple` para o Mac. Opções:
   - **Git** (recomendado): suba para um repositório privado e faça `git clone` no Mac; **ou**
   - Zipe a pasta e transfira pelo recurso de upload do MacinCloud / um Google Drive.

### Etapa B — Compilar o `.ipa` no Mac

No Terminal do Mac, dentro da pasta do projeto:

```bash
# instala o gerador de projeto (uma vez)
brew install xcodegen

# gera o .ipa não assinado
chmod +x build_ipa.sh
./build_ipa.sh
```

Ao final, o arquivo estará em **`build/PhotoVault.ipa`**.

> Alternativa sem script: `xcodegen generate` e depois abra o `.xcodeproj` no Xcode → *Product ▸ Archive* → *Distribute App ▸ Ad Hoc/Development* (ou exporte o `.app`).

### Etapa C — Baixar o `.ipa` para o seu PC Windows

Transfira `build/PhotoVault.ipa` do Mac para o Windows (Git, Drive, ou o compartilhamento do MacinCloud).

### Etapa D — Instalar no iPhone com a AltStore Classic

1. Instale o **AltServer** no Windows: <https://altstore.io>
2. Conecte o iPhone por **USB**, confie no computador.
3. No AltServer (bandeja do Windows): **Install AltStore** → escolha seu iPhone → faça login com seu **Apple ID** (o gratuito serve).
4. No iPhone: *Ajustes ▸ Geral ▸ VPN e Gerenciamento de Dispositivos* → **confie** no seu perfil de desenvolvedor.
5. Abra a **AltStore** no iPhone → aba **My Apps** → toque no **+** (canto superior) → selecione o **`PhotoVault.ipa`**.
6. A AltStore assina com seu Apple ID e instala. Pronto! 🎉

> 🔁 **Validade de 7 dias (conta grátis):** o app expira em 1 semana. Para renovar, abra a AltStore com o AltServer ativo (mantenha o *Background Refresh* ligado e o PC acessível no mesmo Wi-Fi de vez em quando).

---

## 📲 Usando o app

1. Ao abrir, autorize o **acesso às Fotos**.
2. O painel mostra: **fotos na galeria**, **backup concluído** e **última sincronização**.
3. Toque em **"Sincronizar Agora"**.
4. Em **Configurações** (engrenagem): defina o **nome da pasta** e o **formato de exportação**.
5. Abra o app **Arquivos ▸ No meu iPhone ▸ PhotoVault ▸ \<sua pasta\>** e veja as mídias. Selecione e **compartilhe/copie** para onde quiser.

### 📦 Formato de exportação (Original × Compatível)

| Modo | Fotos | Vídeos | Quando usar |
|------|-------|--------|-------------|
| **Original** (padrão) | HEIC/RAW | HEVC/H.265 | Fidelidade máxima, menor tamanho (abre bem em aparelhos Apple). |
| **Compatível** | **JPEG** (q=0,95, resolução máxima, EXIF preservado) | **MP4/H.264** (até 4K) | Abrir em **qualquer** PC (Windows), Android ou navegador. |

A troca vale só para os **próximos** backups; arquivos já copiados permanecem como estão.

---

## 🧪 Testes recomendados

1. **One-way:** sincronize, apague uma foto da galeria, sincronize de novo → a cópia **permanece** na pasta do app. ✅
2. **Sem duplicatas:** toque em "Sincronizar Agora" duas vezes → a 2ª não recria arquivos. ✅
3. **Visibilidade no Arquivos:** após a 1ª sync, veja a pasta em *No meu iPhone ▸ PhotoVault*. ✅
4. **Compatível:** troque para "Compatível" nas Configurações, sincronize um HEIC/HEVC e confira que saíram `.jpg`/`.mp4`. ✅

---

## 🧠 Decisões de arquitetura

| Tema | Decisão |
|------|---------|
| Destino do backup | Pasta `Documents/<folder>` do app, exposta no app Arquivos via `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` (sem iCloud, sem conta paga). |
| One-way | Livro-razão (`ledger.json`) **só cresce**; ausência local nunca apaga a cópia. |
| Extração | `PHAssetResourceManager.writeData(for:toFile:)` (streaming; baixa originais do iCloud Fotos com `isNetworkAccessAllowed`). |
| Formato universal | Fotos → JPEG (ImageIO); vídeos → MP4/H.264 (`AVAssetExportSession`). |
| Concorrência | `actor` (engine + tracker); UI em `@MainActor`; async/await. |

---

## 🔧 Solução de problemas

- **`xcodegen: command not found`** → `brew install xcodegen` no Mac.
- **Build falha por assinatura** → o `build_ipa.sh` já usa `CODE_SIGNING_ALLOWED=NO`; não selecione um time no Xcode.
- **AltStore: "Unable to install" / expira** → mantenha o AltServer rodando; conta grátis expira em 7 dias (renove abrindo a AltStore).
- **A pasta não aparece no Arquivos** → confirme que o `Info.plist` tem `UIFileSharingEnabled` e `LSSupportsOpeningDocumentsInPlace` = `YES` e faça ao menos uma sincronização (a pasta só surge quando há conteúdo).
- **Fotos "sumidas" na exportação** → se a biblioteca usa *Otimizar Armazenamento*, o app baixa o original do iCloud Fotos (precisa de rede) antes de copiar.

---

## ↗️ Migrar para iCloud no futuro (opcional, conta paga)

Se um dia assinar o Apple Developer Program (US$ 99/ano), dá para voltar ao backup em **iCloud Drive**: reintroduza os entitlements de iCloud, o `NSUbiquitousContainers` no Info.plist e troque o destino em `PhotoSyncEngine.resolverPastaDestino` de volta para o ubiquity container. O restante do app (one-way, formatos, UI) permanece igual.
