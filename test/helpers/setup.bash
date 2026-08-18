#!/usr/bin/env bash
# Helpers compartilhados pelos arquivos .bats.

PLUGIN_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PLUGIN_ROOT

# Os mocks vem ANTES de tudo: nenhum teste toca rede, SSH ou servidor.
export PATH="$PLUGIN_ROOT/test/mocks:$PLUGIN_ROOT/bin:$PATH"

# make_project — projeto git temporario com config valida, ja commitado.
make_project() {
  TEST_TMP=$(mktemp -d)
  export TEST_TMP

  # O log dos mocks fica FORA do repositorio, para nao aparecer como arquivo
  # nao rastreado no projeto de teste.
  MOCK_LOG="$TEST_TMP/mock.log"
  export MOCK_LOG
  : > "$MOCK_LOG"

  # O token vive no $HOME do usuario. Apontar para o tmp do teste e o que impede
  # a suite de ler — ou pior, sobrescrever — o token real de quem roda ela.
  CLOUDEZ_TOKEN_FILE="$TEST_TMP/token"
  export CLOUDEZ_TOKEN_FILE
  printf 'tok_teste\n' > "$CLOUDEZ_TOKEN_FILE"

  # CLOUDEZ_TOKEN venceria o arquivo e furaria os testes de autenticacao na
  # maquina de quem tem a variavel exportada.
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

# jq_field <json> <caminho>
jq_field() { printf '%s' "$1" | jq -r "$2"; }

# ------------------------------------------------------------- API da Cloudez --
#
# O mock de `curl` no PATH deixou de funcionar quando o cloudez-login virou Node e
# passou a usar `fetch`: nao ha processo externo para interceptar. No lugar sobe
# uma API de verdade em porta efemera — nenhum teste toca a rede, e o que se afirma
# passa a ser a REQUISICAO recebida, nao o comando montado.

# start_api — sobe a API falsa e aponta o CLOUDEZ_API_URL para ela
start_api() {
  API_CONTROL="$TEST_TMP/api"
  mkdir -p "$API_CONTROL"
  export API_CONTROL

  node "$PLUGIN_ROOT/test/mocks/api-server.mjs" "$API_CONTROL" &
  API_PID=$!
  export API_PID

  # Espera o arquivo `port`, que o servidor escreve ao comecar a ouvir. Um sleep
  # fixo ou passa a maior parte do tempo dormindo a toa, ou falha na maquina
  # lenta — e uma suite que falha as vezes e pior do que uma suite lenta.
  local i
  for i in $(seq 1 200); do
    [ -s "$API_CONTROL/port" ] && break
    sleep 0.05
  done
  [ -s "$API_CONTROL/port" ] || { echo "api falsa nao subiu" >&2; return 1; }

  export CLOUDEZ_API_URL="http://127.0.0.1:$(cat "$API_CONTROL/port")"
}

# api_status <codigo> — o que a API respondera na proxima chamada
api_status() { printf '%s' "$1" > "$API_CONTROL/status"; }

# api_offline — aponta para uma porta onde nao ha ninguem.
#
# E a falha de conexao de verdade, nao uma simulacao dela: o `fetch` levanta a
# mesma excecao que levantaria offline, e o veredito tem que cair para "unknown".
api_offline() { export CLOUDEZ_API_URL="http://127.0.0.1:1"; }

# deploy_state <deploy_id> [status] — escreve o estado que o cloudez-sync le.
#
# Antes isto vinha de `cloudez-begin-deploy`, que virou tool do MCP. Escrever o
# JSON direto e mais honesto para um teste de sync: o que se afirma e sobre o
# TRANSPORTE, e depender de outro adaptador para chegar la escondia isso.
#
# O formato e o mesmo que o internal/cloudez le, e o round-trip dele tem teste
# proprio em Go.
deploy_state() {
  local id="$1" status="${2:-awaiting_upload}"
  mkdir -p .cloudez/state
  jq -n --arg id "$id" --arg s "$status" \
    '{deploy_id: $id, release_id: "20260101T000000Z-abc1234",
      environment: "staging", ref: "abc1234def", status: $s,
      root: "/srv/staging", domain: "staging.example.com",
      ssh: {host: "srv.example.com", user: "deploy", port: 22,
            path: "/srv/staging/releases/20260101T000000Z-abc1234/"}}' \
    > ".cloudez/state/$id.json"
  printf '%s' "$id"
}
