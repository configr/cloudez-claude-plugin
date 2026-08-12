---
description: Cria o .cloudez.yaml do projeto para um domínio e environment, se ainda não existir
argument-hint: <domain> <environment>
allowed-tools: mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_get_site, mcp__cloudez__cloudez_set_app_root_path, mcp__cloudez__cloudez_authorize_ssh_key, Bash(cloudez-setup:*), Bash(cloudez-login:*), Bash(cloudez-pubkey:*), Read, AskUserQuestion
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
- **Nenhum deles** — **encerre.** Diga que o site não foi localizado na conta.
  Não crie o arquivo e não monte um domínio a partir dos candidatos.

Todo candidato vem com `domain` — a tool descarta os que a API devolve sem esse
dado, porque não haveria como o usuário reconhecê-los.

### `site_not_found` — a busca não devolveu nada identificável

**Encerre.** Diga que o site não foi encontrado na conta. Não crie o arquivo e não
sugira criar o site por aqui. Duas causas prováveis, ofereça as duas:

- typo no domínio — confirme a grafia com ele;
- o site ainda não existe na Cloudez — aí ele cria no painel primeiro.

**`upstream_unavailable`** — leia o `hint` antes de dizer qualquer coisa. Se ele
disser que a **rota** não existe, o problema é o endpoint do servidor MCP, não o
domínio do usuário: **não afirme que o site não existe na conta**, relate que a
consulta falhou por um problema nosso. Se for API fora do ar ou timeout, diga que
não foi possível confirmar agora e pergunte se ele quer tentar de novo.

**`not_authenticated` ou `token_invalid`** — volte ao passo 0.

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

Use o domínio **como o `cloudez_get_site` o devolveu** — ele normaliza para
minúsculas, e é essa a forma que o servidor conhece.

Leia o JSON.

**`status: "created"`** — o template foi escrito em `path`, com `domain` e `root`
já preenchidos. O `root` é sempre `~/<domain>/www/claude`: o document root do site
na Cloudez é `~/<domain>/www`, e a estrutura de releases fica num subdiretório
`claude/` dentro dele, para o deploy não tomar conta do `www` inteiro.

Diga para onde o deploy vai publicar, e **avise que o document root do site no
painel precisa apontar para `~/<domain>/www/claude/current`** — sem isso o site
continua servindo o que já estava em `www`, e o deploy parece não ter efeito. O
`root` é explícito no arquivo justamente para o usuário poder discordar.

**Não há nada para o usuário preencher.** O arquivo sai completo: o destino ssh
não mora nele — vem do `cloudez_get_site` a cada deploy, e o `/cloudez:deploy`
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

## 5. Document root do site

Último passo, e o que evita a falha mais confusa deste plugin.

O `cloudez_get_site` do passo 2 devolveu o `app_root_path` do site — o diretório
que o servidor web entrega, relativo a `~/<domain>/www`. O deploy publica em
`<root>/current`, e com o `root` que o `setup` grava isso é **`claude/current`**.

**Se `app_root_path` já for `claude/current`**, diga que está tudo certo e siga.

**Se for qualquer outra coisa** — inclusive ausente — explique o problema em
termos do que vai acontecer, não do campo: com o document root apontando para
outro lugar, o deploy vai rodar inteiro, sem erro nenhum, e o site vai continuar
servindo o conteúdo antigo. É uma falha silenciosa, e o usuário só descobre
comparando o que publicou com o que o navegador mostra.

**Ofereça ajustar, e espere a resposta.** Diga qual é o valor atual e qual
passaria a ser. Duas coisas que ele precisa saber para decidir:

- a mudança vale **na hora**, não no próximo deploy;
- até o primeiro deploy, `claude/current` ainda não existe no servidor — então o
  site fica **fora do ar** nesse intervalo. Para um site novo isso é irrelevante;
  para um que já está no ar, é decisão dele, e o caminho seguro é ajustar logo
  antes do primeiro deploy, não agora.

**Se aceitar:**

```
cloudez_set_app_root_path(domain: "<domain>", app_root_path: "claude/current")
```

Confirme pelo retorno: `changed: true` é ajuste feito, `changed: false` é valor
que já estava correto. Se vier erro dizendo que o valor **não mudou**, não diga
que o document root foi ajustado — a alteração não pegou, e um deploy contando
com ela vai parecer não ter efeito.

**Se recusar**, tudo bem: registre que o `app_root_path` continua em outro valor
e que o primeiro deploy não vai aparecer no site até isso mudar. Não insista e
não ajuste mesmo assim.

## 6. Chave SSH desta máquina

O deploy conecta por SSH com a chave desta máquina. Se ela não estiver autorizada
na conta, o `sync` falha com permissão negada — no meio do deploy, depois de o
build já ter rodado.

O `cloudez_get_site` do passo 2 devolveu as chaves autorizadas do usuário. Liste
as desta máquina:

```sh
cloudez-pubkey
```

Ele lê só arquivos `.pub` e devolve, para cada chave, o `key` (tipo e material,
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

Quando o arquivo estiver completo, o deploy é `/cloudez:deploy <environment>`.
