#!/usr/bin/env bash
# Testes do bin/cloudez-sync — o launcher POSIX — RODANDO NO WINDOWS.
#
# O par .cmd ao lado tem cobertura desde sempre (launcher.ps1), e por isso o
# defeito que este arquivo existe para pegar passou tanto tempo invisível: no
# Windows há DOIS caminhos de entrada, e só um estava sendo verificado.
#
# Quando quem chama é o cmd ou o PowerShell, o PATHEXT resolve para o .cmd.
# Quando quem chama é um bash — Git Bash vem junto com o Git, e é o shell que
# várias ferramentas usam para executar comando —, quem responde é este script
# POSIX. Ele lia `uname -s`, recebia `MINGW64_NT-10.0-22631` em vez de
# `windows`, montava `libexec/sync-mingw64_nt-10.0-22631-amd64` e falhava
# dizendo "binário ausente para mingw64_nt-10.0-22631/amd64" — com o
# sync-windows-amd64.exe correto ali ao lado o tempo todo.
#
# Roda em qualquer plataforma de propósito: as afirmações são sobre o launcher
# escolher o binário certo para o sistema em que está, e isso vale em todo lugar.
# O que só o runner Windows fornece é o `uname` que expõe o bug.

set -uo pipefail

raiz=$(cd -- "$(dirname -- "$0")/../.." && pwd)
launcher="$raiz/bin/cloudez-sync"

falhas=0

verifica() {
  nome=$1
  condicao=$2
  detalhe=${3:-}
  if [ "$condicao" = "0" ]; then
    echo "ok    $nome"
  else
    echo "FALHA $nome"
    if [ -n "$detalhe" ]; then echo "      $detalhe"; fi
    falhas=$((falhas + 1))
  fi
}

echo "uname -s: $(uname -s)    uname -m: $(uname -m)"
echo

if [ -f "$launcher" ]; then
  verifica 'o launcher existe' 0
else
  verifica 'o launcher existe' 1 "$launcher"
fi

# ── o coração do teste ──────────────────────────────────────────────────────
#
# Sem argumentos o binário imprime o uso e sai 2. É por não ser 0 nem 1 que esse
# código serve aqui: distingue "o launcher achou e executou o binário" de "o
# launcher não achou o binário" (que sai 1, do próprio launcher).
saida=$("$launcher" 2>&1)
codigo=$?

printf '      | %s\n' "$saida"

if [ "$codigo" = "1" ]; then
  case "$saida" in
    *ausente*)
      verifica 'o launcher acha o binario da plataforma' 1 \
        "o launcher não encontrou o binário — é o bug do uname/.exe voltando" ;;
    *) verifica 'o launcher acha o binario da plataforma' 1 "saída inesperada" ;;
  esac
else
  verifica 'o launcher acha o binario da plataforma' 0
fi

if [ "$codigo" = "2" ]; then
  verifica 'propaga o codigo de saida do binario' 0
else
  verifica 'propaga o codigo de saida do binario' 1 "esperado 2, veio $codigo"
fi

case "$saida" in
  *"uso: cloudez-sync"*) verifica 'chegou a executar o binario' 0 ;;
  *) verifica 'chegou a executar o binario' 1 "saída: $saida" ;;
esac

# ── o mapeamento em si ──────────────────────────────────────────────────────
#
# Redundante com o teste acima em condições normais, e de propósito: se alguém
# mexer no `case` do launcher, esta afirmação diz QUAL era o problema, em vez de
# só "não achou o binário".
case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
  mingw*|msys*|cygwin*)
    case "$saida" in
      *mingw*|*msys*|*cygwin*)
        verifica 'mapeia MINGW/MSYS/CYGWIN para windows' 1 \
          "o nome do sistema vazou para o caminho do binário" ;;
      *) verifica 'mapeia MINGW/MSYS/CYGWIN para windows' 0 ;;
    esac
    ;;
  *)
    echo "pula  mapeia MINGW/MSYS/CYGWIN para windows (só faz sentido no Windows)"
    ;;
esac

echo
if [ "$falhas" -gt 0 ]; then
  echo "$falhas falha(s)"
  exit 1
fi

echo 'launcher POSIX OK'
exit 0
