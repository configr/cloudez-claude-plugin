#!/usr/bin/env bash
# Onde mora a config do projeto.
#
# Aqui houve um conversor YAML->JSON com quatro parsers alternativos (yq nas duas
# implementacoes, python3+PyYAML, ruby). Ele saiu junto com os adaptadores de
# deploy: quem le a config agora e o servidor MCP, em TypeScript, e o unico
# adaptador que ainda precisa do arquivo — o cloudez-setup — so precisa saber
# ONDE ele fica, nao o que tem dentro.
#
# Funcao pura, sem `set -e` e sem `die`: a politica sobre a falha fica com quem
# chama.

# resolve_config -> caminho do arquivo de config
resolve_config() {
  if [ -n "${CLOUDEZ_CONFIG:-}" ]; then printf '%s' "$CLOUDEZ_CONFIG"; return 0; fi
  local c
  for c in .cloudez.yaml .cloudez.yml; do
    [ -f "$c" ] && { printf '%s' "$c"; return 0; }
  done
  printf '%s' '.cloudez.yaml'
}
