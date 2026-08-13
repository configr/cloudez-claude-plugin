// Package cloudez guarda o estado de deploy compartilhado pelos binarios do
// plugin.
package cloudez

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
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
// O shape espelha o retorno de cloudez_begin_deploy (docs/mcp-tool-contract.md),
// mas esta struct NAO e a fonte da verdade sobre quais campos o estado tem. O
// servidor MCP escreve o mesmo arquivo e conhece campos que ela nao conhece —
// eram dois escritores com schemas diferentes, e o round-trip por aqui apagava
// em silencio o que estava fora da struct. Foi assim que o `domain` gravado
// pelo begin-deploy sumia no sync e o compose_up falhava depois sem ter como
// dizer por que. Veja UnmarshalJSON/MarshalJSON.
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

	// extra guarda os campos que a struct nao conhece, lidos do arquivo e
	// reemitidos na escrita. Nao tem tag json de proposito: quem o serializa e
	// o MarshalJSON abaixo, campo a campo, e nao um `extra: {...}` aninhado.
	extra map[string]json.RawMessage
}

// deployKeys sao as chaves JSON que a struct conhece. Por reflexao, e nao uma
// lista escrita a mao: uma lista manual envelhece no primeiro campo novo, e o
// sintoma seria o campo novo aparecer duplicado ou nunca ser atualizado.
func deployKeys() map[string]bool {
	t := reflect.TypeOf(Deploy{})
	keys := make(map[string]bool, t.NumField())
	for i := range t.NumField() {
		name, _, _ := strings.Cut(t.Field(i).Tag.Get("json"), ",")
		if name == "" || name == "-" {
			continue
		}
		keys[name] = true
	}
	return keys
}

// UnmarshalJSON decodifica os campos conhecidos e guarda o resto em `extra`.
func (d *Deploy) UnmarshalJSON(raw []byte) error {
	// `alias` derruba os metodos de Deploy. Sem isso o json.Unmarshal chamaria
	// este mesmo metodo e recursaria ate estourar a pilha.
	type alias Deploy
	if err := json.Unmarshal(raw, (*alias)(d)); err != nil {
		return err
	}

	var all map[string]json.RawMessage
	if err := json.Unmarshal(raw, &all); err != nil {
		return err
	}

	known := deployKeys()
	d.extra = nil
	for k, v := range all {
		if known[k] {
			continue
		}
		if d.extra == nil {
			d.extra = make(map[string]json.RawMessage)
		}
		d.extra[k] = v
	}
	return nil
}

// MarshalJSON emite os campos conhecidos mais os preservados em `extra`. Campo
// conhecido sempre vence: o que esta struct alterou e o que vale.
//
// Com campos preservados a saida sai com as chaves em ordem alfabetica, porque
// a mesclagem passa por um map. Sem eles, sai na ordem da struct. E so a forma
// do arquivo — nada le o estado por posicao.
func (d *Deploy) MarshalJSON() ([]byte, error) {
	type alias Deploy
	raw, err := json.Marshal((*alias)(d))
	if err != nil {
		return nil, err
	}
	if len(d.extra) == 0 {
		return raw, nil
	}

	var merged map[string]json.RawMessage
	if err := json.Unmarshal(raw, &merged); err != nil {
		return nil, err
	}
	for k, v := range d.extra {
		if _, taken := merged[k]; !taken {
			merged[k] = v
		}
	}
	return json.Marshal(merged)
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
