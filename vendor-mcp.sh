#!/usr/bin/env bash
# Uso: ./vendor-mcp.sh [caminho-do-repo-cloudez-mcp]
#
# Traz o MCP para dentro do plugin. Sao TRES artefatos, e a diferenca importa:
#
#   mcp/cloudez-mcp.mjs    o servidor. Sobe um transporte stdio ao ser importado.
#   mcp/cloudez-auth.mjs   biblioteca. O contrato do token, que o bin/cloudez-login
#                          importa em vez de reimplementar.
#   mcp/cloudez-state.mjs  biblioteca. O contrato do estado do deploy, que o
#                          bin/cloudez-sync importa em vez de reimplementar.
#
# As duas bibliotecas existem porque o servidor nao pode ser importado de um
# adaptador de linha de comando: importa-lo penduraria o processo num transporte
# que ninguem pediu. Entrypoints separados, um bundle cada.
#
# O contrato do ESTADO e o mais recente, e o que ele evita e concreto: o arquivo
# de estado tem dois escritores, e enquanto o sync foi Go os dois mantinham o
# schema em separado. Um round-trip pela struct de Go apagava em silencio o campo
# que ela nao conhecia. Importar em vez de reimplementar tira isso da disciplina
# de quem edita e passa para o build.
#
# O plugin versiona os artefatos para quem o instala nao precisar de nenhuma etapa
# de build — era o mesmo motivo dos binarios que viviam em libexec/, e e o unico
# que sobrou depois que eles sairam. A diferenca e que a fonte mora em OUTRO
# repositorio, entao este script nao compila: ele chama o bundle la e copia o
# resultado.
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
# npm_config_script_shell forca o bash deste processo a rodar os scripts do
# package.json. Sem isso, o npm do Windows chama cmd.exe por padrao, que nao
# entende "$npm_package_version" no banner do esbuild — o bundle sai com a
# string literal em vez da versao, e so o test/mcp.bats pega o defeito.
(cd "$fonte" && npm_config_script_shell="$BASH" npm run bundle)

for artefato in cloudez-mcp.mjs cloudez-auth.mjs cloudez-state.mjs; do
  [ -f "$fonte/dist/$artefato" ] || {
    echo "cloudez: $fonte/dist/$artefato nao foi gerado pelo bundle." >&2
    exit 1
  }
  cp "$fonte/dist/$artefato" "mcp/$artefato"
  echo "── vendorado em mcp/$artefato"
done

sed -n '2p' mcp/cloudez-mcp.mjs
