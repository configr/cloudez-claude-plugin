// O envelope de saída dos adaptadores.
//
// Sucesso vai para stdout, erro vai para stderr, JSON nos dois, exit code
// não-zero em qualquer falha. Isso é contrato, não estilo: o consumidor destes
// scripts é um modelo, e um formato só é o que ele aprende uma vez.
//
// Vale a pena ser um arquivo compartilhado, e não uma cópia em cada adaptador,
// por causa do que aconteceria com as cópias: elas divergiriam no formato do
// erro, e o modelo passaria a ver dois contratos onde a doc promete um. É a
// mesma razão que tirou o contrato do token do plugin — só que aqui o dono do
// contrato é o plugin, e não o MCP.
//
// O que este arquivo NÃO é: o `bin/_json.mjs` que existiu aqui. Aquele construía
// um objeto a partir de pares na linha de comando, com prefixos `:` e `+` para
// tipos e merge — uma minilinguagem que só fazia sentido porque quem a chamava
// era um shell. Com os adaptadores em Node, o objeto é escrito como objeto.

/** Payload de sucesso. Encerra o processo com 0. */
export function ok(payload) {
  process.stdout.write(JSON.stringify(payload, null, 2) + "\n")
  process.exit(0)
}

/**
 * Erro no formato do contrato. Encerra o processo com 1.
 *
 * Em stderr, não em stdout: stdout fica reservado para o payload de sucesso, e
 * quem chama um adaptador dentro de uma substituição de comando capturaria o
 * erro na variável em vez de vê-lo. Já houve regressão exatamente assim.
 */
export function die(code, message, extra = {}) {
  const body = { error: { code, message, retryable: false, ...extra } }
  process.stderr.write(JSON.stringify(body, null, 2) + "\n")
  process.exit(1)
}
