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
		return 2
	}
	deployID, localDir := os.Args[1], os.Args[2]

	dep, err := cloudez.LoadDeploy(deployID)
	if err != nil {
		return cloudez.Fail("deploy_not_found",
			fmt.Sprintf("deploy_id '%s' desconhecido. Rode cloudez-begin-deploy primeiro.", deployID), nil)
	}

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

// transfer executa `tar -c | ssh tar -x`. Devolve um resumo, a stderr agregada
// dos dois processos, e o erro.
func transfer(dep *cloudez.Deploy, localDir string) (string, string, error) {
	// "-C dir ." envia o CONTEUDO do diretorio, nao o diretorio. E o mesmo
	// motivo da barra final no rsync: sem isso o site sobe aninhado um nivel.
	tarArgs := []string{"-czf", "-", "-C", localDir, "."}

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
