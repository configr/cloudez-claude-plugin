/**
 * Handshake MCP minimo: sobe o servidor, pede as tools, imprime os nomes.
 *
 * Uso: mcp-handshake.mjs <bundle> [tool]
 *
 * Sem `tool`, imprime os nomes das tools anunciadas. Com `tool`, chama-a sem
 * argumentos e imprime o resultado, para afirmar sobre o comportamento do
 * bundle vendorizado, nao so sobre ele subir.
 *
 * Fora do bats: ele nao lida bem com processo de vida longa e stdin
 * bidirecional, e aqui se afirma sobre o protocolo, nao sobre um arquivo.
 */
import { spawn } from "node:child_process"

const bundle = process.argv[2]
const tool = process.argv[3]
const child = spawn("node", [bundle], { stdio: ["pipe", "pipe", "ignore"] })

const send = (msg) => child.stdin.write(JSON.stringify(msg) + "\n")
let buf = ""

child.stdout.on("data", (chunk) => {
  buf += chunk
  const linhas = buf.split("\n")
  buf = linhas.pop() ?? ""
  for (const linha of linhas) {
    if (!linha.trim()) continue
    const msg = JSON.parse(linha)
    if (msg.id === 1) {
      send({ jsonrpc: "2.0", method: "notifications/initialized" })
      send({ jsonrpc: "2.0", id: 2, method: "tools/list" })
    }
    if (msg.id === 2) {
      if (!tool) {
        console.log(msg.result.tools.map((t) => t.name).join(" "))
        child.kill()
        process.exit(0)
      }
      send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: tool, arguments: {} } })
    }
    if (msg.id === 3) {
      console.log(JSON.stringify(msg.result.structuredContent ?? msg.result, null, 2))
      child.kill()
      process.exit(0)
    }
  }
})

send({
  jsonrpc: "2.0", id: 1, method: "initialize",
  params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "bats", version: "1" } },
})

setTimeout(() => { console.error("timeout no handshake"); process.exit(1) }, 15000)
