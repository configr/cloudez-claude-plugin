---
description: Faz deploy de um site para a Cloudez, com ativação atômica da release e rollback
argument-hint: "[environment] [diretório]"
allowed-tools: mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_get_site, Bash(cloudez-login:*), Bash(cloudez-begin-deploy:*), Bash(cloudez-sync:*), Bash(cloudez-finalize-deploy:*), Bash(cloudez-rollback:*), Bash(cloudez-list-releases:*), Bash(git:*), Bash(uuidgen:*), Bash(npm:*), Bash(pnpm:*), Bash(yarn:*), Read, AskUserQuestion
---

Argumentos recebidos: `$ARGUMENTS` — o environment e, opcionalmente, o diretório
a publicar.

O deploy acontece em três etapas com estado entre elas: registrar a release,
sincronizar os arquivos, ativar. Os adaptadores `cloudez-*` fazem cada etapa e
imprimem JSON — **leia esse JSON, não presuma sucesso pelo exit code.** Eles
estão no `PATH` enquanto o plugin está ativo; chame pelo nome, sem caminho.

Todos os caminhos são relativos à raiz do projeto sendo publicado, que precisa
ter um `.cloudez.yaml`. Se não tiver, pare e mande o usuário rodar
`/cloudez:setup <domain> <environment>` — sem os dados de servidor não há deploy,
e eles não são seus para inventar.

## 0. Autenticação

Chame `cloudez_auth_status`. Se vier `authenticated: false`, **pare** e conduza o
`/cloudez:login`. Nunca peça o token na conversa.

## 1. Environment

Os environments são as chaves de `cloudez:` no `.cloudez.yaml`. Sem argumento,
escolha nesta ordem: `default`, se existir; senão `staging`, se existir; senão
**pergunte** qual dos environments definidos é o alvo.

`production` nunca entra nessa escolha automática: se o usuário disse "sobe" sem
qualificar, não é produção.

**Produção exige confirmação explícita nesta conversa.** "Sobe pra prod",
"publica em produção", "manda pro ar" contam. Uma conclusão sua de que produção
seria o alvo lógico, não conta. Em dúvida, pergunte antes de rodar qualquer
coisa.

Se o environment pedido não existir no arquivo, **pare** e liste os que existem.

## 2. Confirmar o site na Cloudez

Do bloco do environment, pegue o `domain` e busque o site:

```
cloudez_get_site(domain: "<domain>")
```

**`match: "exact"`** — é o alvo. **Guarde o bloco `ssh`**: `host`, `user` e
`port` são o destino do deploy, e os adaptadores os recebem por ambiente nos
passos 5 a 8.

Esses dados não estão no `.cloudez.yaml` de propósito. Uma cópia do host num
arquivo versionado envelhece: se a Cloudez mover o site de servidor, o valor
escrito continua apontando para o antigo e o deploy vai para o lugar errado sem
reclamar. Buscá-los a cada deploy é o que evita isso.

**`match: "candidates"` ou `site_not_found`** — **pare.** O `domain` veio de um
arquivo versionado: se não casa exatamente com um site da conta, a config está
errada ou aponta para outra conta, e isso se corrige no `.cloudez.yaml`, não
escolhendo um vizinho aqui. Liste os candidatos, quando houver, para o usuário
entender o que existe.

**`ssh_unavailable` dizendo que o usuário não tem SSH liberado (`has_ssh:
false`)** — **pare.** O deploy é impossível até o acesso ser habilitado no painel
da Cloudez, e nenhum valor no `.cloudez.yaml` contorna isso. Sincronizar assim
falharia com permissão negada no meio do caminho.

**`upstream_unavailable`** — leia o `hint`. Se disser que a **rota** não existe,
o problema é o endpoint do servidor MCP: não afirme que o site sumiu da conta.

## 3. Working tree limpo

Rode `git status --porcelain`. Se voltar qualquer coisa, **pare** e reporte o que
está pendente. O `ref` do deploy precisa apontar para um commit real — senão o
rollback fica sem destino e ninguém sabe o que está no ar.

Colete o SHA com `git rev-parse HEAD`.

## 4. Decidir o que subir

O diretório publicado vem dos argumentos. Sem ele: se o projeto tem build
(`package.json` com script `build`, por exemplo), rode o build e use o diretório
de saída; se não tem, pergunte ao usuário qual diretório subir.

Não chute a raiz do repositório — ela levaria `.git` e `node_modules` para o
servidor. O `sync` envia o diretório inteiro, sem filtro.

Se o build falhar, **pare** — não sincronize um build quebrado. Mostre o erro e,
se for algo que você consegue corrigir (import faltando, erro de tipo), corrija e
rode de novo antes de seguir.

## 5. Registrar a release

Os adaptadores recebem o destino ssh por ambiente, com os valores do passo 2.
**Passe as três variáveis em toda chamada** — sem elas o adaptador para com
`missing_ssh_target`:

```sh
CLOUDEZ_SSH_HOST=<ssh.host> CLOUDEZ_SSH_USER=<ssh.user> CLOUDEZ_SSH_PORT=<ssh.port> \
  cloudez-begin-deploy <environment> <sha> <idempotency_key>
```

Este passo **já conecta por ssh** — ele prepara o diretório de release no
servidor. Uma falha de permissão aqui é o mesmo caso descrito no passo 6, com a
mesma exceção para a chave recém-autorizada.

O `idempotency_key` é um UUID que **você gera uma vez por deploy** (`uuidgen`).
Se precisar repetir o comando por qualquer motivo, reuse a mesma chave — ela é o
que impede um retry seu de virar dois deploys.

Guarde o `deploy_id` do retorno.

## 6. Sincronizar

```sh
cloudez-sync <deploy_id> <diretorio>
```

**Este é o único que não leva as variáveis**, e não é esquecimento: o
`begin-deploy` resolveu o destino uma vez e o gravou no estado do deploy, e é de
lá que o `sync` o lê. Passá-las de novo aqui não teria efeito — e se uma delas
viesse diferente, o envio iria para um servidor e a ativação para outro.

Falha aqui é quase sempre SSH: chave não configurada, host desconhecido,
permissão. O campo `logs` do erro traz a saída do `tar` e do `ssh`. Chave ausente
é coisa que só o usuário resolve — reporte e pare, não tente contornar.

**Uma exceção, antes de reportar chave ausente.** Se a chave desta máquina
acabou de ser autorizada — pelo `/cloudez:setup` ou pelo painel —, um `Permission
denied (publickey)` é esperado: a conta registra a autorização na hora, mas
propagá-la até o servidor do site leva um tempo, em geral menos de um minuto e
eventualmente mais. Diga isso ao usuário e **tente novamente em alguns minutos**,
reusando a mesma `idempotency_key`. Só trate como chave ausente se continuar
falhando depois disso — mandá-lo conferir o cadastro que ele acabou de fazer o
faz procurar defeito onde não há.

## 7. Ativar

```sh
CLOUDEZ_SSH_HOST=<ssh.host> CLOUDEZ_SSH_USER=<ssh.user> CLOUDEZ_SSH_PORT=<ssh.port> \
  cloudez-finalize-deploy <deploy_id>
```

Troca o symlink `current` de forma atômica. Se der `activation_failed`, a release
**não** foi ativada e o site continua no ar na versão anterior — reporte e pare.

## 8. Rollback

```sh
CLOUDEZ_SSH_HOST=... CLOUDEZ_SSH_USER=... CLOUDEZ_SSH_PORT=... \
  cloudez-rollback <environment>              # volta para a anterior
CLOUDEZ_SSH_HOST=... CLOUDEZ_SSH_USER=... CLOUDEZ_SSH_PORT=... \
  cloudez-rollback <environment> <release_id> # volta para uma específica
```

O servidor mantém as 5 releases mais recentes; o rollback alcança até ali. Se o
rollback também falhar, isso é um incidente — reporte imediatamente com todos os
logs que você tiver, sem tentar mais nada.

## Como reportar

Comece pelo resultado: subiu ou não subiu, em qual ambiente, qual SHA. Depois o
detalhe.

Não descreva os passos que correram bem — o usuário não precisa saber que o envio
funcionou. Descreva o que ele precisa fazer alguma coisa a respeito: falhas,
rollbacks executados, e o domínio para ele conferir.

Se houve rollback, diga explicitamente **qual versão está no ar agora**.

Se for o primeiro deploy deste site, lembre que o document root no painel da
Cloudez precisa apontar para `<root>/current` — com o `root` que o `setup` gera,
`~/<domain>/www/claude/current`. Sem isso o deploy roda inteiro sem erro e o site
continua servindo o conteúdo antigo.

## Inspeção sem deploy

Quando o usuário só quer saber o estado:

```sh
CLOUDEZ_SSH_HOST=... CLOUDEZ_SSH_USER=... CLOUDEZ_SSH_PORT=... \
  cloudez-list-releases <environment>   # o que está no servidor, qual é a atual
```

Também aqui o destino vem do `cloudez_get_site` — passos 0 a 2 antes.

---

## Nota de implementação

O `root` vem **sempre** do `.cloudez.yaml`, nunca da API: duas fontes para o
destino dos arquivos criariam a pergunta "qual vale?" para a decisão mais
destrutiva daqui, e ela só apareceria quando as duas divergissem.

Os adaptadores `cloudez-begin-deploy`, `cloudez-finalize-deploy`,
`cloudez-rollback` e `cloudez-list-releases` são temporários: viram as tools
`cloudez_*` correspondentes quando o servidor MCP as tiver. O formato de retorno
é o mesmo de propósito (veja `docs/mcp-tool-contract.md`), então o procedimento
acima não muda. A exceção é o passo 6: o transporte continua local, já que o MCP
nunca transporta arquivos.
