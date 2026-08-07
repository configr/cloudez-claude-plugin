#!/usr/bin/env bash
# Helpers compartilhados pelos adaptadores cloudez-*.
#
# O formato de saída destes scripts espelha docs/mcp-tool-contract.md de
# propósito: quando o servidor MCP ficar pronto, a skill troca chamadas Bash por
# chamadas de tool sem mudar o procedimento nem o tratamento de erro.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/_yaml.sh"

CLOUDEZ_STATE_DIR="${CLOUDEZ_STATE_DIR:-.cloudez/state}"
CLOUDEZ_CONFIG_JSON=""   # cache: a conversao YAML->JSON acontece uma vez por processo

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '{"error":{"code":"missing_dependency","message":"%s nao encontrado no PATH","retryable":false}}\n' "$1"
    exit 1
  }
}
need jq

# die <code> <message> [extra_json]
#
# Escreve em stderr, nao em stdout. Helpers como site_config sao chamados dentro
# de $( ), entao um erro em stdout seria capturado na variavel e nunca apareceria.
# stdout fica reservado para o payload de sucesso.
die() {
  local code="$1" message="$2" extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  jq -n --arg c "$code" --arg m "$message" --argjson e "$extra" \
    '{error: ({code: $c, message: $m, retryable: false} + $e)}' >&2
  exit 1
}

# load_config: popula CLOUDEZ_CONFIG_JSON. Nao imprime nada.
#
# Deliberadamente NAO e usada como `x=$(load_config)`: o `exit 1` do die dentro
# de uma substituicao de comando aninhada nao propaga de forma confiavel, e o
# script seguia adiante com a config vazia produzindo um segundo erro enganoso.
# Chamando como comando simples, o die encerra o processo de verdade.
load_config() {
  [ -n "$CLOUDEZ_CONFIG_JSON" ] && return 0

  local f j rc
  f=$(resolve_config)
  [ -f "$f" ] \
    || die config_not_found "Arquivo $f nao encontrado. Copie cloudez.example.yaml e ajuste."

  j=$(yaml_to_json "$f"); rc=$?
  case "$rc" in
    3) die yaml_parser_missing "Nenhum parser YAML disponivel para ler $f." \
         "$(jq -n --arg h "$YAML_PARSER_HINT" '{hint: $h}')" ;;
    0) ;;
    *) die config_invalid "$f nao e um YAML valido." ;;
  esac

  printf '%s' "$j" | jq -e . >/dev/null 2>&1 \
    || die config_invalid "$f nao produziu uma estrutura utilizavel."

  CLOUDEZ_CONFIG_JSON="$j"
}

# site_config <environment> -> JSON do site em stdout
site_config() {
  local env="$1" site
  load_config
  site=$(printf '%s' "$CLOUDEZ_CONFIG_JSON" | jq -c --arg e "$env" '.sites[$e] // empty')
  [ -n "$site" ] \
    || die site_not_found "Ambiente '$env' nao existe em $(resolve_config)." \
         "$(printf '%s' "$CLOUDEZ_CONFIG_JSON" | jq -c '{hint: ("Ambientes definidos: " + (.sites | keys | join(", ")))}')"
  printf '%s' "$site"
}

# cfg <site_json> <jq_path> [default]
cfg() {
  local v
  v=$(printf '%s' "$1" | jq -r "$2 // empty")
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${3:-}"; fi
}

# ssh_run <site_json> <comando...>
# BatchMode=yes e deliberado: sem ele, um host sem chave configurada trava
# esperando senha num prompt que o agente nao consegue responder.
ssh_run() {
  local site="$1"; shift
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -p "$(cfg "$site" .ssh.port 22)" \
      "$(cfg "$site" .ssh.user)@$(cfg "$site" .ssh.host)" "$@"
}

# state_path <deploy_id>
state_path() { printf '%s/%s.json' "$CLOUDEZ_STATE_DIR" "$1"; }

# load_state <deploy_id> -> JSON em stdout
load_state() {
  local f; f=$(state_path "$1")
  [ -f "$f" ] || die deploy_not_found "deploy_id '$1' desconhecido. Rode cloudez-begin-deploy primeiro."
  cat "$f"
}
