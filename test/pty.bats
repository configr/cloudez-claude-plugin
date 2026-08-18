#!/usr/bin/env bats
# O prompt do `cloudez-login`: a leitura do terminal, num terminal de verdade.
#
# Esta camada não existia. O README a listava como limitação conhecida — "ler o
# terminal sem eco precisa de um pty, e alocar um em bats de forma portátil
# significa `script`, cuja sintaxe divergente entre macOS e Linux é exatamente o
# tipo de coisa que já quebrou esta suíte" — e a objeção era legítima, mas menor do
# que parecia: a divergência cabe num condicional, e está no `com_pty`.
#
# O que ela cobre, e nenhuma outra cobre:
#
#   - o modo raw, que o `--stdin` não atravessa;
#   - o backspace e o Ctrl-C, tratados na mão porque o raw os entrega crus. Eram
#     de graça no `read -rs` do bash, e passaram a ser código nosso quando o
#     adaptador virou Node — código sem teste até aqui;
#   - o não-eco, que é a razão de o prompt existir em vez de um `read` comum.
#
# O que ela NÃO cobre, de propósito: a gravação com 0600, a precedência do token e
# validar-depois-de-escrever. Tudo isso o `--stdin` já atravessa em test/auth.bats,
# sem precisar de pty, e duplicar aqui só daria dois lugares para consertar.

load helpers/setup

setup() {
  command -v script >/dev/null 2>&1 || skip "script(1) nao disponivel: sem pty portatil"
  make_project
  start_api
}

# ------------------------------------------------------------------ o harness --
#
# O `com_pty` deixou de ser detalhe de teste e virou peça carregada: sete testes
# dependem dele para afirmar sobre falha. Este verifica o HARNESS, não o plugin.
#
# Existe por um defeito real: o `script` do util-linux devolve o próprio código de
# saída, e não o do filho, a menos que receba `-e`. Sem essa flag toda afirmação de
# falha virava sucesso — e como o `script` do BSD propaga por padrão, o macOS ficou
# verde e só o ubuntu quebrou, depois do push.
@test "o harness de pty propaga o codigo de saida do comando" {
  # Imprime o prompt (para o com_pty não esperar o teto) e sai com 3. O 3 não é 0
  # nem 1: distingue "propagou" de "engoliu" e de "falhou por conta própria".
  run com_pty $'x\n' sh -c 'printf "Token: "; exit 3'
  [ "$status" -eq 3 ]
}

@test "o harness de pty propaga sucesso tambem" {
  run com_pty $'x\n' sh -c 'printf "Token: "; exit 0'
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------------ o básico --

@test "o prompt le o token digitado e o grava" {
  run com_pty $'tok_do_prompt\n' node "$PLUGIN_ROOT/bin/cloudez-login"
  [ "$status" -eq 0 ]
  [ "$(campo_pty "$output" .status)" = "authenticated" ]
  [ "$(campo_pty "$output" .verified)" = "true" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_do_prompt" ]
}

# A razão de o prompt existir em vez de um `read` comum. Um segredo ecoado fica no
# scrollback do terminal e, com frequência, no log de quem grava a sessão.
@test "o que se digita nao aparece na tela" {
  run com_pty $'tok_ultrasecreto\n' node "$PLUGIN_ROOT/bin/cloudez-login"
  [ "$status" -eq 0 ]
  # Na saída do TERMINAL — que é o que o `com_pty` devolve — o token não pode
  # estar em lugar nenhum. No arquivo, tem de estar.
  ! grep -q 'tok_ultrasecreto' <<< "$output"
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_ultrasecreto" ]
  # E o prompt em si foi mostrado: sem isto, um login que nem chegou a perguntar
  # passaria neste teste.
  [[ "$output" == *"Token: "* ]]
}

# -------------------------------------------------- as teclas do modo raw ----
#
# O modo raw entrega backspace e Ctrl-C crus. Com `read -rs` do bash os dois vinham
# de graça; em Node são código nosso, e código nosso quer teste.

@test "backspace corrige o que ja foi digitado" {
  # tok_ERRXX, dois backspaces, OK  ->  tok_ERROK
  run com_pty $'tok_ERRXX\177\177OK\n' node "$PLUGIN_ROOT/bin/cloudez-login"
  [ "$status" -eq 0 ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_ERROK" ]
}

# Sem tratar o ETX na mão, o Ctrl-C não chega ao processo e o terminal fica preso
# em modo raw depois que o usuário desiste.
@test "Ctrl-C cancela o login sem gravar nada" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run com_pty $'tok_arrependido\003' node "$PLUGIN_ROOT/bin/cloudez-login"
  [ "$status" -eq 1 ]
  [ "$(campo_pty "$output" .error.code)" = "interrupted" ]
  [ ! -f "$CLOUDEZ_TOKEN_FILE" ]
}

# ------------------------------------------------------- Enter sem digitar ----

# Rotacionar token no painel é rotina. Sem esta saída não havia como trocar um
# token válido por outro sem apagar o arquivo na mão — e o Enter vazio é o que
# distingue "mantém o atual" de "não informei nada".
@test "Enter vazio mantem o token valido que ja existia" {
  # make_project deixa um token no arquivo, e a API falsa responde 200 para ele.
  run com_pty $'\n' node "$PLUGIN_ROOT/bin/cloudez-login"
  [ "$status" -eq 0 ]
  [ "$(campo_pty "$output" .status)" = "already_authenticated" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_teste" ]
}

@test "Enter vazio sem token valido recusa, em vez de gravar vazio" {
  rm -f "$CLOUDEZ_TOKEN_FILE"
  run com_pty $'\n' node "$PLUGIN_ROOT/bin/cloudez-login"
  [ "$status" -eq 1 ]
  [ "$(campo_pty "$output" .error.code)" = "empty_token" ]
  [ ! -f "$CLOUDEZ_TOKEN_FILE" ]
}

# --------------------------------------------------------- --stdin com TTY ----

# Este ramo esteve fora de alcance ate agora, e test/auth.bats registrava isso por
# escrito: sem pty nao ha como produzir "stdin e um terminal". O guarda existe
# porque `--stdin` sem pipe travaria esperando entrada que nunca vem, e o usuario
# nao teria como saber por que.
@test "--stdin recusa quando stdin e um terminal, e nao um pipe" {
  run com_pty '' node "$PLUGIN_ROOT/bin/cloudez-login" --stdin
  [ "$status" -eq 1 ]
  [ "$(campo_pty "$output" .error.code)" = "usage" ]
  [[ "$output" == *"num pipe"* ]]
}

# ------------------------------------------------------- recusa da Cloudez ----

# O caminho do prompt precisa tratar a recusa como o `--stdin` trata: o token
# digitado é gravado ANTES de validar, e desfeito quando a Cloudez recusa.
@test "token recusado pelo prompt devolve o anterior ao arquivo" {
  api_status 401
  run com_pty $'tok_recusado\n' node "$PLUGIN_ROOT/bin/cloudez-login"
  [ "$status" -eq 1 ]
  [ "$(campo_pty "$output" .error.code)" = "invalid_token" ]
  [ "$(cat "$CLOUDEZ_TOKEN_FILE")" = "tok_teste" ]
}
