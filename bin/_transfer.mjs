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

/**
 * Envia o conteúdo de `localDir` para o destino ssh gravado no estado do deploy.
 *
 * Devolve `{ stats, logs, erro }`. `erro` nulo é sucesso; `logs` é a stderr
 * agregada dos dois processos, e vem preenchida também no sucesso (o ssh emite
 * aviso de host novo na primeira conexão, que não é falha).
 */
export function transferir(dep, localDir) {
  // "-C dir ." envia o CONTEÚDO do diretório, não o diretório. É o mesmo motivo
  // da barra final no rsync: sem isso o site sobe aninhado um nível.
  //
  // --exclude=.git existe porque o diretório publicado deixou de ser sempre um
  // build: numa aplicação em container o que se envia é o contexto de build, e
  // ele costuma ser a raiz do repositório — onde moram o Dockerfile e o compose.
  // Sem a exclusão, todo deploy carregaria o histórico inteiro do git pela rede,
  // e ele não serve para nada dentro de uma imagem.
  //
  // O padrão é o nome puro, sem barra: os dois tar tratam exclusão como
  // NÃO-ancorada por padrão, então `.git` casa tanto `./.git` quanto o `.git` de
  // um submódulo, e NÃO casa `.gitignore` nem `.github/` — que precisam
  // sobreviver. Uma exclusão por prefixo comeria os dois.
  //
  // --exclude vem antes de `-C`: o bsdtar exige que a opção preceda os caminhos
  // a que se aplica.
  const tarArgs = ["-czf", "-", "--exclude", ".git", "-C", localDir, "."]

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
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, COPYFILE_DISABLE: "1" },
  })

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

    return { stats: `tar+ssh -> ${dep.ssh.host}:${dep.ssh.path}`, logs, erro: null }
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
