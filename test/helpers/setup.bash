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

  # Mesma razao, para o guard-rail de escrita: sem isto os testes gravariam
  # pedido e aprovacao no ~/.cloudez real de quem roda a suite.
  CLOUDEZ_GUARD_DIR="$TEST_TMP/guard"
  export CLOUDEZ_GUARD_DIR
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

# campo <json> <caminho> — extrai um campo, no formato do `jq -r`.
#
# Chamava o `jq` e passou a chamar test/helpers/json.mjs. O jq era a ultima
# dependencia que o CI instalava alem do runtime, e ja nao servia a mais nada: o
# runtime do plugin deixou de usa-lo quando os adaptadores viraram Node.
campo() { printf '%s' "$1" | node "$PLUGIN_ROOT/test/helpers/json.mjs" "$2"; }

# campo_de <arquivo> <caminho> — o mesmo, lendo de um arquivo.
campo_de() { node "$PLUGIN_ROOT/test/helpers/json.mjs" "$2" < "$1"; }

# ----------------------------------------------------------------------- pty --
#
# com_pty <bytes> <comando...> — roda o comando num terminal de verdade e "digita"
# os bytes quando o prompt aparecer.
#
# Existe porque o `cloudez-login` abre `/dev/tty`, o terminal de CONTROLE: mockar
# stdin nao alcanca esse caminho. So um pty alcanca, e `script(1)` e o unico
# alocador de pty presente nas duas plataformas da matriz.
#
# Tres detalhes aqui nao sao estilo, sao correcao — os tres custaram uma tentativa:
#
#   1. A ESPERA PELO PROMPT nao e cerimonia nem sleep disfarcado. Alimentar por
#      redirect simples faz os bytes chegarem antes de o filho entrar em modo raw:
#      a disciplina de linha os consome e ECOA, e o login recebe entrada VAZIA. O
#      teste passaria verde afirmando sobre outra coisa. O `pedirToken` liga o raw
#      ANTES de escrever "Token: ", entao ver o prompt e a garantia de que o modo
#      ja trocou.
#
#   2. A entrada e um PIPE, nunca um fifo nomeado. O `script` do BSD faz
#      `tcgetattr` no proprio stdin e recusa fifo com "Operation not supported on
#      socket" — que se le como defeito do teste, e nao como escolha de canal.
#
#   3. O EOT (\004) e cinto de seguranca, e so entra quando FALTA terminador. Sem
#      nenhum, o filho espera Enter para sempre e PENDURA a suite; o `pedirToken`
#      trata EOT como fim de entrada, entao um byte esquecido vira falha em vez de
#      travamento — ja aconteceu ao escrever estes testes.
#
#      Manda-lo SEMPRE, porem, criava uma intermitencia propria: chegando depois
#      de o raw mode ser desligado, o terminal o ECOA como "^D" mais backspaces, e
#      esse eco cai num ponto imprevisivel da saida. Caindo na linha do `{`, o
#      payload deixa de ser localizavel e o teste falha sem nada de errado no
#      codigo sob teste.
com_pty() {
  local bytes="$1"; shift
  local dir; dir=$(mktemp -d)
  local terminal="$dir/terminal"; : > "$terminal"
  local rc=0

  {
    # 200 x 0,05s = 10s de teto. Se o prompt nao veio, mandar os bytes assim mesmo
    # produz uma falha legivel; esperar para sempre nao.
    local _i
    for _i in $(seq 1 200); do
      # Sai tambem se o processo ja falhou: um caminho que nunca chega a
      # perguntar nao tem prompt para esperar, e pagaria o teto inteiro.
      grep -q 'Token: \|aprovo. para liberar\|"error"' "$terminal" 2>/dev/null && break
      sleep 0.05
    done
    # Terminador so quando falta: ver o item 3 do cabecalho.
    case "$bytes" in
      *$'\n' | *$'\004' | *$'\003') printf '%s' "$bytes" ;;
      *) printf '%s\004' "$bytes" ;;
    esac
  } | {
    if script --version 2>/dev/null | grep -q util-linux; then
      # util-linux quer o comando numa string; %q protege caminho com espaco.
      #
      # O -e nao e opcional: SEM ele o script do util-linux devolve o proprio
      # codigo de saida, sempre 0, e toda afirmacao sobre falha do comando passa
      # por sucesso. O do BSD propaga o do filho por padrao e nem conhece a flag —
      # foi assim que o CI quebrou so no ubuntu, com o macOS verde.
      local cmd; cmd=$(printf '%q ' "$@")
      script -q -e -c "$cmd" /dev/null > "$terminal" 2>&1
    else
      script -q /dev/null "$@" > "$terminal" 2>&1
    fi
  } || rc=$?

  # Normaliza o que o TERMINAL acrescenta, e que nao veio de quem esta sob teste:
  #
  #   \r    o pty converte \n em \r\n; sem tirar, toda comparacao falha por um byte
  #         invisivel.
  #   \b    backspace de eco.
  #   ^D    o `script` envia EOT ao pty quando o proprio stdin dele fecha, e o
  #         terminal — ja fora do modo raw a essa altura — ecoa isso como "^D". O
  #         eco cai num ponto que depende de escalonamento: colado ao `{` do
  #         payload, o JSON deixa de comecar em inicio de linha e o extrator falha.
  #         Foi uma intermitencia real, nao hipotetica.
  tr -d '\r\010' < "$terminal" | sed 's/\^D//g'
  rm -rf "$dir"
  return $rc
}

# campo_pty <saida> <caminho> — extrai um campo do JSON que veio junto do terminal.
#
# Num pty stdout e stderr caem no mesmo fluxo, entao o payload sai colado ao banner
# do login e o extrator sozinho engasga. O awk guarda o ULTIMO bloco que comeca numa
# linha `{` sozinha — que e o payload, seja o `ok` ou o `die` — e so ele segue.
campo_pty() {
  printf '%s\n' "$1" \
    | awk '/^\{$/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' \
    | node "$PLUGIN_ROOT/test/helpers/json.mjs" "$2"
}

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
# O formato e o mesmo que o mcp/cloudez-state.mjs le — e agora os DOIS lados leem
# por ali, entao nao ha mais dois schemas para divergirem.
deploy_state() {
  local id="$1" status="${2:-awaiting_upload}"
  mkdir -p .cloudez/state
  cat > ".cloudez/state/$id.json" <<JSON
{
  "deploy_id": "$id",
  "release_id": "20260101T000000Z-abc1234",
  "environment": "staging",
  "ref": "abc1234def",
  "status": "$status",
  "root": "/srv/staging",
  "domain": "staging.example.com",
  "ssh": {
    "host": "srv.example.com",
    "user": "deploy",
    "port": 22,
    "path": "/srv/staging/releases/20260101T000000Z-abc1234/"
  }
}
JSON
  printf '%s' "$id"
}
