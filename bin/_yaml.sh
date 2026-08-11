#!/usr/bin/env bash
# Leitura de YAML sem dependencia obrigatoria.
#
# Funcoes puras, sem `set -e` e sem `die`: elas devolvem codigo de saida e a
# politica sobre a falha fica com quem chama.
#
# A estrategia e converter YAML -> JSON uma vez e manter todo o resto em jq. Nao
# ha parser YAML universal instalado por padrao, entao tentamos em ordem os
# quatro caminhos mais comuns. `yq` tem duas implementacoes populares e
# incompativeis com o mesmo nome, por isso as duas sintaxes.

# resolve_config -> caminho do arquivo de config
resolve_config() {
  if [ -n "${CLOUDEZ_CONFIG:-}" ]; then printf '%s' "$CLOUDEZ_CONFIG"; return 0; fi
  local c
  for c in .cloudez.yaml .cloudez.yml; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  printf '%s' '.cloudez.yaml'
}

# yaml_to_json <arquivo> -> JSON em stdout
#   0 = ok | 1 = YAML invalido | 3 = nenhum parser disponivel
yaml_to_json() {
  local f="$1" out found=0

  if command -v yq >/dev/null 2>&1; then
    found=1
    # mikefarah/yq (Go)
    if out=$(yq -o=json '.' "$f" 2>/dev/null) && [ -n "$out" ]; then
      printf '%s' "$out"; return 0
    fi
    # kislyuk/yq (Python, wrapper do jq)
    if out=$(yq -c '.' "$f" 2>/dev/null) && [ -n "$out" ]; then
      printf '%s' "$out"; return 0
    fi
  fi

  if command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import yaml' >/dev/null 2>&1; then
    found=1
    if out=$(python3 -c 'import sys,yaml,json; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)' "$f" 2>/dev/null) \
       && [ -n "$out" ]; then
      printf '%s' "$out"; return 0
    fi
  fi

  if command -v ruby >/dev/null 2>&1; then
    found=1
    if out=$(ruby -ryaml -rjson -e 'print YAML.safe_load(File.read(ARGV[0])).to_json' "$f" 2>/dev/null) \
       && [ -n "$out" ]; then
      printf '%s' "$out"; return 0
    fi
  fi

  [ "$found" -eq 1 ] && return 1
  return 3
}

# Consumido por _lib.sh apos o source; as crases sao literais na mensagem.
# shellcheck disable=SC2034,SC2016
YAML_PARSER_HINT='Instale um destes: `brew install yq`, `pip install pyyaml`, ou tenha ruby no PATH.'
