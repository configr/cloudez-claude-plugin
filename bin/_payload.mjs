/**
 * Identificador de conteúdo do que um deploy publica.
 *
 * Não é o commit do git: nem todo diretório publicado é um repositório, e
 * mesmo quando é, o commit descreve o fonte, não a saída do build publicada.
 *
 * O hash precisa cobrir exatamente o que o transfer envia; se divergirem, o
 * identificador mente. O formato é contrato entre plataformas e versões do
 * plugin: test/payload.test.mjs fixa o valor de uma árvore conhecida para que
 * uma mudança não passe despercebida.
 */

import { createHash } from "node:crypto"
import { closeSync, fstatSync, lstatSync, openSync, readdirSync, readlinkSync, readSync } from "node:fs"
import { join, sep } from "node:path"

import { carregarIgnore } from "./_ignore.mjs"

/**
 * Resume o que seria enviado: sha do conteúdo, número de arquivos e bytes.
 *
 * Entram no hash: o caminho relativo com barra normal (comparável entre
 * Windows e macOS), o bit de execução (o resto do modo varia por máquina sem
 * o conteúdo mudar), e o conteúdo do arquivo, ou o alvo quando for symlink.
 *
 * Não entram: mtime, dono e grupo, que mudam a cada clone sem o projeto
 * mudar. Diretório vazio é ignorado, como o tar já faz.
 */
export function hashPayload(localDir) {
  const { entries, ignore } = listarPayload(localDir)

  const sum = createHash("sha256")
  let total = 0

  /**
   * Buffer reusado: o diretório publicado pode ser um contexto de build
   * grande, sem tamanho previsível para caber inteiro na memória.
   */
  const buf = Buffer.allocUnsafe(64 * 1024)

  for (const e of entries) {
    const exe = (e.mode & 0o111) !== 0 ? "1" : "0"

    if (e.symlink) {
      const body = Buffer.from(toSlash(readlinkSync(e.path)), "utf8")
      sum.update(cabecalho("l", e.rel, exe, body.length))
      sum.update(body)
      total += body.length
      continue
    }

    const fd = openSync(e.path, "r")
    try {
      sum.update(cabecalho("f", e.rel, exe, fstatSync(fd).size))
      let n
      while ((n = readSync(fd, buf, 0, buf.length, null)) > 0) {
        sum.update(buf.subarray(0, n))
        total += n
      }
    } finally {
      closeSync(fd)
    }
  }

  return {
    content_sha256: sum.digest("hex"),
    files: entries.length,
    bytes: total,
    /**
     * Só quando houve o que reportar, para um projeto sem arquivo de padrão
     * continuar com o retorno de sempre.
     */
    ...(ignore.sources.length > 0 ? { ignored: ignore } : {}),
  }
}

/**
 * Cabeçalho por arquivo, terminado em NUL e com o tamanho.
 *
 * Sem um separador fixo, "ab"+"c" e "a"+"bc" hasheariam igual. O tamanho evita
 * que o nome de um arquivo invada o conteúdo do vizinho.
 */
function cabecalho(tipo, rel, exe, tamanho) {
  return `${tipo} ${rel} ${exe} ${tamanho}\0`
}

/**
 * Nomes que a lista enviada ao tar não sabe representar.
 *
 * A lista vai por stdin separada por quebra de linha, não por NUL: o busybox
 * (o tar de qualquer imagem Alpine) não conhece `--null`. O preço são três
 * caracteres: `\n` e `\r` partem a lista em dois nomes, e a barra invertida é
 * escape para o GNU tar sem `--null`. Espaço e aspas passam ilesos.
 *
 * Recusa em vez de pular: um arquivo que não vai junto produziria uma release
 * incompleta com identificador de aparência normal.
 */
const NOME_INTRANSPORTAVEL = /[\n\r\\]/

// Barra normal em qualquer plataforma: o `filepath.ToSlash` do Go.
function toSlash(p) {
  return sep === "/" ? p : p.split(sep).join("/")
}

// Compatibilidade: a lista, sem os metadados de exclusão.
export function payloadEntries(localDir) {
  return listarPayload(localDir).entries
}

/**
 * Lista, em ordem estável, os arquivos que seriam enviados, e o que ficou de
 * fora.
 *
 * É a mesma lista que `_transfer.mjs` passa ao tar por `-T -`, em vez de
 * repetir a exclusão em `--exclude`: as duas nunca divergem.
 */
export function listarPayload(localDir) {
  const ignore = carregarIgnore(localDir)
  const entries = []
  const podados = []
  const impossiveis = []

  const caminhar = (dir, prefixo) => {
    for (const d of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, d.name)
      const rel = prefixo === "" ? d.name : `${prefixo}/${d.name}`

      /**
       * Testado a cada nível, e não só no fim, para ficar numa função nomeada
       * e testável em vez de espalhado pela caminhada.
       */
      if (excluidoDoPayload(rel)) continue

      /**
       * Não descer no excluído é o que torna isto barato (node_modules custa
       * uma comparação, não 38 mil arquivos), e replica a regra do git:
       * negação não reabilita arquivo sob diretório excluído.
       */
      if (!ignore.vazio && ignore.excluir(rel, d.isDirectory())) {
        podados.push(rel)
        continue
      }

      /**
       * isDirectory não segue symlink, como o WalkDir do Go: um link para
       * diretório é uma entrada, não uma árvore a percorrer.
       */
      if (d.isDirectory()) {
        caminhar(path, rel)
        continue
      }

      const st = lstatSync(path)
      if (NOME_INTRANSPORTAVEL.test(rel)) impossiveis.push(rel)
      entries.push({ rel, path, mode: st.mode, symlink: st.isSymbolicLink() })
    }
  }

  caminhar(localDir, "")

  /**
   * A ordem da caminhada depende do sistema de arquivos; sem ordenar, o
   * mesmo diretório daria hashes diferentes em máquinas diferentes. A
   * comparação é por bytes UTF-8, não por String.sort (UTF-16): as duas
   * divergem acima do BMP, e divergir mudaria o hash entre plataformas.
   */
  entries.sort((a, b) => Buffer.compare(Buffer.from(a.rel, "utf8"), Buffer.from(b.rel, "utf8")))
  podados.sort()

  // Recusa em vez de publicar sem esses arquivos com um hash de aparência normal. Ver NOME_INTRANSPORTAVEL.
  if (impossiveis.length > 0) {
    const erro = new Error(
      `Nome de arquivo que o transporte não sabe carregar: ${impossiveis.sort().slice(0, 10).join(", ")}. ` +
        "A lista de arquivos vai para o tar separada por quebra de linha, e ele interpreta a barra invertida " +
        "como escape: um nome com \\n, \\r ou \\ não chega do outro lado. Renomeie os arquivos.",
    )
    erro.code = "filename_unsupported"
    throw erro
  }

  return {
    entries,
    ignore: {
      sources: ignore.fontes,
      pruned: podados.length,
      /**
       * Caminhos podados, não os arquivos dentro: node_modules conta um, não
       * 38 mil. Limitado porque isto vai num JSON legível.
       */
      paths: podados.slice(0, 50),
    },
  }
}

/**
 * Reproduz o `--exclude .git` do tar: nome puro, não ancorado, então casa
 * `.git` em qualquer profundidade sem casar `.gitignore` nem `.github/`.
 */
export function excluidoDoPayload(rel) {
  return toSlash(rel).split("/").includes(".git")
}
