---
description: Cria o .cloudez.yaml do projeto para um domínio e environment, se ainda não existir
argument-hint: <domain> <environment>
allowed-tools: mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_get_site, Bash(cloudez-setup:*), Bash(cloudez-login:*), Read, AskUserQuestion
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
`root`, `ssh.host`). **Peça confirmação ao usuário e espere a resposta** antes de
ir para o passo 3.

Parece redundante confirmar um casamento exato, e não é: o domínio pode estar
certo e ser o projeto errado — a mesma conta hospeda vários sites, e este é o
último ponto em que isso ainda sai barato de corrigir.

Se ele disser que não é esse, **encerre**. Não tente outra busca por conta
própria: pergunte o domínio correto e volte ao passo 1.

### `match: "candidates"` — não achou exato, mas achou parecidos

**Liste os candidatos**, mostrando o `domain` de cada um. Use AskUserQuestion
quando forem poucos, com uma opção por site, e pergunte se o site dele é algum
daqueles.

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
já preenchidos (`root` é `~/<domain>/www`, o padrão da Cloudez). Diga para onde o
deploy vai publicar — o `root` é explícito no arquivo justamente para o usuário
poder discordar.

Falta o `ssh` (o campo `todo` do retorno). Se o `cloudez_get_site` do passo 2
trouxe `ssh.host` e `ssh.user`, ofereça preencher com esses valores e peça
confirmação. Se não trouxe, **pergunte ao usuário** — `ssh.host` e `ssh.user` vêm
do painel da Cloudez, e não são seus para inventar. Um host plausível e errado
vira um deploy que falha longe daqui.

Se `gitignore` vier como `"updated"`, avise que `.cloudez/` foi acrescentado ao
`.gitignore` — é onde fica o estado dos deploys.

**`status: "exists"`** — já havia config em `path`. Não sobrescreva e não edite
nada por conta própria: leia o arquivo e diga se o environment pedido já está lá.
Se não estiver, mostre um bloco novo no mesmo formato dos existentes e pergunte
antes de acrescentar.

Quando o arquivo estiver completo, o deploy é `/cloudez:deploy <environment>`.
