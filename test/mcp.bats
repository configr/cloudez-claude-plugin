#!/usr/bin/env bats
# O servidor MCP vendorado em mcp/cloudez-mcp.mjs.
#
# O plugin versiona o bundle para quem instala nao precisar de etapa de build —
# mesma decisao dos binarios em libexec/. O risco dessa escolha e a copia
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
  [ "$(jq -r '.mcpServers.cloudez.args[0]' .mcp.json)" = '${CLAUDE_PLUGIN_ROOT}/mcp/cloudez-mcp.mjs' ]
  [ "$(jq -r '.mcpServers.cloudez.command' .mcp.json)" = "node" ]
}

# A costura entre os dois repositorios: o MCP monta o caminho do `cloudez-login`
# a partir da raiz do plugin, e o plugin injeta essa raiz no ambiente. Um dos
# lados mudando de layout quebra a dica de login em silencio — a resposta ainda
# volta, so que sem o comando, e o modelo cai no caminho generico sem explicacao.
@test "o bundle acha o cloudez-login do plugin" {
  run env CLOUDEZ_PLUGIN_ROOT="$PWD" CLOUDEZ_TOKEN_FILE="$BATS_TEST_TMPDIR/sem-token" \
      CLOUDEZ_TOKEN= node "$BATS_TEST_DIRNAME/mcp-handshake.mjs" "$BUNDLE" cloudez_auth_status
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .authenticated)" = "false" ]
  [ "$(jq_field "$output" .login_command)" = "$PWD/bin/cloudez-login" ]
  [ "$(jq_field "$output" .claude_code_command)" = "! $PWD/bin/cloudez-login" ]
}

@test "o .mcp.json injeta a raiz do plugin, que e como o MCP acha o bin/" {
  [ "$(jq -r '.mcpServers.cloudez.env.CLOUDEZ_PLUGIN_ROOT' .mcp.json)" = '${CLAUDE_PLUGIN_ROOT}' ]
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

# Dois artefatos gerados do mesmo fonte que divergem em versao significam que
# alguem copiou um e esqueceu o outro — e a divergencia seria justamente no
# codigo que os dois lados precisam compartilhar.
@test "os dois bundles vieram da mesma versao" {
  # A linha do banner, e nao a primeira do arquivo: o bundle do servidor comeca
  # com o shebang do index.ts, e o da biblioteca nao tem shebang nenhum.
  versao() { grep -m1 -oE '^// cloudez-mcp [0-9]+\.[0-9]+\.[0-9]+' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'; }
  [ -n "$(versao "$LIB")" ]
  [ "$(versao "$LIB")" = "$(versao "$BUNDLE")" ]
}

@test "a biblioteca nao depende de node_modules ao lado" {
  ! grep -qE '^import .* from "(@modelcontextprotocol|zod)' "$LIB"
}

# A razao de existirem DOIS bundles: importar o servidor sobe um transporte stdio
# e penduraria o processo de quem so queria uma funcao. Se alguem um dia apontar
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
