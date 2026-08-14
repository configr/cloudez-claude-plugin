#!/usr/bin/env node
// Constroi um objeto JSON a partir de pares na linha de comando, e imprime.
//
// Existe para tirar o `jq` da lista de dependencias. Ele estava aqui por uma
// razao boa — `jq -n --arg` escapa corretamente valores vindos do usuario
// (dominio, caminho, mensagem com aspas), e montar JSON com printf sobre entrada
// nao confiavel e como se paga uma injecao — mas o Node ja e dependencia dura do
// plugin por causa do servidor MCP, e o JSON.stringify escapa exatamente igual.
// Uma dependencia a menos pelo mesmo nivel de seguranca.
//
// O `jq` nao estava sendo usado para LER JSON em lugar nenhum: os cinco usos
// construiam. Por isso a substituicao cabe em um helper deste tamanho, e nao
// exige reimplementar nada da linguagem dele.
//
// Uso:
//   _json.mjs chave valor [chave valor ...]
//
// Todo valor entra como string. Para outros tipos, prefixe a CHAVE:
//
//   :chave valor   valor e JSON literal (numero, booleano, objeto, array)
//   +chave valor   valor e um objeto JSON cujas chaves sao mescladas na raiz
//
// O `+` existe para o `die`, onde o chamador passa um objeto de campos extras
// que precisa se fundir com {code, message, retryable} em vez de virar um campo
// aninhado.
//
// Nao ha modo de leitura de stdin de proposito: nada no plugin precisa disso, e
// um helper que so escreve nao tem como ser usado para parsear entrada hostil.

const args = process.argv.slice(2)

if (args.length % 2 !== 0) {
  process.stderr.write("_json: numero impar de argumentos — esperado pares chave/valor\n")
  process.exit(2)
}

const out = {}

for (let i = 0; i < args.length; i += 2) {
  const rawKey = args[i]
  const value = args[i + 1]

  if (rawKey.startsWith(":") || rawKey.startsWith("+")) {
    const key = rawKey.slice(1)
    let parsed
    try {
      // Vazio vira {} no caso `+` e null no caso `:`: o chamador em shell
      // frequentemente passa "$extra" de uma variavel que pode nao ter sido
      // setada, e um erro de parse ali trocaria a mensagem de erro real do
      // usuario por uma falha deste helper.
      parsed = value === "" ? (rawKey[0] === "+" ? {} : null) : JSON.parse(value)
    } catch (err) {
      process.stderr.write(`_json: valor de '${key}' nao e JSON valido: ${err.message}\n`)
      process.exit(2)
    }

    if (rawKey.startsWith("+")) {
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
        process.stderr.write(`_json: '+${key}' exige um objeto JSON\n`)
        process.exit(2)
      }
      Object.assign(out, parsed)
    } else {
      out[key] = parsed
    }
    continue
  }

  out[rawKey] = value
}

process.stdout.write(JSON.stringify(out, null, 2) + "\n")
