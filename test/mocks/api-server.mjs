// API da Cloudez, falsa, para os testes de autenticacao. Um servidor real em
// porta efemera: nenhum teste toca a rede, e o que se observa e a requisicao
// que chegou, nao os argumentos montados para um comando.
//
// Uso: api-server.mjs <diretorio-de-controle>
//
//   <dir>/status   codigo HTTP a devolver (default 200). Lido a cada
//                  requisicao, para o teste mudar depois que o servidor subiu.
//   <dir>/port     escrito quando o servidor esta ouvindo: o sinal de
//                  "pronto" que o bats espera, em vez de dormir um tempo fixo.
//
// Registrado no MOCK_LOG, para os testes afirmarem:
//
//   api <metodo> <path>          a rota
//   Authorization: <valor>       o header cru, para o esquema `Token`
//   token_file_at_call=<...>     o conteudo do arquivo de token no momento da
//                                chamada, para provar que o login grava antes
//                                de validar, sem precisar de um pty.

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
