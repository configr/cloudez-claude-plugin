#!/usr/bin/env node
/**
 * Extrai um campo de um JSON, no formato do `jq -r`. JSON pelo stdin,
 * caminho no argumento. Existe para tirar o `jq` da suíte.
 *
 * Não é uma reimplementação do jq, e não deve virar uma: aceita caminho com
 * ponto e índice de array, que é tudo o que a suíte usa. Além disso é sinal
 * de que o teste quer afirmar algo mais complicado do que deveria.
 *
 * Saída no formato do `-r`: string crua, sem aspas; null e campo ausente
 * saem como `null`.
 */

const caminho = process.argv[2] ?? "."

const pedacos = []
for await (const p of process.stdin) pedacos.push(p)

let valor
try {
  valor = JSON.parse(Buffer.concat(pedacos).toString("utf8"))
} catch (e) {
  /**
   * Como o jq: erro de parse não vira `null` em stdout. Um teste que compara com
   * "null" tem de falhar aqui, e não passar por acidente.
   */
  process.stderr.write(`json.mjs: entrada não é JSON válido: ${e.message}\n`)
  process.exit(1)
}

// `.a.b`, `.a[0].b`, ou `.` para o valor inteiro.
for (const [, chave, indice] of caminho.matchAll(/\.([A-Za-z_$][\w$]*)|\[(\d+)\]/g)) {
  if (valor === null || typeof valor !== "object") {
    valor = null
    break
  }
  valor = chave !== undefined ? valor[chave] : valor[Number(indice)]
}

if (valor === undefined || valor === null) process.stdout.write("null\n")
else if (typeof valor === "string") process.stdout.write(valor + "\n")
else if (typeof valor === "object") process.stdout.write(JSON.stringify(valor) + "\n")
else process.stdout.write(String(valor) + "\n")
