#!/usr/bin/env bats
# Autenticacao: o cloudez-login coleta e grava o token. Quem responde pelo estado
# da autenticacao e a tool cloudez_auth_status do MCP — o --check foi removido
# daqui, e os adaptadores de deploy nao exigem token nenhum (falam por ssh).
#
# ─── Por que estes testes mudaram de forma ──────────────────────────────────
#
# Antes havia duas camadas: um punhado de testes chamando funcoes do `_lib.sh`
# direto (`resolve_token`, `verify_token`, `save_token`) e outro punhado
# exercitando o comando. A primeira existia porque o comando so as exercitava
# pelo prompt, que precisa de pty.
#
# O `--stdin` nao precisa de pty e atravessa exatamente as mesmas funcoes. Com o
# cloudez-login em Node elas deixaram de ser codigo do shell chamavel de fora, e
# a camada de baixo perdeu o motivo de existir: hoje tudo aqui e o COMANDO, e a
# cobertura e a mesma. O que continua sem teste automatizado e so a leitura do
# terminal — ver "Limitacoes conhecidas" no README.

load helpers/setup

setup() {
  make_project
  start_api
}

# ------------------------------------------------------------------ endpoint --
#
# Endpoint e header confirmados com a Cloudez. O esquema e `Token`, nao `Bearer`:
# trocar isso devolve 401 e faria todo token parecer recusado, o que manda o
# usuario procurar problema no painel em vez de aqui.

@test "a validacao bate no endpoint e no header confirmados" {
  run bash -c 'printf tok_do_pipe | cloudez-login --stdin'
  [ "$status" -eq 0 ]
  grep -q 'api GET /auth/token/validate/' "$MOCK_LOG"
  grep -q 'Authorization: Token tok_do_pipe' "$MOCK_LOG"
  ! grep -q 'Bearer' "$MOCK_LOG"
}

# --------------------------------------------------------------- precedencia --

@test "o token vem do arquivo quando nao ha variavel" {
  run bash -c 'printf tok_do_pipe | cloudez-login --stdin'
  [ "$(campo "$output" .source)" = "file" ]
}

@test "CLOUDEZ_TOKEN vence o arquivo" {
  run bash -c 'printf tok_do_pipe | CLOUDEZ_TOKEN=tok_do_ambiente cloudez-login --stdin'
  [ "$(campo "$output" .source)" = "env" ]
}

# ----------------------------------------------------------- os tres vereditos --
#
# Esta distincao e contrato, nao detalhe: o MCP a reimplementa do lado dele, e as
# duas implementacoes precisam concordar.

@test "2xx: o token e dado por verificado" {
  run bash -c 'printf tok_bom | cloudez-login --stdin'
  [ "$status" -eq 0 ]
  [ "$(campo "$output" .verified)" = "true" ]
  [ "$(campo "$output" .status)" = "authenticated" ]
}

# 401 e a unica resposta conclusiva: o token existe e a Cloudez o recusou.
@test "401: recusado, e o erro diz isso" {
  api_status 401
  run bash -c 'printf tok_ruim | cloudez-login --stdin'
  [ "$status" -eq 1 ]
  [ "$(campo "$output" .error.code)" = "invalid_token" ]
}

@test "403 tambem e recusa" {
  api_status 403
  run bash -c 'printf tok_ruim | cloudez-login --stdin'
  [ "$status" -eq 1 ]
  [ "$(campo "$output" .error.code)" = "invalid_token" ]
}

# Offline, endpoint errado ou API fora nao sao prova de token ruim. Concluir
# "invalid" aqui mandaria o usuario refazer um login que ja estava certo.
@test "API fora do ar: salva e avisa que nao deu para confirmar" {
  api_offline
  run bash -c 'printf tok_novo | cloudez-login --stdin'
  [ "$status" -eq 0 ]
  [ "$(campo "$output" .verified)" = "false" ]
  [ "$(campo "$output" .warning)" != "null" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_novo" ]
}

@test "404: inconclusivo, nao recusa" {
  api_status 404
  run bash -c 'printf tok_novo | cloudez-login --stdin'
  [ "$status" -eq 0 ]
  [ "$(campo "$output" .verified)" = "false" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_novo" ]
}

# -------------------------------------------------------------------- login --

# O ponto central do desenho: um agente nao consegue rodar o login interativo,
# entao o token nunca passa pelo contexto dele.
@test "login sem TTY falha: um agente nao pode ler o token" {
  rm "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'cloudez-login < /dev/null'
  [ "$status" -eq 1 ]
  [ "$(campo "$output" .error.code)" = "no_tty" ]
  [ ! -f "$CLOUDEZ_TOKEN_FILE" ]
}

# O erro sem TTY precisa ensinar o caminho, e dentro do Claude Code o caminho e o
# `!` — pela tool Bash nao existe terminal de controle nenhum.
@test "o erro sem TTY ensina o ! do Claude Code" {
  rm "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'cloudez-login < /dev/null'
  [[ "$(campo "$output" .error.claude_code_command)" == "! /"*/cloudez-login ]]
  [[ "$(campo "$output" .error.hint)" == *"! "* ]]
}

# A lapide do --check saiu; o erro generico virou o unico caminho de volta ate a
# tool que o substituiu, entao ele precisa cita-la.
@test "argumento desconhecido nao faz nada, e aponta a tool" {
  run cloudez-login --force
  [ "$status" -eq 1 ]
  [ "$(campo "$output" .error.code)" = "usage" ]
  [[ "$(campo "$output" .error.hint)" == *cloudez_auth_status* ]]
}

# O login por e-mail e senha foi abandonado. Quem vier da doc antiga merece um erro
# que explica, nao "argumento desconhecido".
@test "--password responde que foi descontinuado" {
  run cloudez-login --password
  [ "$status" -eq 1 ]
  [ "$(campo "$output" .error.code)" = "password_login_disabled" ]
}

# ------------------------------------------------------------------- --stdin --
#
# O caminho sem TTY: o token vem de um pipe (clipboard, arquivo, variavel) e nunca
# passa por prompt nem pelo contexto de quem chama. Estes testes rodam sem terminal
# nenhum — que e exatamente a situacao do agente.

@test "stdin salva o token vindo do pipe, sem TTY" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'printf tok_do_clipboard | cloudez-login --stdin'
  [ "$status" -eq 0 ]
  [ "$(campo "$output" .status)" = "authenticated" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_do_clipboard" ]
  [ "$(ls -l "$CLOUDEZ_TOKEN_FILE" | cut -c1-10)" = "-rw-------" ]
}

@test "stdin tolera newline no fim, que todo clipboard traz" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'printf "tok_com_newline\n" | cloudez-login --stdin'
  [ "$status" -eq 0 ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_com_newline" ]
}

@test "stdin num terminal nao trava esperando entrada que nao vem" {
  run cloudez-login --stdin < /dev/null
  # Sem terminal aqui: o que se afirma e que o modo existe e nao pendura. O ramo
  # do "--stdin com TTY" precisa de um pty para existir, e mora em test/pty.bats.
  [ "$status" -eq 1 ]
  [ "$(campo "$output" .error.code)" = "empty_token" ]
}

@test "stdin vazio nao salva nada" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run bash -c ': | cloudez-login --stdin'
  [ "$status" -eq 1 ]
  [ "$(campo "$output" .error.code)" = "empty_token" ]
  [ ! -f "$CLOUDEZ_TOKEN_FILE" ]
}

# Clipboard com outra coisa dentro e o erro mais provavel aqui.
@test "stdin com texto que nao e token nao gasta chamada de API" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'printf "Seu token: abc123" | cloudez-login --stdin'
  [ "$status" -eq 1 ]
  [ "$(campo "$output" .error.code)" = "invalid_token" ]
  ! grep -q 'Authorization' "$MOCK_LOG"
}

@test "stdin nao imprime o token" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'printf tok_secreto | cloudez-login --stdin'
  [[ "$output" != *tok_secreto* ]]
}

# ------------------------------------------------------------ gravar e desfazer --
#
# O que tem consequencia: escrever o segredo com 0600, validar DEPOIS do write, e
# desfazer quando a Cloudez recusa.

@test "a validacao roda depois do write: a API ve o token ja no arquivo" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'printf tok_novo | cloudez-login --stdin'
  [ "$status" -eq 0 ]
  # O servidor registra o conteudo do arquivo no instante da chamada. Se a ordem
  # se invertesse, aqui apareceria vazio — ou o token anterior.
  grep -q 'token_file_at_call=tok_novo' "$MOCK_LOG"
}

@test "token recusado devolve o anterior ao arquivo" {
  printf 'tok_bom\n' > "$CLOUDEZ_TOKEN_FILE"
  api_status 401
  run bash -c 'printf tok_ruim | cloudez-login --stdin'
  [ "$status" -eq 1 ]
  [ "$(campo "$output" .error.code)" = "invalid_token" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_bom" ]
}

@test "token recusado sem anterior nao deixa arquivo para tras" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  api_status 401
  run bash -c 'printf tok_ruim | cloudez-login --stdin'
  [ "$status" -eq 1 ]
  [ ! -f "$CLOUDEZ_TOKEN_FILE" ]
}

@test "o diretorio do token nasce fechado" {
  rm -rf "$TEST_TMP/casa"
  run bash -c "printf tok_novo | CLOUDEZ_TOKEN_FILE='$TEST_TMP/casa/.cloudez/token' cloudez-login --stdin"
  [ "$status" -eq 0 ]
  [ "$(ls -ld "$TEST_TMP/casa/.cloudez" | cut -c1-10)" = "drwx------" ]
}

# ------------------------------------------------------------------- setup ----
#
# O cloudez-setup nao fala com a Cloudez: escrever config e decisao local. Um
# adaptador que exigisse token para isso travaria o usuario antes da hora.

@test "setup funciona sem token: escrever config nao fala com a Cloudez" {
  rm -f "$CLOUDEZ_TOKEN_FILE" .cloudez.yaml
  run cloudez-setup novo.example.com staging
  [ "$status" -eq 0 ]
  [ -f .cloudez.yaml ]
}

@test "setup sem token nao gasta chamada de API" {
  rm -f "$CLOUDEZ_TOKEN_FILE" .cloudez.yaml
  run cloudez-setup novo.example.com staging
  ! grep -q 'Authorization' "$MOCK_LOG"
}

@test "setup sem dominio reclama do dominio" {
  run cloudez-setup
  [ "$status" -eq 1 ]
  [ "$(campo "$output" .error.code)" = "missing_domain" ]
}

# ------------------------------------------------------------- piso do Node ----
#
# O cloudez-login NAO tem extensao, porque `cloudez-login` e o nome que o usuario
# digita. Sem extensao, o Node 20 assume CommonJS e o `import` do arquivo vira
# erro de sintaxe — quem desfaz isso e o `bin/package.json` com `type: module`.
#
# Node 22+ detecta o modulo pela sintaxe sozinho, entao o defeito seria INVISIVEL
# na maquina de quem tem Node novo. `--no-experimental-detect-module` desliga a
# deteccao e reproduz o Node 20 em qualquer versao.
@test "o login roda sem a deteccao de modulo, que e o piso Node 20" {
  run bash -c 'printf tok_do_pipe | node --no-experimental-detect-module "$PLUGIN_ROOT/bin/cloudez-login" --stdin'
  [ "$status" -eq 0 ]
  [ "$(campo "$output" .status)" = "authenticated" ]
}

@test "o setup tambem roda sem a deteccao de modulo" {
  rm .cloudez.yaml
  run bash -c 'node --no-experimental-detect-module "$PLUGIN_ROOT/bin/cloudez-setup" novo.example.com staging'
  [ "$status" -eq 0 ]
  [ "$(campo "$output" .status)" = "created" ]
}

@test "o bin/package.json existe e so declara o tipo do modulo" {
  [ "$(campo_de "$PLUGIN_ROOT/bin/package.json" .type)" = "module" ]
  # Um package.json com dependencias em bin/ transformaria o plugin em algo que
  # precisa de npm install — exatamente o que o bundle vendorado evita.
  #
  # Campo ausente sai como "null", que e o que se afirma aqui. Antes era um
  # `has("dependencies")` do jq; a diferenca so apareceria num package.json com
  # `"dependencies": null` escrito a mao, que nao e um estado que alguem produz.
  [ "$(campo_de "$PLUGIN_ROOT/bin/package.json" .dependencies)" = "null" ]
}
