// API da Cloudez, falsa, para os testes de autenticacao.
//
// Substitui o antigo `test/mocks/curl`, um shim no PATH. Ele deixou de servir
// quando o `cloudez-login` virou Node e passou a usar `fetch`: nao ha mais
// processo externo para interceptar. Um servidor de verdade em porta efemera
// resolve o mesmo problema — nenhum teste toca a rede — e ainda melhora a
// afirmacao: o que se observa e a REQUISICAO que chegou, e nao os argumentos que
// alguem montou para um comando.
//
// Uso: api-server.mjs <diretorio-de-controle>
//
//   <dir>/status   codigo HTTP a devolver (default 200). Lido a CADA requisicao,
//                  para o teste poder muda-lo depois que o servidor ja subiu.
//   <dir>/port     escrito por este processo quando esta ouvindo. E o sinal de
//                  "pronto" que o bats espera, em vez de dormir um tempo fixo.
//
// O que ele registra no MOCK_LOG e o que os testes precisam afirmar:
//
//   api <metodo> <path>          a rota, para conferir o endpoint
//   Authorization: <valor>       o header cru, para conferir o esquema `Token`
//   token_file_at_call=<...>     o conteudo do arquivo de token NO MOMENTO da
//                                chamada. E o que permite provar que o login
//                                grava ANTES de validar, sem precisar de um pty.

import { createServer } from "node:http"
import { appendFileSync, readFileSync, writeFileSync } from "node:fs"
import { join } from "node:path"

const controle = process.argv[2]
const log = process.env.MOCK_LOG

const registrar = (linha) => {
  if (log) appendFileSync(log, linha + "\n")
}

const ler = (nome, padrao) => {
  try {
    return readFileSync(join(controle, nome), "utf8").trim()
  } catch {
    return padrao
  }
}

const servidor = createServer((req, res) => {
  registrar(`api ${req.method} ${req.url}`)
  registrar(`Authorization: ${req.headers.authorization ?? ""}`)

  const arquivoToken = process.env.CLOUDEZ_TOKEN_FILE
  if (arquivoToken) {
    try {
      registrar(`token_file_at_call=${readFileSync(arquivoToken, "utf8").replace(/[\r\n]/g, "")}`)
    } catch {
      // Sem arquivo: o proprio silencio e a informacao, e ha teste que afirma isso.
    }
  }

  res.writeHead(Number(ler("status", "200")), { "content-type": "application/json" })
  res.end("{}")
})

servidor.listen(0, "127.0.0.1", () => {
  writeFileSync(join(controle, "port"), String(servidor.address().port))
})
