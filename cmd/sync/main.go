// Command sync envia o build para o diretorio de release criado pelo
// begin-deploy.
//
// Transporte: `tar` local em stream para `tar` remoto, atraves de `ssh`. Tres
// razoes para nao ser rsync:
//
//   - rsync nao existe no Windows; tar e ssh existem nativamente nas tres
//     plataformas (Windows 10 1803+ traz bsdtar, 1809+ traz OpenSSH).
//   - o diretorio de release esta sempre vazio, entao o delta transfer do rsync
//     nao tem contra o que comparar — pagariamos o protocolo dele a toa.
//   - um stream unico e mais rapido que os round-trips por arquivo do scp.
//
// O pipe entre os dois processos e montado com os.Pipe, sem passar por shell.
// Isso nao e detalhe: o pipeline do PowerShell e orientado a texto e corromperia
// o .tar.gz no meio do caminho.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/configr/cloudez-claude-plugin/internal/cloudez"
)

func main() {
	os.Exit(run())
}

func run() int {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "uso: cloudez-sync <deploy_id> <diretorio_local>")
		fmt.Fprintln(os.Stderr, "     cloudez-sync --hash-only <diretorio_local>")
		return 2
	}

	// --hash-only roda ANTES do begin-deploy, e por isso nao recebe deploy_id:
	// quem o chama esta justamente formando o release_id que ainda nao existe.
	// Nao toca a rede nem o estado — le o diretorio e imprime o resumo.
	if os.Args[1] == "--hash-only" {
		return hashOnly(os.Args[2])
	}

	deployID, localDir := os.Args[1], os.Args[2]

	dep, err := cloudez.LoadDeploy(deployID)
	if err != nil {
		return cloudez.Fail("deploy_not_found",
			fmt.Sprintf("deploy_id '%s' desconhecido. Rode cloudez-begin-deploy primeiro.", deployID), nil)
	}

	if code := checkDir(localDir); code != 0 {
		return code
	}

	stats, errOut, err := transfer(dep, localDir)
	if err != nil {
		return cloudez.Fail("transfer_failed",
			fmt.Sprintf("Falha ao enviar '%s' para %s.", localDir, dep.SSH.Host),
			map[string]any{"logs": errOut, "retryable": true})
	}

	dep.Status = "uploaded"
	dep.TransferStats = stats
	if err := dep.Save(); err != nil {
		return cloudez.Fail("state_write_failed", err.Error(), nil)
	}

	out, _ := json.MarshalIndent(dep, "", "  ")
	fmt.Println(string(out))
	return 0
}

// checkDir aplica as mesmas duas recusas ao diretorio publicado nos dois modos.
// Valem tanto para o envio quanto para o hash: hashear um diretorio vazio
// devolveria um sha valido para conteudo nenhum, e o deploy so descobriria isso
// depois de registrar a release.
func checkDir(localDir string) int {
	info, err := os.Stat(localDir)
	if err != nil || !info.IsDir() {
		return cloudez.Fail("build_output_missing",
			fmt.Sprintf("Diretorio '%s' nao existe. O build rodou?", localDir), nil)
	}
	entries, err := os.ReadDir(localDir)
	if err != nil || len(entries) == 0 {
		return cloudez.Fail("build_output_empty",
			fmt.Sprintf("Diretorio '%s' esta vazio.", localDir), nil)
	}
	return 0
}

// hashOnly imprime o identificador de conteudo do que seria enviado, para o
// passo que forma o release_id sem depender de git. Ver cloudez.HashPayload.
func hashOnly(localDir string) int {
	if code := checkDir(localDir); code != 0 {
		return code
	}

	h, err := cloudez.HashPayload(localDir)
	if err != nil {
		return cloudez.Fail("hash_failed",
			fmt.Sprintf("Nao foi possivel ler '%s' por inteiro: %s", localDir, err.Error()), nil)
	}

	// Um diretorio cujo unico conteudo e `.git` passa pelo checkDir (nao esta
	// vazio) e chega aqui sem nenhum arquivo publicavel. Enviar isso criaria uma
	// release vazia com identificador de aparencia normal.
	if h.Files == 0 {
		return cloudez.Fail("build_output_empty",
			fmt.Sprintf("Diretorio '%s' nao tem nenhum arquivo publicavel (so `.git`, que o deploy exclui).", localDir), nil)
	}

	out, _ := json.MarshalIndent(h, "", "  ")
	fmt.Println(string(out))
	return 0
}

// transfer executa `tar -c | ssh tar -x`. Devolve um resumo, a stderr agregada
// dos dois processos, e o erro.
func transfer(dep *cloudez.Deploy, localDir string) (string, string, error) {
	// "-C dir ." envia o CONTEUDO do diretorio, nao o diretorio. E o mesmo
	// motivo da barra final no rsync: sem isso o site sobe aninhado um nivel.
	//
	// --exclude=.git existe porque o diretorio publicado deixou de ser sempre um
	// build: numa aplicacao em container o que se envia e o contexto de build, e
	// ele costuma ser a raiz do repositorio — onde moram o Dockerfile e o
	// compose. Sem a exclusao, todo deploy carregaria o historico inteiro do git
	// pela rede, e ele nao serve para nada dentro de uma imagem.
	//
	// O padrao e o nome puro, sem barra: os dois tar tratam exclusao como
	// NAO-ancorada por padrao, entao `.git` casa tanto `./.git` quanto o `.git`
	// de um submodulo, e NAO casa `.gitignore` nem `.github/` — que precisam
	// sobreviver. Uma exclusao por prefixo comeria os dois.
	//
	// --exclude vem antes de `-C`: o bsdtar exige que a opcao preceda os
	// caminhos a que se aplica.
	tarArgs := []string{"-czf", "-", "--exclude", ".git", "-C", localDir, "."}

	remote := fmt.Sprintf("tar xzf - -C %s", shellQuote(dep.SSH.Path))
	sshArgs := []string{
		"-o", "BatchMode=yes",
		"-o", "StrictHostKeyChecking=accept-new",
		"-p", strconv.Itoa(dep.SSH.Port),
		dep.SSH.User + "@" + dep.SSH.Host,
		remote,
	}

	tarCmd := exec.Command("tar", tarArgs...)
	sshCmd := exec.Command("ssh", sshArgs...)

	// COPYFILE_DISABLE=1 impede o tar do macOS de empacotar os metadados
	// AppleDouble — os arquivos `._index.html`, `._style.css` e um `._.` por
	// diretorio. Eles nao quebram o site, mas viajam em toda release e sujam o
	// que o usuario ve no servidor.
	//
	// A variavel nao existe fora do macOS, e um tar que nao a conhece a ignora:
	// nao ha condicional por plataforma aqui de proposito.
	//
	// Vale a origem e nao o destino: excluir por padrao no tar remoto exigiria
	// um --exclude que o bsdtar e o GNU tar escrevem diferente, e mandar bytes
	// para depois descarta-los e pior do que nao mandar.
	tarCmd.Env = append(os.Environ(), "COPYFILE_DISABLE=1")

	var tarErr, sshErr bytes.Buffer
	tarCmd.Stderr = &tarErr
	sshCmd.Stderr = &sshErr

	// os.Pipe em vez de StdoutPipe: com *os.File o exec entrega o descritor
	// direto ao filho, sem goroutine de copia no meio. Menos partes moveis num
	// caminho que carrega dados binarios.
	pr, pw, err := os.Pipe()
	if err != nil {
		return "", err.Error(), err
	}
	tarCmd.Stdout = pw
	sshCmd.Stdin = pr

	if err := sshCmd.Start(); err != nil {
		pr.Close()
		pw.Close()
		return "", "ssh: " + err.Error(), err
	}
	if err := tarCmd.Start(); err != nil {
		pr.Close()
		pw.Close()
		_ = sshCmd.Process.Kill()
		_ = sshCmd.Wait()
		return "", "tar: " + err.Error(), err
	}

	// O processo pai precisa soltar as duas pontas: enquanto ele segurar a
	// ponta de escrita, o ssh nunca ve EOF e o comando remoto nao termina.
	pw.Close()
	pr.Close()

	tarWait := tarCmd.Wait()
	sshWait := sshCmd.Wait()

	logs := strings.TrimSpace(tarErr.String() + "\n" + sshErr.String())
	if tarWait != nil {
		return "", logs, tarWait
	}
	if sshWait != nil {
		return "", logs, sshWait
	}

	return fmt.Sprintf("tar+ssh -> %s:%s", dep.SSH.Host, dep.SSH.Path), logs, nil
}

// shellQuote protege o caminho para o shell REMOTO — o ssh junta os argumentos
// numa string e quem interpreta e o shell do servidor.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
