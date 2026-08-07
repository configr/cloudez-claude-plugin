// Package cloudez carrega a configuracao de deploy compartilhada pelos
// binarios do plugin.
package cloudez

import (
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

// StateDir e onde vivem o estado dos deploys e as aprovacoes, relativo a raiz
// do projeto. Sobreponivel por CLOUDEZ_STATE_DIR.
func StateDir() string {
	if v := os.Getenv("CLOUDEZ_STATE_DIR"); v != "" {
		return v
	}
	return ".cloudez/state"
}

// StateRoot e o primeiro segmento de StateDir — o diretorio que a checagem de
// arvore limpa ignora, ja que e escrito durante o proprio deploy.
func StateRoot() string {
	d := StateDir()
	if i := strings.IndexByte(d, '/'); i >= 0 {
		return d[:i]
	}
	return d
}

type Site struct {
	HealthURL string `yaml:"health_url"`
	Build     struct {
		Command   string `yaml:"command"`
		OutputDir string `yaml:"output_dir"`
	} `yaml:"build"`
	Paths struct {
		Root string `yaml:"root"`
	} `yaml:"paths"`
	Rsync struct {
		Exclude []string `yaml:"exclude"`
	} `yaml:"rsync"`
}

type Config struct {
	Path string `yaml:"-"`

	Guard struct {
		ProtectedEnvironments []string `yaml:"protected_environments"`
		AllowedBranches       []string `yaml:"allowed_branches"`
		ApprovalTTLMinutes    *int     `yaml:"approval_ttl_minutes"`
		RequireCleanTree      *bool    `yaml:"require_clean_tree"`
	} `yaml:"guard"`

	Sites map[string]Site `yaml:"sites"`
}

// Load procura .cloudez.yaml (ou .yml) no diretorio atual e o carrega.
// Retorna nil quando nao ha config utilizavel — ausente ou ilegivel.
// Distinguir os dois casos e responsabilidade de quem chama, se importar.
func Load() *Config {
	path := os.Getenv("CLOUDEZ_CONFIG")
	if path == "" {
		for _, c := range []string{".cloudez.yaml", ".cloudez.yml"} {
			if _, err := os.Stat(c); err == nil {
				path = c
				break
			}
		}
	}
	if path == "" {
		return nil
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		return nil
	}

	var c Config
	if err := yaml.Unmarshal(raw, &c); err != nil {
		return nil
	}
	c.Path = path
	return &c
}

func (c *Config) ProtectedEnvironments() []string {
	if len(c.Guard.ProtectedEnvironments) > 0 {
		return c.Guard.ProtectedEnvironments
	}
	return []string{"production"}
}

func (c *Config) AllowedBranches() []string {
	if len(c.Guard.AllowedBranches) > 0 {
		return c.Guard.AllowedBranches
	}
	return []string{"main", "master"}
}

func (c *Config) ApprovalTTL() int {
	if c.Guard.ApprovalTTLMinutes != nil {
		return *c.Guard.ApprovalTTLMinutes
	}
	return 15
}

func (c *Config) RequireCleanTree() bool {
	if c.Guard.RequireCleanTree != nil {
		return *c.Guard.RequireCleanTree
	}
	return true
}

func (c *Config) IsProtected(env string) bool {
	for _, p := range c.ProtectedEnvironments() {
		if p == env {
			return true
		}
	}
	return false
}

func (c *Config) RootOf(env string) string {
	return c.Sites[env].Paths.Root
}
