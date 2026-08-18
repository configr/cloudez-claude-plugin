// O identificador de conteúdo do payload (bin/_payload.mjs).
//
// Port da suíte que vivia em internal/cloudez/payload_test.go. Roda em
// `node --test`, embutido no Node 20 — o piso que o plugin já declara —, então
// não acrescenta dependência nenhuma à árvore.
//
// Por que não em bats, como o resto: aqui o que se afirma é sobre uma FUNÇÃO, não
// sobre um comando. As propriedades relativas ("mudar X muda o hash") precisam
// hashear duas árvores e comparar, e fazer isso por linha de comando seria
// exercitar o adaptador para testar a biblioteca. O comportamento do
// `cloudez-sync` continua coberto em test/adapters.bats.

import assert from "node:assert/strict"
import { chmodSync, mkdirSync, mkdtempSync, symlinkSync, utimesSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import { spawnSync } from "node:child_process"
import { test } from "node:test"

import { excluidoDoPayload, hashPayload, payloadEntries } from "../bin/_payload.mjs"

const NO_WINDOWS = process.platform === "win32"

/**
 * Monta uma árvore a partir de um mapa caminho->conteúdo. Um caminho terminado em
 * "/" vira diretório vazio.
 */
function escrever(arquivos) {
  const dir = mkdtempSync(join(tmpdir(), "cloudez-payload-"))
  for (const [rel, conteudo] of Object.entries(arquivos)) {
    const full = join(dir, rel)
    if (rel.endsWith("/")) {
      mkdirSync(full, { recursive: true })
      continue
    }
    mkdirSync(dirname(full), { recursive: true })
    writeFileSync(full, conteudo)
  }
  return dir
}

const sha = (dir) => hashPayload(dir).content_sha256

/**
 * O tar REAL, não o mock de test/mocks/. Estes testes afirmam sobre a listagem de
 * um pacote, e o mock não empacota nada — um teste que o usasse passaria vazio.
 */
function tarReal(args, stdin) {
  return spawnSync("tar", args, {
    env: { ...process.env, PATH: "/usr/bin:/bin" },
    input: stdin,
    maxBuffer: 64 * 1024 * 1024,
  })
}

// O contrato central: o hash cobre exatamente o conjunto que o transfer envia. Se
// divergirem, o release_id descreve algo que não foi ao ar — pior do que não ter
// identificador. A regra de exclusão está escrita duas vezes (no
// `excluidoDoPayload` e no tar do transfer) e este teste é o que impede as duas de
// divergirem.
test("o hash cobre o mesmo conjunto que o tar", { skip: NO_WINDOWS && "tar do Windows não confere aqui" }, () => {
  const dir = escrever({
    "index.html": "<h1>oi</h1>",
    ".gitignore": "node_modules\n",
    ".github/workflows/ci": "on: push\n",
    ".git/HEAD": "ref: refs/heads/main\n",
    ".git/objects/ab/cd": "binario",
    "vendor/lib/.git/HEAD": "ref: refs/heads/main\n",
    "vendor/lib/index.js": "module.exports = 1\n",
    "assets/img/logo.svg": "<svg/>",
    "docs/.gitkeep": "",
    "nested/deep/a/b/c.txt": "c",
  })

  // Mesmos argumentos do transfer, menos a compressão: aqui interessa a lista.
  const pacote = tarReal(["-cf", "-", "--exclude", ".git", "-C", dir, "."])
  assert.equal(pacote.status, 0, `tar -c falhou: ${pacote.stderr}`)
  const listagem = tarReal(["-tf", "-"], pacote.stdout)
  assert.equal(listagem.status, 0, `tar -t falhou: ${listagem.stderr}`)

  const doTar = new Set()
  for (const linha of listagem.stdout.toString().trim().split("\n")) {
    const rel = linha.trim().replace(/^\.\//, "")
    // Diretórios saem com barra final; o hash só considera arquivos.
    if (rel === "" || rel === "." || rel.endsWith("/")) continue
    doTar.add(rel)
  }

  const doHash = new Set(payloadEntries(dir).map((e) => e.rel))

  for (const rel of doTar) assert.ok(doHash.has(rel), `o tar envia ${rel}, mas o hash não o cobre`)
  for (const rel of doHash) assert.ok(doTar.has(rel), `o hash cobre ${rel}, mas o tar não o envia`)
  assert.ok(doHash.size > 0, "nenhum arquivo considerado — o teste não verificou nada")
})

// `.gitignore` e `.github/` precisam sobreviver até o servidor: a exclusão é por
// nome puro, não por prefixo. Já o `.git` de um submódulo, em qualquer
// profundidade, cai — porque o padrão do tar não é ancorado na raiz.
test("a exclusão pega .git em qualquer nível, mas não os vizinhos", () => {
  const casos = [
    [".git", true],
    [".git/HEAD", true],
    ["vendor/lib/.git", true],
    ["vendor/lib/.git/objects/ab", true],
    [".gitignore", false],
    [".github", false],
    [".github/workflows/ci.yml", false],
    ["src/.gitkeep", false],
    ["agit/x", false],
    ["x/.gitmodules", false],
  ]
  for (const [rel, excluido] of casos) {
    assert.equal(excluidoDoPayload(rel), excluido, `excluidoDoPayload(${rel})`)
  }
})

// O identificador só serve se a mesma entrada der o mesmo hash em máquinas
// diferentes. A ordem da caminhada depende do sistema de arquivos, então o mesmo
// conteúdo criado em ordem diferente precisa colidir de propósito.
test("mesmo conteúdo, mesmo hash", () => {
  const a = escrever({ "a.txt": "um", "b/c.txt": "dois" })
  const b = escrever({ "b/c.txt": "dois", "a.txt": "um" })
  assert.equal(sha(a), sha(b))
})

// mtime muda a cada clone do repositório sem que uma linha do projeto mude. Se
// entrasse no hash, o CI e a máquina do desenvolvedor nunca concordariam.
test("mtime não entra no hash", () => {
  const dir = escrever({ "a.txt": "um" })
  const antes = sha(dir)

  const passado = new Date(Date.now() - 72 * 60 * 60 * 1000)
  utimesSync(join(dir, "a.txt"), passado, passado)

  assert.equal(sha(dir), antes, "mudar o mtime mudou o hash")
})

// O bit de execução muda o comportamento do que está no ar — um entrypoint que
// perde o +x quebra o container — então precisa contar.
test("o bit de execução entra no hash", { skip: NO_WINDOWS && "modo de arquivo não é comparável no Windows" }, () => {
  const dir = escrever({ "entrypoint.sh": "#!/bin/sh\n" })
  const semExec = sha(dir)

  chmodSync(join(dir, "entrypoint.sh"), 0o755)

  assert.notEqual(sha(dir), semExec, "dar +x não mudou o hash")
})

// Sem um separador que não pode aparecer num caminho, dois conjuntos distintos de
// arquivos concatenariam para os mesmos bytes. O caso clássico: o nome de um
// invade o conteúdo do outro.
test("a fronteira entre nome e conteúdo é respeitada", () => {
  const a = escrever({ ab: "c" })
  const b = escrever({ a: "bc" })
  assert.notEqual(sha(a), sha(b), '{"ab": "c"} e {"a": "bc"} colidiram')
})

test("conteúdo movido entre arquivos muda o hash", () => {
  const a = escrever({ "x.txt": "um", "y.txt": "dois" })
  const b = escrever({ "x.txt": "dois", "y.txt": "um" })
  assert.notEqual(sha(a), sha(b))
})

// O tar preserva symlinks em vez de segui-los. Seguir aqui hashearia bytes que
// nunca viajam, e um link quebrado — que o tar transporta sem reclamar — viraria
// erro de deploy.
test("o symlink é hasheado pelo alvo", { skip: NO_WINDOWS && "symlink exige privilégio no Windows" }, () => {
  const dir = escrever({ "real.txt": "conteudo" })
  symlinkSync("real.txt", join(dir, "link.txt"))
  const comLink = sha(dir)

  // Mesma árvore, mas o link vira arquivo comum com o conteúdo do alvo.
  const copia = escrever({ "real.txt": "conteudo", "link.txt": "conteudo" })
  assert.notEqual(comLink, sha(copia), "o symlink foi seguido: hasheou o conteúdo do alvo")

  // E um link quebrado não pode falhar: o tar o transporta.
  const quebrado = escrever({ "a.txt": "x" })
  symlinkSync("nao-existe.txt", join(quebrado, "orfao"))
  assert.doesNotThrow(() => hashPayload(quebrado), "link quebrado virou erro")
})

// Diretório cujo único conteúdo é `.git` não tem nada publicável. Quem chama
// precisa distinguir isso de um deploy legítimo — é o que o files === 0 permite, e
// o cloudez-sync usa para recusar.
test("só .git não tem arquivo publicável", () => {
  const dir = escrever({ ".git/HEAD": "ref: refs/heads/main\n" })
  assert.equal(hashPayload(dir).files, 0)
})

// files e bytes vão para o usuário junto do sha; se mentirem, mentem numa tela
// onde alguém decide se o deploy parece certo.
test("a contagem e os bytes conferem", () => {
  const dir = escrever({ "a.txt": "12345", "b/c.txt": "678", ".git/x": "ignorado" })
  const h = hashPayload(dir)
  assert.equal(h.files, 2)
  assert.equal(h.bytes, 8)
})

// Âncora entre plataformas. As outras propriedades daqui são relativas ("mudar X
// muda o hash"), e todas continuariam valendo se o Windows produzisse uma família
// de hashes inteiramente diferente da do Linux.
//
// Isso não seria detalhe: o release_id sairia diferente para o mesmo conteúdo
// dependendo de quem publicou, e duas releases idênticas passariam por distintas —
// exatamente o que o identificador existe para evitar.
//
// Este valor é o MESMO que a suíte em Go fixava antes do port. Que ele tenha
// sobrevivido à troca de linguagem é o que garante que nenhuma release já
// publicada mudou de identificador.
test("o hash de uma árvore conhecida não mudou", () => {
  const esperado = "03ff8bfa4d33e6cad50a7101e974ef34d6e8ccd51a77fbaacf97b7355cef01fc"

  const dir = escrever({
    "index.html": "<h1>oi</h1>",
    "assets/logo.svg": "svg",
    ".git/HEAD": "ref: x",
  })

  const h = hashPayload(dir)
  assert.equal(h.files, 2, "o .git tem de ficar de fora")
  assert.equal(h.content_sha256, esperado, "o formato do hash mudou — releases já publicadas mudariam de id")
})

// O prefixo de 7 dígitos é o que vira sufixo do release_id (ver commands/deploy.md).
test("os 7 primeiros dígitos servem de sufixo do release_id", () => {
  const dir = escrever({ "a.txt": "um" })
  const h = hashPayload(dir)
  const curto = h.content_sha256.slice(0, 7)
  assert.equal(curto.length, 7)
  assert.ok(h.content_sha256.startsWith(curto))
})

// Diretórios vazios não contam: o tar os transporta, mas depois de extraídos num
// diretório de release eles não se distinguem de ausência.
test("diretório vazio não muda o hash", () => {
  const sem = escrever({ "a.txt": "um" })
  const com = escrever({ "a.txt": "um", "vazio/": "" })
  assert.equal(sha(sem), sha(com), "um diretório vazio a mais mudou o hash")

  // E a lista precisa continuar estável.
  const nomes = payloadEntries(com).map((e) => e.rel)
  const ordenados = [...nomes].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
  assert.deepEqual(nomes, ordenados, `lista fora de ordem: ${nomes}`)
})
