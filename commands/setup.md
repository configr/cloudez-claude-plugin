---
description: Cria o .cloudez.yaml do projeto para um domínio e environment, se ainda não existir
argument-hint: <domain> <environment>
allowed-tools: mcp__cloudez__cloudez_auth_status, Bash(cloudez-setup:*), Bash(cloudez-login:*), Read, AskUserQuestion
---

## 0. Autenticação

Chame `cloudez_auth_status`. Se vier `authenticated: false`, **avise e siga
adiante mesmo assim**: escrever o `.cloudez.yaml` é operação local e não fala com
a Cloudez, então bloquear aqui seria inventar um impedimento. O login é
necessário para o deploy, não para a config — encaminhe `/cloudez:login` no fim,
junto com o que mais ficou pendente.

Nunca peça o token na conversa.

## 1. Domínio e environment

Argumentos recebidos: `$ARGUMENTS` — o domínio e o environment, nessa ordem.
Falta algum? Pergunte. Não rode nada antes de ter os dois.

**Domínio.** Pergunte em texto livre, propondo um valor se o projeto der pista
dele (README, `package.json`, config de CI). Tem que ser um FQDN e nada mais:
`meusite.com.br`, `staging.meusite.com.br`. Sem `https://`, sem `/caminho`, sem
`?query`, sem `:porta` — o adaptador recusa esses casos, então não insista;
corrija com o usuário.

**Environment.** Pergunte com AskUserQuestion, nestas opções:

- `default` (recomendado) — para projeto com um destino só;
- `staging`;
- `production`.

O "Other" do próprio widget cobre "escreva a sua própria". Pergunta estruturada
e não texto livre porque o nome vira chave no arquivo: um "prod" digitado onde o
resto do time usa "production" só aparece semanas depois.

## 2. Criar a config

Com os dois em mãos:

```sh
cloudez-setup <domain> <environment>
```

Leia o JSON.

**`status: "created"`** — o template foi escrito em `path`, com `domain` e `root`
já preenchidos (`root` é `~/<domain>/www`, o padrão da Cloudez). Diga para onde o
deploy vai publicar — o `root` é explícito no arquivo justamente para o usuário
poder discordar.

Falta o `ssh` (o campo `todo` do retorno). `ssh.host` e `ssh.user` vêm do painel
da Cloudez: não invente. Um host plausível e errado vira um deploy que falha
longe daqui. Pergunte.

Se `gitignore` vier como `"updated"`, avise que `.cloudez/` foi acrescentado ao
`.gitignore` — é onde fica o estado dos deploys.

**`status: "exists"`** — já havia config em `path`. Não sobrescreva e não edite
nada por conta própria: leia o arquivo e diga se o environment pedido já está lá.
Se não estiver, mostre um bloco novo no mesmo formato dos existentes e pergunte
antes de acrescentar.

Quando o arquivo estiver completo, o deploy é `/cloudez:deploy <environment>`.
