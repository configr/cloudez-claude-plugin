#!/usr/bin/env node
// Barreira contra escrita em aplicação viva.
//
// Rodado pelo harness como hook `PreToolUse`, antes de a tool executar.
// Recebe a chamada em JSON pelo stdin e decide pelo código de saída: 0
// deixa passar, 2 bloqueia e devolve o stderr ao modelo como motivo.
//
// Existe por dois incidentes reais (um recado de teste gravado num mural
// público, um PNG num site de uploads), nenhum por desobediência a uma
// regra escrita: nos dois casos a escrita parecia parte do pedido. Por isso
// o hook não interpreta a intenção, só vê verbo de escrita para host remoto
// e barra.
//
// A aprovação exige terminal pelo mesmo motivo que o `cloudez-login`
// interativo falha com `no_tty` pela tool Bash: sem terminal de controle,
// "aprovado" significaria "o modelo decidiu por si".
//
// Fecha só as vias enumeráveis (`curl`, `wget` pela tool Bash), não
// `python -c "requests.post(...)"` nem a tool de outro MCP.

import { mkdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

import { escritaRemota, hash } from "./_guard.mjs"

/** Minutos de validade. Curto porque a aprovação vale para UM comando. */
export const TTL_MIN = 10

/**
 * Onde ficam o pedido e a aprovação. `CLOUDEZ_GUARD_DIR` isola a suíte do
 * `~/.cloudez` real, como `CLOUDEZ_TOKEN_FILE` faz para o token.
 */
const DIR = process.env.CLOUDEZ_GUARD_DIR || join(homedir(), ".cloudez")
const PENDENTE = join(DIR, "pending-write.json")
const APROVADO = join(DIR, "approved-write.json")

const chamada = interpretar(await lerStdin())
const comando = chamada?.tool_input?.command

// Só a tool Bash; as demais não passam por aqui.
if (chamada?.tool_name !== "Bash" || typeof comando !== "string") process.exit(0)

const alvos = escritaRemota(comando)
if (alvos.length === 0) process.exit(0)

const digest = hash(comando)

if (aprovado(digest)) {
  // Uso único: some ao ser usada, senão "por comando" viraria "por TTL".
  try {
    unlinkSync(APROVADO)
  } catch {}
  process.exit(0)
}

registrarPendente(comando, digest, alvos)
process.stderr.write(motivo(alvos))
process.exit(2)

export function motivo(alvos) {
  return (
    `Bloqueado: isto ESCREVE numa aplicação remota (${alvos.join(", ")}).\n\n` +
    "Escrever em aplicação viva para verificar que algo funciona já deixou um\n" +
    "recado de teste num mural público e uma imagem num site de uploads. A\n" +
    "verificação por leitura (GET/HEAD) continua liberada, e localhost também.\n\n" +
    "Se a escrita for mesmo necessária, quem libera é o usuário, no terminal dele:\n\n" +
    "    cloudez-approve\n\n" +
    `A aprovação vale para este comando exato, uma vez só, por ${TTL_MIN} minutos.\n` +
    "NÃO tente emitir você mesmo: o comando exige terminal e falha sem ele — é\n" +
    "isso que faz a aprovação significar 'um humano decidiu'.\n"
  )
}

function interpretar(txt) {
  try {
    return JSON.parse(txt)
  } catch {
    // Entrada que não entendo não é motivo para travar a sessão inteira.
    return null
  }
}

function aprovado(digest) {
  let a
  try {
    a = JSON.parse(readFileSync(APROVADO, "utf8"))
  } catch {
    return false
  }
  if (a?.hash !== digest) return false
  return (Date.now() - Number(a.at || 0)) / 60000 < TTL_MIN
}

/**
 * Deixa o comando bloqueado em disco para o `cloudez-approve` exibi-lo, em
 * vez de o usuário redigitar um comando que pode aprovar diferente do real.
 */
function registrarPendente(cmd, digest, alvos) {
  try {
    mkdirSync(DIR, { recursive: true, mode: 0o700 })
    writeFileSync(PENDENTE, JSON.stringify({ command: cmd, hash: digest, hosts: alvos, at: Date.now() }, null, 2), {
      mode: 0o600,
    })
  } catch {
    // Não conseguir registrar não muda a decisão: o bloqueio vale assim mesmo.
  }
}

function lerStdin() {
  return new Promise((resolve) => {
    let s = ""
    process.stdin.setEncoding("utf8")
    process.stdin.on("data", (d) => (s += d))
    process.stdin.on("end", () => resolve(s))
    process.stdin.on("error", () => resolve(""))
  })
}
