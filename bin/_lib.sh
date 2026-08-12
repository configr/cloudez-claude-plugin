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
         '{"hint":"Ex.: root: ~/meusite.com.br/www/claude — o deploy publica em <root>/current."}'
  printf '%s' "${root#\~/}"
}

# ------------------------------------------------------------------- destino --
#
# O destino ssh NAO mora mais no .cloudez.yaml. Ele vem da conta do usuario, via
# cloudez_get_site (cloud.fqdn e user.username), e quem chama estes adaptadores
# passa nas variaveis abaixo:
#
#   CLOUDEZ_SSH_HOST   CLOUDEZ_SSH_USER   CLOUDEZ_SSH_PORT
#
# Tirar isso da config elimina uma copia que envelhece: se a Cloudez mover o site
# de servidor, um host escrito num arquivo versionado continua apontando para o
# antigo, e o deploy vai para o lugar errado sem reclamar.
#
# O bloco `ssh` da config ainda e aceito como fallback, para .cloudez.yaml
# escritos antes desta mudanca nao pararem de funcionar de um dia para o outro.

# ssh_target <site_json> <campo> <variavel_de_ambiente> [default]
ssh_target() {
  local site="$1" field="$2" env_var="$3" default="${4:-}" value
  value="${!env_var:-}"
  [ -n "$value" ] || value=$(cfg "$site" "$field" "$default")
  printf '%s' "$value"
}

# ssh_run <site_json> <comando...>
# BatchMode=yes e deliberado: sem ele, um host sem chave configurada trava
# esperando senha num prompt que o agente nao consegue responder.
ssh_run() {
  local site="$1"; shift
  local host user port
  host=$(ssh_target "$site" .ssh.host CLOUDEZ_SSH_HOST)
  user=$(ssh_target "$site" .ssh.user CLOUDEZ_SSH_USER)
  port=$(ssh_target "$site" .ssh.port CLOUDEZ_SSH_PORT 22)

  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
      -p "$port" "$user@$host" "$@"
}

# require_ssh_target <site_json> — morre se nao houver destino
#
# Chame no nivel de cima do adaptador, NUNCA dentro de $( ). Os adaptadores
# envolvem ssh_run em substituicao de comando para capturar os logs, e ali um
# die morre no subshell: o `if !` de fora ve so o status nao-zero e reporta
# ssh_failed, escondendo que o problema era nao ter para onde conectar. O
# usuario iria depurar chave e rede em vez do que realmente falta.
require_ssh_target() {
  local site="$1"
  { [ -n "$(ssh_target "$site" .ssh.host CLOUDEZ_SSH_HOST)" ] \
    && [ -n "$(ssh_target "$site" .ssh.user CLOUDEZ_SSH_USER)" ]; } \
    || die missing_ssh_target "Destino ssh desconhecido: host e usuario nao foram informados." \
         '{"hint":"Estes dados vem do cloudez_get_site (cloud.fqdn e user.username) e sao passados em CLOUDEZ_SSH_HOST e CLOUDEZ_SSH_USER. Rode o deploy pelo /cloudez:deploy, que os obtem antes de chamar os adaptadores."}'
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

# graphical_session — ha sessao grafica local, e portanto clipboard?
#
# X11 e Wayland guardam o clipboard no servidor grafico. Sem DISPLAY nem
# WAYLAND_DISPLAY o utilitario esta instalado e falha: e o caso de SSH, container,
# CI e Claude Code rodando em maquina remota.
graphical_session() { [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; }

# clipboard_read_cmd -> comando que imprime o clipboard, ou vazio se nao houver
#
# Serve para montar a dica do caminho sem TTY: o token sai do clipboard direto para
# o pipe, sem passar por prompt nem por contexto de modelo.
#
# Vazio nao e falha: quem chama simplesmente nao oferece esse caminho. Sugerir um
# comando que existe e nao funciona e pior do que nao sugerir nada — o usuario
# tentaria, veria um erro do xclip e nao saberia de quem e a culpa.
clipboard_read_cmd() {
  # macOS: presente sempre, e nao depende de variavel de sessao grafica.
  if command -v pbpaste >/dev/null 2>&1; then printf 'pbpaste'; return 0; fi

  # Windows, via WSL ou Git Bash.
  if command -v powershell.exe >/dev/null 2>&1; then
    printf 'powershell.exe -NoProfile -Command Get-Clipboard'; return 0
  fi

  graphical_session || return 0

  if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-paste >/dev/null 2>&1; then
    printf 'wl-paste'
  elif command -v xclip >/dev/null 2>&1; then
    printf 'xclip -selection clipboard -o'
  elif command -v xsel >/dev/null 2>&1; then
    printf 'xsel --clipboard --output'
  fi
}

# login_hint -> JSON com as duas formas de autenticar
#
# Caminho absoluto porque bin/ so esta no PATH da tool Bash, nao no terminal do
# usuario.
#
# Duas saidas, e a ordem importa: a primeira nao precisa de terminal nenhum (o
# token vai do clipboard para o pipe) e por isso funciona onde o agente esta; a
# segunda e o prompt interativo, que exige TTY e, no Claude Code, o prefixo `!`
# para rodar no terminal da sessao — pela tool Bash nao ha terminal de controle
# (/dev/tty responde "Device not configured").
login_hint() {
  local bin clip pipe
  bin="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/cloudez-login"
  clip=$(clipboard_read_cmd)
  [ -n "$clip" ] && pipe="$clip | $bin --stdin"

  jq -n --arg b "$bin" --arg p "${pipe:-}" \
    '{hint: (if $p == "" then
               ("Peca ao usuario para rodar: ! " + $b + " (o ! executa no terminal da sessao, onde existe TTY).")
             else
               ("Peca ao usuario para copiar o token e autorize rodar: " + $p
                + "  — o token vai do clipboard direto para o processo, sem passar pela conversa. Alternativa com prompt: ! " + $b)
             end),
      login_command: $b,
      claude_code_command: ("! " + $b)}
     | if $p == "" then . else . + {clipboard_command: $p} end'
}

# save_token <token> -> veredito em stdout ("valid" | "unknown")
#
# A ordem aqui e deliberada: escreve primeiro, valida depois, contra o token que
# ja esta no arquivo — e nao contra o que estava na memoria.
#
# A verify_token daqui e a unica do lado shell. Ela precisa concordar com a do
# MCP, que reimplementa a mesma tabela (2xx valido, 401/403 recusado, o resto
# inconclusivo): sao duas implementacoes de um contrato, nao duas opinioes.
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

# Nao ha require_token aqui. O gate de autenticacao e a tool `cloudez_auth_status`
# do MCP, que e quem de fato usa o token contra a API — nenhum adaptador deste
# diretorio precisa dele. O deploy inteiro (begin, sync, finalize, rollback,
# list-releases) fala com o servidor por ssh, com a chave do usuario.
#
# O que sobrou de token neste arquivo serve so ao cloudez-login: resolve_token e
# token_source para o relatorio, verify_token e save_token para gravar e conferir
# o que foi gravado.

# -------------------------------------------------------------------- state --

# state_path <deploy_id>
state_path() { printf '%s/%s.json' "$CLOUDEZ_STATE_DIR" "$1"; }

# load_state <deploy_id> -> JSON em stdout
load_state() {
  local f; f=$(state_path "$1")
  [ -f "$f" ] || die deploy_not_found "deploy_id '$1' desconhecido. Rode cloudez-begin-deploy primeiro."
  cat "$f"
}
