#!/usr/bin/env bash
#
# build_ipa.sh — gera um .ipa NÃO ASSINADO do PhotoVault, pronto para a AltStore.
#
# Rode em um Mac com Xcode (ex.: MacinCloud). Pré-requisitos:
#   xcode-select --install          # ferramentas de linha de comando (se preciso)
#   brew install xcodegen           # gerador do .xcodeproj
#
# Resultado: build/PhotoVault.ipa  (transfira-o para o seu PC e instale via AltStore)

set -euo pipefail

PROJECT="PhotoVaultiCloudSync.xcodeproj"
SCHEME="PhotoVaultiCloudSync"
CONFIG="Release"
BUILD_DIR="build"
ARCHIVE="${BUILD_DIR}/PhotoVault.xcarchive"

echo "==> 1/4  Gerando o projeto Xcode (XcodeGen)…"
xcodegen generate

echo "==> 2/4  Arquivando SEM assinatura (a AltStore assina depois)…"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -sdk iphoneos \
  -archivePath "${ARCHIVE}" \
  archive \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  | xcpretty || true   # xcpretty é opcional; ignora se não estiver instalado

echo "==> 3/4  Empacotando .app em Payload/ → .ipa…"
APP_PATH="$(ls -d "${ARCHIVE}/Products/Applications/"*.app | head -n 1)"
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "ERRO: .app não encontrado no archive. O build falhou?" >&2
  exit 1
fi

rm -rf "${BUILD_DIR}/Payload" "${BUILD_DIR}/PhotoVault.ipa"
mkdir -p "${BUILD_DIR}/Payload"
cp -R "${APP_PATH}" "${BUILD_DIR}/Payload/"
( cd "${BUILD_DIR}" && zip -qry "PhotoVault.ipa" "Payload" )
rm -rf "${BUILD_DIR}/Payload"

echo "==> 4/4  Pronto!"
echo "    Arquivo: ${BUILD_DIR}/PhotoVault.ipa"
echo "    Transfira-o para o seu PC e instale com a AltStore Classic."
