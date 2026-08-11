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
    ssh: {host: srv.example.com, user: deploy, port: 22}
  production:
    domain: example.com
    root: /srv/production
    ssh: {host: srv.example.com, user: deploy, port: 22}
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
