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
