#!/usr/bin/env bats
# Autenticacao: cloudez-login e a exigencia de token nos adaptadores.

load helpers/setup

setup() { make_project; }

# ------------------------------------------------------------------- --check --

@test "check com token salvo: authenticated" {
  run cloudez-login --check
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .status)" = "authenticated" ]
  [ "$(jq_field "$output" .source)" = "file" ]
  [ "$(jq_field "$output" .verified)" = "true" ]
}

# Endpoint e header confirmados com a Cloudez. O esquema e `Token`, nao `Bearer`:
# trocar isso devolve 401 e faria todo token parecer recusado, o que manda o
# usuario procurar problema no painel em vez de aqui.
@test "check chama o endpoint e o header confirmados" {
  cloudez-login --check >/dev/null
  grep -q 'Authorization: Token tok_teste' "$MOCK_LOG"
  grep -q 'https://api.cloudez.io/auth/token/validate/' "$MOCK_LOG"
  ! grep -q 'Bearer' "$MOCK_LOG"
}

@test "CLOUDEZ_API_URL sobrepoe a base, para testar sem editar o script" {
  CLOUDEZ_API_URL=http://localhost:8000 cloudez-login --check >/dev/null
  grep -q 'http://localhost:8000/auth/token/validate/' "$MOCK_LOG"
}

@test "check sem token: not_authenticated com o caminho do login" {
  rm "$CLOUDEZ_TOKEN_FILE"
  run cloudez-login --check
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "not_authenticated" ]
  [[ "$(jq_field "$output" .error.login_command)" == /*/cloudez-login ]]
}

# 401 e a unica resposta conclusiva: o token existe e a Cloudez o recusou.
@test "check com token recusado pela API: token_invalid" {
  MOCK_HTTP_STATUS=401 run cloudez-login --check
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "token_invalid" ]
}

# Offline, endpoint errado ou API fora nao sao prova de token ruim. Falhar fechado
# aqui deixaria o usuario sem deploy justamente quando ele nao pode consertar
# nada — e a chamada seguinte ao MCP falha com o erro dela, mais informativo.
@test "check com API fora do ar: passa, mas avisa que nao verificou" {
  MOCK_CURL_EXIT=7 run cloudez-login --check
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .status)" = "authenticated" ]
  [ "$(jq_field "$output" .verified)" = "false" ]
  [[ "$(jq_field "$output" .warning)" == *API* ]]
}

@test "check com endpoint desconhecido (404): passa como nao verificado" {
  MOCK_HTTP_STATUS=404 run cloudez-login --check
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .verified)" = "false" ]
}

@test "CLOUDEZ_TOKEN vence o arquivo" {
  rm "$CLOUDEZ_TOKEN_FILE"
  CLOUDEZ_TOKEN=tok_do_ambiente run cloudez-login --check
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .source)" = "env" ]
}

# O token e o segredo: ele nao pode sair em stdout, que e o que vira contexto do
# modelo.
@test "nenhuma saida contem o token" {
  run cloudez-login --check
  [[ "$output" != *tok_teste* ]]
  MOCK_HTTP_STATUS=401 run cloudez-login --check
  [[ "$output" != *tok_teste* ]]
}

# -------------------------------------------------------------------- login --

# O ponto central do desenho: um agente nao consegue rodar o login, entao o token
# nunca passa pelo contexto dele.
@test "login sem TTY falha: um agente nao pode ler o token" {
  rm "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'cloudez-login < /dev/null'
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "no_tty" ]
  [ ! -f "$CLOUDEZ_TOKEN_FILE" ]
}

@test "login com argumento desconhecido nao faz nada" {
  run cloudez-login --force
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "usage" ]
}

# O erro sem TTY precisa ensinar o caminho, e dentro do Claude Code o caminho e o
# `!` — pela tool Bash nao existe terminal de controle nenhum.
@test "o erro sem TTY ensina o ! do Claude Code" {
  rm "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'cloudez-login < /dev/null'
  [[ "$(jq_field "$output" .error.claude_code_command)" == "! /"*/cloudez-login ]]
  [[ "$(jq_field "$output" .error.hint)" == *"! "* ]]
}

# O login por e-mail e senha foi abandonado. Quem vier da doc antiga merece um erro
# que explica, nao "argumento desconhecido".
@test "--password responde que foi descontinuado" {
  run cloudez-login --password
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "password_login_disabled" ]
}

# ---------------------------------------------------------------- save_token --
#
# O prompt do login precisa de pty, mas o que tem consequencia — escrever o
# segredo, validar, desfazer — mora em save_token, que da para chamar direto.

# save <token> — chama save_token com o _lib.sh carregado
save() { bash -c "source '$PLUGIN_ROOT/bin/_lib.sh'; save_token '$1'"; }

@test "save_token grava o token com permissao 0600" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run save tok_novo
  [ "$status" -eq 0 ]
  [ "$output" = "valid" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_novo" ]
  [ "$(ls -l "$CLOUDEZ_TOKEN_FILE" | cut -c1-10)" = "-rw-------" ]
}

# O pedido era validar LOGO APOS salvar. Isto afirma a ordem sem pty: o mock
# registra o conteudo do arquivo no instante da chamada da API.
@test "a validacao roda depois do write: a API ve o token ja no arquivo" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  save tok_novo >/dev/null
  grep -q 'token_file_at_call=tok_novo' "$MOCK_LOG"
}

# Perder uma credencial que funcionava por causa de um paste errado seria pior do
# que o paste errado.
@test "token recusado devolve o anterior ao arquivo" {
  printf 'tok_bom\n' > "$CLOUDEZ_TOKEN_FILE"
  MOCK_HTTP_STATUS=401 run save tok_ruim
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "invalid_token" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_bom" ]
}

@test "token recusado sem anterior nao deixa arquivo para tras" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  MOCK_HTTP_STATUS=401 run save tok_ruim
  [ "$status" -eq 1 ]
  [ ! -f "$CLOUDEZ_TOKEN_FILE" ]
}

# Inconclusivo nao e recusa: o token fica salvo, e quem chama reporta
# verified:false.
@test "API inalcancavel salva o token e devolve unknown" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  MOCK_CURL_EXIT=7 run save tok_novo
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_novo" ]
}

# ------------------------------------------------------- adaptadores exigem --

@test "setup sem token nao cria config" {
  rm .cloudez.yaml "$CLOUDEZ_TOKEN_FILE"
  run cloudez-setup meusite.com.br staging
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "not_authenticated" ]
  [ ! -f .cloudez.yaml ]
}

# A autenticacao vem antes de validar argumentos: o usuario resolve uma coisa por
# vez, e a que bloqueia tudo aparece primeiro.
@test "setup sem token reclama do token, nao do dominio" {
  rm .cloudez.yaml "$CLOUDEZ_TOKEN_FILE"
  run cloudez-setup
  [ "$(jq_field "$output" .error.code)" = "not_authenticated" ]
}

@test "setup com token recusado nao cria config" {
  rm .cloudez.yaml
  MOCK_HTTP_STATUS=403 run cloudez-setup meusite.com.br staging
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "token_invalid" ]
  [ ! -f .cloudez.yaml ]
}

