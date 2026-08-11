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
    || die config_not_found "Arquivo $f nao encontrado. Rode cloudez-setup para criar o template."

  j=$(yaml_to_json "$f"); rc=$?
  case "$rc" in
    3) die yaml_parser_missing "Nenhum parser YAML disponivel para ler $f." \
         "$(jq -n --arg h "$YAML_PARSER_HINT" '{hint: $h}')" ;;
    0) ;;
    *) die config_invalid "$f nao e um YAML valido." ;;
  esac

  printf '%s' "$j" | jq -e . >/dev/null 2>&1 \
    || die config_invalid "$f nao produziu uma estrutura utilizavel."

  # O bloco raiz se chama `cloudez`. Checar aqui e o que transforma uma config
  # antiga (que usava `sites:`) num erro nomeado, em vez de um site_not_found
  # com lista de ambientes vazia — que manda o usuario procurar no lugar errado.
  printf '%s' "$j" | jq -e 'has("cloudez")' >/dev/null 2>&1 \
    || die config_invalid "$f nao tem o bloco 'cloudez:' no topo." \
         '{"hint":"Cada ambiente vira uma chave dentro de cloudez:. O nome antigo era sites:."}'

  CLOUDEZ_CONFIG_JSON="$j"
}

# site_config <environment> -> JSON do site em stdout
site_config() {
  local environment="$1" site
  load_config
  site=$(printf '%s' "$CLOUDEZ_CONFIG_JSON" | jq -c --arg e "$environment" '.cloudez[$e] // empty')
  [ -n "$site" ] \
    || die site_not_found "Ambiente '$environment' nao existe em $(resolve_config)." \
         "$(printf '%s' "$CLOUDEZ_CONFIG_JSON" | jq -c '{hint: ("Ambientes definidos: " + (.cloudez | keys | join(", ")))}')"
  printf '%s' "$site"
}

# cfg <site_json> <jq_path> [default]
cfg() {
  local v
  v=$(printf '%s' "$1" | jq -r "$2 // empty")
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${3:-}"; fi
}

# site_root <site_json> <environment> -> caminho do site no servidor
#
# `root` e obrigatorio e explicito na config: para onde os arquivos vao e a
# decisao mais destrutiva do deploy, e derivar isso de outro campo deixaria o
# destino implicito num arquivo que alguem le com pressa.
#
# Um `~/` inicial e REMOVIDO, nao expandido: os comandos remotos vao entre aspas
# simples (senao um caminho com espaco quebraria), e dentro delas o shell do
# servidor nao expande til — sobraria um diretorio chamado `~`. Caminho relativo
# resolve a partir do $HOME do usuario ssh, que e exatamente o que `~/` diz.
site_root() {
  local site="$1" environment="$2" root
  root=$(cfg "$site" .root)
  [ -n "$root" ] \
    || die config_invalid "Ambiente '$environment' nao tem root definido em $(resolve_config)." \
         '{"hint":"Ex.: root: ~/meusite.com.br/www — o deploy publica em <root>/current."}'
  printf '%s' "${root#\~/}"
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
