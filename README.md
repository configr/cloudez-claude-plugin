# cloudez-claude-plugin

Plugin do Claude Code para desenvolver e fazer deploy de sites na Cloudez.

## Arquitetura

Três camadas, deliberadamente separadas:

| Camada | O quê | Onde |
|---|---|---|
| **MCP** | capacidade — verbos primitivos da API Cloudez | repositório separado; contrato em [`docs/mcp-tool-contract.md`](docs/mcp-tool-contract.md) |
| **Comandos** | procedimento — a sequência de cada operação | `commands/` |
| **Skill** | porta de entrada em linguagem natural; encaminha ao comando | `skills/deploy/SKILL.md` |
| **Transporte** | envio dos arquivos | `bin/cloudez-sync` (Node) |
| **Adaptadores** | o que depende da máquina local | `bin/` (Node) |

O MCP é o control plane: descobre o destino, registra a release, ativa e faz
rollback. Ele nunca move bytes.

### Por que só Node

O `bin/` em shell era transitório, e acabou. Encolheu duas vezes e sumiu na
terceira.

Primeiro por **migração para o MCP**: `begin-deploy`, `finalize-deploy`,
`rollback`, `list-releases` e `compose-up` viraram tools e saíram daqui. Depois
por **troca de linguagem**: `cloudez-login` e `cloudez-setup` viraram Node,
porque o shell deles só existia numa época em que Node não era pré-requisito
assumido — e sustentar essa ficção custava um helper para escrever JSON com uma
minilinguagem de prefixos, um `curl` opcional e a pergunta de se há bash na
máquina. Com os dois em Node, os três arquivos de apoio (`_lib.sh`, `_yaml.sh`,
`_json.mjs`) saíram juntos: eram 174 linhas de andaime.

O que sobrou em `bin/` é o que **não** migra para o MCP, por depender da máquina
de quem publica: coletar o token (exige TTY) e escrever o `.cloudez.yaml`.

O `sync` não migra por outra razão: o transporte fica sempre local, por decisão
do contrato. Ele foi escrito **em Go** por bastante tempo, e a razão era boa —
distribuir um executável que não depende de runtime. Ela morreu no dia em que
Node 20+ virou pré-requisito assumido: o servidor MCP é um bundle Node que sobe
em toda invocação do plugin, então sem Node não há plugin, e um transporte nativo
não salvava nada.

O que ele custava, em troca de nada: 15 MB de binários versionados para seis
plataformas, três jobs de CI (dois só para tornar os blobs auditáveis), um
launcher de shell por plataforma para escolher o arquivo certo — e um segundo
escritor do arquivo de estado mantendo o schema por conta própria, que é o item
com defeito registrado: o round-trip por uma struct que não conhecia
`content_sha256` apagava o campo em silêncio.

Ele usa `tar` em stream sobre `ssh`, não `rsync`: o diretório de release está
sempre vazio, então o delta transfer não tem contra o que comparar, e
`tar`/`ssh` existem nativamente nas três plataformas enquanto `rsync` não existe
no Windows. O pipe entre os dois processos é montado por
descritor, sem passar por shell — o pipeline do PowerShell é orientado a texto e
corromperia o `.tar.gz`. Em Node isso significa passar o `stdout` do `tar` no
`stdio` do `ssh`, e **nunca** `.pipe()`, que rotearia cada byte pelo event loop.

## Instalação

Para desenvolvimento e uso local:

```sh
claude --plugin-dir /caminho/para/cloudez-claude-plugin
```

Não há etapa de build. O servidor MCP em `mcp/` é versionado no repositório e
todo o resto é fonte que roda direto, então o único pré-requisito é **Node 20+**.
`./vendor-mcp.sh` é necessário apenas depois de alterar o servidor MCP, que vive
em [repositório separado](https://github.com/configr/cloudez-mcp).

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
- `/cloudez:compose [diretório]` — escreve o `docker-compose.yml` da aplicação,
  junto com o usuário. Não é geração por template: o comando lê o projeto,
  pergunta o que ele não responde e propõe. As restrições do ambiente — a porta
  publicada é a **8080**, o dado que precisa sobreviver vai em volume nomeado —
  entram sem negociação;
- `/cloudez:deploy [environment] [diretório]` — o deploy. Confirma o site na
  Cloudez antes de qualquer coisa, então **exige autenticação**. Também é
  acionado quando você pedir em linguagem natural ("sobe o site", "publica em
  staging"): a skill `skills/deploy/` não tem procedimento próprio, ela só
  encaminha para este comando;
- `/cloudez:rollback [environment] [release_id]` — volta o site para uma release
  anterior. Existe separado porque a operação de emergência não pode morar dentro
  do procedimento que a causou: quem precisa dela não vai rolar um documento longo
  no pior momento. Não exige repositório git nem working tree limpo — nada é
  publicado a partir do disco local, as releases já estão no servidor. Em site de container ele
  reconstrói a imagem depois de trocar o symlink, sem o que o rollback não surte
  efeito nenhum.

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
- [x] Control plane inteiro no MCP; no `bin/` sobra o que exige TTY, escreve no
      projeto, ou é o transporte
- [x] Sync em Node (`tar` sobre `ssh`, sem `rsync`) — era Go, e o Go saiu junto
      com 15 MB de binários versionados e dois jobs de CI
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
- [x] Build antes da ativação: `cloudez_compose_build` constrói a imagem a partir
      de `releases/<id>` com o symlink ainda apontando para a versão anterior, e o
      `cloudez_compose_up` deixa de reconstruir. Encurta a janela em que o disco e
      o container discordam, de "o build inteiro" para "a recriação do container",
      e faz build quebrado ser deploy que não começou (contrato §3.8)
- [x] Comando `/cloudez:rollback`, para a operação de emergência não morar dentro
      do procedimento que a causou. Carrega o que foi exercitado contra servidor
      de verdade: em site de container o `cloudez_rollback` não basta — ele troca
      o symlink e o container segue na imagem anterior, servindo justamente o que
      se tentava tirar do ar —, então o comando reconstrói com
      `cloudez_compose_build` + `cloudez_compose_up` e fecha com
      `cloudez_health_check`
- [ ] O rollback de container depende de estado LOCAL. O `cloudez_rollback` é
      chaveado por domínio + root (estado do servidor), mas o `compose_build` e o
      `compose_up` são chaveados por `deploy_id` (estado em `.cloudez/state/`).
      Voltar de outra máquina, ou depois da poda de 7 dias, deixa a release
      alcançável e a imagem não — hoje o contorno é refazer o deploy no commit
      correspondente. Chavear as duas por release resolveria

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
```

**Token é a única forma de autenticar.** Gere no painel da Cloudez.

O `cloudez-login` só **coleta e grava**. Quem responde se você está autenticado é
a tool `cloudez_auth_status` do MCP, porque é o MCP que usa o token contra a API —
duas noções de "estou autenticado" em lugares diferentes acabam divergindo, e a
que erra é sempre a que ninguém está olhando. Nenhum adaptador em `bin/` exige
token: o deploy inteiro fala com o servidor por `ssh`, com a sua chave.

**Como** autenticar nesta máquina — o caminho absoluto do `cloudez-login` e o
utilitário de clipboard, se houver — vem da própria `cloudez_auth_status`, nos
campos `claude_code_command` e `clipboard_command`. Existiu um `cloudez-login
--hint` para isso, justificado por "o MCP não tem como saber": deixou de valer
quando o servidor passou a ser distribuído dentro do plugin, e o que sobrava era
uma chamada de Bash entre descobrir que falta token e saber o que fazer. Fora do
plugin — rodando o MCP do repositório dele — os campos simplesmente não vêm, em
vez de virem com um caminho inventado.

O `--stdin` é o caminho que funciona onde o agente está: um pipe não precisa de
terminal, e o segredo vai da origem (clipboard, arquivo, variável, gerenciador de
senhas) direto para o processo, sem passar pelo contexto de ninguém. Quem monta o
pipe nunca vê o valor — e é isso que permite rodar pela tool Bash sem vazar nada.

> O que **não** vale é o próprio agente montar o pipe com um token que ele
> conhece: se ele conhece, já vazou. Vale pipe de fonte opaca, não `echo`.

`--stdin` em si é portátil — é um pipe. O **clipboard como fonte** não é, e o
`cloudez_auth_status` só o oferece quando existe de verdade:

| Ambiente | Clipboard |
|---|---|
| macOS | `pbpaste`, sempre presente |
| Windows via WSL ou Git Bash | `powershell.exe Get-Clipboard` |
| Linux, SSH, container, CI, Claude Code remoto | **nenhum** — cai para o prompt |

Houve uma via para X11 e Wayland (`wl-paste`, `xclip`, `xsel`), atrás de uma
checagem de `DISPLAY`/`WAYLAND_DISPLAY` — porque instalado não é o mesmo que
disponível: esses utilitários guardam o clipboard no servidor gráfico e, sem ele,
existem e falham. A checagem estava certa; a via saiu assim mesmo, porque
**ninguém nunca a rodou** contra um desktop Linux de verdade. Num fluxo de
credencial, oferecer um comando não verificado troca "roda algo que funciona" por
"vê um erro do xclip e não sabe de quem é a culpa".

O que se perde é conveniência, não capacidade: no Linux com desktop o login cai
para o prompt com `!`, que funciona em toda parte. A precedência continua com
teste; se alguém exercitar a via de verdade, ela volta.

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
| offline, 5xx | **inconclusivo** — passa com `verified: false` e um `warning` |

Falhar fechado no terceiro caso deixaria você sem deploy justamente quando não há
o que consertar, e a chamada seguinte à API falha com o erro dela, mais
informativo.

No login, a validação roda **depois** de escrever o arquivo, contra o token que
acabou de ser gravado — não contra o que estava na memória. Se a Cloudez recusar,
o token anterior volta: um paste errado não custa a credencial que já funcionava.

Isso tudo mora em **um lugar só**, `src/token-store.ts` no repositório do MCP, e
chega ao plugin pelo bundle `mcp/cloudez-auth.mjs`. A função devolve o veredito
com o arquivo já restaurado; que a recusa seja fatal, com que código de erro e o
que se imprime é decisão do `cloudez-login` — mecanismo na biblioteca, política
em quem tem interface com gente.

## Limitações conhecidas

**~~O prompt do login não tem cobertura automatizada.~~ Fechada**, por
`test/pty.bats`. A objeção registrada aqui era que alocar um pty de forma portátil
significa `script(1)`, cuja sintaxe divergente entre macOS e Linux é o tipo de
coisa que já quebrou esta suíte. Ela era legítima e acabou sendo a parte fácil: a
divergência cabe num condicional de três linhas dentro do `com_pty`.

O caro foi outro, e vale registrar porque nada disso aparece na documentação do
`script`:

- **alimentar por redirect simples não funciona.** Os bytes chegam antes de o
  processo entrar em modo raw, a disciplina de linha os consome e ecoa, e o login
  recebe entrada **vazia** — um teste verde afirmando sobre outra coisa. A
  sincronização é esperar o prompt aparecer, que é um ponto exato: `pedirToken`
  liga o raw **antes** de escrever `Token: `;
- **a entrada tem de ser um pipe, nunca um fifo nomeado.** O `script` do BSD faz
  `tcgetattr` no próprio stdin e recusa fifo;
- **o `script` envia EOT ao pty quando o stdin dele fecha**, e o terminal ecoa isso
  como `^D`. O eco cai num ponto que depende de escalonamento — colado ao `{` do
  payload, o JSON deixa de começar em início de linha. Era intermitência real, e
  por isso a captura normaliza `\r`, `\b` e `^D`.

O que a camada nova cobre e nenhuma outra cobria: o modo raw, o **backspace** e o
**Ctrl-C** — que o `read -rs` do bash dava de graça e viraram código nosso quando o
adaptador virou Node — e o não-eco, que é a razão de o prompt existir. De quebra,
tornou alcançável o ramo do `--stdin` chamado de um terminal, que o
`test/auth.bats` registrava por escrito como fora de alcance.

Isso levou o `cloudez-login` de **60,5% para 93,8%** das linhas com código, e o
total de `bin/` para 95,4%. O que sobra sem cobertura ali é o ramo de Windows do
`abrirTerminal`, que por definição não roda na matriz.

**Uma ressalva honesta:** o caminho do `script` foi exercitado de verdade só no
macOS. O ramo do util-linux segue por leitura da documentação — quem o executa é o
CI, no primeiro push.

O que tem consequência já estava coberto antes disso, e continua: escrever o
segredo com 0600, validar **depois** do write e desfazer quando a Cloudez recusa
são todos atravessados pelo `--stdin`, que não precisa de pty. O `test/pty.bats`
não duplica nenhum deles de propósito.

**A detecção de clipboard só foi verificada em macOS.** O caminho `pbpaste` foi
testado de verdade; o "sem clipboard → não oferece nada" é exercitado pelo CI em
`ubuntu-latest`, onde não há nenhum. O ramo `powershell.exe` segue por raciocínio
— ninguém rodou. Os ramos X11/Wayland **saíram** pela mesma razão, e essa é a
diferença: o `powershell.exe` fica porque no Windows não há alternativa boa, e o
`xclip` saiu porque no Linux o prompt com `!` já resolve.

**A validação do token só foi exercitada contra a API real à mão.** Os testes
sobem uma API falsa em porta efêmera (`test/mocks/api-server.mjs`) — o que
verifica a requisição enviada, o esquema `Token` e os três vereditos, mas não que
`api.cloudez.io` responda o que se espera. Verificado manualmente: um token
inventado devolve `401`, e o plugin traduz isso em `token_invalid`. O caminho do
token válido (`2xx`) depende de uma credencial de verdade e nunca passou pela
suíte.

**~~`/cloudez:login` e `/cloudez:setup` no Windows só funcionam sob um bash.~~
Fechada.** Foram três causas encadeadas, e vale registrar as três porque a
última só ficou visível depois de as outras duas saírem.

O `jq` foi a primeira: o Windows não o traz e o Git for Windows também não — o
Git Bash embarca um subconjunto do MSYS2 com bash, coreutils, sed, awk, curl, ssh
e tar, sem ele —, então o `need jq` reprovava justamente no único ambiente onde
esses scripts rodavam.

A segunda foi os dois serem **bash sem par `.cmd`**. O `cloudez-sync.cmd` existe
e funciona porque invoca um `.exe` nativo; um `.cmd` não roda script POSIX sem um
bash para chamá-lo. Fechou quando os dois viraram Node, com shebang próprio.

A terceira apareceu por causa da segunda: um arquivo **sem extensão** com sintaxe
ESM é lido como CommonJS pelo Node 20, e o `import` vira erro de sintaxe. O Node
22+ detecta o módulo sozinho, então o defeito era invisível em máquina moderna e
quebraria exatamente no piso declarado. Resolvido pelo `bin/package.json` com
`{"type": "module"}`, e fixado por testes que rodam os dois adaptadores com
`--no-experimental-detect-module`.

O que segue sem verificação é o **deploy** a partir de Windows, e hoje por uma
razão só: ninguém rodou um. A barreira que estava registrada aqui — o
`commands/deploy.md` mandando gerar o `idempotency_key` com `uuidgen`, que o Git
Bash não embarca — caiu quando o servidor passou a gerar a chave: o comando agora
diz para **não** passá-la.

**O Windows tem cobertura das duas portas de entrada do `sync`.** Um job sobre
`windows-latest`, com o Node fixado em 20 — o piso declarado, e não o que o runner
traz por acaso, porque é exatamente aí que um arquivo sem extensão com sintaxe ESM
é lido como CommonJS:

- `bin/cloudez-sync.cmd`, o caminho de quem chama pelo cmd ou PowerShell, que
  existe porque no Windows o shebang não vale nada: propagar o código de saída,
  resolver o alvo pelo próprio nome do arquivo e falhar com mensagem útil quando o
  alvo não está lá;
- `bin/cloudez-sync`, o caminho de quem chama de dentro de um bash — Git Bash vem
  junto com o Git. Verifica que o shebang resolve neste ambiente e carrega a
  **âncora do hash entre plataformas**: um `--hash-only` sobre uma árvore conhecida
  cujo `content_sha256` precisa bater com o valor fixado na suíte de unidade. É o
  que impede o Windows de produzir uma família de hashes própria — se divergisse, o
  mesmo conteúdo publicado de máquinas diferentes viraria releases diferentes.

Esta segunda frente existe porque o plugin já quebrou exatamente aí, na versão
anterior da peça: `uname -s` no Git Bash devolve `MINGW64_NT-10.0-...`, não
`windows`, e o launcher procurava um binário com esse nome enquanto o
`sync-windows-amd64.exe` correto estava ao lado. O `.cmd` tinha cobertura desde
sempre e o POSIX não, então o defeito ficou invisível: há dois caminhos de
entrada, e um só era verificado. Sem binário por plataforma essa classe de
defeito desapareceu, mas a lição sobre cobrir as DUAS portas não.

O que segue sem verificação em Windows: a suíte `bats` não roda ali — portá-la
significaria bash e coreutils no runner, muito trabalho para cobrir o que já é
coberto em duas outras plataformas — e um deploy de verdade a partir de Windows
nunca foi feito.

**`sync` → `finalize` contra servidor real** continua sem cobertura: os testes
verificam o comando enviado, não o efeito no servidor. A exceção é o formato do
pacote — o empacotamento e a detecção de corrupção rodam com o `tar` de verdade,
porque nenhum mock reproduz o CRC do gzip.

**Não há mais binário versionado.** Eram seis, ~15 MB somando as plataformas, e
cada rebuild acrescentava cópias ao histórico do git — o que já era administrado
rebuildando só quando o fonte mudava, e chegou a ter Git LFS como plano B. Saíram
com o Go: hoje o único artefato versionado é o bundle do MCP, e o que ele embarca
é auditável lendo o repositório.

## Testes

```sh
test/run.sh
```

Quatro camadas: `claude plugin validate` (estrutura), `shellcheck` (estático),
`node --test` (unidade) e `bats` (comportamento). Ferramentas ausentes viram aviso
local e erro com `--strict`, que é o que o CI usa — `git clone && test/run.sh`
funciona sem instalar nada, mas o CI não passa com meia suíte.

A camada de unidade existe para o que afirma sobre uma **função**, e não sobre um
comando: as propriedades do hash do payload precisam hashear duas árvores e
comparar, e fazer isso por linha de comando seria exercitar o adaptador para
testar a biblioteca. `node --test` é embutido no Node 20, então ela não custa
dependência nenhuma.

Havia uma quinta, de **build**, e ela saiu junto com o Go: não há mais artefato
para compilar antes de testar.

A única dependência que a suíte pede além do runtime é o `shellcheck`, e é de
lint. O `jq` era a outra, e saiu quando `test/helpers/json.mjs` assumiu a
extração de campo — as afirmações que o usavam continuam idênticas.

### Cobertura

```sh
test/run.sh --coverage
```

Junta o que as **duas** camadas executaram e reporta `bin/` por linha e por função.
Nenhuma ferramenta embutida faz isso aqui: o `--experimental-test-coverage` do
`node --test` só enxerga o que o próprio processo carrega, e os adaptadores são
exercitados pelo bats como subprocesso. O que alcança os dois é o
`NODE_V8_COVERAGE`, que faz todo processo Node despejar o coverage bruto do V8 num
diretório; `test/coverage.mjs` junta. O `c8` resolveria em uma linha, ao preço de
trazer `node_modules` e um `npm install` de volta.

**Não é portão de CI, de propósito.** Cobertura como critério de aprovação produz
teste escrito para o número. Como relatório sob demanda ela já se pagou: apontou
que os únicos caminhos sem exercício em `bin/cloudez-sync` são três `catch` de
erro difícil de provocar, e que o `proc.on("error")` do transporte — o caso de
`tar` ou `ssh` ausentes do PATH — foi verificado à mão e nunca virou teste.

Foi também o que motivou o `test/pty.bats`: a primeira medição pôs o
`cloudez-login` em 60,5%, e as linhas que faltavam eram exatamente a limitação do
prompt de TTY que este README declarava. Que a medição caísse ali, sozinha, é o que
deu confiança de que ela mede o que se pensa — e o que mostrou que valia a pena
atacar a limitação em vez de conviver com ela. Hoje o arquivo está em 96,9%.

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

| Script | Linguagem | Por que não é uma tool |
|---|---|---|
| `cloudez-login` | Node | Coletar o token exige TTY, e um servidor stdio não tem terminal de controle |
| `cloudez-setup` | Node | **Escreve** no projeto do usuário |
| `cloudez-sync` | Node | O transporte fica sempre local, por decisão do contrato |
| `_out.mjs` | Node | Não é adaptador: o envelope de saída que os dois compartilham |

O `cloudez-login` não implementa o contrato do token: importa
`mcp/cloudez-auth.mjs`, o mesmo código que o servidor usa.

Ler a máquina local nunca foi razão para ficar fora do MCP — o servidor roda na
mesma máquina, e já lê `~/.cloudez/token`. Por isso `cloudez-pubkey` e
`cloudez-compose` viraram `cloudez_list_local_ssh_keys` e `cloudez_find_compose`:
o que se ganha é permissão, porque um comando que precisava de
`Bash(cloudez-pubkey:*)` autorizava executar shell, e uma tool autoriza uma
leitura.

O `cloudez-setup` fica porque **escrever** no projeto é decisão de outra ordem, e
merece a discussão de onde o servidor tem permissão para gravar antes de migrar.

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
`cloudez_get_site` (`cloud.fqdn` e `user.username`), a cada deploy. Quem os
resolve é o `cloudez_begin_deploy`, **uma vez**, e os grava no estado do deploy em
`.cloudez/state/` — é de lá que o `cloudez-sync`, o `finalize` e o `compose_up` os
leem. Resolver a cada passo abriria a porta para o envio ir a um servidor e a
ativação a outro.

Houve uma fase em que o modelo repassava esses valores aos adaptadores por
ambiente, em `CLOUDEZ_SSH_HOST`, `CLOUDEZ_SSH_USER` e `CLOUDEZ_SSH_PORT`. Essas
variáveis **não existem mais** em nenhum código do plugin — a doc as citava
depois de o mecanismo ter saído.

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

Na máquina local: **Node 20+**, `ssh` e `tar`. No servidor, GNU coreutils — a
troca atômica do symlink usa `mv -T`, que não existe em BSD/macOS.

O Node é **pré-requisito declarado**, não uma conveniência: ele roda o servidor
MCP embutido e os dois adaptadores de `bin/`. Assumi-lo
explicitamente é o que permitiu apagar as acomodações que existiam para
contorná-lo — cada uma delas custava mais complexidade do que a dependência que
evitava.

**`git` não é dependência.** Foi até o deploy passar a identificar a release pelo
hash do conteúdo publicado; antes disso o `ref` era a única referência, e sem
repositório não havia deploy. Hoje o commit entra no `release_id` quando existe
(sufixo `g1a2b3c`) e o hash do conteúdo entra quando não (sufixo `c9f8e7d`). As
duas chamadas que restam já toleram a ausência: o passo 3 do deploy segue sem
`ref`, e o `cloudez-setup` grava `gitignore: "skipped"` fora de um repositório.

**`jq` saiu, e saiu duas vezes.** Primeiro do runtime: nos adaptadores ele nunca
lia JSON — os usos construíam, sempre `jq -n --arg`, que estava ali porque é o que
escapa corretamente valores vindos do usuário (domínio, caminhos, mensagens com
aspas). O substituto foi um helper em Node, `_json.mjs`, com uma minilinguagem de
prefixos (`:` para literal, `+` para merge na raiz) que só fazia sentido porque
quem o chamava era um shell; ele também já saiu, porque com os adaptadores em Node
o objeto é escrito como objeto.

Ficou como dependência **de teste**, onde finalmente fazia o que sabe fazer: ler
JSON. Saiu de lá também, quando `test/helpers/json.mjs` assumiu a extração de
campo — um extrator de ~40 linhas que aceita caminho com ponto e índice de array,
e nada além disso. As afirmações que o usavam continuam idênticas; o que mudou é
que `git clone && test/run.sh` deixou de pedir um pacote a mais.

O que sobrou de dependência externa na suíte é o `shellcheck`, e é de lint.

**`curl` saiu do runtime também.** Ele era *opcional* de propósito — sem ele o
token não era verificado e a resposta caía para `verified: false` —, e esse ramo
inteiro deixou de existir quando o `cloudez-login` virou Node: o `fetch` é nativo
desde o Node 18. Uma dependência a menos e um caso a menos para testar.

Autenticação SSH é por chave, em `~/.ssh/`. Os scripts rodam com
`BatchMode=yes`: sem chave configurada eles falham na hora em vez de travar num
prompt de senha que o agente não consegue responder.

## Configuração

O `.mcp.json` referencia o servidor MCP por variável de ambiente, já que ele
vive em outro repositório:

```sh
export CLOUDEZ_MCP_PATH=/caminho/para/o/repo/do/mcp
```

O MCP vem **dentro do plugin**, em dois arquivos com as dependências embutidas.
Não há `npm install`, registry nem passo extra de instalação.

| Arquivo | O quê | Quem usa |
|---|---|---|
| `mcp/cloudez-mcp.mjs` | o servidor; sobe um transporte stdio ao ser importado | o `.mcp.json`, via `${CLAUDE_PLUGIN_ROOT}` |
| `mcp/cloudez-auth.mjs` | biblioteca: o contrato do token | `bin/cloudez-login`, por `import` |

São dois porque o servidor **não pode ser importado**: um adaptador de linha de
comando que o importasse ficaria pendurado num transporte que ninguém pediu.
Entrypoints separados (`src/index.ts` e `src/plugin-lib.ts`), um bundle cada, o
mesmo `vendor-mcp.sh` traz os dois — e a suíte confere que carregam a mesma
versão, porque copiar um e esquecer o outro divergiria exatamente no código que
os dois lados precisam compartilhar.

O segundo existe para acabar com uma duplicação que era só disciplina: o
`cloudez-login` reimplementava a precedência do token, o header `Authorization:
Token` e a tabela de vereditos que o MCP já tinha. Hoje ele importa. O modo de
falha que isso fecha é o pior de diagnosticar — o login dizendo "autenticado" e
o MCP dizendo que não.

Era a mesma decisão dos binários que viviam em `libexec/`, e pelo mesmo motivo:
quem instala um plugin não deveria precisar montar nada. Hoje é a única
sobrevivente dela — os binários saíram quando o `sync` virou Node, e o bundle de
768 KB é o que restou de artefato versionado, contra os 15 MB que eles ocupavam.

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
