#!/usr/bin/env node
// Relatório de cobertura de `bin/`, juntando o que os DOIS layers de teste
// executaram.
//
// Uso: test/run.sh --coverage  (ou: node test/coverage.mjs <dir-do-NODE_V8_COVERAGE>)
//
// Existe porque nenhuma ferramenta embutida cobre o caso desta suíte. O
// `node --test --experimental-test-coverage` só enxerga o que o próprio processo
// de teste carrega — aqui, só o `_payload.mjs`. Os adaptadores são exercitados
// pelo bats, que os roda como SUBPROCESSO, e para esses o que existe é o
// `NODE_V8_COVERAGE`: cada processo Node despeja o coverage bruto do V8 num
// diretório ao sair. Falta só juntar, e é isso que este arquivo faz.
//
// A alternativa era o `c8`, que faz tudo isso numa linha — e traria `node_modules`
// e um `npm install` de volta para um repositório que acabou de eliminar toda
// etapa de instalação. Noventa linhas custam menos que essa regressão.
//
// ── Duas decisões de medição, e as duas já morderam ──
//
// 1. NÃO conte "ranges aninhados com count > 0" como cobertura de bloco. O V8 só
//    emite sub-range quando a contagem DIFERE do range que o contém, ou seja: os
//    aninhados são os BURACOS. Aquela métrica mede a fração de buracos que não são
//    buracos e tende a zero por construção — na primeira versão deste relatório o
//    `cloudez-sync` apareceu com 100% de funções e 0% de blocos ao mesmo tempo, o
//    que é o sintoma exato. O certo é resolver byte a byte, com o range mais
//    interno mandando.
//
// 2. Comentário NÃO conta como linha coberta. Este repositório é densamente
//    comentado — há arquivos com mais comentário que código — e contá-los faria a
//    cobertura subir sozinha ao escrever documentação.

import { readdirSync, readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

const dir = process.argv[2]
const filtro = process.argv[3] ?? "/bin/"

if (!dir) {
  process.stderr.write("uso: node test/coverage.mjs <dir-do-NODE_V8_COVERAGE> [filtro]\n")
  process.exit(2)
}

// url -> uma entrada por processo que carregou o arquivo
const porArquivo = new Map()

for (const f of readdirSync(dir)) {
  if (!f.endsWith(".json")) continue
  let j
  try {
    j = JSON.parse(readFileSync(`${dir}/${f}`, "utf8"))
  } catch {
    continue // Arquivo truncado por um processo morto no meio. Ignora.
  }
  for (const script of j.result ?? []) {
    if (!script.url.startsWith("file://") || !script.url.includes(filtro)) continue
    if (!porArquivo.has(script.url)) porArquivo.set(script.url, [])
    porArquivo.get(script.url).push(script.functions ?? [])
  }
}

if (porArquivo.size === 0) {
  process.stderr.write(`cobertura: nenhum dado para '${filtro}' em ${dir}.\n`)
  process.stderr.write("cobertura: o NODE_V8_COVERAGE estava exportado quando os testes rodaram?\n")
  process.exit(1)
}

const soComentario = (l) => {
  const t = l.trim()
  return t === "" || t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")
}

const pct = (a, b) => (b ? `${((a / b) * 100).toFixed(1).padStart(5)}%` : "   n/a")

console.log("arquivo                    linhas com codigo      funcoes")
console.log("─".repeat(62))

let totalL = 0, cobL = 0, totalF = 0, cobF = 0
const lacunas = []

for (const [url, execucoes] of [...porArquivo].sort()) {
  const caminho = fileURLToPath(url)
  const fonte = readFileSync(caminho, "utf8")
  const nome = caminho.split("/").slice(-2).join("/")

  // conhecido[i]: o byte está dentro de alguma função. contagem[i]: maior count
  // visto entre os processos — um caminho exercitado por QUALQUER teste conta.
  const conhecido = new Uint8Array(fonte.length)
  const contagem = new Int32Array(fonte.length)

  for (const funcs of execucoes) {
    const ranges = funcs.flatMap((fn) => fn.ranges)
    // Externo primeiro, interno depois: o mais interno sobrescreve o pai.
    ranges.sort((a, b) => a.startOffset - b.startOffset || b.endOffset - a.endOffset)

    const local = new Int32Array(fonte.length).fill(-1)
    for (const r of ranges) {
      for (let i = r.startOffset; i < Math.min(r.endOffset, fonte.length); i++) local[i] = r.count
    }
    for (let i = 0; i < fonte.length; i++) {
      if (local[i] < 0) continue
      conhecido[i] = 1
      if (local[i] > contagem[i]) contagem[i] = local[i]
    }
  }

  // Função coberta = o corpo rodou em algum processo.
  const corpos = new Map()
  for (const funcs of execucoes) {
    for (const fn of funcs) {
      const k = `${fn.ranges[0].startOffset}:${fn.ranges[0].endOffset}`
      corpos.set(k, Math.max(corpos.get(k) ?? 0, fn.ranges[0].count))
    }
  }
  const fTot = corpos.size
  const fCob = [...corpos.values()].filter((c) => c > 0).length

  let offset = 0, lTot = 0, lCob = 0
  const semCobertura = []

  for (const [n, linha] of fonte.split("\n").entries()) {
    const ini = offset
    const fim = offset + linha.length
    offset = fim + 1

    if (soComentario(linha)) continue

    let temCodigo = false
    let rodou = false
    for (let i = ini; i < fim; i++) {
      if (!conhecido[i] || /\s/.test(fonte[i])) continue
      temCodigo = true
      if (contagem[i] > 0) {
        rodou = true
        break
      }
    }
    if (!temCodigo) continue

    lTot++
    if (rodou) lCob++
    else semCobertura.push(n + 1)
  }

  totalL += lTot
  cobL += lCob
  totalF += fTot
  cobF += fCob

  console.log(
    `${nome.padEnd(25)} ${pct(lCob, lTot)} (${String(lCob).padStart(3)}/${String(lTot).padStart(3)})` +
      `      ${pct(fCob, fTot)} (${fCob}/${fTot})`,
  )
  if (semCobertura.length) lacunas.push(`  ${nome}: ${faixas(semCobertura)}`)
}

/** 1,2,3,7,8 -> "1-3, 7-8". Uma lista crua de 60 números não se lê. */
function faixas(ns) {
  const saida = []
  let ini = ns[0]
  let ant = ns[0]
  for (const n of ns.slice(1)) {
    if (n === ant + 1) {
      ant = n
      continue
    }
    saida.push(ini === ant ? `${ini}` : `${ini}-${ant}`)
    ini = ant = n
  }
  saida.push(ini === ant ? `${ini}` : `${ini}-${ant}`)
  return saida.join(", ")
}

console.log("─".repeat(62))
console.log(
  `${"TOTAL".padEnd(25)} ${pct(cobL, totalL)} (${cobL}/${totalL})` +
    `      ${pct(cobF, totalF)} (${cobF}/${totalF})`,
)

if (lacunas.length) console.log("\nlinhas nunca executadas:\n" + lacunas.join("\n"))

// Sai 0 mesmo com cobertura baixa, de propósito: isto é um relatório, não um
// portão. Um número de cobertura como critério de aprovação produz teste escrito
// para o número — e as lacunas que este relatório apontou até agora eram todas
// caminhos de erro que valem uma decisão humana, não um teste automático de
// fachada.
