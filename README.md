# cloudez-claude-plugin

Plugin do Claude Code para desenvolver e fazer deploy de sites na Cloudez.

## Arquitetura

Três camadas, deliberadamente separadas:

| Camada | O quê | Onde |
|---|---|---|
| **MCP** | capacidade — verbos primitivos da API Cloudez | repositório separado; contrato em [`docs/mcp-tool-contract.md`](docs/mcp-tool-contract.md) |
| **Skill** | procedimento — a sequência do deploy | `skills/deploy/SKILL.md` |
| **Guard-rails** | as regras que o modelo não contorna | `cmd/guard/` (Go) |
| **Transporte** | envio dos arquivos | `cmd/sync/` (Go) |
| **Adaptadores** | resto da execução, até o MCP chegar | `bin/` (shell, transitório) |

O MCP é o control plane: descobre o destino, registra a release, ativa, verifica
e faz rollback. Ele nunca move bytes.

### Por que duas linguagens

O `bin/` em shell é transitório — quando o servidor MCP entrar, `begin-deploy`,
`finalize-deploy`, `rollback`, `list-releases` e `health-check` viram tools do
servidor e somem daqui. Não vale reescrever código com data marcada.

Duas peças **não** migram, e essas estão em Go:

- **o guard**, porque é um hook e o `hooks.json` guarda uma string de comando
  estática — nenhum interpretador tem um nome que sirva em macOS, Linux e
  Windows ao mesmo tempo, e um binário resolve isso;
- **o sync**, porque o rsync fica sempre local.

O ganho medido não foi só portabilidade: o guard roda a cada chamada da tool
Bash, e saiu de **149ms para 3ms**. A versão em shell pagava um cold start do
parser de YAML em todo comando da sessão.

O `sync` usa `tar` em stream sobre `ssh`, não `rsync`: o diretório de release
está sempre vazio, então o delta transfer não tem contra o que comparar, e
`tar`/`ssh` existem nativamente nas três plataformas enquanto `rsync` não existe
no Windows. O pipe entre os dois processos é montado sem shell — o pipeline do
PowerShell é orientado a texto e corromperia o `.tar.gz`.

## Instalação

Para desenvolvimento e uso local:

```sh
./build.sh                 # compila os binários (precisa de Go)
claude --plugin-dir /caminho/para/cloudez-claude-plugin
```

Os binários de `libexec/` são versionados no repositório, então quem só usa o
plugin não precisa de Go. `./build.sh` é necessário apenas depois de alterar
algo em `cmd/`.

O `hooks.json` aponta para `libexec/guard`, sem extensão: no POSIX isso resolve
para o launcher em `sh`, no Windows o PATHEXT resolve para `guard.cmd`. É a
única forma de ter uma string de comando estática servindo nos três sistemas.

Depois de editar qualquer arquivo do plugin, `/reload-plugins` recarrega sem
reiniciar a sessão.

Para conferir a estrutura antes de carregar:

```sh
claude plugin validate /caminho/para/cloudez-claude-plugin
```

A skill fica disponível como `/cloudez:deploy` (ou é acionada sozinha quando
você pedir para publicar algo). Os executáveis de `bin/` entram no `PATH` da
tool Bash enquanto o plugin está ativo — no seu terminal eles não estão, então
`cloudez-approve` precisa ser chamado pelo caminho completo (o bloqueio do guard
já imprime ele pronto).

### Instalar de verdade (aparece em `/plugin`)

`--plugin-dir` carrega o plugin só naquela sessão. Para ele ficar instalado e
aparecer na lista de `/plugin`, use o marketplace — este repositório é os dois
ao mesmo tempo (`.claude-plugin/marketplace.json` lista o plugin com
`source: "./"`, a própria raiz).

Local, para você mesmo:

```
/plugin marketplace add ~/Sandbox/cloudez/cloudez-claude-plugin
/plugin install cloudez@cloudez
```

Para o time, depois de publicar o repositório:

```
/plugin marketplace add configr/cloudez-claude-plugin
/plugin install cloudez@cloudez
```

Funciona com repositório privado — quem instala precisa ter acesso de leitura ao
repo. Não há passo de publicação em diretório público, e o plugin não fica
visível para ninguém fora de quem você mandar o comando.

Depois de instalado, `/plugin` mostra o `cloudez` na lista, com opções de
habilitar, desabilitar e atualizar. Atualizações chegam com
`/plugin marketplace update cloudez` depois de você dar push.

## Estado atual

- [x] Contrato das tools MCP (`docs/mcp-tool-contract.md`)
- [x] Esqueleto do plugin (`plugin.json`, `.mcp.json`, `/deploy`)
- [x] Skill de deploy (`skills/deploy/SKILL.md`)
- [x] Adaptadores `bin/` para trabalhar antes do MCP ficar pronto
- [x] Hooks de guard-rail para produção
- [x] Guard portado para Go (multiplataforma, 149ms → 3ms)
- [x] Sync portado para Go (`tar` sobre `ssh`, sem `rsync`)
- [ ] Servidor MCP (repositório separado)

## Limitações conhecidas

**O caminho Windows não tem verificação automatizada.** Os binários são
compilados para `windows/amd64` e `windows/arm64`, e o launcher `guard.cmd`
existe, mas nada disso é executado em CI — não há runner Windows na matriz. Duas
coisas em particular seguem por raciocínio, não por teste: se o PATHEXT resolve
`libexec/guard` para `guard.cmd` quando o harness invoca o hook, e se
`exit /b %ERRORLEVEL%` propaga o código 2 até o Claude Code. Se algum dos dois
falhar, o guard falha **aberto** no Windows.

Antes de declarar suporte a Windows, isso precisa ser testado numa máquina real.

**`sync` → `finalize` contra servidor real** continua sem cobertura: os testes
verificam o comando enviado, não o efeito no servidor.

**Os binários em `libexec/` são versionados** — hoje ~32 MB somando as seis
plataformas de cada comando. Cada rebuild acrescenta cópias ao histórico do git.
Como o guard e o sync mudam pouco, isso é administrável rebuildando só quando
`cmd/` mudar; se virar problema, as saídas são Git LFS ou publicar releases e
baixar na instalação.

## Testes

```sh
test/run.sh
```

Três camadas: `claude plugin validate` (estrutura), `shellcheck` (estático) e
`bats` (comportamento). Ferramentas ausentes viram aviso local e erro com
`--strict`, que é o que o CI usa — `git clone && test/run.sh` funciona sem
instalar nada, mas o CI não passa com meia suíte.

O `bats` faz bootstrap sozinho em `test/bats/` (gitignorado) na primeira
execução, então não há submodule nem passo de instalação.

Nenhum teste toca rede, SSH ou servidor: `test/mocks/` contém shims de `ssh`,
`tar` e `curl` prependados no `PATH`, e os testes afirmam sobre o comando
**enviado**, lendo `$MOCK_LOG`. É assim que se verifica, por exemplo, que o
`finalize` manda uma troca atômica de symlink — sem executar `mv -T`, que é GNU
e daria falso negativo no macOS.

O CI roda em **ubuntu e macOS**. Isso não é cerimônia: um bug em que o guard
falhava aberto no macOS (alternância BRE no `sed`, que só o GNU suporta) passou
despercebido justamente por só termos testado num lugar.

O que a suíte **não** cobre é `sync` → `finalize` contra um servidor real —
continua sendo teste manual contra staging.

## Guard-rails

O binário `guard` (`cmd/guard/`) roda como `PreToolUse` e é a camada que o modelo não
contorna conversando — as checagens dentro dos scripts são conveniência, estas
são a regra. Bloqueia com exit code 2 (não com JSON de `permissionDecision`:
um campo errado no JSON falharia *aberto*, que é o modo de falha inaceitável
aqui).

| Situação | Ação |
|---|---|
| Working tree suja | bloqueia qualquer deploy |
| `rsync`/`ssh`/`scp` direto na raiz de ambiente protegido | bloqueia |
| Ambiente protegido, branch fora da lista | bloqueia |
| Ambiente protegido sem aprovação válida | bloqueia |
| Aprovação expirada ou de outro commit | bloqueia |

O guard cobre tanto os scripts `bin/` quanto as tools MCP quando elas existirem.

### Aprovação de produção

```sh
bin/cloudez-approve production
```

Mostra o que vai subir (ambiente, servidor, branch, commit) e pede o nome do
ambiente digitado. **Exige TTY** — rodado pela tool Bash de um agente, falha.
É isso que faz a aprovação significar "um humano decidiu" em vez de "o modelo
decidiu por si".

A aprovação vale `guard.approval_ttl_minutes` e é vinculada ao SHA de `HEAD`.
Commitar depois de aprovar invalida a aprovação, para que uma alteração
posterior não entre de carona.

Configuração em `.cloudez.yaml`:

```yaml
guard:
  protected_environments: [production]
  allowed_branches: [main, master]
  approval_ttl_minutes: 15
  require_clean_tree: true
```

> Adicione `.cloudez/` ao `.gitignore` do projeto publicado — é onde vivem o
> estado dos deploys e as aprovações. O guard já ignora esse diretório na
> checagem de árvore limpa, mas ele não deveria ir para o repositório.

## Adaptadores `bin/`

Enquanto o servidor MCP não fica pronto, a skill chama estes scripts via Bash.
Cada um imprime JSON no mesmo formato da tool MCP equivalente, então a troca
depois é substituição, não reescrita.

| Script | Tool MCP correspondente |
|---|---|
| `cloudez-begin-deploy` | `cloudez_begin_deploy` |
| `cloudez-sync` (Go) | *(nenhuma — o transporte fica sempre local)* |
| `cloudez-finalize-deploy` | `cloudez_finalize_deploy` |
| `cloudez-health-check` | `cloudez_health_check` |
| `cloudez-list-releases` | `cloudez_list_releases` |
| `cloudez-rollback` | `cloudez_rollback` |

Sucesso vai para stdout, erro para stderr — ambos JSON. Exit code não-zero em
qualquer falha.

### Configuração do projeto

Cada projeto publicado precisa de um `.cloudez.yaml` na raiz (`.cloudez.yml`
também serve). Copie `cloudez.example.yaml` e ajuste `ssh`, `paths.root`,
`build` e `health_url` por ambiente.

A leitura do YAML tenta, nesta ordem: `yq` (as duas implementações populares,
que são incompatíveis entre si apesar do nome comum), `python3` com PyYAML, e
`ruby` — que resolve o caso do macOS sem instalar nada, já que YAML está na
stdlib dele. Basta um dos quatro.

O deploy usa o padrão releases + symlink:

```
<paths.root>/
  releases/20260807T143000Z-a1b2c3d/
  current -> releases/20260807T143000Z-a1b2c3d
  shared/
```

O document root do site no painel da Cloudez precisa apontar para `current`.

### Dependências

`git`, `ssh`, `tar`, `curl` na máquina local, mais `jq` enquanto o `bin/` em
shell existir. No servidor, GNU coreutils — a
troca atômica do symlink usa `mv -T`, que não existe em BSD/macOS.

Autenticação SSH é por chave, em `~/.ssh/`. Os scripts rodam com
`BatchMode=yes`: sem chave configurada eles falham na hora em vez de travar num
prompt de senha que o agente não consegue responder.

## Configuração

O `.mcp.json` referencia o servidor MCP por variável de ambiente, já que ele
vive em outro repositório:

```sh
export CLOUDEZ_MCP_PATH=/caminho/para/o/repo/do/mcp
export CLOUDEZ_TOKEN_STAGING=...
export CLOUDEZ_TOKEN_PRODUCTION=...
```

Ajuste `command`/`args` no `.mcp.json` quando o servidor MCP definir como é
distribuído (npx, binário, etc.) — o valor atual é um placeholder.

Tokens **separados por ambiente** não é detalhe: um token de staging capaz de
alterar produção anula os guard-rails.

### Permissões

Para reduzir prompts de permissão, as tools read-only podem ir para o allowlist
em `.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "mcp__cloudez__cloudez_list_sites",
      "mcp__cloudez__cloudez_get_site",
      "mcp__cloudez__cloudez_get_deploy_status",
      "mcp__cloudez__cloudez_list_releases",
      "mcp__cloudez__cloudez_health_check",
      "mcp__cloudez__cloudez_get_logs"
    ]
  }
}
```

As tools que mudam estado (`begin_deploy`, `finalize_deploy`, `rollback`)
ficam de fora de propósito.
