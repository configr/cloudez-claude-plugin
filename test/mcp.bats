#!/usr/bin/env bats
# O servidor MCP vendorado em mcp/cloudez-mcp.mjs.
#
# O plugin versiona o bundle para quem instala nao precisar de etapa de build. Era
# a mesma decisao dos binarios de libexec/, e hoje e a unica sobrevivente dela: os
# binarios sairam quando o sync virou Node. O risco dessa escolha e a copia
# apodrecer: um arquivo truncado, uma versao antiga, um bundle gerado de um
# fonte quebrado. Nada disso apareceria ate alguem tentar usar o plugin, e ai o
# sintoma seria "nenhuma tool disponivel", que nao aponta para ca.
#
# Estes testes exercitam o arquivo REAL, pelo protocolo, e nao afirmam sobre o
# fonte do outro repositorio — que pode nem estar presente na maquina.

load helpers/setup

BUNDLE="mcp/cloudez-mcp.mjs"

setup() {
  cd "$BATS_TEST_DIRNAME/.." || return 1
  command -v node >/dev/null 2>&1 || skip "node nao instalado"
}

@test "o bundle existe e diz de qual versao veio" {
  [ -f "$BUNDLE" ]
  # O cabecalho e o que permite saber, olhando so o plugin, qual cloudez-mcp
  # esta copia carrega.
  grep -qE '^// cloudez-mcp [0-9]+\.[0-9]+\.[0-9]+ ' "$BUNDLE"
}

@test "o bundle nao depende de node_modules ao lado" {
  # Um bundle que ainda importe pacote externo quebraria na maquina de quem
  # instalou o plugin, onde nao ha node_modules nenhum.
  ! grep -qE '^import .* from "(@modelcontextprotocol|zod)' "$BUNDLE"
}

@test "o servidor sobe e anuncia as tools pelo protocolo" {
  run node "$BATS_TEST_DIRNAME/mcp-handshake.mjs" "$BUNDLE"
  [ "$status" -eq 0 ]
  # As quatro que todo fluxo do plugin atravessa.
  [[ "$output" == *cloudez_auth_status* ]]
  [[ "$output" == *cloudez_get_site* ]]
  [[ "$output" == *cloudez_begin_deploy* ]]
  [[ "$output" == *cloudez_finalize_deploy* ]]
}

# O .mcp.json e o que liga o plugin ao bundle. Um caminho errado ali produz o
# mesmo sintoma de um bundle ausente.
@test "o .mcp.json aponta para o bundle, pela raiz do plugin" {
  [ "$(campo_de .mcp.json '.mcpServers.cloudez.args[0]')" = '${CLAUDE_PLUGIN_ROOT}/mcp/cloudez-mcp.mjs' ]
  [ "$(campo_de .mcp.json .mcpServers.cloudez.command)" = "node" ]
}

# A costura entre os dois repositorios: o MCP monta o caminho do `cloudez-login`
# a partir da raiz do plugin, e o plugin injeta essa raiz no ambiente. Um dos
# lados mudando de layout quebra a dica de login em silencio — a resposta ainda
# volta, so que sem o comando, e o modelo cai no caminho generico sem explicacao.
@test "o bundle acha o cloudez-login do plugin" {
  run env CLOUDEZ_PLUGIN_ROOT="$PWD" CLOUDEZ_TOKEN_FILE="$BATS_TEST_TMPDIR/sem-token" \
      CLOUDEZ_TOKEN= node "$BATS_TEST_DIRNAME/mcp-handshake.mjs" "$BUNDLE" cloudez_auth_status
  [ "$status" -eq 0 ]
  [ "$(campo "$output" .authenticated)" = "false" ]
  [ "$(campo "$output" .login_command)" = "$PWD/bin/cloudez-login" ]
  [ "$(campo "$output" .claude_code_command)" = "! $PWD/bin/cloudez-login" ]
}

@test "o .mcp.json injeta a raiz do plugin, que e como o MCP acha o bin/" {
  [ "$(campo_de .mcp.json .mcpServers.cloudez.env.CLOUDEZ_PLUGIN_ROOT)" = '${CLAUDE_PLUGIN_ROOT}' ]
}

# ------------------------------------------------------- bundle de biblioteca --
#
# O segundo artefato vendorado. Existe porque o `bin/cloudez-login` precisa do
# contrato do token — precedencia, tabela de vereditos, gravar-depois-validar —
# e reimplementa-lo era ter duas versoes de uma coisa so, com o pior modo de
# falha possivel: o login dizendo autenticado e o MCP dizendo que nao.

LIB="mcp/cloudez-auth.mjs"

@test "a biblioteca existe e diz de qual versao veio" {
  [ -f "$LIB" ]
  grep -qE '^// cloudez-mcp [0-9]+\.[0-9]+\.[0-9]+ ' "$LIB"
}

# Artefatos gerados do mesmo fonte que divergem em versao significam que alguem
# copiou um e esqueceu o outro — e a divergencia seria justamente no codigo que
# os dois lados precisam compartilhar.
#
# O $ESTADO e atribuido mais abaixo, na secao dele. Funciona porque o bats carrega
# o arquivo inteiro antes de rodar qualquer teste: a atribuicao acontece no source,
# nao na ordem em que os @test aparecem.
@test "os tres bundles vieram da mesma versao" {
  # A linha do banner, e nao a primeira do arquivo: o bundle do servidor comeca
  # com o shebang do index.ts, e os de biblioteca nao tem shebang nenhum.
  versao() { grep -m1 -oE '^// cloudez-mcp [0-9]+\.[0-9]+\.[0-9]+' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }
  [ -n "$(versao "$LIB")" ]
  [ "$(versao "$LIB")" = "$(versao "$BUNDLE")" ]
  [ "$(versao "$ESTADO")" = "$(versao "$BUNDLE")" ]
}

@test "a biblioteca nao depende de node_modules ao lado" {
  ! grep -qE '^import .* from "(@modelcontextprotocol|zod)' "$LIB"
}

# A razao de o servidor nao ser o unico bundle: importa-lo sobe um transporte
# stdio e penduraria o processo de quem so queria uma funcao. Se alguem um dia apontar
# o `bundle:lib` para o `index.ts`, este teste estoura no timeout.
@test "importar a biblioteca nao sobe servidor nenhum" {
  run node -e "
    const t = setTimeout(() => { console.error('pendurou'); process.exit(1) }, 5000)
    import('./$LIB').then((m) => {
      clearTimeout(t)
      const faltando = ['resolveToken','tokenSource','verifyToken','tokenFile','saveToken']
        .filter((n) => typeof m[n] !== 'function')
      if (faltando.length) { console.error('faltando: ' + faltando); process.exit(1) }
      process.exit(0)
    })
  "
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------- bundle do estado do deploy --
#
# O terceiro artefato vendorado, e o mais novo. Existe porque o arquivo de estado
# do deploy tem DOIS escritores — o begin/finalize no MCP e o cloudez-sync aqui —
# e enquanto o sync foi escrito em Go cada lado mantinha o schema por conta
# propria. O modo de falha nao era teorico: um round-trip pela struct de Go
# apagava em silencio o campo que ela nao conhecia, e a tool que precisava dele
# falhava depois, longe da causa.

ESTADO="mcp/cloudez-state.mjs"

@test "o bundle do estado existe e diz de qual versao veio" {
  [ -f "$ESTADO" ]
  grep -qE '^// cloudez-mcp [0-9]+\.[0-9]+\.[0-9]+ ' "$ESTADO"
}

@test "o bundle do estado nao depende de node_modules ao lado" {
  ! grep -qE '^import .* from "(@modelcontextprotocol|zod)' "$ESTADO"
}

# Mesma razao do teste equivalente da biblioteca de auth: se alguem apontar o
# bundle:state para o index.ts, isto estoura no timeout em vez de pendurar a
# suite. E as tres funcoes sao o contrato que o cloudez-sync importa — faltando
# uma, o sync quebra em runtime, longe daqui.
@test "importar o bundle do estado nao sobe servidor nenhum" {
  run node -e "
    const t = setTimeout(() => { console.error('pendurou'); process.exit(1) }, 5000)
    import('./$ESTADO').then((m) => {
      clearTimeout(t)
      const faltando = ['loadState','saveState','statePath']
        .filter((n) => typeof m[n] !== 'function')
      if (faltando.length) { console.error('faltando: ' + faltando); process.exit(1) }
      process.exit(0)
    })
  "
  [ "$status" -eq 0 ]
}
