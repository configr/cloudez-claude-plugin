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

# is_fqdn <valor>
#
# FQDN e nada mais: protocolo, caminho, querystring ou porta reprovam. Usado no
# dominio do site (cloudez-setup) e no dominio do painel (cloudez-login) — os dois
# viram parte de URL ou de caminho, e um valor solto ali reaparece longe da causa.
is_fqdn() {
  printf '%s' "$1" | grep -qE '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' \
    && [ "${#1}" -le 253 ]
}

# -------------------------------------------------------------------- token --
#
# O token e credencial do USUARIO, nao do projeto: um arquivo no $HOME serve
# todos os repositorios, em vez de uma copia do mesmo segredo por projeto — e
# fica fora da arvore que o cloudez-sync empacota com tar.
#
# Precedencia: CLOUDEZ_TOKEN (CI, headless) > arquivo.
# CLOUDEZ_TOKEN_FILE existe para os testes nao escreverem no $HOME de verdade.
#
# Nenhuma funcao daqui imprime o token. Ele nao entra em log, em JSON de retorno
# nem em mensagem de erro: o consumidor destes scripts e um modelo, e o que sai
# no stdout vira contexto.

token_file() { printf '%s' "${CLOUDEZ_TOKEN_FILE:-$HOME/.cloudez/token}"; }

# resolve_token -> token em stdout; vazio quando nao ha nenhum
resolve_token() {
  if [ -n "${CLOUDEZ_TOKEN:-}" ]; then printf '%s' "$CLOUDEZ_TOKEN"; return 0; fi
  local f; f=$(token_file)
  [ -f "$f" ] || return 0
  # tr -d: o newline final do arquivo e o CR de quem editou no Windows
  tr -d '\r\n' < "$f"
}

# token_source -> "env" | "file" | "none"
token_source() {
  if [ -n "${CLOUDEZ_TOKEN:-}" ]; then printf 'env'
  elif [ -f "$(token_file)" ]; then printf 'file'
  else printf 'none'; fi
}

# cloudez_api_check <token> -> codigo HTTP em stdout, "000" quando nao deu para
# falar com a API.
#
# Endpoint e header confirmados com a Cloudez:
#
#   GET https://api.cloudez.io/auth/token/validate/
#   Authorization: Token <key>
#
# `Token`, nao `Bearer` — trocar o esquema devolve 401 e faria todo token parecer
# recusado. Esta funcao e a unica superficie de contato com a API de autenticacao.
#
# curl e opcional de proposito: sem ele nao ha verificacao, e a resposta e
# "unknown" em vez de erro. Um adaptador que exige curl para ler um arquivo local
# seria dependencia nova por nada.
cloudez_api_check() {
  command -v curl >/dev/null 2>&1 || { printf '000'; return 0; }
  local code
  # Numa falha de conexao o curl imprime 000 e ainda sai nao-zero; o `|| true`
  # impede o set -e de matar o script, e o codigo continua sendo 000.
  code=$(curl -s -o /dev/null -w '%{http_code}' \
           --max-time "${CLOUDEZ_API_TIMEOUT:-10}" \
           -H "Authorization: Token $1" \
           "${CLOUDEZ_API_URL:-https://api.cloudez.io}${CLOUDEZ_API_VALIDATE_PATH:-/auth/token/validate/}" \
           2>/dev/null || true)
  printf '%s' "${code:-000}"
}

# verify_token <token> -> "valid" | "invalid" | "unknown"
#
# So a recusa explicita da API e conclusiva. Offline, endpoint errado ou API fora
# viram "unknown", e quem chama trata como aceitavel: falhar fechado ai deixaria
# o usuario sem deploy justamente quando ele nao tem como consertar nada — e a
# chamada seguinte ao MCP falha com o erro dela, que e mais informativo.
verify_token() {
  case "$(cloudez_api_check "$1")" in
    2*)      printf 'valid' ;;
    401|403) printf 'invalid' ;;
    *)       printf 'unknown' ;;
  esac
}

# login_hint -> JSON com o caminho absoluto do cloudez-login
#
# Absoluto porque bin/ so esta no PATH da tool Bash, nao no terminal do usuario —
# e e no terminal dele que o login roda.
#
# O `!` na frente e o que resolve isso dentro do Claude Code: ele executa no
# terminal da sessao, onde existe TTY. Pela tool Bash nao ha terminal de controle
# nenhum (/dev/tty responde "Device not configured"), entao nao e questao de
# permissao ou de flag — nao tem onde perguntar.
login_hint() {
  local bin
  bin="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cloudez-login"
  jq -n --arg b "$bin" \
    '{hint: ("No Claude Code, peca ao usuario para enviar uma mensagem com: ! " + $b
             + "  (o ! executa no terminal da sessao, onde existe TTY). Fora do Claude Code, e rodar o comando no terminal dele."),
      login_command: $b,
      claude_code_command: ("! " + $b)}'
}

# save_token <token> -> veredito em stdout ("valid" | "unknown")
#
# A ordem aqui e deliberada: escreve primeiro, valida depois, contra o token que
# ja esta no arquivo — e nao contra o que estava na memoria. Quem valida e a mesma
# verify_token que o --check usa, para nao existirem duas nocoes de "token bom"
# divergindo com o tempo.
#
# Se a Cloudez recusar, o token anterior volta: perder uma credencial que
# funcionava por causa de um paste errado seria pior do que o paste errado. O
# anterior vem de uma variavel, nao de uma copia em disco — um segredo nao precisa
# de um segundo arquivo por perto, nem por um instante.
save_token() {
  local token="$1" f previous="" verdict
  f=$(token_file)
  [ -f "$f" ] && previous=$(tr -d '\r\n' < "$f")

  mkdir -p "$(dirname "$f")"
  chmod 700 "$(dirname "$f")" 2>/dev/null || true

  # umask no subshell em vez de chmod depois: entre criar o arquivo e ajustar a
  # permissao existe uma janela em que ele fica legivel por outros.
  (umask 077; printf '%s\n' "$token" > "$f")

  verdict=$(verify_token "$token")
  if [ "$verdict" = invalid ]; then
    if [ -n "$previous" ]; then
      (umask 077; printf '%s\n' "$previous" > "$f")
    else
      rm -f "$f"
    fi
    die invalid_token "A Cloudez recusou este token." \
      '{"hint":"Confira se o token foi copiado inteiro e se nao foi revogado no painel. O arquivo nao foi alterado."}'
  fi

  printf '%s' "$verdict"
}

# require_token -> token em stdout; morre se nao houver, ou se a API recusar
require_token() {
  local t
  t=$(resolve_token)
  [ -n "$t" ] \
    || die not_authenticated "Nenhum token da Cloudez encontrado em $(token_file)." "$(login_hint)"
  [ "$(verify_token "$t")" != invalid ] \
    || die token_invalid "A Cloudez recusou o token salvo (expirado ou revogado)." "$(login_hint)"
  printf '%s' "$t"
}

# -------------------------------------------------------------------- state --

# state_path <deploy_id>
state_path() { printf '%s/%s.json' "$CLOUDEZ_STATE_DIR" "$1"; }

# load_state <deploy_id> -> JSON em stdout
load_state() {
  local f; f=$(state_path "$1")
  [ -f "$f" ] || die deploy_not_found "deploy_id '$1' desconhecido. Rode cloudez-begin-deploy primeiro."
  cat "$f"
}
