// O identificador de CONTEÚDO do que um deploy publica.
//
// Existe porque o commit do git não serve para isso, por duas razões em ordem de
// importância: nem todo diretório publicado vive num repositório, e mesmo quando
// vive, o sha descreve o FONTE. No caminho sem container o que se publica é a
// saída do build (`dist/`), que o commit não fixa — o mesmo commit com outra
// versão do Node produz bytes diferentes e release_id idêntico.
//
// O contrato que importa: este hash cobre EXATAMENTE o conjunto de bytes que o
// transfer envia. Se os dois divergirem o identificador mente, o que é pior do
// que não ter identificador. Por isso a exclusão do `.git` está escrita aqui com
// a mesma semântica não-ancorada do tar, e não como um filtro aproximado.
//
// Este arquivo é o port do `internal/cloudez/payload.go`. O formato do hash é
// contrato ENTRE PLATAFORMAS e entre versões do plugin: mudá-lo faz o mesmo
// conteúdo virar releases diferentes. O `test/payload.test.mjs` fixa o valor de
// uma árvore conhecida justamente para que a mudança não passe calada.

import { createHash } from "node:crypto"
import { closeSync, fstatSync, lstatSync, openSync, readdirSync, readlinkSync, readSync } from "node:fs"
import { join, sep } from "node:path"

/**
 * Resume o que seria enviado: sha do conteúdo, número de arquivos e bytes.
 *
 * O que entra no hash, e por quê:
 *
 *   - o caminho relativo, sempre com barra normal. Sem normalizar, o mesmo
 *     projeto hasheado no Windows e no macOS daria resultados diferentes e o
 *     identificador deixaria de ser comparável entre máquinas.
 *   - o bit de execução, e só ele. Permissão de executável muda o comportamento
 *     do que está no ar — um entrypoint que perde o +x quebra o container — e
 *     precisa contar. O resto do modo (dono, grupo, umask de quem clonou) varia
 *     por máquina sem que o conteúdo mude.
 *   - o conteúdo do arquivo, ou o ALVO do symlink quando for um. O tar preserva
 *     symlinks em vez de segui-los, então seguir aqui hashearia bytes que nunca
 *     viajam — e um link quebrado, que o tar transporta sem reclamar, viraria
 *     erro de deploy.
 *
 * O que NÃO entra: mtime, dono e grupo. Todos mudam a cada clone do repositório
 * sem que uma linha do projeto tenha mudado, e fariam o hash de um mesmo
 * conteúdo diferir entre a máquina do desenvolvedor e o CI.
 *
 * Diretórios vazios são ignorados, acompanhando o tar, que os transporta mas não
 * os distingue de ausência depois de extraídos num diretório de release.
 */
export function hashPayload(localDir) {
  const entries = payloadEntries(localDir)

  const sum = createHash("sha256")
  let total = 0

  // Buffer reusado em vez de ler o arquivo inteiro na memória: o diretório
  // publicado pode ser o contexto de build de um container, e ele não tem
  // tamanho previsível.
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

  return { content_sha256: sum.digest("hex"), files: entries.length, bytes: total }
}

/**
 * O cabeçalho por arquivo. Termina em NUL e carrega o tamanho.
 *
 * Sem um separador que não pode aparecer num caminho, "ab" + "c" e "a" + "bc"
 * hasheariam igual e dois conjuntos de arquivos distintos colidiriam. O tamanho
 * fecha a outra metade: sem ele, o nome de um arquivo poderia invadir o conteúdo
 * do vizinho.
 */
function cabecalho(tipo, rel, exe, tamanho) {
  return `${tipo} ${rel} ${exe} ${tamanho}\0`
}

/** Barra normal em qualquer plataforma — o `filepath.ToSlash` do Go. */
function toSlash(p) {
  return sep === "/" ? p : p.split(sep).join("/")
}

/**
 * Lista, em ordem estável, os arquivos que seriam enviados.
 *
 * Separada do hash para que o teste possa comparar este conjunto com o que o
 * `tar` do transfer de fato empacota — a duplicação da regra de exclusão só é
 * segura enquanto alguém verifica que as duas concordam.
 */
export function payloadEntries(localDir) {
  const entries = []

  const caminhar = (dir, prefixo) => {
    for (const d of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, d.name)
      const rel = prefixo === "" ? d.name : `${prefixo}/${d.name}`

      // Um diretório excluído não é percorrido, então testar o rel completo a
      // cada nível dá o mesmo resultado que testá-lo uma vez no fim — mas mantém
      // a regra numa função com nome, que dá para testar direto.
      if (excluidoDoPayload(rel)) continue

      // `isDirectory` aqui NÃO segue symlink, igual ao WalkDir do Go: um link
      // para diretório é uma entrada, não uma árvore a percorrer.
      if (d.isDirectory()) {
        caminhar(path, rel)
        continue
      }

      const st = lstatSync(path)
      entries.push({ rel, path, mode: st.mode, symlink: st.isSymbolicLink() })
    }
  }

  caminhar(localDir, "")

  // A ordem da caminhada depende do sistema de arquivos. Sem ordenar, o mesmo
  // diretório daria hashes diferentes em máquinas diferentes.
  //
  // A comparação é por BYTES de UTF-8, e não a de `String.prototype.sort`, que
  // ordena por unidade de código UTF-16. As duas divergem acima do BMP (emoji num
  // nome de arquivo, por exemplo), e o Go ordena por byte — divergir aqui faria o
  // mesmo conteúdo hashear diferente entre este port e as releases já publicadas.
  entries.sort((a, b) => Buffer.compare(Buffer.from(a.rel, "utf8"), Buffer.from(b.rel, "utf8")))
  return entries
}

/**
 * Reproduz o `--exclude .git` do tar do transfer.
 *
 * A semântica é a NÃO-ancorada dos dois tar: o padrão é o nome puro, então casa
 * `./.git` e também o `.git` de um submódulo em qualquer profundidade, e não casa
 * `.gitignore` nem `.github/` — que precisam sobreviver até o servidor. Comparar
 * por prefixo comeria os dois.
 */
export function excluidoDoPayload(rel) {
  return toSlash(rel).split("/").includes(".git")
}
