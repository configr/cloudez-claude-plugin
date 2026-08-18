#!/usr/bin/env bash
# Uso: ./vendor-mcp.sh [caminho-do-repo-cloudez-mcp]
#
# Traz o MCP para dentro do plugin. Sao DOIS artefatos, e a diferenca importa:
#
#   mcp/cloudez-mcp.mjs    o servidor. Sobe um transporte stdio ao ser importado.
#   mcp/cloudez-auth.mjs   biblioteca. O contrato do token, que o bin/cloudez-login
#                          importa em vez de reimplementar.
#
# O segundo existe porque o primeiro nao pode ser importado de um adaptador de
# linha de comando: importar o servidor penduraria o processo num transporte que
# ninguem pediu. Entrypoints separados, um bundle cada.
#
# Existe pelo mesmo motivo do build.sh: o plugin versiona o artefato para quem o
# instala nao precisar de nenhuma etapa de build. A diferenca e que a fonte mora
# em OUTRO repositorio, entao este script nao compila — ele chama o bundle la e
# copia o resultado.
#
# Os bundles carregam a versao no cabecalho. E o que permite saber, olhando so o
# plugin, de qual cloudez-mcp esta copia veio — sem isso a divergencia entre os
# dois repositorios so apareceria quando algo quebrasse.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
fonte="${1:-../cloudez-mcp}"

[ -f "$fonte/package.json" ] || {
  echo "cloudez: repositorio do MCP nao encontrado em '$fonte'." >&2
  echo "cloudez: passe o caminho como argumento: ./vendor-mcp.sh /caminho/cloudez-mcp" >&2
  exit 1
}

echo "── bundle em $fonte"
(cd "$fonte" && npm run bundle)

for artefato in cloudez-mcp.mjs cloudez-auth.mjs; do
  [ -f "$fonte/dist/$artefato" ] || {
    echo "cloudez: $fonte/dist/$artefato nao foi gerado pelo bundle." >&2
    exit 1
  }
  cp "$fonte/dist/$artefato" "mcp/$artefato"
  echo "── vendorado em mcp/$artefato"
done

sed -n '2p' mcp/cloudez-mcp.mjs
