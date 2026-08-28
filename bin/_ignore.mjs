// O que o deploy não publica, lido do projeto: `.gitignore` primeiro,
// `.cloudezignore` depois. O último padrão que casa decide, como no git, e é
// por isso que o `.cloudezignore` consegue desfazer com `!` uma regra do
// `.gitignore`.
//
// O `.dockerignore` não é lido de propósito: ali é correto excluir o
// Dockerfile e o compose, mas o deploy publica o diretório para construir
// depois, no servidor, e respeitar essa regra quebraria todo site em
// container. Quem quiser as mesmas regras aqui copia para um
// `.cloudezignore`.
//
// Só os arquivos da raiz do diretório publicado são lidos; um `.gitignore`
// dentro de um subdiretório não vale aqui, diferente do git.

import { readFileSync } from "node:fs"
import { join } from "node:path"

/** Na ordem de leitura: o último a casar vence, então o de baixo desempata. */
export const FONTES_IGNORE = [".gitignore", ".cloudezignore"]

/**
 * Compila uma linha de padrão. Devolve `null` para o que não é regra.
 *
 * Suporta o subconjunto que resolve o problema real: comentário, negação com `!`,
 * âncora com `/`, diretório com `/` no fim, e os curingas `*`, `?` e `**`.
 */
function compilar(linha) {
  // Espaço no fim é ruído de edição, e o git também o descarta. O escape com
  // barra invertida não é tratado: nome de arquivo terminado em espaço é raro o
  // bastante para não pagar a complexidade.
  let p = linha.replace(/\s+$/, "")
  if (p === "" || p.startsWith("#")) return null

  let negado = false
  if (p.startsWith("!")) {
    negado = true
    p = p.slice(1)
  }

  let soDiretorio = false
  if (p.endsWith("/")) {
    soDiretorio = true
    p = p.slice(0, -1)
  }

  let ancorado = false
  if (p.startsWith("/")) {
    ancorado = true
    p = p.slice(1)
  }
  if (p === "") return null

  // Barra no meio também ancora, e a do fim não: é a regra do git. `docs/build`
  // vale só na raiz; `build/` vale em qualquer nível.
  if (p.includes("/")) ancorado = true

  const partes = p.split("/").map((seg) => (seg === "**" ? null : segmentoParaRegex(seg)))

  let corpo = ""
  for (let i = 0; i < partes.length; i++) {
    const ultimo = i === partes.length - 1
    if (partes[i] === null) {
      // `**` no fim cobre a sub-árvore inteira; no meio, zero ou mais níveis.
      corpo += ultimo ? ".*" : "(?:[^/]+/)*"
      continue
    }
    corpo += ultimo ? partes[i] : `${partes[i]}/`
  }

  // Sem âncora o padrão vale em qualquer profundidade: é o que faz `node_modules`
  // pegar também `pacotes/x/node_modules`.
  const re = new RegExp(ancorado ? `^${corpo}$` : `^(?:.*/)?${corpo}$`)
  return { re, negado, soDiretorio }
}

/** `*` e `?` não atravessam barra; o resto é literal. */
function segmentoParaRegex(seg) {
  let out = ""
  for (const c of seg) {
    if (c === "*") out += "[^/]*"
    else if (c === "?") out += "[^/]"
    else out += c.replace(/[.+^${}()|[\]\\]/g, "\\$&")
  }
  return out
}

/**
 * Lê os arquivos de padrão de `dir` e devolve o que decide se um caminho entra.
 *
 * `fontes` diz quais existiam: o `--hash-only` o reporta, para o usuário
 * explicar por que a contagem de arquivos caiu.
 */
export function carregarIgnore(dir) {
  const regras = []
  const fontes = []

  for (const nome of FONTES_IGNORE) {
    let texto
    try {
      texto = readFileSync(join(dir, nome), "utf8")
    } catch {
      continue // Ausente é o caso comum, e não é erro.
    }
    fontes.push(nome)
    for (const linha of texto.split(/\r?\n/)) {
      const regra = compilar(linha)
      if (regra) regras.push(regra)
    }
  }

  return {
    fontes,
    vazio: regras.length === 0,
    /**
     * O último padrão que casa decide. Um caminho dentro de diretório
     * excluído nunca chega aqui, pois quem caminha a árvore não desce nele:
     * é também a regra do git, onde negação não reabilita esse caso.
     */
    excluir(rel, ehDiretorio) {
      let excluido = false
      for (const r of regras) {
        if (r.soDiretorio && !ehDiretorio) continue
        if (r.re.test(rel)) excluido = !r.negado
      }
      return excluido
    },
  }
}
