# cloudez-claude-plugin

Plugin do Claude Code para desenvolver e fazer deploy de sites na Cloudez.

## Arquitetura

Três camadas, deliberadamente separadas:

| Camada | O quê | Onde |
|---|---|---|
| **MCP** | capacidade — verbos primitivos da API Cloudez | repositório separado; contrato em [`docs/mcp-tool-contract.md`](docs/mcp-tool-contract.md) |
| **Comandos** | entradas explícitas, pedidas pelo usuário | `commands/` |
| **Skill** | procedimento — a sequência do deploy | `skills/deploy/SKILL.md` |
| **Transporte** | envio dos arquivos | `cmd/sync/` (Go) |
| **Adaptadores** | resto da execução, até o MCP chegar | `bin/` (shell, transitório) |

O MCP é o control plane: descobre o destino, registra a release, ativa e faz
rollback. Ele nunca move bytes.

### Por que duas linguagens

O `bin/` em shell é transitório — quando o servidor MCP entrar, `begin-deploy`,
`finalize-deploy`, `rollback` e `list-releases` viram tools do servidor e somem
daqui. Não vale reescrever código com data marcada.

Uma peça **não** migra, e é por isso que está em Go: o `sync`, porque o
transporte fica sempre local.

Ele usa `tar` em stream sobre `ssh`, não `rsync`: o diretório de release está
sempre vazio, então o delta transfer não tem contra o que comparar, e
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

Depois de editar qualquer arquivo do plugin, `/reload-plugins` recarrega sem
reiniciar a sessão.

Para conferir a estrutura antes de carregar:

```sh
claude plugin validate /caminho/para/cloudez-claude-plugin
```

Depois de carregado:

- `/cloudez:setup <domain> <environment>` — cria o `.cloudez.yaml` do projeto, se
  ainda não existir. Os dois argumentos são obrigatórios: o domínio identifica o
  site, o environment dá nome ao bloco gerado. Faltando algum, o comando pergunta;
- `/cloudez:deploy [environment] [diretório]` — o deploy. Também é acionado
  sozinho quando você pedir para publicar algo, sem precisar do comando.

Os executáveis de `bin/` entram no `PATH` da tool Bash enquanto o plugin está
ativo.

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
- [x] Comando `/cloudez:setup` (`commands/setup.md`)
- [x] Adaptadores `bin/` para trabalhar antes do MCP ficar pronto
- [x] Sync em Go (`tar` sobre `ssh`, sem `rsync`)
- [ ] Dados de SSH vindos da API, pelo domínio, em vez da config local
- [ ] Servidor MCP (repositório separado)

## Limitações conhecidas

**O caminho Windows não tem verificação automatizada.** Os binários são
compilados para `windows/amd64` e `windows/arm64`, e o launcher
`bin/cloudez-sync.cmd` existe, mas nada disso é executado em CI — não há runner
Windows na matriz. Antes de declarar suporte a Windows, isso precisa ser testado
numa máquina real.

**`sync` → `finalize` contra servidor real** continua sem cobertura: os testes
verificam o comando enviado, não o efeito no servidor.

**Os binários em `libexec/` são versionados** — hoje ~13 MB somando as seis
plataformas. Cada rebuild acrescenta cópias ao histórico do git. Como o `sync`
muda pouco, isso é administrável rebuildando só quando `cmd/` mudar; se virar
problema, as saídas são Git LFS ou publicar releases e baixar na instalação.

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

Nenhum teste toca rede, SSH ou servidor: `test/mocks/` contém shims de `ssh` e
`tar` prependados no `PATH`, e os testes afirmam sobre o comando **enviado**,
lendo `$MOCK_LOG`. É assim que se verifica, por exemplo, que o `finalize` manda
uma troca atômica de symlink — sem executar `mv -T`, que é GNU e daria falso
negativo no macOS.

O CI roda em **ubuntu e macOS**. Isso não é cerimônia: as duas plataformas
divergem em utilitários que este projeto usa, e bugs que só apareciam num lado
já passaram despercebidos por só termos testado no outro.

## Adaptadores `bin/`

Enquanto o servidor MCP não fica pronto, a skill chama estes scripts via Bash.
Cada um imprime JSON no mesmo formato da tool MCP equivalente, então a troca
depois é substituição, não reescrita.

| Script | Tool MCP correspondente |
|---|---|
| `cloudez-setup` | *(nenhuma — a config é local)* |
| `cloudez-begin-deploy` | `cloudez_begin_deploy` |
| `cloudez-sync` (Go) | *(nenhuma — o transporte fica sempre local)* |
| `cloudez-finalize-deploy` | `cloudez_finalize_deploy` |
| `cloudez-list-releases` | `cloudez_list_releases` |
| `cloudez-rollback` | `cloudez_rollback` |

Sucesso vai para stdout, erro para stderr — ambos JSON. Exit code não-zero em
qualquer falha.

### Configuração do projeto

Cada projeto publicado precisa de um `.cloudez.yaml` na raiz (`.cloudez.yml`
também serve). `/cloudez:setup <domain> <environment>` cria o template — ou copie
`cloudez.example.yaml`. Cada chave dentro de `cloudez:` é um **environment**, e o
nome é livre: um projeto com um destino só costuma usar `default`.

```yaml
cloudez:
  staging:
    domain: staging.meusite.com.br
    root: ~/staging.meusite.com.br/www
    ssh: {host: srv-12.cloudez.io, user: deploy, port: 22}
```

As chaves da config são todas em inglês — só os textos, ajudas e erros do plugin
são em português.

O `domain` é o identificador do site — não há `site_id` na config. O `setup`
exige um FQDN (`meusite.com.br`), sem protocolo, caminho, query ou porta, e
normaliza para minúsculas: o domínio também vira caminho no servidor, e caminho
diferencia maiúscula onde o DNS não diferencia.

O `root` é **obrigatório e explícito**, e o padrão da Cloudez é
`~/<domain>/www`. Ele não é derivado do domínio de propósito: para onde os
arquivos vão é a decisão mais destrutiva do deploy, e destino implícito é
destino que ninguém confere.

Um `~/` inicial é removido, não expandido — os comandos remotos vão entre aspas
simples, e dentro delas o shell do servidor não expande til (criaria um
diretório chamado `~`). Caminho relativo resolve a partir do `$HOME` do usuário
ssh, que é o que `~/` significa. Caminho absoluto continua absoluto.

O bloco `ssh` é temporário: a intenção é buscar host, usuário e porta na API da
Cloudez a partir do domínio, e aí ele sai da config.

> Adicione `.cloudez/` ao `.gitignore` do projeto publicado — é onde vive o
> estado dos deploys, que não deveria ir para o repositório.

A leitura do YAML tenta, nesta ordem: `yq` (as duas implementações populares,
que são incompatíveis entre si apesar do nome comum), `python3` com PyYAML, e
`ruby` — que resolve o caso do macOS sem instalar nada, já que YAML está na
stdlib dele. Basta um dos três.

O deploy usa o padrão releases + symlink:

```
<root>/
  releases/20260807T143000Z-a1b2c3d/
  current -> releases/20260807T143000Z-a1b2c3d
  shared/
```

O document root do site no painel da Cloudez precisa apontar para `current` —
com `root: ~/<domain>/www`, isso é `~/<domain>/www/current`, e não
`~/<domain>/www`.
O servidor guarda as 5 releases mais recentes — é até onde o rollback alcança.

### Dependências

`git`, `ssh` e `tar` na máquina local, mais `jq` enquanto o `bin/` em shell
existir. No servidor, GNU coreutils — a troca atômica do symlink usa `mv -T`,
que não existe em BSD/macOS.

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
alterar produção derruba a separação entre os dois.

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
      "mcp__cloudez__cloudez_list_releases"
    ]
  }
}
```

As tools que mudam estado (`begin_deploy`, `finalize_deploy`, `rollback`)
ficam de fora de propósito.
