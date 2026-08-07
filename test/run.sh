#!/usr/bin/env bash
# Entrada unica da suite. Roda as tres camadas:
#
#   1. estrutura  — claude plugin validate
#   2. estatico   — shellcheck
#   3. comportamento — bats
#
# Ferramentas ausentes viram aviso localmente e erro no CI (--strict), para que
# um `git clone && test/run.sh` funcione sem instalar nada, mas o CI nao passe
# por engano com meia suite. `claude` e a excecao: e sempre opcional, porque a
# CLI nao esta disponivel em runner de CI.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

BATS_VERSION="v1.11.0"
STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1
[ -n "${CI:-}" ] && STRICT=1

rc=0
skipped=()

step() { printf '\n\033[1m── %s\033[0m\n' "$1"; }
optional() { printf '\033[33mpulado: %s nao instalado\033[0m\n' "$1"; skipped+=("$1"); }
missing() {
  if [ "$STRICT" -eq 1 ]; then
    printf '\033[31mFALTA: %s (obrigatorio com --strict/CI)\033[0m\n' "$1"; rc=1
  else
    printf '\033[33mpulado: %s nao instalado\033[0m\n' "$1"; skipped+=("$1")
  fi
}

# ---------------------------------------------------------------- estrutura --
step "estrutura (claude plugin validate)"
if command -v claude >/dev/null 2>&1; then
  claude plugin validate . || rc=1
else
  optional "claude"
fi

# ------------------------------------------------------------------- build --
# Antes dos testes, sempre: sem isto a suite valida um binario velho e passa
# verde sobre codigo que voce acabou de quebrar.
step "build (go)"
if command -v go >/dev/null 2>&1; then
  go vet ./... || rc=1
  ./build.sh || rc=1
else
  missing "go"
fi

# ----------------------------------------------------------------- estatico --
step "estatico (shellcheck)"
if command -v shellcheck >/dev/null 2>&1; then
  # Só arquivos de shell: bin/ e libexec/ tambem guardam launchers .cmd e
  # binarios compilados, que o shellcheck tentaria interpretar como script.
  #
  # find|xargs em vez de mapfile: `mapfile` e builtin do bash 4+, e o bash que o
  # macOS traz e o 3.2. O CI pegou isso — a matriz de duas plataformas existe
  # exatamente para esse tipo de coisa.
  #
  # SC1091: nao seguir o source de _lib.sh/_yaml.sh (resolvido em runtime).
  find bin libexec test/mocks -maxdepth 1 -type f \
    ! -name '*.cmd' ! -name '*.exe' ! -name '*-amd64' ! -name '*-arm64' -print0 \
    | xargs -0 shellcheck -e SC1091 build.sh test/run.sh || rc=1
  printf 'ok\n'
else
  missing "shellcheck"
fi

# ------------------------------------------------------------- comportamento --
step "comportamento (bats)"
BATS=""
if [ -x test/bats/bin/bats ]; then
  BATS=test/bats/bin/bats
elif command -v bats >/dev/null 2>&1; then
  BATS=$(command -v bats)
elif command -v git >/dev/null 2>&1; then
  printf 'bats nao encontrado; clonando %s em test/bats...\n' "$BATS_VERSION"
  if git clone --depth 1 --branch "$BATS_VERSION" -q \
       https://github.com/bats-core/bats-core.git test/bats 2>/dev/null; then
    BATS=test/bats/bin/bats
  fi
fi

if [ -n "$BATS" ]; then
  "$BATS" test/*.bats || rc=1
else
  missing "bats"
fi

# ------------------------------------------------------------------ resumo ---
printf '\n'
if [ "$rc" -eq 0 ]; then
  printf '\033[32mSUITE OK\033[0m'
  [ ${#skipped[@]} -gt 0 ] && printf ' (pulado: %s)' "${skipped[*]}"
  printf '\n'
else
  printf '\033[31mSUITE FALHOU\033[0m\n'
fi
exit "$rc"
