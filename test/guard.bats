#!/usr/bin/env bats
# O guard-rail de escrita em aplicacao viva.
#
# Existe por dois incidentes: um recado assinado "Claude" num mural publico
# gravado em Postgres, e um PNG num site de uploads. Nenhum foi desobediencia a
# uma regra escrita — foram falhas de CLASSIFICACAO, e por isso a barreira e
# mecanica em vez de textual.

load helpers/setup

setup() { make_project; }

chamada() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$1"; }
guard() { chamada "$1" | node "$PLUGIN_ROOT/hooks/guard-write.mjs"; }

aprovar_para() {
  mkdir -p "$CLOUDEZ_GUARD_DIR"
  node -e '
    const c = require("node:crypto"), fs = require("node:fs"), p = require("node:path")
    const h = c.createHash("sha256").update(process.argv[1], "utf8").digest("hex")
    const at = Date.now() - Number(process.argv[2] || 0) * 60000
    fs.writeFileSync(p.join(process.env.CLOUDEZ_GUARD_DIR, "approved-write.json"), JSON.stringify({ hash: h, at }))
  ' "$1" "${2:-0}"
}

# ---------------------------------------------------------------- a decisao --

# Ler nao muda nada do outro lado, e e como se confere um status ou uma listagem.
@test "guard: leitura remota passa" {
  run guard '"curl -s https://site.com/api/uploads"'
  [ "$status" -eq 0 ]
}

@test "guard: leitura com flags de saida passa" {
  run guard '"curl -s -o /dev/null -w %{http_code} https://site.com/"'
  [ "$status" -eq 0 ]
}

@test "guard: escrita remota bloqueia com exit 2" {
  run guard '"curl -X POST https://site.com/api/uploads"'
  [ "$status" -eq 2 ]
  [[ "$output" == *"ESCREVE numa aplicacao remota"* ]] || [[ "$output" == *"ESCREVE numa aplicação remota"* ]]
  [[ "$output" == *"cloudez-approve"* ]]
}

# -d ja implica POST no curl, e -F e upload: o criterio e o VERBO, nao o conteudo.
@test "guard: -d e -F bloqueiam sem precisar de -X" {
  run guard '"curl -d nome=x https://mural.com/recados"'
  [ "$status" -eq 2 ]
  run guard '"curl -s -F file=@a.png https://site.com/api/uploads"'
  [ "$status" -eq 2 ]
}

@test "guard: DELETE bloqueia" {
  run guard '"curl -X DELETE https://site.com/api/uploads/1"'
  [ "$status" -eq 2 ]
}

# O /cloudez:dev sobe a aplicacao em localhost para ser exercitada a vontade.
@test "guard: escrita em localhost passa" {
  run guard '"curl -X POST http://localhost:3005/api/uploads"'
  [ "$status" -eq 0 ]
  run guard '"curl -X POST http://127.0.0.1:3000/x"'
  [ "$status" -eq 0 ]
}

# REGRESSAO: a analise varria a linha INTEIRA, e qualquer flag terminada em d, F
# ou T contava como intencao de escrita — mesmo vindo de outro programa do
# pipeline. Leitura seguida de filtro comum era bloqueada, que e metade do uso
# legitimo de curl.
@test "guard: leitura com filtro no pipe passa" {
  run guard '"curl -s https://site.com/x | grep -F erro"'
  [ "$status" -eq 0 ]
  run guard '"curl -s https://site.com/x | cut -d , -f2"'
  [ "$status" -eq 0 ]
  run guard '"curl -s https://site.com/x | xargs -d \n echo"'
  [ "$status" -eq 0 ]
}

# Mas escrita em QUALQUER trecho do pipeline continua barrada.
@test "guard: escrita num trecho posterior do pipe bloqueia" {
  run guard '"curl -s https://a.com/ | curl -X POST https://b.com/"'
  [ "$status" -eq 2 ]
  [[ "$output" == *"b.com"* ]]
}

@test "guard: os comandos do proprio plugin passam" {
  run guard '"cloudez-sync dpl_x ../site"'
  [ "$status" -eq 0 ]
  run guard '"pbpaste | /caminho/bin/cloudez-login --stdin"'
  [ "$status" -eq 0 ]
}

@test "guard: comando sem curl nem wget passa" {
  run guard '"git push origin main"'
  [ "$status" -eq 0 ]
}

@test "guard: tool que nao e Bash passa" {
  run bash -c 'printf "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/x\"}}" | node "$PLUGIN_ROOT/hooks/guard-write.mjs"'
  [ "$status" -eq 0 ]
}

# --------------------------------------------------------------- a aprovacao --

@test "guard: o bloqueio registra o pedido para o approve exibir" {
  run guard '"curl -X POST https://site.com/api/uploads"'
  [ "$status" -eq 2 ]
  [ -f "$CLOUDEZ_GUARD_DIR/pending-write.json" ]
  [ "$(campo_de "$CLOUDEZ_GUARD_DIR/pending-write.json" .command)" = "curl -X POST https://site.com/api/uploads" ]
}

@test "guard: aprovacao libera o comando exato" {
  aprovar_para "curl -X POST https://site.com/api/uploads"
  run guard '"curl -X POST https://site.com/api/uploads"'
  [ "$status" -eq 0 ]
}

# "Por comando" tem de significar por comando: sem isso viraria por janela de tempo.
@test "guard: a aprovacao e de USO UNICO" {
  aprovar_para "curl -X POST https://site.com/api/uploads"
  run guard '"curl -X POST https://site.com/api/uploads"'
  [ "$status" -eq 0 ]
  [ ! -f "$CLOUDEZ_GUARD_DIR/approved-write.json" ]
  run guard '"curl -X POST https://site.com/api/uploads"'
  [ "$status" -eq 2 ]
}

# Aprovar um POST nao pode liberar um DELETE no mesmo dominio.
@test "guard: aprovacao nao vale para outro comando" {
  aprovar_para "curl -X POST https://site.com/inofensivo"
  run guard '"curl -X DELETE https://site.com/api/tudo"'
  [ "$status" -eq 2 ]
}

@test "guard: aprovacao expirada nao vale" {
  aprovar_para "curl -X POST https://site.com/api/uploads" 11
  run guard '"curl -X POST https://site.com/api/uploads"'
  [ "$status" -eq 2 ]
}

# ------------------------------------------------------------------ o approve --

# ESTA e a propriedade que sustenta a barreira. A primeira versao usava
# createReadStream, que e preguicoso e nao falha de forma sincrona: o approve
# rodado SEM terminal exibia o prompt em vez de recusar.
@test "guard: cloudez-approve sem TTY recusa" {
  run guard '"curl -X POST https://site.com/api/uploads"'
  run bash -c 'cloudez-approve < /dev/null 2>&1'
  [ "$status" -ne 0 ]
  [ "$(campo "$output" .error.code)" = "no_tty" ]
  [ ! -f "$CLOUDEZ_GUARD_DIR/approved-write.json" ]
}

@test "guard: approve sem nada pendente recusa" {
  run bash -c 'cloudez-approve < /dev/null 2>&1'
  [ "$status" -ne 0 ]
}

@test "guard: com terminal, aprova e libera uma vez" {
  run guard '"curl -X POST https://site.com/api/uploads"'
  [ "$status" -eq 2 ]

  # Com \n: o readline resolve na quebra de linha. Sem terminador o helper manda
  # EOT, e o readline — diferente do prompt do cloudez-login — nao o trata como
  # fim de entrada, entao a pergunta nunca resolve e a suite pendura.
  com_pty $'aprovo\n' cloudez-approve
  [ -f "$CLOUDEZ_GUARD_DIR/approved-write.json" ]

  run guard '"curl -X POST https://site.com/api/uploads"'
  [ "$status" -eq 0 ]
}

@test "guard: com terminal, resposta diferente NAO aprova" {
  run guard '"curl -X POST https://site.com/api/uploads"'
  com_pty $'nao\n' cloudez-approve || true
  [ ! -f "$CLOUDEZ_GUARD_DIR/approved-write.json" ]
}
