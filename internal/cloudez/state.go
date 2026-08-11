// Package cloudez guarda o estado de deploy compartilhado pelos binarios do
// plugin.
package cloudez

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// StateDir e onde vive o estado dos deploys, relativo a raiz do projeto.
// Sobreponivel por CLOUDEZ_STATE_DIR.
func StateDir() string {
	if v := os.Getenv("CLOUDEZ_STATE_DIR"); v != "" {
		return v
	}
	return ".cloudez/state"
}

// Deploy e o estado gravado por begin-deploy e consumido por sync/finalize.
//
// O shape espelha o retorno de cloudez_begin_deploy (docs/mcp-tool-contract.md):
// quando o servidor MCP entrar, o estado vem de la sem conversao.
type Deploy struct {
	DeployID    string `json:"deploy_id"`
	ReleaseID   string `json:"release_id"`
	Environment string `json:"environment"`
	Ref         string `json:"ref"`
	Note        string `json:"note,omitempty"`
	Status      string `json:"status"`

	SSH struct {
		Host string `json:"host"`
		User string `json:"user"`
		Port int    `json:"port"`
		Path string `json:"path"`
	} `json:"ssh"`

	Root string `json:"root"`

	TransferStats string `json:"transfer_stats,omitempty"`
}

func DeployStatePath(deployID string) string {
	return filepath.Join(StateDir(), deployID+".json")
}

func LoadDeploy(deployID string) (*Deploy, error) {
	raw, err := os.ReadFile(DeployStatePath(deployID))
	if err != nil {
		return nil, err
	}
	var d Deploy
	if err := json.Unmarshal(raw, &d); err != nil {
		return nil, err
	}
	return &d, nil
}

func (d *Deploy) Save() error {
	raw, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(DeployStatePath(d.DeployID), append(raw, '\n'), 0o644)
}

// EnvironmentOfDeploy devolve o ambiente de um deploy_id, ou string vazia.
func EnvironmentOfDeploy(deployID string) string {
	if deployID == "" {
		return ""
	}
	d, err := LoadDeploy(deployID)
	if err != nil {
		return ""
	}
	return d.Environment
}

// Fail imprime um erro no formato do contrato (JSON em stderr) e devolve o
// codigo de saida. O mesmo shape dos adaptadores em shell e das tools MCP.
func Fail(code, message string, extra map[string]any) int {
	e := map[string]any{"code": code, "message": message, "retryable": false}
	for k, v := range extra {
		e[k] = v
	}
	out, _ := json.MarshalIndent(map[string]any{"error": e}, "", "  ")
	fmt.Fprintln(os.Stderr, string(out))
	return 1
}
