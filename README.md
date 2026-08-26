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

### Comandos

Com o plugin ativo:

- `/cloudez:login` — verifica se há token da Cloudez salvo e, se não houver,
  conduz o usuário até ele: pergunta se já tem conta, aponta a página certa do
  painel dele (ou o cadastro, se for o caso) e captura o token sem que ele passe
  pela conversa;
- `/cloudez:setup <domain> <environment>` — cria o `.cloudez.yaml` do projeto, se
  ainda não existir. Os dois argumentos são obrigatórios: o domínio identifica o
  site, o environment dá nome ao bloco gerado. Faltando algum, o comando pergunta.
  Antes de escrever qualquer coisa ele confirma o domínio contra a API
  (`cloudez_get_site`), então **exige autenticação** e começa pelo
  `/cloudez:login`. Domínio que não está na conta é erro, não config criada com
  aviso: um typo aceito aqui só apareceria no deploy, longe da causa;
- `/cloudez:compose [diretório]` — escreve o Compose da aplicação, junto com o
  usuário. Não é geração por template: o comando lê o projeto, pergunta o que ele
  não responde e propõe. As restrições do ambiente — a porta publicada precisa
  bater com a `custom_port` do site (**3000** por padrão), o dado que precisa
  sobreviver sai do diretório da release — entram sem negociação.
  **Se já existe um Compose no projeto, ele não é reescrito**: o arquivo é o de
  desenvolvimento, é o que o usuário roda todo dia, e as diferenças de produção
  vão para um `docker-compose.cloudez.yml` que só o servidor lê. Localmente
  continua sendo `docker compose up`, sem argumento. Dado que precisa sobreviver
  vai em **volume nomeado**, que a poda de releases não alcança e cuja permissão o
  Docker resolve sozinho; quem preferir o dado visível no host usa bind relativo,
  e aí o deploy o liga a `claude/shared/` no modelo do Capistrano;
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

## Do zero ao ar: um deploy completo

O caminho inteiro, na ordem. Cada passo é um comando — você conversa com ele, e
ele conduz. O que está escrito aqui é o que esperar, não um roteiro a decorar.

**Antes de começar, uma coisa precisa existir e não é criada por aqui: o site na
Cloudez.** Crie-o no painel, com o tipo **Docker** (`container_docker`). O plugin
publica aplicação em container e só; num site de tipo estático o deploy roda
inteiro, sem erro nenhum, e a Cloudez continua servindo os arquivos como estavam —
a falha mais confusa que este plugin consegue produzir. O `/cloudez:setup` para e
avisa se encontrar o tipo errado.

### 1. `/cloudez:login`

Ele verifica se já existe token salvo. Não havendo, pergunta se você tem conta,
aponta a página certa do painel — que é **o seu**, porque a Cloudez é white-label
e cada revenda tem o próprio domínio — e captura o token.

O token **não passa pela conversa**: você copia, e o comando o lê da área de
transferência. Ele fica em `~/.cloudez/token`, com modo 600, e é validado contra a
API antes de ser aceito.

### 2. `/cloudez:setup <domínio> <environment>`

```
/cloudez:setup meusite.com.br producao
```

Cria o `.cloudez.yaml` do projeto. Antes de escrever qualquer coisa, ele confirma
o domínio contra a API — um typo aceito aqui só apareceria no deploy, longe da
causa.

Além do arquivo, este passo confere **o que o site precisa ter configurado**, que
é onde quase todo primeiro deploy tropeça:

- **`app_root_path` = `claude/current`.** O deploy publica em
  `~/<domínio>/www/claude/current`, e o servidor web precisa entregar esse
  diretório. Apontando para outro lugar, o site continua servindo o que já estava
  em `www` e o deploy parece não ter efeito;
- **`custom_port` igual à porta que o Compose publica.** É para onde o nginx da
  Cloudez encaminha. Não batendo, o deploy termina verde e o site responde 502;
- **a chave SSH desta máquina autorizada na conta.** Sem isso o envio falha por
  permissão negada — no meio do deploy, depois de o build já ter rodado. O comando
  lista suas chaves locais e propõe autorizar.

### 3. `/cloudez:dev` (opcional, mas é o passo barato)

Sobe a aplicação na sua máquina — pelo dev server do projeto, quando é Node, ou em
container — e abre no navegador. Descobrir aqui que falta uma variável de ambiente
custa um minuto; descobrir no deploy custa um site fora do ar.

### 4. `/cloudez:deploy`

```
/cloudez:deploy producao
```

O que ele faz, em ordem: **mede o site como ele está agora** (para haver com o que
comparar depois), registra a release, envia os arquivos, constrói a imagem, troca
o symlink `current` e sobe o container. A ativação é a troca de um link —
atômica, e reversível.

No fim ele verifica que o site responde e **compara com a medição do começo**. Se
o site estava fora do ar antes do deploy, ele diz isso em vez de creditar a falha
à sua mudança.

Você também chega aqui em linguagem natural — "sobe o site", "publica em staging".

> **Projeto sem Compose?** O deploy **para** antes de publicar qualquer coisa e te
> manda para o `/cloudez:compose` — sem Compose ele estaria publicando arquivos que
> ninguém executa. Você não precisa chamar aquele comando antes: chame quando o
> deploy pedir, e rode o deploy de novo depois.
>
> O `/cloudez:compose` escreve o arquivo **junto com você**, lendo o projeto e
> perguntando o que ele não responde. Se já existe um Compose, ele **não é
> reescrito**: aquele arquivo é o de desenvolvimento, é o que você roda todo dia, e
> as diferenças de produção vão para um `docker-compose.cloudez.yml` que só o
> servidor lê. Precisando de banco, ele pergunta em vez de decidir — o padrão é no
> container, com volume nomeado, e a alternativa é uma instância gerenciada pela
> Cloudez.

### 5. Deu errado: `/cloudez:rollback`

```
/cloudez:rollback producao
```

Volta para a release anterior. Existe como comando separado de propósito: quem
precisa dele não vai rolar um documento longo no pior momento possível. Não exige
git nem working tree limpa — as releases já estão no servidor.

### Depois do primeiro deploy

- **Banco no container?** Configure o backup, que é sua responsabilidade nessa
  opção: `cloudez_install_backup` grava o script no servidor **e o roda uma vez**
  para provar que funciona, e `cloudez_create_cron` agenda;
- **Credenciais?** `cloudez_set_env` as grava em `<root>/shared/.cloudez.env` no
  servidor. É a única rota: a sobreposição é versionada, e o que está no
  `.gitignore` não é transferido;
- **O servidor guarda o histórico.** Cada deploy escreve um manifesto em
  `<root>/.cloudez/deploys/`, com o commit e o hash do que subiu. Serve para
  descobrir o que está no ar mesmo quando quem publicou foi outra pessoa.

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
      estado compartilhado com o `cloudez-sync` pelo arquivo `~/.cloudez/state/`)
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
      `compose_up` são chaveados por `deploy_id` (estado em `~/.cloudez/state/`).
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

**Token é a única forma de autenticar.** Gere no painel da Cloudez, em
`https://<domínio-do-painel>/account?tab=token`.

O domínio varia: a Cloudez é **white-label**, e cada revenda tem o seu —
`cloud.configr.com` é o da Configr, não é "o" painel. Quem ainda não tem conta
cria em <https://cloud.configr.com/register>. O `/cloudez:login` conduz os dois
caminhos, e é ele que pergunta o domínio em vez de presumir um.

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

## Banco de dados

O padrão é **no container, com volume nomeado** — o banco no mesmo arquivo que o
resto, subindo igual na máquina de quem desenvolve e no servidor, sem depender de
recurso provisionado na conta. O volume nomeado importa porque o Postgres roda
como o usuário `postgres` da imagem, e volume nomeado herda essa dona.

O preço é o backup, que passa a ser do projeto — e o plugin o configura, em vez
de deixar a instrução escrita e nada rodando. São duas chamadas:
`cloudez_install_backup` grava `<root>/.cloudez/backup-db.sh` no servidor **e o
roda uma vez**, e `cloudez_create_cron` agenda pelo painel da Cloudez (e não por
`crontab -e` no ssh, que ficaria invisível para quem administra o site e sumiria
numa migração de servidor).

A execução de verificação é o ponto: ela prova que o serviço se chama o que
disseram, que o cliente do banco existe naquela imagem e que o container responde
a `exec`. Sem ela, o primeiro sinal de que nada disso é verdade seria uma
restauração que não acontece.

Os dumps são **lógicos** (`pg_dump`/`mysqldump` contra o container em pé), vão
para `<root>/shared/backup/<engine>/` e ficam 7 diários e 4 semanais. O dump vai
para `shared/` mesmo com o banco em volume nomeado — o volume é onde o banco vive,
e `shared/backup/` é onde as cópias ficam visíveis no host.

O script recusa três coisas de propósito, e cada uma é um jeito conhecido de um
backup existir sem servir: **podar antes de o dump novo estar no lugar** (uma
semana de falhas apagaria os bons um por dia), **aceitar um dump vazio** (o gzip
de um erro é um arquivo válido e minúsculo) e **confundir o status do gzip com o
do dump** (num pipeline o shell só olha o último comando). Quem quiser saber se
está rodando lê `ULTIMO_OK` e `ULTIMA_FALHA` no mesmo diretório — cron que falha
em silêncio é o modo de falha padrão dessa rotina.

**Datadir nunca vai para `shared/` por bind.** O bind relativo é para arquivo. Para
banco ele junta a permissão dependente do host com uma semeadura que copia arquivo
de um datadir possivelmente em uso — cópia inconsistente, na melhor hipótese.

Depois de propor isso, o `/cloudez:compose` **oferece** a alternativa gerenciada,
como otimização e não como padrão: `cloudez_create_database(domain, engine,
database_name)` provisiona a instância na cloud do site e a vincula a ele. A cloud
e o vínculo saem do domínio; a senha é gerada pela tool e nunca recebida pela
conversa. O que ela resolve é justamente o backup; o que ela custa é recurso na
conta, que pode ser cobrado. Em produção o serviço de banco do Compose não sobe
(`profiles: ["dev"]`), e quem depende dele precisa de `depends_on: !reset null` —
sem isso o Compose recusa o projeto inteiro. Engines disponíveis variam por
empresa: confira com `cloudez_list_database_types`.

Nos dois casos o desenvolvimento é igual — o banco sobe pelo Compose na máquina de
quem desenvolve. O que muda é só produção.

## Segredos, e por onde eles chegam ao servidor

Não havia rota. O `docker-compose.cloudez.yml` é versionado, então a credencial
não pode ir nele; e o que está no `.gitignore` o `cloudez-sync` não transfere,
então um `.env` local nunca chega lá. Ou o segredo ia para o git, ou não existia
em produção.

`cloudez_set_env(domain, root, vars)` grava em `<root>/shared/.cloudez.env`, modo
600, e o deploy o liga dentro de cada release — o mesmo modelo Capistrano do resto
do `shared/`, então ele sobrevive à poda e uma release nova o encontra no lugar. A
sobreposição declara `env_file: [.cloudez.env]` para a aplicação lê-las.

Duas decisões que valem ser ditas:

**Mescla por chave.** Gravar o `DATABASE_URL` não apaga um `SECRET_KEY` que já
estava no arquivo — o arquivo é de todas as variáveis do site, não de uma. Quem
quiser o contrário pede `replace`.

**O retorno traz só os NOMES.** Um retorno com o valor colocaria a credencial no
transcript a cada chamada, inclusive nas que só conferem o que está lá.

E o deploy liga o arquivo **apenas se ele existir**: criar um vazio sempre daria a
todo site um `shared/` e um arquivo que ninguém pediu. O custo dessa escolha é que
declarar `env_file` antes de gravar as variáveis faz o Compose recusar o projeto —
uma falha barulhenta, com mensagem própria, que é a categoria certa para uma ordem
invertida entre dois passos.

## Guard-rail de escrita em aplicação viva

O plugin instala um hook `PreToolUse` (`hooks/hooks.json`) que **bloqueia escrita
HTTP para host remoto** feita pela tool Bash: `curl`/`wget` com `-X POST|PUT|PATCH
|DELETE`, `-d`, `-F`, `-T` e equivalentes. Leitura (`GET`, `HEAD`) passa, e
`localhost` passa — o `/cloudez:dev` sobe a aplicação ali justamente para ser
exercitada.

Ele existe por dois incidentes, não por precaução teórica: um agente deixou um
recado assinado "Claude" num mural público gravado em Postgres, e enviou um PNG de
teste a um site de uploads. **Nenhum dos dois foi desobediência a uma regra
escrita** — foram falhas de classificação, em que a escrita parecia parte do que
tinha sido pedido. Instrução em `commands/` não corrige isso, porque depende do
mesmo julgamento que falhou.

Bloqueado, o agente recebe o motivo e o caminho. Quem libera é o usuário:

```sh
cloudez-approve      # no terminal DELE, não pela tool Bash
```

A análise é por **trecho** do comando, não pela linha inteira: só conta como
escrita a flag que está no mesmo segmento do `curl`. Sem isso,
`curl -s <url> | grep -F erro` era bloqueado — e `cut -d` e `xargs -d` também,
porque a varredura global via o `-d` de outro programa do pipeline. Leitura
seguida de filtro é metade do uso legítimo de `curl`.

Os comandos do próprio plugin não passam por aqui: o `cloudez-sync` usa tar sobre
ssh, o `cloudez-login` lê do clipboard, e as tools do MCP fazem HTTP dentro do
processo Node — nenhum deles é `curl` pela tool Bash.

A aprovação vale para **o comando exato** (hash do texto inteiro), **uma vez só**
— o hook a apaga ao usar — e expira em 10 minutos. O comando exibe o que foi
bloqueado, lido de `~/.cloudez/pending-write.json`, em vez de pedir que o usuário
redigite: comando redigitado é comando que se aprova diferente do que vai rodar.

**A peça que faz isso valer é o terminal.** O `cloudez-approve` abre `/dev/tty`
com `openSync` e recusa com `no_tty` quando não há terminal de controle — que é o
caso de qualquer coisa rodada pela tool Bash de um agente. É isso, e só isso, que
distingue "um humano decidiu" de "o modelo decidiu por si". A primeira versão
usava `createReadStream`, que é preguiçoso e não falha de forma síncrona: o
approve rodado sem terminal exibia o prompt em vez de recusar.

**O limite, dito de frente:** isto fecha as vias enumeráveis — `curl` e `wget` pela
tool Bash. Não fecha `python -c "requests.post(...)"`, `nc`, nem tools de outros
MCP. Prometer cobertura total seria repetir o erro de confiar num julgamento, só
que agora no julgamento sobre o que foi enumerado.

`CLOUDEZ_GUARD_DIR` sobrepõe o diretório de estado, e é o que a suíte usa para não
escrever no `~/.cloudez` de quem roda os testes.

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

**O ramo do util-linux custou um CI vermelho, e a lição ficou em teste.** Ele foi
escrito por leitura da documentação, com o macOS verde, e quebrou no primeiro
push: o `script` do util-linux devolve o **próprio** código de saída, não o do
filho, a menos que receba `-e`. Sem a flag, toda afirmação sobre falha virava
sucesso — e como o `script` do BSD propaga por padrão, só o ubuntu acusou.

Duas coisas saíram disso. A flag, obviamente; e dois testes que verificam o
**harness**, não o plugin: `com_pty` rodando um comando que sai com 3 e outro que
sai com 0. Um harness do qual sete testes dependem para afirmar sobre falha
precisa provar que sabe distinguir falha de sucesso.

O ramo também passou a ser exercitável fora do Linux, por um `script` falso que se
anuncia como util-linux e recusa a chamada sem `-e`. Não substitui o CI, mas tira
"nunca ninguém rodou" da frente.

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
`~/.cloudez/state/` — é de lá que o `cloudez-sync`, o `finalize` e o `compose_up`
os leem. Resolver a cada passo abriria a porta para o envio ir a um servidor e a
ativação a outro.

O caminho é **absoluto**, e isso é correção de defeito. Era `.cloudez/state/`,
relativo, e o arquivo tem dois escritores que resolviam esse relativo contra
diretórios diferentes: o servidor MCP contra o diretório da sessão, o
`cloudez-sync` contra o diretório de onde foi chamado. Enquanto coincidiam
funcionava; quando não, o `begin_deploy` gravava num lugar e o sync procurava
noutro, e o deploy morria com `deploy_not_found` sem nada de errado com ele. O
home já era a casa do plugin — o token mora em `~/.cloudez/token` desde sempre.

A leitura ainda cai no `.cloudez/state/` do diretório atual quando não acha no
home, para um deploy em andamento no momento do upgrade não ficar órfão. A
escrita é sempre no home. `CLOUDEZ_STATE_DIR` continua sobrepondo os dois, e é o
que a suíte usa para isolar.

**Não se guarda o estado no servidor**, e a razão é onde ele é LIDO: o
`cloudez-sync` lê dali o destino ssh para então conectar, e um estado no servidor
precisaria do destino para ser lido — que é o dado que ele contém. Além disso o
sync deixaria de funcionar sem token, já que resolver o destino de novo passa
pela API.

### Onde o dado persistente mora

**Volume nomeado é o padrão**, em produção e em desenvolvimento — o mesmo arquivo
nos dois lugares. Ele não está em `releases/`, então a poda não o alcança, e o
Docker inicializa dono e modo a partir da imagem, o que resolve a permissão sem
`user:` nem `chown`.

O custo é o nome: `<projeto>_<volume>`, com o projeto derivado do domínio. Mudou o
projeto, o volume antigo é orfanado e a aplicação sobe com um vazio, sem erro —
foi o que a migração do Compose v1 para v2 provocaria. E o dado não está na árvore
do site, então backup precisa ser dump lógico e não `tar` de diretório.

**Bind relativo continua suportado**, como caminho alternativo para quem quer o
dado visível no host. Nesse caso o deploy o liga a `<root>/shared/<nome>` por
symlink refeito a cada deploy, com semeadura a partir da release anterior — e a
permissão volta a ser responsabilidade do projeto (`user:` na sobreposição).

**Trocar de um para o outro não migra dado.** São lugares diferentes, e nenhum lê
o outro: a aplicação sobe apontando para o novo, vazio, sem erro em lugar nenhum.
A cópia é manual, com o container parado, antes do deploy que muda o arquivo.

### O manifesto da release, no servidor

O que o servidor ganha, em vez do estado, é um manifesto por release em
`<root>/.cloudez/deploys/<release_id>.json`, escrito pelo `finalize`:

```json
{
  "release_id": "20260820T182630Z-g2c4bc8a",
  "domain": "claudetestdocker.cloudez.io",
  "environment": "docker",
  "ref": "2c4bc8a94dda089632dd57b2d41da05f454daec9",
  "content_sha256": "10ebd7ad…",
  "previous_release_id": "20260820T181556Z-g7751486",
  "deployed_at": "2026-08-20T18:26:41Z"
}
```

Ele responde "o que está no ar e de qual commit veio" sem depender da máquina de
quem publicou — antes disso, quem não tivesse o estado local dependia do nome do
diretório da release.

Mora em `<root>/.cloudez/`, e não dentro da release, por duas razões: a poda
apaga `releases/<id>` e levaria o histórico junto, e escrever dentro da release
sujaria a árvore publicada depois de o `content_sha256` já a ter descrito. O
caminho fica acima do `app_root_path` (`claude/current`), então o nginx não o
serve.

A hora vem do `date` do **servidor**: o relógio de quem publica pode estar em
qualquer lugar, e o manifesto é lido de lá. Escrevê-lo é best-effort, como a
poda — falhar aqui não invalida um deploy que já ativou.

Houve uma fase em que o modelo repassava esses valores aos adaptadores por
ambiente, em `CLOUDEZ_SSH_HOST`, `CLOUDEZ_SSH_USER` e `CLOUDEZ_SSH_PORT`. Essas
variáveis **não existem mais** em nenhum código do plugin — a doc as citava
depois de o mecanismo ter saído.

Uma cópia do host num arquivo versionado envelhece: se a Cloudez mover o site de
servidor, o valor escrito continua apontando para o antigo e o deploy vai para o
lugar errado sem reclamar. Buscar a cada vez custa uma chamada e elimina a
classe inteira de erro.

### O que o deploy NÃO publica

O `cloudez-sync` sempre exclui o `.git`. Além dele, lê dois arquivos de padrão na
raiz do diretório publicado:

| Arquivo | Para quê |
|---|---|
| `.gitignore` | O que o projeto já ignora — `node_modules`, `dist`, `.next` |
| `.cloudezignore` | O que só o deploy precisa excluir, ou reincluir |

Os padrões são avaliados na ordem acima e **o último que casa decide**, como no
git. Como o `.cloudezignore` é lido por último, um `!` nele reabilita o que o
`.gitignore` excluiu — que é o caso do artefato ignorado pelo git mas necessário
em produção:

```gitignore
# .cloudezignore
!dist            # o build vai ao ar, ainda que o git o ignore
relatorios/      # isto nunca precisou sair da minha máquina
```

A sintaxe é a do `.gitignore`: comentário com `#`, negação com `!`, âncora com
`/` no início ou no meio, diretório com `/` no fim, e os curingas `*`, `?` e
`**`. **Só os arquivos da raiz** do diretório publicado são lidos — um
`app/.gitignore` não vale aqui, diferente do git.

**O `.dockerignore` não é lido**, e é decisão, não esquecimento: ele descreve o
que não entra no contexto enviado ao daemon, e ali é correto excluir o
`Dockerfile` e o `docker-compose.yml`, porque o Docker os recebe por outro
caminho. O deploy publica esse diretório para construir **depois**, no servidor —
respeitá-lo faria todo site em container falhar com `compose_missing`. Quem
quiser aquelas regras aqui copia o que serve para o `.cloudezignore`.

Sem isto, o contexto de build de um projeto Node viaja inteiro: 38 mil arquivos
e 532 MB num site cujo fonte tem 0,3 MB, multiplicados pelas cinco releases que
o servidor retém — e refeitos pelo `npm ci` da imagem de qualquer jeito.

A lista resultante é a MESMA que o `cloudez-sync` entrega ao `tar` (por `-T -`,
com os nomes pela stdin) e que o `content_sha256` cobre. Não há duas regras para
divergirem, que era o risco de traduzir padrões de gitignore para `--exclude`.

O separador é a quebra de linha, e não o NUL: `--null` seria mais seguro para nome
de arquivo esquisito, mas o busybox não o conhece — e busybox é o tar de qualquer
imagem Alpine, base comum de CI para projeto Node. O preço são três caracteres,
que o sync **recusa** em vez de transportar errado: `\n` e `\r`, que partiriam a
lista, e a **barra invertida**, que o GNU tar interpreta como escape quando os
nomes não vêm com `--null`. Espaço e aspas passam ilesos.

E a ordem dos argumentos importa: o `-C` vem **antes** do `-T`. No GNU tar ele é
posicional, e no fim da linha não alcança os nomes que chegam pela stdin — o
pacote sai vazio, com um aviso fácil de não ler. O bsdtar aceita as duas ordens,
o que fez esse defeito passar despercebido em macOS e quebrar só no CI.

Um efeito colateral registrado: **diretório vazio deixa de ser enviado**. O tar
com `.` os transportava; a lista só tem arquivos. O hash já os ignorava, então o
identificador não muda de semântica.

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
