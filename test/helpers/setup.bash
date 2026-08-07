#!/usr/bin/env bash
# Helpers compartilhados pelos arquivos .bats.

PLUGIN_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
export PLUGIN_ROOT

# Os mocks vem ANTES de tudo: nenhum teste toca rede, SSH ou servidor.
export PATH="$PLUGIN_ROOT/test/mocks:$PLUGIN_ROOT/bin:$PATH"

# Os testes chamam o LAUNCHER, nao o binario direto — assim a selecao de
# plataforma tambem entra na suite.
GUARD="$PLUGIN_ROOT/libexec/guard"
export GUARD

# make_project — projeto git temporario com config valida, ja commitado.
make_project() {
  TEST_TMP=$(mktemp -d)
  export TEST_TMP

  # O log dos mocks fica FORA do repositorio. Dentro, ele apareceria como
  # arquivo nao rastreado e o guard bloquearia todo deploy por arvore suja —
  # que foi exatamente o que aconteceu na primeira execucao desta suite.
  MOCK_LOG="$TEST_TMP/mock.log"
  export MOCK_LOG
  : > "$MOCK_LOG"

  mkdir -p "$TEST_TMP/project"
  cd "$TEST_TMP/project" || return 1

  git init -q -b main .
  git config user.email test@example.com
  git config user.name  Test
  git config commit.gpgsign false

  cat > .cloudez.yaml <<'YAML'
guard:
  protected_environments: [production]
  allowed_branches: [main]
  approval_ttl_minutes: 15
  require_clean_tree: true
sites:
  staging:
    health_url: https://staging.example.com/
    build: {command: "true", output_dir: dist}
    ssh: {host: srv.example.com, user: deploy, port: 22}
    paths: {root: /srv/staging}
    rsync: {exclude: [.git, node_modules]}
    keep_releases: 5
  production:
    health_url: https://example.com/
    build: {command: "true", output_dir: dist}
    ssh: {host: srv.example.com, user: deploy, port: 22}
    paths: {root: /srv/production}
    keep_releases: 10
YAML

  printf '.cloudez/\n' > .gitignore
  git add -A
  git commit -qm "init"
}

teardown() {
  [ -n "${TEST_TMP:-}" ] && [ -d "$TEST_TMP" ] && rm -rf "$TEST_TMP"
  return 0
}

# bash_payload <comando> — payload PreToolUse para a tool Bash
bash_payload() {
  jq -nc --arg c "$1" --arg cwd "$PWD" \
    '{tool_name:"Bash", cwd:$cwd, tool_input:{command:$c}}'
}

# mcp_payload <tool> <environment> — payload PreToolUse para uma tool MCP
mcp_payload() {
  jq -nc --arg t "mcp__cloudez__$1" --arg e "$2" --arg cwd "$PWD" \
    '{tool_name:$t, cwd:$cwd, tool_input:{environment:$e}}'
}

# approve <environment> [sha] [epoch] — forja uma aprovacao
approve() {
  mkdir -p .cloudez/state
  jq -n --arg e "$1" \
        --arg s "${2:-$(git rev-parse HEAD)}" \
        --argjson t "${3:-$(date +%s)}" \
    '{environment:$e, sha:$s, approved_at_epoch:$t}' \
    > ".cloudez/state/approval-$1.json"
}

# guard <payload> — roda o hook, expondo status/output
guard() { printf '%s' "$1" | "$GUARD"; }

# jq_field <json> <caminho>
jq_field() { printf '%s' "$1" | jq -r "$2"; }
