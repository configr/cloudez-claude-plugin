// Command guard e o hook PreToolUse que aplica os guard-rails de deploy.
//
// Contrato com o harness:
//
//	exit 0  libera
//	exit 2  bloqueia, com a razao em stderr (volta para o modelo)
//	outro   erro nao-bloqueante
//
// Usamos exit 2 em vez do JSON de permissionDecision de proposito: um campo
// errado no JSON faria o hook falhar ABERTO, que e o modo de falha inaceitavel
// num guard-rail.
//
// Este hook e a camada que o modelo nao contorna conversando. As checagens
// dentro dos adaptadores sao conveniencia; estas sao a regra.
//
// Por que Go e nao shell: o hooks.json guarda uma string de comando estatica, e
// nenhum interpretador tem um nome de comando que sirva em macOS, Linux e
// Windows ao mesmo tempo. Um binario resolve isso, roda em ~2ms num hook que e
// invocado a cada chamada de Bash, e elimina a dependencia de jq — cuja
// ausencia desligava o guard em silencio.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/configr/cloudez-claude-plugin/internal/cloudez"
)

const (
	allow = 0
	block = 2
)

// payload e o subconjunto do evento PreToolUse que nos interessa.
type payload struct {
	ToolName  string `json:"tool_name"`
	CWD       string `json:"cwd"`
	ToolInput struct {
		Command     string `json:"command"`
		Environment string `json:"environment"`
		SiteID      string `json:"site_id"`
	} `json:"tool_input"`
}

func main() {
	os.Exit(run())
}

func run() int {
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		return allow
	}

	var p payload
	if err := json.Unmarshal(raw, &p); err != nil {
		return allow
	}

	if !watchedTool(p.ToolName) {
		return allow
	}

	cwd := p.CWD
	if cwd == "" {
		cwd = "."
	}
	if err := os.Chdir(cwd); err != nil {
		return allow
	}

	// Config ausente significa projeto sem deploy Cloudez. Config ilegivel
	// tambem libera: bloquear ali transformaria um erro de indentacao em
	// "nenhum comando roda", sem explicacao util — e os adaptadores ja abortam
	// com mensagem clara. As regras abaixo so valem sobre config valida.
	cfg := cloudez.Load()
	if cfg == nil {
		return allow
	}

	env, action, blocked := resolveTarget(p, cfg)
	if blocked != "" {
		return deny(blocked)
	}
	if env == "" {
		return allow
	}

	return check(cfg, cfg.Path, env, action)
}

func watchedTool(name string) bool {
	if name == "Bash" {
		return true
	}
	return len(name) >= 16 && name[:16] == "mcp__cloudez__cl"
}

func deny(reason string) int {
	fmt.Fprintln(os.Stderr, reason)
	return block
}
