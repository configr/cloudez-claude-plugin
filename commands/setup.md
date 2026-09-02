---
description: Cria o .cloudez.yaml do projeto para um domínio e environment, se ainda não existir
argument-hint: <domain> <environment> [--database cloudez|docker]
allowed-tools: mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_panel_info, mcp__cloudez__cloudez_signup, mcp__cloudez__cloudez_resend_phone_code, mcp__cloudez__cloudez_confirm_phone, mcp__cloudez__cloudez_get_site, mcp__cloudez__cloudez_list_sites, mcp__cloudez__cloudez_list_clouds, mcp__cloudez__cloudez_create_site, mcp__cloudez__cloudez_configure_site, mcp__cloudez__cloudez_authorize_ssh_key, mcp__cloudez__cloudez_find_compose, mcp__cloudez__cloudez_list_local_ssh_keys, Bash(cloudez-setup:*), Read, AskUserQuestion
---

## 0. Autenticação, antes de qualquer coisa

Chame `cloudez_auth_status`.

**`authenticated: false`** — **pare aqui.** Conduza o `/cloudez:login` e só volte
depois que ele passar. Não é possível seguir: o passo 2 confirma o domínio contra
a API da Cloudez, e sem token não há como saber se o site existe. Criar a config
assim mesmo seria escrever um arquivo que aponta para um site que talvez não
exista — e a descoberta viria no deploy, longe da causa.

Se `verified` for `false` com `authenticated: true`, siga: há token e a Cloudez
não o desmentiu (offline ou API fora). O passo 2 vai falhar de forma mais
informativa se o problema for real.

Nunca peça o token na conversa.

## 1. Domínio

Argumentos recebidos: `$ARGUMENTS` — o domínio e o environment, nessa ordem.

Comece pelo domínio, sozinho. Pergunte em texto livre, propondo um valor se o
projeto der pista dele (README, `package.json`, config de CI). Tem que ser um
FQDN e nada mais: `meusite.com.br`, `staging.meusite.com.br`. Sem `https://`, sem
`/caminho`, sem `?query`, sem `:porta`.

Não pergunte o environment ainda — se o domínio estiver errado, a resposta é
descartada.

## 2. Confirmar o site na conta

```
cloudez_get_site(domain: "<domain>")
```

A busca não é exata do lado da API: ela pode trazer domínios vizinhos. Por isso há
três desfechos, e **em nenhum deles você segue sozinho**.

### `match: "exact"` — achou

Diga que encontrou, mostrando o `domain` e o que mais veio (`name`, `stack`,
`ssh.host`). **Peça confirmação ao usuário e espere a resposta** antes de ir para
o passo 3.

Parece redundante confirmar um casamento exato, e não é: o domínio pode estar
certo e ser o projeto errado — a mesma conta hospeda vários sites, e este é o
último ponto em que isso ainda sai barato de corrigir.

Se ele disser que não é esse, **encerre**. Não tente outra busca por conta
própria: pergunte o domínio correto e volte ao passo 1.

### `match: "candidates"` — não achou exato, mas achou parecidos

**Liste os candidatos**, mostrando o `domain` de cada um — e também os de
`other_domains`, quando vierem: o site é conhecido por mais de um domínio, e o
usuário pode reconhecê-lo por qualquer um deles. Use AskUserQuestion quando forem
poucos, com uma opção por site, e pergunte se o site dele é algum daqueles.

- **Escolheu um** — siga com o domínio **daquele candidato**, não com o que ele
  digitou no passo 1. Refaça o `cloudez_get_site` com o domínio escolhido para
  obter os dados completos, e siga para o passo 3.
- **Nenhum deles** — pergunte se ele quer criar um site novo com o domínio do
  passo 1. Se sim, vá para "Criar o site", abaixo. Se não, **encerre**: peça o
  domínio correto e volte ao passo 1.

Todo candidato vem com `domain` — a tool descarta os que a API devolve sem esse
dado, porque não haveria como o usuário reconhecê-los.

### `site_not_found` — a busca não devolveu nada identificável

Antes de encerrar, **ofereça procurar**. O domínio pode estar com typo, ou o
usuário pode lembrar do site por outro nome:

```
cloudez_list_sites(query: "<parte do nome ou do domínio>")
```

Pergunte a ele que parte usar — uma palavra do nome do projeto costuma bastar, e
a busca casa parcialmente (`claude` encontra `claudetest.cloudez.io` e
`claudetestdocker.cloudez.io`). **Não invente termos** nem tente varreduras
amplas: não existe listagem completa da conta, e adivinhar gasta chamadas sem
convergir.

- **Achou o site dele na lista** — siga com aquele domínio e refaça o
  `cloudez_get_site` para obter os dados completos.
- **Não achou, ou veio vazio** — pergunte se é typo no domínio ou se o site
  ainda não existe. No primeiro caso, peça o domínio certo e volte ao passo 1.
  No segundo, pergunte se ele quer criar um site novo ali. Se sim, vá para
  "Criar o site", abaixo. Se não, **encerre**.

Se o retorno trouxer `truncated`, repasse: a busca veio incompleta, e um domínio
ausente dela ainda pode existir na conta.

**`upstream_unavailable`** — leia o `hint` antes de dizer qualquer coisa. Se ele
disser que a **rota** não existe, o problema é o endpoint do servidor MCP, não o
domínio do usuário: **não afirme que o site não existe na conta**, relate que a
consulta falhou por um problema nosso. Se for API fora do ar ou timeout, diga que
não foi possível confirmar agora e pergunte se ele quer tentar de novo.

**`not_authenticated` ou `token_invalid`** — volte ao passo 0.

### Criar o site

Chegou aqui porque o usuário confirmou que quer um site novo, com o domínio do
passo 1 — não algo que ele precise fazer no painel primeiro.

```
cloudez_list_clouds()
```

- **Nenhuma cloud** — vá direto para "Contratar uma cloud nova", abaixo. Isto é
  conta antiga sem trial nenhum contratado; não confunda com conta nova, que já
  sai do `/cloudez:login` com uma (`cloudez_setup_trial_cloud`);
- **Uma cloud só** — use o `id` dela direto, sem perguntar: não há entre o quê
  escolher;
- **Mais de uma** — pergunte qual com AskUserQuestion, mostrando `name` e
  `fqdn` de cada uma, e acrescente "contratar uma nova" como opção — o usuário
  pode querer uma cloud separada mesmo já tendo outras.

Se ele escolher "contratar uma nova", vá para "Contratar uma cloud nova",
abaixo. Do contrário, com o `id` escolhido:

```
cloudez_create_site(cloud: <id>, domain: "<domain do passo 1>")
```

**Não pergunte o tipo do site.** É sempre `claude` — o único que este plugin
publica — e a tool não aceita outro.

O domínio é único **por cloud**, não por conta: se vier `invalid_argument`
dizendo que o domínio já existe, é porque já há um site com ele **naquela
cloud especificamente**. Confirme o domínio com o usuário antes de tentar de
novo — repetir sem mudar nada dá o mesmo erro.

**`site_creation_unconfirmed`** — a chamada falhou DEPOIS de enviada (visto na
prática: criar o site demora, e um timeout não significa que nada foi criado).
**Não chame `cloudez_create_site` de novo agora.** Chame `cloudez_get_site`
com o mesmo domínio primeiro: se o site já aparecer lá, trate como sucesso e
siga para o passo 3; só repita a criação se ele realmente não existir.

Com o site criado, siga para o passo 3 com o `domain` que a tool devolveu. O
retorno de `cloudez_create_site` tem a MESMA forma do `cloudez_get_site` —
`stack`, `ssh` ou `ssh_unavailable`, `app_root_path`, `custom_port` —, então
onde os passos 4 a 6 disserem "o `cloudez_get_site` do passo 2", leia-se
"a confirmação do passo 2, seja ela `cloudez_get_site` ou `cloudez_create_site`".
Os passos 5 a 7 seguem sem alteração: o site nasceu já do tipo `claude`, então
a checagem de tipo do passo 5 passa direto.

#### Contratar uma cloud nova

Siga o procedimento de `/cloudez:hire-cloud` — é o mesmo comando que atende
quem pede para contratar uma cloud fora deste fluxo, e o procedimento não é
duplicado aqui: ele já cuida do painel (perguntando só se ainda não houver um
lembrado nesta máquina), do aviso de que é sempre contratação paga, e do
antes/depois de `cloudez_list_clouds` para achar a cloud nova.

Com a cloud nova identificada, volte para `cloudez_create_site`, acima, usando
o `id` dela — sem perguntar, se veio uma só.

## 3. Environment

Só agora, com o domínio confirmado. Pergunte com AskUserQuestion:

- `default` (recomendado) — para projeto com um destino só;
- `staging`;
- `production`.

O "Other" do próprio widget cobre "escreva a sua própria". Pergunta estruturada e
não texto livre porque o nome vira chave no arquivo: um "prod" digitado onde o
resto do time usa "production" só aparece semanas depois.

## 4. Criar a config

```sh
cloudez-setup <domain> <environment>
```

O `--database` existe e **não é para agora** — ver a nota no fim deste passo.

Use o domínio **como o `cloudez_get_site` o devolveu** — ele normaliza para
minúsculas, e é essa a forma que o servidor conhece.

Leia o JSON.

**`status: "created"`** — o template foi escrito em `path`, com o `domain`.

O arquivo NÃO traz o diretório do servidor, e isso é decisão: ele é sempre
`~/<domain>/www/claude`, e as tools o derivam do domínio. Guardá-lo criaria a
chance de ficar velho — a Cloudez renomeia o diretório quando o domínio do site
muda, e o valor escrito passaria a apontar para o que deixou de existir. É a mesma
razão pela qual o bloco `ssh` não está lá.

Diga para onde o deploy vai publicar — `~/<domain>/www/claude` — e **avise que o
document root do site no painel precisa apontar para
`~/<domain>/www/claude/current`**. Sem isso o site continua servindo o que já
estava em `www`, e o deploy parece não ter efeito.

**O `database:` fica para depois.** Ele registra onde o banco de produção mora —
`cloudez` para a instância gerenciada, `docker` para o container com volume
nomeado — e a escolha é do `/cloudez:compose`, que é onde o usuário a faz. Não
pergunte aqui: seria decidir antes de saber se a aplicação precisa de banco.

**Não há mais nada para o usuário preencher.** O arquivo sai completo: nem o
destino ssh nem o diretório do servidor moram nele — vem do `cloudez_get_site` a cada deploy, e o `/cloudez:deploy`
o repassa aos adaptadores. Uma cópia do host num arquivo versionado envelheceria:
se a Cloudez mover o site de servidor, o valor escrito continuaria apontando para
o antigo.

Se o `cloudez_get_site` do passo 2 trouxe `ssh_unavailable` dizendo que o usuário
**não tem SSH liberado** (`has_ssh: false`), avise agora: a config está pronta,
mas o deploy não vai funcionar até o acesso ser habilitado no painel da Cloudez.
Não é algo que se resolva no arquivo.

Se `gitignore` vier como `"updated"`, avise que `.cloudez/` foi acrescentado ao
`.gitignore` — é onde fica o estado dos deploys.

**`status: "exists"`** — já havia config em `path`. Não sobrescreva e não edite
nada por conta própria: leia o arquivo e diga se o environment pedido já está lá.
Se não estiver, mostre um bloco novo no mesmo formato dos existentes e pergunte
antes de acrescentar.

## 5. O que o site precisa ter configurado na Cloudez

Último passo, e o que evita a falha mais confusa deste plugin.

São **dois** valores, e o deploy depende dos dois. O `cloudez_get_site` do passo 2
já devolveu ambos.

**O tipo do site, antes de tudo.** Este plugin publica aplicação em container, e
só. O tipo a exigir é **`claude`** — é o tipo da Cloudez para isso, um invólucro
do antigo `container_docker` com nome, slug e ícone próprios e o mesmo
provisionamento por baixo.

`container_docker` **também segue**, sem alarde: é o tipo anterior, e o que a
Cloudez provisiona é o mesmo. Recusar um site criado antes de o tipo novo existir
quebraria quem já publica sem impedir falha nenhuma.

Qualquer outro `stack` — `html` é o caso real — **pare aqui.** A Cloudez serviria
os arquivos como estáticos, o container nunca subiria, e o deploy rodaria inteiro
sem erro nenhum. É a falha mais confusa que este plugin consegue produzir, e a
razão desta checagem existir.

Diga que o tipo do site precisa ser trocado para **Claude** no painel, e que o
setup continua quando isso estiver feito. Não tente corrigir por conta própria — o
tipo muda o que a Cloudez provisiona, e não é reversível por um comando nosso.

**O `app_root_path`** é o diretório que o servidor web entrega, relativo a
`~/<domain>/www`. O deploy publica em `~/<domain>/www/claude/current`, então o
valor é **`claude/current`**.

**A `custom_port`** é a porta do host para onde o nginx da Cloudez encaminha `/`.
Ela precisa bater com a porta que o Compose publica. Neste passo o projeto pode
ainda não ter Compose nenhum — então:

- **tem Compose** (o `ports` do `cloudez_find_compose` traz um `published`): a
  `custom_port` tem de valer exatamente esse número;
- **não tem**: use **3000**, que é o que o `/cloudez:compose` vai escrever depois.

**Se os dois já estiverem certos**, diga que está tudo certo e siga.

**Se algum estiver diferente** — inclusive ausente — explique em termos do que vai
acontecer, não do campo:

- **document root errado**: o deploy roda inteiro, sem erro nenhum, e o site
  continua servindo o conteúdo antigo. O usuário só descobre comparando o que
  publicou com o que o navegador mostra;
- **porta errada**: o container sobe, o deploy se declara bem-sucedido, e o site
  responde **502** — o nginx encaminha para uma porta onde não há ninguém.

As duas são falhas silenciosas no deploy e barulhentas depois, longe da causa.

**Ofereça ajustar, e espere a resposta.** Diga qual é o valor atual e qual
passaria a ser. Duas coisas que ele precisa saber para decidir:

- a mudança vale **na hora**, não no próximo deploy;
- até o primeiro deploy, `claude/current` ainda não existe no servidor — então o
  site fica **fora do ar** nesse intervalo. Para um site novo isso é irrelevante;
  para um que já está no ar, é decisão dele, e o caminho seguro é ajustar logo
  antes do primeiro deploy, não agora.

**Se aceitar**, os dois vão na MESMA chamada — passe só o que estiver errado:

```
cloudez_configure_site(
  domain: "<domain>",
  app_root_path: "claude/current",
  custom_port: "<3000, ou a porta que o Compose publica>"
)
```

Uma escrita só, e não duas, porque são pré-requisitos da mesma publicação: em
chamadas separadas, a segunda falhando deixa o site com metade da configuração e
nada no retorno dizendo isso.

Confirme pelo retorno: `changed` é a **lista** de valores efetivamente escritos —
vazia quando já estava tudo certo. Se vier erro dizendo que o valor **não mudou**,
não diga que a configuração foi ajustada: a alteração não pegou, e um deploy
contando com ela vai parecer não ter efeito.

**Se recusar**, tudo bem: registre o que continua diferente e o que vai acontecer
por causa disso no primeiro deploy. Não insista e não ajuste mesmo assim.

## 6. Chave SSH desta máquina

O deploy conecta por SSH com a chave desta máquina. Se ela não estiver autorizada
na conta, o `sync` falha com permissão negada — no meio do deploy, depois de o
build já ter rodado.

O `cloudez_get_site` do passo 2 devolveu as chaves autorizadas do usuário. Liste
as desta máquina:

```
cloudez_list_local_ssh_keys()
```

Ela lê só arquivos `.pub` e devolve, para cada chave, o `key` (tipo e material,
sem comentário), o `comment` e o `fingerprint`.

**Se alguma das chaves locais já estiver autorizada**, diga qual, pelo
`fingerprint`, e siga. Nada a fazer.

**Se nenhuma estiver:**

- **uma chave local só** — proponha autorizá-la, mostrando `fingerprint` e
  `comment`;
- **mais de uma** — pergunte com AskUserQuestion qual usar, identificando cada
  opção pelo `fingerprint` e pelo `comment`. Não escolha por conta própria;
- **`no_public_key`** — não há chave nesta máquina. Diga para ele gerar uma com
  `ssh-keygen -t ed25519` e rodar o `/cloudez:setup` de novo. Não gere a chave
  por ele: o par tem que nascer na máquina de quem vai usá-lo.

**Peça aceite explícito antes de autorizar.** Isto concede acesso SSH permanente
à conta a partir desta máquina — não é o mesmo que escrever um arquivo local, e
não é decisão sua.

**Se aceitar:**

```
cloudez_authorize_ssh_key(domain: "<domain>", public_key: "<key completa>")
```

Passe a linha da chave **pública**. Nunca leia nem envie um arquivo sem `.pub` —
esse é a chave privada, e ela não sai da máquina.

Confirme pelo retorno: `added: true` é chave autorizada agora, `added: false` é
chave que já estava lá. Se vier erro dizendo que **outras chaves sumiram**,
avise o usuário imediatamente: outras pessoas podem ter perdido acesso SSH à
conta, e isso se confere no painel da Cloudez.

**A chave não passa a valer no mesmo instante.** A conta registra a autorização na
hora, mas propagá-la até o servidor do site leva um tempo — em geral menos de um
minuto, eventualmente mais. Diga isso ao confirmar que autorizou: se o deploy
seguinte falhar com `Permission denied (publickey)`, a resposta é **tentar
novamente em alguns minutos**, e não investigar a chave. O sintoma é idêntico ao
de chave errada, e é justamente por isso que ele precisa saber antes de vê-lo.

**Se recusar**, registre que o deploy vai falhar na conexão até a chave ser
autorizada — pelo painel, se ele preferir fazer à mão.

## 7. Como a aplicação roda

O site já foi confirmado como publicável (`claude`) no passo 5. Falta saber se o
projeto tem o arquivo que faz o container existir — e qual porta ele publica:

```
cloudez_find_compose()
```

Ela procura os quatro nomes que o Compose aceita, **na ordem que o próprio
Compose usa** — `compose.yaml`, `compose.yml`, `docker-compose.yaml`,
`docker-compose.yml` — e devolve o que seria efetivamente usado.

O tipo do site já foi confirmado no passo 5 — se não fosse publicável, o
setup teria parado lá. Então sobram dois casos:

| Projeto | O que dizer |
|---|---|
| tem Compose | Diga qual arquivo será usado, e **qual porta ele publica** (o `ports` do retorno). Se essa porta não bate com a `custom_port` que o passo 5 gravou, diga isso agora: é a divergência que dá 502 |
| não tem | O deploy publicaria arquivos que ninguém executa. **Ofereça o `/cloudez:compose`**, que escreve o arquivo junto com o usuário |

**Não gere o Compose por conta própria.** Ele não sai de template: depende do que
a aplicação é, como sobe e do que precisa em volta — por isso o `/cloudez:compose`
é uma conversa, e não um passo automático daqui.

Se vier `parse_error` em vez de `ports`, diga que o arquivo existe mas não pôde
ser lido, e mostre a mensagem. Um Compose que este plugin não entende não impede o
deploy, mas impede conferir a porta — e o usuário precisa saber que essa
verificação não aconteceu.

Se vier `ignored`, o projeto tem mais de um arquivo de Compose. Diga qual será
usado e quais serão ignorados — um arquivo editado que nunca entra em nada é
caro de diagnosticar.

Isto é diagnóstico, não bloqueio: a config já está escrita e o deploy é que vai
sofrer a consequência. Encerre relatando o que encontrou.

Quando o arquivo estiver completo, o deploy é `/cloudez:deploy <environment>`.
