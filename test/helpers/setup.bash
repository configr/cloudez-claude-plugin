#!/usr/bin/env bash
# Helpers compartilhados pelos arquivos .bats.

PLUGIN_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PLUGIN_ROOT

# Os mocks vem ANTES de tudo: nenhum teste toca rede, SSH ou servidor.
export PATH="$PLUGIN_ROOT/test/mocks:$PLUGIN_ROOT/bin:$PATH"

# make_project: projeto git temporario com config valida, ja commitado.
make_project() {
  TEST_TMP=$(mktemp -d)
  export TEST_TMP

  # Log dos mocks fora do repositorio, para nao virar arquivo nao rastreado
  # no projeto de teste.
  MOCK_LOG="$TEST_TMP/mock.log"
  export MOCK_LOG
  : > "$MOCK_LOG"

  # Isola do token real de quem roda a suite.
  CLOUDEZ_TOKEN_FILE="$TEST_TMP/token"
  export CLOUDEZ_TOKEN_FILE

  # Mesma razao, para o guard-rail de escrita.
  CLOUDEZ_GUARD_DIR="$TEST_TMP/guard"
  export CLOUDEZ_GUARD_DIR
  printf 'tok_teste\n' > "$CLOUDEZ_TOKEN_FILE"

  # Venceria o arquivo e furaria os testes na maquina de quem a tem exportada.
  unset CLOUDEZ_TOKEN

  mkdir -p "$TEST_TMP/project"
  cd "$TEST_TMP/project" || return 1

  git init -q -b main .
  git config user.email test@example.com
  git config user.name  Test
  git config commit.gpgsign false

  cat > .cloudez.yaml <<'YAML'
cloudez:
  staging:
    domain: staging.example.com
    root: /srv/staging
  production:
    domain: example.com
    root: /srv/production
YAML

  printf '.cloudez/\n' > .gitignore
  git add -A
  git commit -qm "init"
}

teardown() {
  [ -n "${API_PID:-}" ] && kill "$API_PID" 2>/dev/null
  [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"
  return 0
}

# campo <json> <caminho>: extrai um campo, no formato do `jq -r`.
campo() { printf '%s' "$1" | node "$PLUGIN_ROOT/test/helpers/json.mjs" "$2"; }

# campo_de <arquivo> <caminho>: o mesmo, lendo de um arquivo.
campo_de() { node "$PLUGIN_ROOT/test/helpers/json.mjs" "$2" < "$1"; }

# com_pty <bytes> <comando...>: roda o comando num terminal de verdade e
# "digita" os bytes quando o prompt aparecer.
#
# Existe porque o `cloudez-login` abre `/dev/tty`, o terminal de controle;
# mockar stdin nao alcanca esse caminho, so um pty aloca (via `script(1)`).
#
# Espera o prompt aparecer antes de escrever: alimentar por redirect simples
# faz os bytes chegarem antes do modo raw, e a disciplina de linha os
# consome e ecoa, entregando entrada vazia ao login.
#
# A entrada e um pipe, nunca um fifo nomeado: o `script` do BSD recusa fifo
# em stdin.
#
# O EOT (\004) so entra quando falta terminador, para o filho nao esperar
# Enter para sempre; mandado sempre, o terminal o ecoaria como "^D" num
# ponto imprevisivel da saida e quebraria a extracao do payload.
com_pty() {
  local bytes="$1"; shift
  local dir; dir=$(mktemp -d)
  local terminal="$dir/terminal"; : > "$terminal"
  local rc=0

  {
    # 200 x 0,05s = 10s de teto. Se o prompt nao veio, mandar os bytes assim mesmo
    # produz uma falha legivel; esperar para sempre nao.
    local _i
    for _i in $(seq 1 200); do
      # Sai tambem se o processo ja falhou: um caminho que nunca chega a
      # perguntar nao tem prompt para esperar, e pagaria o teto inteiro.
      grep -q 'Token: \|aprovo. para liberar\|"error"' "$terminal" 2>/dev/null && break
      sleep 0.05
    done
    # Terminador so quando falta: ver o item 3 do cabecalho.
    case "$bytes" in
      *$'\n' | *$'\004' | *$'\003') printf '%s' "$bytes" ;;
      *) printf '%s\004' "$bytes" ;;
    esac
  } | {
    if script --version 2>/dev/null | grep -q util-linux; then
      # util-linux quer o comando numa string; %q protege caminho com espaco.
      # O -e nao e opcional: sem ele o script devolve sempre 0, mascarando
      # falha do comando (o BSD propaga por padrao e nem conhece a flag).
      local cmd; cmd=$(printf '%q ' "$@")
      script -q -e -c "$cmd" /dev/null > "$terminal" 2>&1
    else
      script -q /dev/null "$@" > "$terminal" 2>&1
    fi
  } || rc=$?

  # Normaliza o que o terminal acrescenta e nao veio de quem esta sob teste:
  # \r do pty (\n vira \r\n), \b de backspace, e o "^D" que o terminal ecoa
  # quando o `script` fecha o stdin dele fora do modo raw.
  tr -d '\r\010' < "$terminal" | sed 's/\^D//g'
  rm -rf "$dir"
  return $rc
}

# campo_pty <saida> <caminho>: extrai um campo do JSON que veio junto do
# terminal. Num pty, stdout e stderr caem no mesmo fluxo e o payload sai
# colado ao banner do login; o awk guarda so o ultimo bloco que comeca numa
# linha `{` sozinha.
campo_pty() {
  printf '%s\n' "$1" \
    | awk '/^\{$/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' \
    | node "$PLUGIN_ROOT/test/helpers/json.mjs" "$2"
}

# API da Cloudez: sobe um servidor real em porta efemera, ja que o
# cloudez-login usa `fetch` e nao ha mais processo externo para interceptar.
# O que se afirma e a requisicao recebida, nao o comando montado.

# start_api: sobe a API falsa e aponta o CLOUDEZ_API_URL para ela.
start_api() {
  API_CONTROL="$TEST_TMP/api"
  mkdir -p "$API_CONTROL"
  export API_CONTROL

  node "$PLUGIN_ROOT/test/mocks/api-server.mjs" "$API_CONTROL" &
  API_PID=$!
  export API_PID

  # Espera o arquivo `port` em vez de um sleep fixo, que ou desperdica tempo
  # ou falha numa maquina lenta.
  local i
  for i in $(seq 1 200); do
    [ -s "$API_CONTROL/port" ] && break
    sleep 0.05
  done
  [ -s "$API_CONTROL/port" ] || { echo "api falsa nao subiu" >&2; return 1; }

  export CLOUDEZ_API_URL="http://127.0.0.1:$(cat "$API_CONTROL/port")"
}

# api_status <codigo>: o que a API respondera na proxima chamada.
api_status() { printf '%s' "$1" > "$API_CONTROL/status"; }

# api_offline: aponta para uma porta onde nao ha ninguem, para exercitar a
# falha de conexao de verdade, nao uma simulacao dela.
api_offline() { export CLOUDEZ_API_URL="http://127.0.0.1:1"; }

# deploy_state <deploy_id> [status]: escreve o estado que o cloudez-sync le,
# no mesmo formato que mcp/cloudez-state.mjs, para os dois lados nao terem
# schemas que divergem.
deploy_state() {
  local id="$1" status="${2:-awaiting_upload}"
  mkdir -p .cloudez/state
  cat > ".cloudez/state/$id.json" <<JSON
{
  "deploy_id": "$id",
  "release_id": "20260101T000000Z-abc1234",
  "environment": "staging",
  "ref": "abc1234def",
  "status": "$status",
  "root": "/srv/staging",
  "domain": "staging.example.com",
  "ssh": {
    "host": "srv.example.com",
    "user": "deploy",
    "port": 22,
    "path": "/srv/staging/releases/20260101T000000Z-abc1234/"
  }
}
JSON
  printf '%s' "$id"
}
