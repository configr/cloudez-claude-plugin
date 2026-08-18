#!/usr/bin/env bash
# O `bin/cloudez-sync` chamado de dentro de um bash NO WINDOWS.
#
# Existe porque no Windows há DUAS portas de entrada, e um defeito em uma fica
# invisível enquanto a outra é a testada. A do cmd/PowerShell é o `.cmd`, coberto
# pelo `launcher.ps1`; esta é a do Git Bash, que vem junto com o Git e é o shell
# que várias ferramentas — inclusive o Claude Code — usam para rodar comando.
#
# O arquivo que estava aqui antes testava OUTRA coisa: o launcher POSIX escolhia o
# binário Go da plataforma, e `uname -s` no Git Bash devolve
# `MINGW64_NT-10.0-22631`, não `windows`. O launcher montava um nome de arquivo que
# nunca existiu, e o erro dizia "binário ausente para mingw64_nt-...", que se lê
# como falta de build.
#
# Sem binário por plataforma, essa classe de defeito desapareceu. O que sobrou para
# verificar aqui é mais estreito e ainda vale: o `#!/usr/bin/env node` resolve neste
# ambiente, e o hash sai igual ao das outras plataformas.
#
# Fora do bats de propósito: portar a suíte para o runner Windows exigiria bash e
# coreutils só para cobrir duas afirmações.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

falhas=0

passou() { printf 'ok    %s\n' "$1"; }
falhou() {
  printf 'FALHA %s\n      %s\n' "$1" "$2"
  falhas=$((falhas + 1))
}

# Os dois afirmadores recebem o valor já calculado, em vez de um `A && B || C`:
# naquela forma, um afirmador que falhasse dispararia TAMBÉM o ramo de erro, e o
# mesmo teste apareceria como ok e como falha.
afirma_igual() { # <nome> <esperado> <obtido>
  if [ "$2" = "$3" ]; then passou "$1"; else falhou "$1" "esperado '$2', veio '$3'"; fi
}

afirma_contem() { # <nome> <agulha> <palheiro>
  case "$3" in
    *"$2"*) passou "$1" ;;
    *) falhou "$1" "nao achei '$2' em: $3" ;;
  esac
}

# ── o shebang resolve sob o Git Bash ────────────────────────────────────────
#
# Sem argumentos o sync imprime o uso e sai 2. O 2 é o que distingue "executou e me
# disse que chamei errado" de "não executou": um shebang que não resolve dá 126 ou
# 127, e um arquivo lido como CommonJS dá erro de sintaxe com 1.
saida=$(./bin/cloudez-sync 2>&1)
codigo=$?

afirma_igual 'o shebang resolve e o script executa' 2 "$codigo"
afirma_contem 'imprimiu o uso' 'uso: cloudez-sync' "$saida"

# ── a âncora do hash entre plataformas ──────────────────────────────────────
#
# O --hash-only é a peça que anda no disco: percorre a árvore, normaliza caminho e
# lê modo de arquivo. É onde uma diferença de plataforma aparece, e onde o Windows
# diverge mais do resto.
#
# O MESMO conteúdo tem de dar o MESMO sha que nas outras plataformas. É o que torna
# o release_id comparável entre a máquina de quem publica e qualquer outra — se o
# Windows divergir aqui, dois deploys do mesmo conteúdo viram releases diferentes.
#
# O valor é o mesmo fixado em test/payload.test.mjs e em test/adapters.bats, e os
# três mudam JUNTOS.
ESPERADO=03ff8bfa4d33e6cad50a7101e974ef34d6e8ccd51a77fbaacf97b7355cef01fc

raiz=$(mktemp -d)
mkdir -p "$raiz/assets" "$raiz/.git"
printf '<h1>oi</h1>' > "$raiz/index.html"
printf 'svg'         > "$raiz/assets/logo.svg"
printf 'ref: x'      > "$raiz/.git/HEAD"

saida=$(./bin/cloudez-sync --hash-only "$raiz" 2>&1)
codigo=$?
rm -rf "$raiz"

afirma_igual 'o --hash-only roda' 0 "$codigo"

obtido=$(printf '%s' "$saida" | sed -n 's/.*"content_sha256": "\([a-f0-9]*\)".*/\1/p')
afirma_igual 'o sha bate com as outras plataformas' "$ESPERADO" "$obtido"

# 2 arquivos: o .git fica de fora, como no tar do transfer.
afirma_contem 'o .git foi excluido' '"files": 2' "$saida"

printf '\n'
if [ "$falhas" -gt 0 ]; then
  printf '%s falha(s)\n' "$falhas"
  exit 1
fi
printf 'sync sob Git Bash OK\n'
