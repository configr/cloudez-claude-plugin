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
  [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"
  return 0
}

# jq_field <json> <caminho>
jq_field() { printf '%s' "$1" | jq -r "$2"; }

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
