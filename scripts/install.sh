#!/bin/sh
# Installs or updates Kuroneko from the latest GitHub release:
#
#   curl -fsSL https://github.com/gandarfh/kuroneko/releases/latest/download/install.sh | sh
#
# Resolves "latest" through the GitHub Releases redirect (no API rate limit,
# no jq). Meetings, notes, voices and models live in
# ~/Library/Application Support/Kuroneko and are never touched.
#
#   KURONEKO_INSTALL_DIR   where the app goes (default /Applications)
#   KURONEKO_SIGN_IDENTITY certificate to sign with (default "Apple Development")
#   KURONEKO_FORCE=1       reinstall the same version / update mid-recording
set -eu

REPO="gandarfh/kuroneko"
APP="Kuroneko"
BUNDLE_ID="com.gandarfh.kuroneko"
INSTALL_DIR="${KURONEKO_INSTALL_DIR:-/Applications}"
SIGN_IDENTITY="${KURONEKO_SIGN_IDENTITY:-Apple Development}"
FORCE="${KURONEKO_FORCE:-}"
DATABASE="$HOME/Library/Application Support/Kuroneko/kuroneko.sqlite"
TARGET="${INSTALL_DIR}/${APP}.app"

fail() {
  echo "erro: $*" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "o Kuroneko só roda no macOS"
[ "$(uname -m)" = "arm64" ] || fail "o Kuroneko precisa de um Mac com Apple Silicon"

latest_url=$(curl --proto '=https' -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest")
tag="${latest_url##*/}"
case "$tag" in
  v*) ;;
  *) fail "nenhuma versão publicada em https://github.com/${REPO}/releases" ;;
esac
version="${tag#v}"
asset="${APP}-${version}.zip"
base_url="https://github.com/${REPO}/releases/download/${tag}"

installed=""
if [ -f "${TARGET}/Contents/Info.plist" ]; then
  installed=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${TARGET}/Contents/Info.plist" 2>/dev/null || true)
fi
if [ "$installed" = "$version" ] && [ -z "$FORCE" ]; then
  echo "Kuroneko ${version} já está instalado em ${TARGET}."
  exit 0
fi

running=""
if pgrep -x "$APP" >/dev/null 2>&1; then
  running=1
  # Quitting mid-call would cut the recording in two.
  recording=0
  if [ -f "$DATABASE" ]; then
    recording=$(sqlite3 "$DATABASE" "SELECT count(*) FROM meeting WHERE status = 'recording'" 2>/dev/null || echo 0)
  fi
  if [ "$recording" != "0" ] && [ -z "$FORCE" ]; then
    fail "o Kuroneko está gravando uma reunião; atualize depois da chamada (ou rode com KURONEKO_FORCE=1)"
  fi
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

echo "Baixando Kuroneko ${tag}..."
curl --proto '=https' -fsSL -o "${workdir}/${asset}" "${base_url}/${asset}"
curl --proto '=https' -fsSL -o "${workdir}/SHA256SUMS" "${base_url}/SHA256SUMS"

expected=$(grep " ${asset}\$" "${workdir}/SHA256SUMS" | cut -d' ' -f1)
[ -n "$expected" ] || fail "${asset} não está no SHA256SUMS"
actual=$(shasum -a 256 "${workdir}/${asset}" | cut -d' ' -f1)
if [ "$expected" != "$actual" ]; then
  echo "erro: o checksum de ${asset} não confere" >&2
  echo "  esperado: $expected" >&2
  echo "  recebido: $actual" >&2
  exit 1
fi

ditto -x -k "${workdir}/${asset}" "${workdir}/app"
app="${workdir}/app/${APP}.app"
[ -d "$app" ] || fail "o pacote não contém ${APP}.app"

# macOS ties the mic, system audio and Automation permissions to the app's
# signature. Releases are signed ad hoc, which changes with every build, so
# the app is re-signed with the user's own certificate: then each update
# keeps the permissions already granted.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${SIGN_IDENTITY}"; then
  codesign --force --sign "$SIGN_IDENTITY" "$app"
else
  echo "aviso: certificado \"${SIGN_IDENTITY}\" não encontrado; o macOS vai pedir as permissões de novo a cada atualização" >&2
fi

if [ -n "$running" ]; then
  # A regular quit, so the app finishes what it is writing. A transcription
  # cut short resumes on the next launch.
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  waited=0
  while pgrep -x "$APP" >/dev/null 2>&1; do
    waited=$((waited + 1))
    if [ "$waited" -gt 20 ]; then
      pkill -x "$APP" || true
      sleep 1
      break
    fi
    sleep 0.5
  done
fi

mkdir -p "$INSTALL_DIR" 2>/dev/null || true
[ -w "$INSTALL_DIR" ] || fail "sem permissão para escrever em ${INSTALL_DIR}; rode com KURONEKO_INSTALL_DIR=\"\$HOME/Applications\""
rm -rf "$TARGET"
ditto "$app" "$TARGET"

if [ -n "$installed" ]; then
  echo "Kuroneko atualizado de ${installed} para ${version} em ${TARGET}."
else
  echo "Kuroneko ${version} instalado em ${TARGET}."
fi
open "$TARGET"
