/**
 * Envelope de saída compartilhado pelos adaptadores de bin/.
 *
 * Sucesso em stdout, erro em stderr, os dois em JSON, exit code não-zero em
 * qualquer falha. É contrato, não estilo: um adaptador com formato próprio
 * faria o modelo ver dois contratos de erro onde a doc promete um.
 */

// Payload de sucesso. Encerra o processo com 0.
export function ok(payload) {
  process.stdout.write(JSON.stringify(payload, null, 2) + "\n")
  process.exit(0)
}

/**
 * Erro no formato do contrato. Encerra o processo com 1.
 *
 * Sempre em stderr: um adaptador chamado dentro de uma substituição de
 * comando capturaria o erro em stdout na variável, em vez de vê-lo.
 */
export function die(code, message, extra = {}) {
  const body = { error: { code, message, retryable: false, ...extra } }
  process.stderr.write(JSON.stringify(body, null, 2) + "\n")
  process.exit(1)
}
