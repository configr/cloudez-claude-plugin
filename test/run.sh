#!/usr/bin/env bash
# Entrada unica da suite. Roda as quatro camadas:
#
#   1. estrutura     — claude plugin validate
#   2. estatico      — shellcheck
#   3. unidade       — node --test
#   4. comportamento — bats
#
# Ferramentas ausentes viram aviso localmente e erro no CI (--strict), para que
# um `git clone && test/run.sh` funcione sem instalar nada, mas o CI nao passe
# por engano com meia suite. `claude` e a excecao: e sempre opcional, porque a
# CLI nao esta disponivel em runner de CI.
#
# `--coverage` acrescenta um relatorio de cobertura de bin/ ao fim, juntando o que
# as duas camadas de teste executaram. Fica FORA do CI de proposito: e relatorio,
# nao portao. Ver test/coverage.mjs.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

BATS_VERSION="v1.11.0"
STRICT=0
COBERTURA=0

for arg in "$@"; do
  case "$arg" in
    --strict)   STRICT=1 ;;
    --coverage) COBERTURA=1 ;;
    *) printf 'uso: test/run.sh [--strict] [--coverage]\n' >&2; exit 2 ;;
  esac
done
[ -n "${CI:-}" ] && STRICT=1

# NODE_V8_COVERAGE faz TODO processo Node despejar o coverage bruto do V8 aqui ao
# sair — inclusive os adaptadores que o bats roda como subprocesso, que sao
# justamente os que nenhuma ferramenta embutida alcanca. O relatorio e montado no
# fim, por test/coverage.mjs.
if [ "$COBERTURA" -eq 1 ]; then
  COV_DIR=$(mktemp -d)
  export NODE_V8_COVERAGE="$COV_DIR"
fi

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

# ----------------------------------------------------------------- estatico --
step "estatico (shellcheck)"
if command -v shellcheck >/dev/null 2>&1; then
  # Só arquivos de shell. A selecao e pelo SHEBANG, e nao por uma lista de nomes:
  # bin/ guarda launcher .cmd e scripts sem extensao que NAO sao shell. Uma lista
  # de exclusoes envelheceria a cada migracao, e o sintoma seria uma reprovacao de
  # JavaScript pelo linter de shell.
  #
  # Hoje bin/ nao tem mais nenhum shell: o ultimo era o launcher que escolhia o
  # binario Go da plataforma. O que a busca ainda acha sao os mocks e o teste de
  # Windows — e bin/ fica na lista de proposito, para um script novo la ser pego
  # sem ninguem precisar lembrar de vir aqui.
  #
  # find|xargs em vez de mapfile: `mapfile` e builtin do bash 4+, e o bash que o
  # macOS traz e o 3.2. O CI pegou isso — a matriz de duas plataformas existe
  # exatamente para esse tipo de coisa.
  #
  find bin test/mocks test/windows -maxdepth 1 -type f \
    ! -name '*.cmd' ! -name '*.mjs' ! -name '*.ps1' -print0 \
    | xargs -0 awk 'FNR == 1 && /^#!.*(bash|[ \/]sh)$/ { print FILENAME }' \
    | xargs shellcheck -e SC1091 test/run.sh vendor-mcp.sh || rc=1
  printf 'ok\n'
else
  missing "shellcheck"
fi

# -------------------------------------------------------------------- unidade --
# As propriedades do hash do payload (bin/_payload.mjs).
#
# Nao cabem em bats porque afirmam sobre uma FUNCAO, nao sobre um comando: cada
# uma hasheia duas arvores e compara os resultados. Passar por linha de comando
# seria exercitar o adaptador para testar a biblioteca.
#
# `node --test` e embutido no Node 20, que o plugin ja declara como piso — esta
# camada nao acrescenta dependencia nenhuma a arvore.
step "unidade (node --test)"
if command -v node >/dev/null 2>&1; then
  node --test test/*.test.mjs || rc=1
else
  missing "node"
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

# -------------------------------------------------------------- cobertura ---
if [ "$COBERTURA" -eq 1 ]; then
  step "cobertura (bin/)"
  # Desexporta antes de rodar o relatorio: senao ele se auto-mede, escrevendo no
  # diretorio que esta lendo.
  unset NODE_V8_COVERAGE
  node test/coverage.mjs "$COV_DIR" || rc=1
  rm -rf "$COV_DIR"
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
