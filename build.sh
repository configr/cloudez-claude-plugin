#!/usr/bin/env bash
# Compila os binarios do plugin para todas as plataformas suportadas.
#
# CGO_ENABLED=0 e o que torna o binario realmente estatico — sem ele, alguns
# caminhos da stdlib (resolucao DNS, os/user) linkam contra a libc do sistema e
# o binario deixa de ser autocontido.
#
# Os artefatos vao para libexec/. Quem os invoca e o launcher `bin/cloudez-<cmd>`
# (com o par .cmd para Windows), que escolhe o arquivo da plataforma atual.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TARGETS="darwin/arm64 darwin/amd64 linux/amd64 linux/arm64 windows/amd64 windows/arm64"
CMDS="${1:-sync}"

mkdir -p libexec

for cmd in $CMDS; do
  for t in $TARGETS; do
    os="${t%/*}"; arch="${t#*/}"
    out="libexec/$cmd-$os-$arch"
    [ "$os" = "windows" ] && out="$out.exe"
    CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" \
      go build -trimpath -ldflags="-s -w" -o "$out" "./cmd/$cmd"
    printf '%-40s %s\n' "$out" "$(du -h "$out" | cut -f1)"
  done
done
