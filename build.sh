#!/usr/bin/env bash
# Compila os binarios do plugin para todas as plataformas suportadas.
#
# CGO_ENABLED=0 e o que torna o binario realmente estatico — sem ele, alguns
# caminhos da stdlib (resolucao DNS, os/user) linkam contra a libc do sistema e
# o binario deixa de ser autocontido.
#
# Os artefatos vao para libexec/, junto com os dois launchers. O hooks.json
# aponta para `libexec/guard` sem extensao: no POSIX isso resolve para o script
# sh, no Windows o PATHEXT resolve para o .cmd. E a unica forma de ter uma
# string de comando estatica que serve nos tres sistemas.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TARGETS="darwin/arm64 darwin/amd64 linux/amd64 linux/arm64 windows/amd64 windows/arm64"
CMDS="${1:-guard}"

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
