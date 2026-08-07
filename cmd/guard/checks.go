package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/configr/cloudez-claude-plugin/internal/cloudez"
)

// check aplica as regras em ordem de custo e abrangencia: arvore limpa vale
// para todo ambiente; branch e aprovacao so para ambientes protegidos.
func check(cfg *cloudez.Config, cfgPath, env, action string) int {
	if cfg.RequireCleanTree() && action != "rollback" {
		if dirty := dirtyTree(); dirty != "" {
			return deny(fmt.Sprintf(`Bloqueado: working tree com alteracoes nao commitadas.

%s

Um deploy de arvore suja nao corresponde a nenhum commit — ninguem consegue
saber depois o que esta no ar, e o rollback fica sem referencia. Commite ou
descarte antes de subir.`, dirty))
		}
	}

	if !cfg.IsProtected(env) {
		return allow
	}

	branches := cfg.AllowedBranches()
	if branch := currentBranch(); branch != "" && !contains(branches, branch) {
		return deny(fmt.Sprintf(`Bloqueado: deploy para '%s' a partir da branch '%s'.

Branches permitidas para ambientes protegidos: %s

Se isto e intencional, ajuste guard.allowed_branches em %s.`,
			env, branch, strings.Join(branches, " "), cfgPath))
	}

	return checkApproval(cfg, env)
}

func checkApproval(cfg *cloudez.Config, env string) int {
	ttl := cfg.ApprovalTTL()
	hint := approvalHint(env, ttl)

	raw, err := os.ReadFile(filepath.Join(cloudez.StateDir(), "approval-"+env+".json"))
	if err != nil {
		return deny(fmt.Sprintf("Bloqueado: deploy para '%s' sem aprovacao.\n\n%s", env, hint))
	}

	var a struct {
		SHA             string `json:"sha"`
		ApprovedAtEpoch int64  `json:"approved_at_epoch"`
	}
	if err := json.Unmarshal(raw, &a); err != nil {
		return deny(fmt.Sprintf("Bloqueado: a aprovacao para '%s' esta ilegivel.\n\n%s", env, hint))
	}

	ageMin := int((time.Now().Unix() - a.ApprovedAtEpoch) / 60)
	if ageMin >= ttl {
		return deny(fmt.Sprintf(
			"Bloqueado: aprovacao para '%s' expirou (emitida ha %dmin, validade %dmin).\n\n%s",
			env, ageMin, ttl, hint))
	}

	head := headSHA()
	if head != "" && a.SHA != "" && head != a.SHA {
		return deny(fmt.Sprintf(`Bloqueado: a aprovacao para '%s' e do commit %s, mas HEAD agora e %s.

O codigo mudou depois da aprovacao. Uma aprovacao vale para um commit especifico
justamente para que uma alteracao posterior nao entre carona nela.

%s`, env, short(a.SHA), short(head), hint))
	}

	return allow
}

// approvalHint precisa do caminho ABSOLUTO: instalado, o plugin vive num
// diretorio de cache que o usuario nao adivinha, e bin/ so esta no PATH da tool
// Bash — nao no terminal dele, que e justamente onde a aprovacao e emitida.
func approvalHint(env string, ttl int) string {
	bin := "cloudez-approve"
	if exe, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		bin = filepath.Join(filepath.Dir(exe), "..", "bin", "cloudez-approve")
		bin = filepath.Clean(bin)
	}

	return fmt.Sprintf(`Peca ao usuario para rodar, no terminal dele:

    %s %s

O comando exige TTY e confirmacao digitada — voce nao consegue executa-lo pela
tool Bash, e isso e intencional. A aprovacao vale %d minutos e so para o
commit atual.`, bin, env, ttl)
}

// ---------------------------------------------------------------------- git --

func git(args ...string) (string, bool) {
	out, err := exec.Command("git", args...).Output()
	if err != nil {
		return "", false
	}
	return strings.TrimSpace(string(out)), true
}

func inRepo() bool {
	_, ok := git("rev-parse", "--git-dir")
	return ok
}

// dirtyTree devolve ate 20 linhas de `git status --porcelain`, ou string vazia.
//
// O diretorio de estado e excluido: ele e escrito durante o proprio deploy,
// entao inclui-lo bloquearia todo deploy em projeto que esqueceu de por
// .cloudez/ no .gitignore.
func dirtyTree() string {
	if !inRepo() {
		return ""
	}
	out, ok := git("status", "--porcelain", "--", ":(exclude)"+cloudez.StateRoot())
	if !ok || out == "" {
		return ""
	}
	lines := strings.Split(out, "\n")
	if len(lines) > 20 {
		lines = lines[:20]
	}
	return strings.Join(lines, "\n")
}

func currentBranch() string {
	if !inRepo() {
		return ""
	}
	b, _ := git("rev-parse", "--abbrev-ref", "HEAD")
	return b
}

func headSHA() string {
	if !inRepo() {
		return ""
	}
	s, _ := git("rev-parse", "HEAD")
	return s
}

// -------------------------------------------------------------------- util --

func contains(haystack []string, needle string) bool {
	for _, h := range haystack {
		if h == needle {
			return true
		}
	}
	return false
}

func short(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}
