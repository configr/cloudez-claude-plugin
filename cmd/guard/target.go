package main

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/configr/cloudez-claude-plugin/internal/cloudez"
)

// transferCmd casa uma invocacao de rsync/scp/ssh como palavra isolada, para
// nao disparar em algo como "myssh" ou "rsyncd".
var transferCmd = regexp.MustCompile(`(^|[^\w-])(rsync|scp|ssh)([^\w-]|$)`)

// resolveTarget descobre qual ambiente o comando afeta e que acao ele executa.
// Retorna (env, action, motivoDeBloqueio). Um motivo nao vazio bloqueia na hora.
func resolveTarget(p payload, cfg *cloudez.Config) (env, action, blocked string) {
	if p.ToolName != "Bash" {
		// Tools MCP trazem o ambiente estruturado — sem parsing de linha
		// de comando, sem ambiguidade.
		action = strings.TrimPrefix(p.ToolName, "mcp__cloudez__cloudez_")
		env = p.ToolInput.Environment
		if env == "" {
			env = p.ToolInput.SiteID
		}
		return env, action, ""
	}

	cmd := p.ToolInput.Command

	// Bypass do mecanismo de release: rsync/ssh/scp apontando direto para a
	// raiz de um ambiente protegido. Sem esta regra, o modelo pode "ajudar"
	// escrevendo em current/ e destruir a capacidade de rollback.
	if transferCmd.MatchString(cmd) {
		for _, penv := range cfg.ProtectedEnvironments() {
			root := cfg.RootOf(penv)
			if root == "" || !strings.Contains(cmd, root) {
				continue
			}
			return "", "", fmt.Sprintf(`Bloqueado: comando rsync/ssh/scp direto para a raiz de '%s' (%s).

Escrever direto no servidor pula o diretorio de release e o symlink atomico, o
que destroi a possibilidade de rollback e pode deixar o site fora do ar no meio
da copia.

Use os adaptadores: cloudez-begin-deploy, cloudez-sync, cloudez-finalize-deploy.`, penv, root)
		}
	}

	switch {
	case strings.Contains(cmd, "cloudez-begin-deploy"):
		return argAfter(cmd, "cloudez-begin-deploy"), "begin", ""

	case strings.Contains(cmd, "cloudez-rollback"):
		return argAfter(cmd, "cloudez-rollback"), "rollback", ""

	case strings.Contains(cmd, "cloudez-finalize-deploy"),
		strings.Contains(cmd, "cloudez-sync"):
		// Estes recebem deploy_id, nao ambiente — o ambiente sai do estado
		// gravado pelo begin-deploy.
		id := argAfter(cmd, "cloudez-finalize-deploy")
		if id == "" {
			id = argAfter(cmd, "cloudez-sync")
		}
		return envOfDeploy(id), "deploy", ""
	}

	return "", "", ""
}

// argAfter devolve o primeiro argumento depois de name.
//
// A versao em shell usava alternancia BRE (`\(a\|b\)`), que e extensao do GNU
// sed e nao casa no BSD sed do macOS — o guard falhava ABERTO ali para
// sync/finalize. Uma expressao regular de verdade elimina a classe inteira de
// bug junto com a dependencia de sed.
func argAfter(cmd, name string) string {
	re := regexp.MustCompile(regexp.QuoteMeta(name) + `\s+([^\s;|&]+)`)
	if m := re.FindStringSubmatch(cmd); m != nil {
		return m[1]
	}
	return ""
}

func envOfDeploy(deployID string) string {
	return cloudez.EnvironmentOfDeploy(deployID)
}
