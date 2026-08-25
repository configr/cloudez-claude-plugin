// Confere que todo import relativo de um arquivo do plugin aponta para um
// arquivo RASTREADO pelo git.
//
// Existe por um defeito concreto: `git commit -am` estagia os arquivos
// modificados, mas NÃO os novos. Um módulo novo (`bin/_ignore.mjs`) ficou fora do
// commit, e a suíte inteira passou — porque ela roda contra a árvore de trabalho,
// onde o arquivo está. A versão publicada saiu sem ele, e o `cloudez-sync` morria
// no import antes de fazer qualquer coisa.
//
// A verificação é contra `git ls-files`, e não contra um `git archive HEAD`, de
// propósito: com o archive, escrever um módulo novo e rodar a suíte antes de
// commitar falharia sempre, e o teste viraria ruído que se aprende a ignorar.
// Rastreado é o que basta — um arquivo em `git add` já vai junto no commit.
//
// Imprime uma linha por problema e sai com 1. Silêncio e 0 é sucesso.

import { execFileSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { dirname, relative, resolve } from "node:path"

const raiz = process.argv[2] ?? "."

const rastreados = new Set(
  execFileSync("git", ["-C", raiz, "ls-files"], { encoding: "utf8" }).split("\n").filter(Boolean),
)

// Só os arquivos que o plugin de fato carrega em tempo de execução — inclusive
// os `hooks/`, que o harness executa fora de qualquer comando. Os `mcp/*.mjs`
// são bundles sem import relativo — se um dia tiverem, entram aqui também.
const alvos = [...rastreados].filter(
  (f) => (f.startsWith("bin/") || f.startsWith("mcp/") || f.startsWith("hooks/")) && (f.endsWith(".mjs") || f === "bin/cloudez-sync"),
)

const problemas = []

for (const arquivo of alvos) {
  const texto = readFileSync(resolve(raiz, arquivo), "utf8")

  // `import ... from "./x.mjs"` e `import("./x.mjs")`. Só os relativos: pacote do
  // npm e módulo do node não são problema nosso.
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
