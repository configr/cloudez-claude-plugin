/**
 * Confere que todo import relativo de um arquivo do plugin aponta para um
 * arquivo rastreado pelo git.
 *
 * `git commit -am` estagia modificados, mas não novos: um módulo novo
 * esquecido no commit faria a suíte passar (roda contra a árvore de
 * trabalho) e a versão publicada quebrar no import.
 *
 * Contra `git ls-files`, não `git archive HEAD`: rastreado (em `git add`)
 * já basta, e exigir o commit feito faria o teste falhar sempre que se
 * escreve um módulo novo antes de commitar.
 *
 * Imprime uma linha por problema e sai com 1. Silêncio e 0 é sucesso.
 */

import { execFileSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { dirname, relative, resolve } from "node:path"

const raiz = process.argv[2] ?? "."

const rastreados = new Set(
  execFileSync("git", ["-C", raiz, "ls-files"], { encoding: "utf8" }).split("\n").filter(Boolean),
)

/**
 * Só os arquivos que o plugin de fato carrega em tempo de execução,
 * incluindo hooks/, que o harness executa fora de qualquer comando.
 */
const alvos = [...rastreados].filter(
  (f) => (f.startsWith("bin/") || f.startsWith("mcp/") || f.startsWith("hooks/")) && (f.endsWith(".mjs") || f === "bin/cloudez-sync"),
)

const problemas = []

for (const arquivo of alvos) {
  const texto = readFileSync(resolve(raiz, arquivo), "utf8")

  /**
   * `import ... from "./x.mjs"` e `import("./x.mjs")`. Só os relativos:
   * pacote do npm e módulo do node não são problema nosso.
   */
  for (const m of texto.matchAll(/from\s+"(\.\.?\/[^"]+)"|import\(\s*"(\.\.?\/[^"]+)"/g)) {
    const especificador = m[1] ?? m[2]
    const destino = resolve(dirname(resolve(raiz, arquivo)), especificador)
    const rel = relative(resolve(raiz), destino).split("\\").join("/")

    if (rastreados.has(rel)) continue

    problemas.push(
      existsSync(destino)
        ? `${arquivo} importa ${especificador}, que existe no disco mas NÃO está rastreado pelo git`
        : `${arquivo} importa ${especificador}, que não existe`,
    )
  }
}

for (const p of problemas) console.log(p)
process.exit(problemas.length === 0 ? 0 : 1)
