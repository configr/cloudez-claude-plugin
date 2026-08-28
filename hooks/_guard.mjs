// Decisão do guard-rail de escrita, separada do processo que a aplica, para
// poder ser testada como função em vez de exercitar o adaptador.

import { createHash } from "node:crypto"

/**
 * Os hosts remotos que este comando escreveria. Vazio significa "pode passar".
 *
 * O critério é o verbo, não o conteúdo: num `curl`, `-d` já implica POST e
 * `-F` é upload. Leitura (GET, HEAD) passa sempre.
 */
export function escritaRemota(cmd) {
  if (typeof cmd !== "string") return []

  const remotos = []
  for (const trecho of segmentos(cmd)) {
    if (!/(^|\s)(curl|wget)(\s|$)/.test(trecho)) continue
    if (!escreve(trecho)) continue
    for (const host of hosts(trecho)) if (!local(host)) remotos.push(host)
  }
  return [...new Set(remotos)]
}

/**
 * Quebra a linha nos operadores do shell.
 *
 * Sem isto, uma flag `-d` de `cut` ou `xargs` no mesmo pipeline de um `curl`
 * de leitura contava como intenção de escrita. A quebra é textual e não
 * entende aspas, mas só pode partir um trecho em dois, nunca juntar dois.
 */
function segmentos(cmd) {
  return cmd.split(/\|\||&&|[|;\n]/)
}

/** Verbo de escrita neste trecho. `-d` já é POST no curl, `-F` é upload. */
function escreve(t) {
  return (
    /(^|\s)-X\s*(POST|PUT|PATCH|DELETE)\b/i.test(t) ||
    /--request[=\s]+(POST|PUT|PATCH|DELETE)\b/i.test(t) ||
    /(^|\s)-[a-zA-Z]*[dFT](\s|=)/.test(t) ||
    /--(data|data-raw|data-binary|data-urlencode|form|upload-file|post-data|post-file)\b/.test(t) ||
    /--method[=\s]+(POST|PUT|PATCH|DELETE)\b/i.test(t)
  )
}

function hosts(t) {
  const out = []
  for (const m of t.matchAll(/https?:\/\/([^\s/'"$)]+)/gi)) {
    out.push(
      m[1]
        .replace(/^[^@]*@/, "") // usuário:senha@
        .replace(/:\d+$/, "") // porta
        .toLowerCase(),
    )
  }
  return out
}

/**
 * Endereço da própria máquina. O `/cloudez:dev` sobe a aplicação em
 * `localhost` para ser exercitada à vontade; barrar ali não protegeria nada.
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
 * Hash do comando inteiro, não só do host: aprovar um `POST /api/uploads`
 * não pode liberar um `DELETE /api/uploads/tudo` do mesmo domínio.
 */
export function hash(cmd) {
  return createHash("sha256").update(cmd, "utf8").digest("hex")
}
