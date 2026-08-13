# cloudez-claude-plugin

Plugin do Claude Code para desenvolver e fazer deploy de sites na Cloudez.

## Arquitetura

Três camadas, deliberadamente separadas:

| Camada | O quê | Onde |
|---|---|---|
| **MCP** | capacidade — verbos primitivos da API Cloudez | repositório separado; contrato em [`docs/mcp-tool-contract.md`](docs/mcp-tool-contract.md) |
| **Comandos** | procedimento — a sequência de cada operação | `commands/` |
| **Skill** | porta de entrada em linguagem natural; encaminha ao comando | `skills/deploy/SKILL.md` |
| **Transporte** | envio dos arquivos | `cmd/sync/` (Go) |
| **Adaptadores** | o que depende da máquina local | `bin/` (shell) |

O MCP é o control plane: descobre o destino, registra a release, ativa e faz
rollback. Ele nunca move bytes.

### Por que duas linguagens

O `bin/` em shell era transitório e encolheu: `begin-deploy`,
`finalize-deploy`, `rollback`, `list-releases` e `compose-up` viraram tools do
servidor MCP e saíram daqui. O que sobrou é o que **não** migra, por depender da
máquina de quem publica — coletar o token (exige TTY), ler `~/.ssh`, escrever o
`.cloudez.yaml`, inspecionar o diretório do projeto.

Uma peça não migra por outra razão, e é por isso que está em Go: o `sync`,
porque o transporte fica sempre local.

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

Os binários de `libexec/` e o servidor MCP em `mcp/` são versionados no
repositório, então quem só usa o plugin não precisa de Go nem de build nenhum —
só de **Node 20+** para rodar o servidor. `./build.sh` é necessário apenas
depois de alterar algo em `cmd/`; `./vendor-mcp.sh` só depois de alterar o
servidor MCP, que vive em [repositório
separado](https://github.com/configr/cloudez-mcp).

Depois de editar qualquer arquivo do plugin, `/reload-plugins` recarrega sem
reiniciar a sessão.

Para conferir a estrutura antes de carregar:

```sh
claude plugin validate /caminho/para/cloudez-claude-plugin
```

Depois de carregado:

- `/cloudez:login` — verifica se há token da Cloudez salvo e conduz o login;
- `/cloudez:setup <domain> <environment>` — cria o `.cloudez.yaml` do projeto, se
  ainda não existir. Os dois argumentos são obrigatórios: o domínio identifica o
  site, o environment dá nome ao bloco gerado. Faltando algum, o comando pergunta.
  Antes de escrever qualquer coisa ele confirma o domínio contra a API
  (`cloudez_get_site`), então **exige autenticação** e começa pelo
  `/cloudez:login`. Domínio que não está na conta é erro, não config criada com
  aviso: um typo aceito aqui só apareceria no deploy, longe da causa;
- `/cloudez:deploy [environment] [diretório]` — o deploy. Confirma o site na
  Cloudez antes de qualquer coisa, então **exige autenticação**. Também é
  acionado quando você pedir em linguagem natural ("sobe o site", "publica em
  staging"): a skill `skills/deploy/` não tem procedimento próprio, ela só
  encaminha para este comando.

> **O procedimento do deploy mora num lugar só**, em `commands/deploy.md`. A
> skill existe para dar a porta de entrada em linguagem natural, e nada mais —
> duas descrições do mesmo deploy divergem, e a errada acaba sendo justamente a
> que ninguém está lendo na hora.

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
- [x] Skill de deploy como porta em linguagem natural (`skills/deploy/SKILL.md`)
- [x] Comandos `/cloudez:setup` e `/cloudez:login` (`commands/`)
- [x] Control plane inteiro no MCP; o `bin/` fica só com o que é local
- [x] Sync em Go (`tar` sobre `ssh`, sem `rsync`)
- [x] Autenticação: `~/.cloudez/token` + validação em `/auth/token/validate/`
- [x] Tools `cloudez_auth_status` e `cloudez_get_site` no servidor MCP
- [x] `/cloudez:deploy` como comando, com a skill reduzida a roteador
- [x] `ssh.host` e `ssh.user` vindos da API (`cloud.fqdn`, `user.username`)
- [x] Slugs de `stack` e `current_release` confirmados contra a API real — e o
      contrato assumia errado: `stack` não é slug de `values`, é `type.slug`
      (`html`, `container_docker`); `current_release` não existe na resposta do
      site (só o symlink `current` no servidor sabe). `mapSite` já lê `stack` de
      `type.slug` (com `values` como precedência); `current_release` continua fora
- [x] Bloco `ssh` fora do `.cloudez.yaml` — vem do `cloudez_get_site` a cada deploy
- [x] `/cloudez:setup` completo: confirma o site, ajusta o document root e
      autoriza a chave SSH da máquina — exercitado contra a API real
- [x] Deploy rodado de ponta a ponta contra um servidor de verdade, várias vezes
- [x] Rollback exercitado contra um servidor de verdade
- [x] Deploy via Docker, parte 1: os arquivos do container (Compose, Dockerfile,
      código) chegam ao servidor — o `/cloudez:deploy` publica o contexto de
      build em vez do resultado de um build local
- [x] Deploy via Docker, parte 2: `cloudez_compose_up` sobe o container depois do
      finalize, no fluxo do `/cloudez:deploy` — exercitado contra um servidor de
      verdade (o health check ficou fora de escopo: o modelo confere batendo no
      domínio, contrato §3.12)
- [x] Tools de ciclo de vida no MCP, 1ª leva: `cloudez_begin_deploy`,
      `cloudez_finalize_deploy`, `cloudez_compose_up` (SSH via child_process,
      estado compartilhado com o `cloudez-sync` pelo arquivo `.cloudez/state/`)
- [x] Tools de ciclo de vida no MCP, 2ª leva: `cloudez_list_releases` e
      `cloudez_rollback` — todo o control plane agora é MCP; em `bin/` só resta o
      transporte `cloudez-sync`. Suíte do MCP em 113 testes (ssh e API falsos)
- [x] Servidor MCP embutido no plugin (`mcp/cloudez-mcp.mjs`), sem passo de instalação

## Autenticação

O token da Cloudez vive em **`~/.cloudez/token`**, com permissão `0600` — é
credencial do usuário, não do projeto: um arquivo no `$HOME` serve todos os
repositórios, em vez de uma cópia do mesmo segredo em cada um. E fica fora da
árvore que o `cloudez-sync` empacota com `tar`.

`CLOUDEZ_TOKEN` no ambiente vence o arquivo (CI, uso headless).
`CLOUDEZ_TOKEN_FILE` muda o caminho, e é o que a suíte usa para não tocar no seu
token de verdade.

```sh
pbpaste | bin/cloudez-login --stdin   # token do clipboard, sem prompt e sem TTY
bin/cloudez-login                     # pergunta o token. Exige terminal
bin/cloudez-login --hint              # como autenticar nesta máquina
```

**Token é a única forma de autenticar.** Gere no painel da Cloudez.

O `cloudez-login` só **coleta e grava**. Quem responde se você está autenticado é
a tool `cloudez_auth_status` do MCP, porque é o MCP que usa o token contra a API —
duas noções de "estou autenticado" em lugares diferentes acabam divergindo, e a
que erra é sempre a que ninguém está olhando. Nenhum adaptador em `bin/` exige
token: o deploy inteiro fala com o servidor por `ssh`, com a sua chave.

O `--hint` fica no shell porque a resposta é local — onde o plugin foi instalado e
se existe clipboard nesta máquina. O MCP não tem como saber isso.

O `--stdin` é o caminho que funciona onde o agente está: um pipe não precisa de
terminal, e o segredo vai da origem (clipboard, arquivo, variável, gerenciador de
senhas) direto para o processo, sem passar pelo contexto de ninguém. Quem monta o
pipe nunca vê o valor — e é isso que permite rodar pela tool Bash sem vazar nada.

> O que **não** vale é o próprio agente montar o pipe com um token que ele
> conhece: se ele conhece, já vazou. Vale pipe de fonte opaca, não `echo`.

`--stdin` em si é portátil — é um pipe. O **clipboard como fonte** não é, e a dica
do erro só o oferece quando existe de verdade:

| Ambiente | Clipboard |
|---|---|
| macOS | `pbpaste`, sempre presente |
| Linux com sessão gráfica | `wl-paste` / `xclip` / `xsel`, se instalado |
| Windows via WSL ou Git Bash | `powershell.exe Get-Clipboard` |
| SSH, container, CI, Claude Code remoto | **nenhum** — a dica cai para o prompt |

`wl-paste` e `xclip` **instalados** não significam clipboard **disponível**: X11 e
Wayland guardam o clipboard no servidor gráfico, e sem `DISPLAY`/`WAYLAND_DISPLAY`
o comando existe e falha. A detecção checa a sessão gráfica antes de sugerir
qualquer coisa — sugerir um comando que quebra é pior que não sugerir nada.

Onde não há clipboard, as fontes que sempre funcionam:

```sh
cloudez-login --stdin < caminho/para/o/token   # arquivo
echo "$CLOUDEZ_TOKEN" | cloudez-login --stdin  # variável, CI
```

O modo **interativo** exige TTY, e isso é deliberado: um token colado na conversa
entra no contexto do modelo e no transcript da sessão — um lugar que você não
controla e não consegue limpar. O prompt roda no seu terminal, não ecoa o que é
digitado, e o token não aparece em nenhuma saída dos adaptadores.

**Dentro do Claude Code, chame o modo interativo com `!` na frente**, que executa
no terminal da sessão:

```
! /caminho/para/o/plugin/bin/cloudez-login
```

A tool Bash não serve para o prompt, e não é conservadorismo do plugin: ali não
existe terminal de controle nenhum — `/dev/tty` aparece mas responde
`Device not configured`. Medido, não presumido. O erro `no_tty` traz os dois
comandos prontos: `claude_code_command` (com o `!`) e `clipboard_command` (o pipe,
quando há clipboard).

Login por e-mail e senha **foi abandonado**: exigia o mesmo TTY, mais a senha do
usuário e um 2FA que só funciona com terminal. O que foi descoberto da API nessa
tentativa está no apêndice A de [`docs/mcp-tool-contract.md`](docs/mcp-tool-contract.md),
para não ser redescoberto do zero. `--password` responde `password_login_disabled`.

A resposta é lida em três faixas, e a diferença importa:

| Resposta da API | Interpretação |
|---|---|
| 2xx | token válido (`verified: true`) |
| 401 / 403 | recusado: exige login novo |
| offline, 5xx, sem `curl` | **inconclusivo** — passa com `verified: false` e um `warning` |

Falhar fechado no terceiro caso deixaria você sem deploy justamente quando não há
o que consertar, e a chamada seguinte à API falha com o erro dela, mais
informativo.

No login, a validação roda **depois** de escrever o arquivo, contra o token que
acabou de ser gravado — não contra o que estava na memória. Se a Cloudez recusar,
o token anterior volta: um paste errado não custa a credencial que já funcionava.

## Limitações conhecidas

**O prompt do login não tem cobertura automatizada.** `read < /dev/tty` precisa de
um pty, e alocar um em `bats` de forma portátil significa `script`, cuja sintaxe
divergente entre macOS e Linux é exatamente o tipo de coisa que já quebrou esta
suíte. O que fica sem teste é só a leitura do terminal: o que tem consequência —
escrever o segredo com 0600, validar depois do write, desfazer quando a Cloudez
recusa — mora em `save_token` (`bin/_lib.sh`) e é chamado direto pelos testes. O
`--stdin`, que não precisa de pty, é testado de ponta a ponta.

**A detecção de clipboard só foi verificada em macOS e em Linux headless.** O
caminho macOS foi testado de verdade; o "sem sessão gráfica → não oferece nada" é
exercitado pelo CI em `ubuntu-latest`, onde não há clipboard algum. Os ramos
`xclip`, `xsel` e `powershell.exe` seguem por raciocínio — ninguém rodou.

**A validação do token só foi exercitada contra a API real à mão** — os testes usam
um mock de `curl`. Verificado manualmente: um token inventado devolve `401` de
`api.cloudez.io`, e o plugin traduz isso em `token_invalid`. O caminho do token
válido (`2xx`) depende de uma credencial de verdade e nunca passou pela suíte.

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

O que sobrou depois de o control plane migrar para o MCP. Todos existem por
precisarem da **máquina local** — nenhum fala com a Cloudez.

| Script | Por que não é uma tool |
|---|---|
| `cloudez-login` | Coletar o token exige TTY; em argumento de tool ele entraria no transcript |
| `cloudez-pubkey` | Lê as chaves públicas de `~/.ssh` |
| `cloudez-setup` | Escreve o `.cloudez.yaml` do projeto |
| `cloudez-compose` | Inspeciona o diretório publicado |
| `cloudez-sync` (Go) | O transporte fica sempre local, por decisão do contrato |

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
    root: ~/staging.meusite.com.br/www/claude
```

As chaves da config são todas em inglês — só os textos, ajudas e erros do plugin
são em português.

O `domain` é o identificador do site — não há `site_id` na config. O `setup`
exige um FQDN (`meusite.com.br`), sem protocolo, caminho, query ou porta, e
normaliza para minúsculas: o domínio também vira caminho no servidor, e caminho
diferencia maiúscula onde o DNS não diferencia.

O `root` é **obrigatório e explícito**, e o `setup` gera
`~/<domain>/www/claude`. O document root do site na Cloudez é `~/<domain>/www`;
a estrutura de releases mora num subdiretório `claude/` dentro dele, para o
deploy não tomar conta do `www` inteiro — o que apagaria o que já estivesse lá.
Ele fica escrito no arquivo em vez de derivado do domínio de propósito: para onde
os arquivos vão é a decisão mais destrutiva do deploy, e destino implícito é
destino que ninguém confere.

Um `~/` inicial é removido, não expandido — os comandos remotos vão entre aspas
simples, e dentro delas o shell do servidor não expande til (criaria um
diretório chamado `~`). Caminho relativo resolve a partir do `$HOME` do usuário
ssh, que é o que `~/` significa. Caminho absoluto continua absoluto.

**Não há bloco `ssh` na config.** Host e usuário vêm da conta do usuário, pelo
`cloudez_get_site` (`cloud.fqdn` e `user.username`), a cada deploy — o
`/cloudez:deploy` os repassa aos adaptadores em `CLOUDEZ_SSH_HOST`,
`CLOUDEZ_SSH_USER` e `CLOUDEZ_SSH_PORT`.

Uma cópia do host num arquivo versionado envelhece: se a Cloudez mover o site de
servidor, o valor escrito continua apontando para o antigo e o deploy vai para o
lugar errado sem reclamar. Buscar a cada vez custa uma chamada e elimina a
classe inteira de erro.

Um bloco `ssh` presente na config ainda é aceito como fallback, para arquivos
escritos antes desta mudança não pararem de funcionar.

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
com o `root` que o `setup` gera, isso é `~/<domain>/www/claude/current`. Sem
esse ajuste no painel, o site segue servindo o que já estava em `~/<domain>/www`
e o deploy parece não ter efeito nenhum.
O servidor guarda as 5 releases mais recentes — é até onde o rollback alcança.

### Dependências

`git`, `ssh` e `tar` na máquina local, mais `jq` para os adaptadores em shell
e **Node 20+** para o servidor MCP embutido. No servidor, GNU coreutils — a
troca atômica do symlink usa `mv -T`, que não existe em BSD/macOS.

`curl` é **opcional**: sem ele o token não é verificado contra a API e o retorno
diz `verified: false`. Exigir curl para ler um arquivo local seria dependência
nova por nada.

Autenticação SSH é por chave, em `~/.ssh/`. Os scripts rodam com
`BatchMode=yes`: sem chave configurada eles falham na hora em vez de travar num
prompt de senha que o agente não consegue responder.

## Configuração

O `.mcp.json` referencia o servidor MCP por variável de ambiente, já que ele
vive em outro repositório:

```sh
export CLOUDEZ_MCP_PATH=/caminho/para/o/repo/do/mcp
```

O servidor MCP vem **dentro do plugin**, em `mcp/cloudez-mcp.mjs`: um arquivo
só, com as dependências embutidas, apontado pelo `.mcp.json` via
`${CLAUDE_PLUGIN_ROOT}`. Não há `npm install`, registry nem passo extra de
instalação.

É a mesma decisão dos binários de `libexec/`, e pelo mesmo motivo: quem instala
um plugin não deveria precisar montar nada. O bundle tem 768 KB — um dezessete
avos do que os binários Go já ocupam aqui.

O fonte fica em repositório separado. `./vendor-mcp.sh [caminho]` roda o bundle
lá e traz o resultado; o cabeçalho do arquivo diz de qual versão do
`cloudez-mcp` a cópia veio, que é o que torna a divergência entre os dois
repositórios visível antes de virar defeito.

O token **não** é passado por argumento nem colocado no `.mcp.json`: o servidor
MCP lê `~/.cloudez/token`, o mesmo arquivo que o `cloudez-login` escreve, e aceita
`CLOUDEZ_TOKEN` no ambiente como sobreposição. Uma fonte da verdade, escrita por
um comando que exige TTY.

O servidor relê esse arquivo **a cada chamada**, nunca na inicialização. Um
servidor stdio sobe junto com a sessão e só morre com ela; token lido no boot
congelaria o estado de autenticação, e quem rodasse `cloudez-login` no meio da
sessão continuaria vendo "não autenticado" sem entender por quê. É pela mesma
razão que o `.mcp.json` não injeta `CLOUDEZ_TOKEN` via `env` — o ambiente do
subprocesso é fixado no `spawn`. Em uso headless, escreva o arquivo em vez de
exportar a variável.

Um token com escopo por ambiente (staging que não alcança produção) seria melhor
para limitar estrago, mas depende de a Cloudez emitir tokens escopados — está
como pendência no contrato, não implementado.

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
