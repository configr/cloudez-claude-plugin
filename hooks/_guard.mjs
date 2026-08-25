// A decisão do guard-rail de escrita, separada do processo que a aplica.
//
// Separada para poder ser testada como função: o entrypoint lê stdin e chama
// `process.exit`, e um teste que passasse por ele estaria exercitando o adaptador
// para verificar a regra. É a mesma divisão de `bin/_payload.mjs` e
// `bin/cloudez-sync`.

import { createHash } from "node:crypto"

/**
 * Os hosts REMOTOS que este comando escreveria. Vazio significa "pode passar".
 *
 * O critério é o VERBO, não o conteúdo: num `curl`, `-d` já implica POST e `-F`
 * é upload. Procurar por "parece dado de teste" seria adivinhação — a regra é
 * mecânica de propósito, porque o que falhou antes foi justamente o julgamento.
 *
 * Leitura passa. `GET` e `HEAD` não mudam nada do outro lado, e conferir um
 * status ou ler uma listagem é passo legítimo e frequente do deploy.
 */
export function escritaRemota(cmd) {
  if (typeof cmd !== "string" || !/\b(curl|wget)\b/.test(cmd)) return []

  const escreve =
    /(^|\s)-X\s*(POST|PUT|PATCH|DELETE)\b/i.test(cmd) ||
    /--request[=\s]+(POST|PUT|PATCH|DELETE)\b/i.test(cmd) ||
    // Flags curtas agrupadas: `-sd`, `-fF`, `-T`. O `-d` sozinho já é POST.
    /(^|\s)-[a-zA-Z]*[dFT](\s|=)/.test(cmd) ||
    /--(data|data-raw|data-binary|data-urlencode|form|upload-file|post-data|post-file)\b/.test(cmd) ||
    /--method[=\s]+(POST|PUT|PATCH|DELETE)\b/i.test(cmd)

  if (!escreve) return []

  const remotos = []
  for (const m of cmd.matchAll(/https?:\/\/([^\s/'"$)]+)/gi)) {
    const host = m[1]
      .replace(/^[^@]*@/, "") // usuário:senha@
      .replace(/:\d+$/, "") // porta
      .toLowerCase()
    if (!local(host)) remotos.push(host)
  }
  return [...new Set(remotos)]
}

/**
 * Endereço da própria máquina.
 *
 * O `/cloudez:dev` sobe a aplicação em `localhost` justamente para ser
 * exercitada à vontade — barrar ali tiraria o valor daquele comando sem proteger
 * nada.
 */
export function local(host) {
  return (
    host === "localhost" ||
    host === "127.0.0.1" ||
    host === "::1" ||
    host === "[::1]" ||
    host === "0.0.0.0" ||
    host.endsWith(".localhost") ||
    host.endsWith(".local")
  )
}

/**
 * O comando INTEIRO, e não só o host.
 *
 * A aprovação é por comando: aprovar um `POST /api/uploads` não pode liberar um
 * `DELETE /api/uploads/tudo` para o mesmo domínio.
 */
export function hash(cmd) {
  return createHash("sha256").update(cmd, "utf8").digest("hex")
}
