// O transporte: `tar` local em stream para `tar` remoto, através de `ssh`.
//
// Três razões para não ser rsync, e elas continuam valendo:
//
//   - rsync não existe no Windows; tar e ssh existem nativamente nas três
//     plataformas (Windows 10 1803+ traz bsdtar, 1809+ traz OpenSSH).
//   - o diretório de release está sempre vazio, então o delta transfer do rsync
//     não tem contra o que comparar — pagaríamos o protocolo dele à toa.
//   - um stream único é mais rápido que os round-trips por arquivo do scp.
//
// O pipe entre os dois processos é montado por descritor, sem passar por shell.
// Isso não é detalhe: o pipeline do PowerShell é orientado a texto e corromperia
// o .tar.gz no meio do caminho. Em Node isso significa passar `tar.stdout` no
// `stdio` do ssh — o descritor é duplicado para o filho — e NUNCA
// `tar.stdout.pipe(ssh.stdin)`, que rotearia cada byte pelo event loop do
// JavaScript. Ver o comentário do `esperar` sobre por que o pai não lê.

import { spawn } from "node:child_process"

import { listarPayload } from "./_payload.mjs"

/**
 * Envia o conteúdo de `localDir` para o destino ssh gravado no estado do deploy.
 *
 * Devolve `{ stats, logs, erro }`. `erro` nulo é sucesso; `logs` é a stderr
 * agregada dos dois processos, e vem preenchida também no sucesso (o ssh emite
 * aviso de host novo na primeira conexão, que não é falha).
 */
export function transferir(dep, localDir) {
  // A LISTA vai por stdin, em vez de `--exclude` e um `.` no fim.
  //
  // A razão é o `.gitignore`. Enquanto a única exclusão era `.git`, a regra cabia
  // num `--exclude` e o hash a repetia numa função — com um teste impedindo as
  // duas de divergirem. Com padrão de usuário no meio isso deixa de ser viável:
  // a semântica do gitignore (âncora, negação, `**`, diretório com barra) não tem
  // tradução fiel para `--exclude`, e cada divergência seria um `release_id` que
  // descreve um conjunto de bytes diferente do que subiu.
  //
  // Passando a lista, o conjunto é o MESMO objeto que o hash percorre — não há
  // duas regras para concordar.
  //
  // Separador é a QUEBRA DE LINHA, não o NUL. O `--null` seria mais seguro para
  // nome de arquivo esquisito, mas o busybox não o conhece — e busybox é o tar de
  // qualquer imagem Alpine, base comum de CI para projeto Node. Os nomes que a
  // quebra de linha não sabe carregar são RECUSADOS lá no `_payload.mjs`, em vez
  // de transportados errado.
  //
  // A ORDEM não é estética: `-C` vem ANTES de `-T`, e inverter quebra em Linux.
  // No GNU tar o `-C` é POSICIONAL — vale só para os caminhos que aparecem depois
  // dele —, e como os nomes entram pelo `-T`, um `-C` no fim não os alcança: o tar
  // procura cada arquivo no diretório errado e produz um pacote VAZIO, avisando
  // apenas que "these options are positional". O bsdtar aceita as duas ordens, o
  // que faz o defeito passar despercebido em macOS e explodir no servidor.
  //
  // Efeito colateral registrado: diretório VAZIO deixa de ser enviado. O tar com
  // `.` os transportava; a lista só tem arquivos. O hash já os ignorava, então o
  // identificador não muda de semântica — e diretório que a aplicação precisa
  // costuma vir de `mkdir` dela ou do `shared/` do deploy.
  const { entries, ignore } = listarPayload(localDir)
  const tarArgs = ["-czf", "-", "-C", localDir, "-T", "-"]

  const remoto = `tar xzf - -C ${aspasParaShellRemoto(dep.ssh.path)}`
  const sshArgs = [
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=accept-new",
    "-p", String(dep.ssh.port),
    `${dep.ssh.user}@${dep.ssh.host}`,
    remoto,
  ]

  // COPYFILE_DISABLE=1 impede o tar do macOS de empacotar os metadados
  // AppleDouble — os arquivos `._index.html`, `._style.css` e um `._.` por
  // diretório. Eles não quebram o site, mas viajam em toda release e sujam o que
  // o usuário vê no servidor.
  //
  // A variável não existe fora do macOS, e um tar que não a conhece a ignora: não
  // há condicional por plataforma aqui de propósito.
  //
  // Vale a ORIGEM e não o destino: excluir no tar remoto exigiria um --exclude
  // que o bsdtar e o GNU tar escrevem diferente, e mandar bytes para depois
  // descartá-los é pior do que não mandar.
  const tar = spawn("tar", tarArgs, {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, COPYFILE_DISABLE: "1" },
  })

  // A lista entra pela stdin do tar. Escrever antes de ligar o ssh não trava: o
  // tar só começa a produzir saída depois de ler os nomes, e o pipe do sistema
  // absorve a lista — que é de nomes, não de conteúdo.
  tar.stdin.on("error", () => {}) // EPIPE quando o tar morre antes de ler tudo.
  tar.stdin.end(entries.map((e) => e.rel).join("\n") + "\n")

  // O `tar.stdout` entra como stdin do ssh: o Node duplica o descritor para o
  // filho, então os bytes vão do tar ao ssh sem passar por aqui.
  //
  // O pai fica com a ponta de LEITURA, e isso é seguro por um motivo assimétrico:
  // EOF num pipe depende de as pontas de ESCRITA fecharem, e a única é a do
  // próprio tar. Fosse o contrário — o pai segurando a escrita — o ssh nunca
  // veria EOF e o comando remoto não terminaria.
  //
  // O que o pai não pode fazer é LER: haveria dois leitores no mesmo pipe e os
  // bytes se dividiriam entre eles, corrompendo o pacote de um jeito que depende
  // de escalonamento. Um Readable de filho nasce pausado, então não lemos por
  // omissão; o `destroy` abaixo torna isso explícito em vez de deixá-lo por
  // conta de um detalhe do runtime.
  const ssh = spawn("ssh", sshArgs, { stdio: [tar.stdout, "pipe", "pipe"] })
  tar.stdout.destroy()

  let tarErr = ""
  let sshErr = ""
  tar.stderr.setEncoding("utf8")
  ssh.stderr.setEncoding("utf8")
  tar.stderr.on("data", (d) => { tarErr += d })
  ssh.stderr.on("data", (d) => { sshErr += d })

  return Promise.all([esperar(tar, "tar"), esperar(ssh, "ssh")]).then(([doTar, doSsh]) => {
    const logs = `${tarErr}\n${sshErr}`.trim()

    // A ordem das duas checagens importa. O caso perigoso do pipe é o tar LOCAL
    // falhar no meio — arquivo ilegível, disco cheio — e o tar remoto extrair o
    // parcial e sair zero: verificando só o ssh, o deploy publicaria uma release
    // incompleta como sucesso. E invertida, uma falha do tar seria reportada com
    // o erro do ssh, e o usuário procuraria problema de rede tendo um de arquivo.
    if (doTar) return { stats: "", logs, erro: doTar }
    if (doSsh) return { stats: "", logs, erro: doSsh }

    const resumo = ignore.sources.length > 0 ? ` (${ignore.sources.join("+")}: ${ignore.pruned} podados)` : ""
    return { stats: `tar+ssh -> ${dep.ssh.host}:${dep.ssh.path}${resumo}`, logs, erro: null }
  })
}

/**
 * Espera um dos dois processos. Resolve com `null` em sucesso, ou com uma mensagem
 * quando o processo falhou ou nem chegou a existir.
 *
 * O `error` cobre o caso de o binário não estar no PATH, que no Node não é um
 * código de saída — é um evento em vez de um `exit`.
 */
function esperar(proc, nome) {
  return new Promise((resolve) => {
    proc.on("error", (e) => resolve(`${nome}: ${e.message}`))
    proc.on("close", (code, signal) => {
      if (signal) return resolve(`${nome}: terminado por ${signal}`)
      resolve(code === 0 ? null : `${nome}: saiu com ${code}`)
    })
  })
}

/**
 * Protege o caminho para o shell REMOTO — o ssh junta os argumentos numa string e
 * quem interpreta é o shell do servidor.
 */
function aspasParaShellRemoto(s) {
  return `'${s.split("'").join(`'\\''`)}'`
}
