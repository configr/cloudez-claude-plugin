#!/usr/bin/env bash
# Uso: ./vendor-mcp.sh [caminho-do-repo-cloudez-mcp]
#
# Traz o servidor MCP para dentro do plugin, como um arquivo so.
#
# Existe pelo mesmo motivo do build.sh: o plugin versiona o artefato para quem o
# instala nao precisar de nenhuma etapa de build. A diferenca e que a fonte mora
# em OUTRO repositorio, entao este script nao compila — ele chama o bundle la e
# copia o resultado.
#
# O bundle carrega a versao no cabecalho. E o que permite saber, olhando so o
# plugin, de qual cloudez-mcp esta copia veio — sem isso a divergencia entre os
# dois repositorios so apareceria quando algo quebrasse.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
destino="mcp/cloudez-mcp.mjs"
fonte="${1:-../cloudez-mcp}"

[ -f "$fonte/package.json" ] || {
  echo "cloudez: repositorio do MCP nao encontrado em '$fonte'." >&2
  echo "cloudez: passe o caminho como argumento: ./vendor-mcp.sh /caminho/cloudez-mcp" >&2
  exit 1
}

echo "── bundle em $fonte"
(cd "$fonte" && npm run bundle)

cp "$fonte/dist/cloudez-mcp.mjs" "$destino"

echo "── vendorado em $destino"
sed -n '2p' "$destino"
