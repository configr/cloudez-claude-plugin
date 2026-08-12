#!/usr/bin/env bats
# Autenticacao: o cloudez-login coleta e grava o token. Quem responde pelo estado
# da autenticacao e a tool cloudez_auth_status do MCP — o --check foi removido
# daqui, e os adaptadores de deploy nao exigem token nenhum (falam por ssh).
#
# O que sobrou de token no shell e testado abaixo direto nas funcoes do _lib.sh,
# porque o unico comando que as exercita de ponta a ponta exige pty.

load helpers/setup

setup() { make_project; }

# lib <expressao> — roda algo com o _lib.sh carregado
lib() { bash -c "source '$PLUGIN_ROOT/bin/_lib.sh'; $1"; }

# --------------------------------------------------------------- precedencia --

@test "resolve_token le o arquivo quando nao ha variavel" {
  [ "$(lib resolve_token)" = "tok_teste" ]
  [ "$(lib token_source)" = "file" ]
}

@test "CLOUDEZ_TOKEN vence o arquivo" {
  [ "$(CLOUDEZ_TOKEN=tok_do_ambiente lib resolve_token)" = "tok_do_ambiente" ]
  [ "$(CLOUDEZ_TOKEN=tok_do_ambiente lib token_source)" = "env" ]
}

@test "sem arquivo e sem variavel nao ha token" {
  rm "$CLOUDEZ_TOKEN_FILE"
  [ -z "$(lib resolve_token)" ]
  [ "$(lib token_source)" = "none" ]
}

# -------------------------------------------------------------- verify_token --
#
# Os tres vereditos. Esta distincao e contrato, nao detalhe: o MCP a reimplementa
# do lado dele, e as duas implementacoes precisam concordar.

# Endpoint e header confirmados com a Cloudez. O esquema e `Token`, nao `Bearer`:
# trocar isso devolve 401 e faria todo token parecer recusado, o que manda o
# usuario procurar problema no painel em vez de aqui.
@test "verify_token chama o endpoint e o header confirmados" {
  lib "verify_token tok_teste" >/dev/null
  grep -q 'Authorization: Token tok_teste' "$MOCK_LOG"
  grep -q 'https://api.cloudez.io/auth/token/validate/' "$MOCK_LOG"
  ! grep -q 'Bearer' "$MOCK_LOG"
}

@test "CLOUDEZ_API_URL sobrepoe a base, para testar sem editar o script" {
  CLOUDEZ_API_URL=http://localhost:8000 lib "verify_token tok_teste" >/dev/null
  grep -q 'http://localhost:8000/auth/token/validate/' "$MOCK_LOG"
}

@test "2xx: valid" {
  [ "$(lib 'verify_token tok_teste')" = "valid" ]
}

# 401 e a unica resposta conclusiva: o token existe e a Cloudez o recusou.
@test "401: invalid" {
  [ "$(MOCK_HTTP_STATUS=401 lib 'verify_token tok_teste')" = "invalid" ]
}

# Offline, endpoint errado ou API fora nao sao prova de token ruim. Concluir
# "invalid" aqui mandaria o usuario refazer um login que ja estava certo.
@test "API fora do ar: unknown" {
  [ "$(MOCK_CURL_EXIT=7 lib 'verify_token tok_teste')" = "unknown" ]
}

@test "404: unknown, nao invalid" {
  [ "$(MOCK_HTTP_STATUS=404 lib 'verify_token tok_teste')" = "unknown" ]
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

# Mesma razao do --password: o substituto do --check nao e outra flag, e uma tool
# do MCP. "Argumento desconhecido" nao levaria ninguem ate ela.
@test "--check responde que agora e tool do MCP" {
  run cloudez-login --check
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "check_moved_to_mcp" ]
  [[ "$(jq_field "$output" .error.hint)" == *cloudez_auth_status* ]]
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
  [ "$(jq_field "$output" .status)" = "authenticated" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_do_clipboard" ]
  [ "$(ls -l "$CLOUDEZ_TOKEN_FILE" | cut -c1-10)" = "-rw-------" ]
}

@test "stdin tolera newline no fim, que todo clipboard traz" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'printf "tok_com_newline\n" | cloudez-login --stdin'
  [ "$status" -eq 0 ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_com_newline" ]
}

@test "stdin vazio nao salva nada" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run bash -c ': | cloudez-login --stdin'
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "empty_token" ]
  [ ! -f "$CLOUDEZ_TOKEN_FILE" ]
}

# Clipboard com outra coisa dentro e o erro mais provavel aqui.
@test "stdin com texto que nao e token nao gasta chamada de API" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'printf "Seu token: abc123" | cloudez-login --stdin'
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "invalid_token" ]
  ! grep -q 'Authorization' "$MOCK_LOG"
}

@test "stdin com token recusado devolve o anterior" {
  printf 'tok_bom\n' > "$CLOUDEZ_TOKEN_FILE"
  # O prefixo vai no cloudez-login, nao no printf: num pipeline cada comando tem o
  # seu proprio ambiente.
  run bash -c 'printf tok_ruim | MOCK_HTTP_STATUS=401 cloudez-login --stdin'
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "invalid_token" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_bom" ]
}

@test "stdin nao imprime o token" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run bash -c 'printf tok_secreto | cloudez-login --stdin'
  [[ "$output" != *tok_secreto* ]]
}

# A dica do erro tem que oferecer o caminho que funciona onde o agente esta. Este
# teste depende de haver clipboard na maquina: em CI Linux headless nao ha, e o
# comportamento correto ali e a dica NAO citar clipboard (veja o teste seguinte).
# O --hint responde "como autentico aqui", nao "estou autenticado" — entao nao
# pode depender de token nem gastar chamada de API.
@test "--hint funciona sem token e sem falar com a API" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run cloudez-login --hint
  [ "$status" -eq 0 ]
  [[ "$(jq_field "$output" .claude_code_command)" == "! /"*/cloudez-login ]]
  [ ! -s "$MOCK_LOG" ] || ! grep -q 'Authorization' "$MOCK_LOG"
}

@test "a dica oferece o caminho por clipboard, quando ha clipboard" {
  clip=$(lib clipboard_read_cmd)
  [ -n "$clip" ] || skip "sem clipboard nesta maquina"
  out=$(lib login_hint)
  [[ "$(jq_field "$out" .clipboard_command)" == *"--stdin" ]]
  [[ "$(jq_field "$out" .hint)" == *clipboard* ]]
}

# Sem clipboard, a dica cai para o prompt interativo em vez de sugerir um comando
# que nao existe.
@test "sem clipboard, a dica oferece so o caminho interativo" {
  out=$(bash -c "source '$PLUGIN_ROOT/bin/_lib.sh'
                 clipboard_read_cmd() { :; }
                 login_hint")
  [ "$(jq_field "$out" 'has("clipboard_command")')" = "false" ]
  [[ "$(jq_field "$out" .hint)" == *"! /"* ]]
}

# X11 e Wayland guardam o clipboard no servidor grafico: sem DISPLAY o utilitario
# existe e falha. E o caso de SSH, container, CI e Claude Code em maquina remota —
# e sugerir um comando que falha e pior do que nao sugerir nada.
@test "sem sessao grafica nao ha clipboard" {
  run bash -c "source '$PLUGIN_ROOT/bin/_lib.sh'; unset DISPLAY WAYLAND_DISPLAY; graphical_session"
  [ "$status" -eq 1 ]
  run bash -c "source '$PLUGIN_ROOT/bin/_lib.sh'; DISPLAY=:0 graphical_session"
  [ "$status" -eq 0 ]
  run bash -c "source '$PLUGIN_ROOT/bin/_lib.sh'; WAYLAND_DISPLAY=wayland-0 graphical_session"
  [ "$status" -eq 0 ]
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

# --------------------------------------------- adaptadores NAO exigem token --
#
# Nenhum adaptador em bin/ cobra autenticacao. O deploy inteiro fala com o
# servidor por ssh, com a chave do usuario, e o cloudez-setup so escreve um
# arquivo local a partir dos argumentos. Quem cobra token e o MCP, porque e ele
# quem usa o token contra a API.

@test "setup funciona sem token: escrever config nao fala com a Cloudez" {
  rm .cloudez.yaml "$CLOUDEZ_TOKEN_FILE"
  run cloudez-setup meusite.com.br staging
  [ "$status" -eq 0 ]
  [ -f .cloudez.yaml ]
}

@test "setup sem token nao gasta chamada de API" {
  rm .cloudez.yaml "$CLOUDEZ_TOKEN_FILE"
  cloudez-setup meusite.com.br staging >/dev/null
  [ ! -s "$MOCK_LOG" ] || ! grep -q 'Authorization' "$MOCK_LOG"
}

# Sem o gate, o primeiro erro que o usuario ve e o do argumento que faltou — que
# e o que ele pode consertar sozinho ali mesmo.
@test "setup sem dominio reclama do dominio" {
  rm .cloudez.yaml
  run cloudez-setup
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "missing_domain" ]
}

