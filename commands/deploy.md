---
description: Faz deploy de um site para a Cloudez, com ativação atômica da release e rollback
argument-hint: "[environment] [diretório]"
allowed-tools: mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_get_site, mcp__cloudez__cloudez_find_compose, mcp__cloudez__cloudez_begin_deploy, mcp__cloudez__cloudez_finalize_deploy, mcp__cloudez__cloudez_compose_up, mcp__cloudez__cloudez_list_releases, mcp__cloudez__cloudez_rollback, Bash(cloudez-login:*), Bash(cloudez-sync:*), Bash(git:*), Bash(uuidgen:*), Bash(npm:*), Bash(pnpm:*), Bash(yarn:*), Read, AskUserQuestion
---

Argumentos recebidos: `$ARGUMENTS` — o environment e, opcionalmente, o diretório
a publicar.

O deploy acontece em três etapas com estado entre elas: registrar a release,
sincronizar os arquivos, ativar. As duas pontas de control plane —
`cloudez_begin_deploy` e `cloudez_finalize_deploy` (mais `cloudez_compose_up` em
site de container) — são **tools do MCP**; o transporte do meio (`cloudez-sync`)
segue local, porque o MCP nunca move bytes. Tanto a tool quanto o adaptador
devolvem JSON estruturado — **leia esse JSON, não presuma sucesso pelo exit code
nem por a chamada ter retornado.** O único adaptador em shell que resta é o
transporte, `cloudez-sync`; ele está no `PATH` enquanto o plugin está ativo,
chame pelo nome, sem caminho.

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
passos 5 a 9.

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

O diretório publicado vem dos argumentos. Sem ele, **o que se publica depende de
a aplicação rodar em container ou não**, e são decisões opostas:

```
cloudez_find_compose(directory: "<diretório candidato>")
```

### `compose: true` — aplicação em container

Publique o **diretório do arquivo de Compose**, que é o contexto de build — em
geral a raiz do projeto. É lá que estão o `Dockerfile` e o `compose`, e sem eles
não há o que subir do outro lado.

**Não rode o build local.** Quem constrói a imagem é o Docker, a partir do
`Dockerfile`; rodar `npm run build` aqui e publicar o `dist/` mandaria um
diretório sem `Dockerfile` e sem `compose`, e o container não teria como existir.

O `sync` exclui o `.git`, então publicar a raiz não carrega o histórico do
repositório. O resto vai inteiro: o que não deve entrar na imagem é assunto do
`.dockerignore`, aplicado no build.

### `compose: false` — aplicação tradicional

Como antes: se o projeto tem build (`package.json` com script `build`, por
exemplo), rode o build e use o diretório de saída; se não tem, pergunte ao
usuário qual diretório subir.

Aqui **não** publique a raiz do repositório — ela levaria `node_modules` e o
resto do código-fonte para um servidor que só vai servir arquivos.

Se o build falhar, **pare** — não sincronize um build quebrado. Mostre o erro e,
se for algo que você consegue corrigir (import faltando, erro de tipo), corrija e
rode de novo antes de seguir.

## 5. Registrar a release

```
cloudez_begin_deploy(
  domain: "<domain>",
  root: "<root do bloco do environment no .cloudez.yaml>",
  ref: "<sha>",
  idempotency_key: "<uuid>",
  environment: "<environment>"
)
```

A tool resolve o destino ssh sozinha, pelo `domain` (o mesmo `cloudez_get_site`
do passo 2) — **não passe host, user nem port**. O `root` vem do `.cloudez.yaml`
(o bloco do environment): é a única fonte dele, e a tool não o busca na API de
propósito.

Este passo **já conecta por ssh** — ele prepara o diretório de release no
servidor. Uma falha de permissão aqui volta como `ssh_failed` (retryable), o
mesmo caso descrito no passo 6, com a mesma exceção para a chave recém-autorizada.

O `idempotency_key` é um UUID que **você gera uma vez por deploy** (`uuidgen`).
Se precisar repetir a chamada por qualquer motivo, reuse a mesma chave — ela é o
que impede um retry seu de virar dois deploys.

Guarde o `deploy_id` do retorno. O destino ssh já foi gravado no estado do
deploy, e é de lá que o `cloudez-sync` o lê no passo 6.

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

```
cloudez_finalize_deploy(deploy_id: "<deploy_id>")
```

Troca o symlink `current` de forma atômica. Se der `activation_failed`, a release
**não** foi ativada e o site continua no ar na versão anterior — reporte e pare.

Se vier `replaced_directory` no retorno, o `current` era um **diretório de
verdade** e não um symlink: o site já tinha conteúdo antes de o plugin entrar.
Ele foi **movido**, nunca apagado, para o caminho que o campo informa. **Diga
isso ao usuário** — é conteúdo dele posto de lado, e só ele decide se ainda
serve para alguma coisa. Sem esse aviso vira um diretório órfão no servidor que
só aparece quando alguém for olhar.

Se vier `pruned_replaced`, esse número de diretórios substituídos **antigos** foi
apagado para o servidor não acumular cópias inteiras do document root. Reporte
também: é conteúdo do usuário, e apagar em silêncio seria pior do que acumular.
Os dois mais recentes sempre ficam.

`previous_release_id` **não aparece** quando não havia release anterior — é o
caso do primeiro deploy do site. Campo ausente, não string vazia.

## 8. Subir o container — só quando `compose: true`

**Aplicação tradicional para aqui.** Trocar o symlink já pôs o conteúdo no ar, e
não há container nenhum a subir. Pule este passo.

**Aplicação em container não.** Publicar os arquivos não põe uma aplicação em
container no ar: o nginx da Cloudez encaminha `/` para uma porta local, e quem
escuta ali é o container do usuário. Sem este passo o deploy termina em
`succeeded` com o site respondendo **502** no primeiro deploy, ou servindo a
**release anterior** nos seguintes — falha que não aparece em nenhum JSON de
retorno, só no navegador.

```
cloudez_compose_up(deploy_id: "<deploy_id>")
```

Roda `docker compose up -d --build` na release recém-ativada. **Depois do
`finalize`, nunca antes** — o build lê o `current`, e invertendo a ordem a imagem
sairia da release anterior: arquivos novos servindo código velho, sem sinal
nenhum disso no retorno.

O retorno traz `compose.project` e `compose.containers`, com `name`, `state` e
`ports` de cada um. **Confira o `state`**: um container em `restarting` ou
`exited` é deploy fracassado com JSON de sucesso.

O `project` vem do domínio, não do diretório. Isso sobrepõe um `name:` que o
usuário tenha no compose dele, e é deliberado — o daemon do Docker é um só para
todos os sites da máquina, e o nome derivado do diretório seria `current` para
todos eles. Dois sites deste plugin no mesmo servidor viravam o mesmo projeto, e
o deploy de um derrubava o container do outro.

Erros que **não se resolvem no projeto** e cujo `hint` você deve repassar como
está — os dois são ação da Cloudez, não do usuário:

- **`compose_failed` com permissão negada no `docker.sock`** — o usuário do site
  não está no grupo `docker`;
- **`compose_failed` com `iptables: No chain/target/match`** — as chains do
  Docker sumiram do host e nenhuma porta publicada funciona. Não tente contornar
  com `network_mode: host`: resolve o sintoma e amarra o projeto a um defeito
  daquele servidor.

**`compose_missing`** é outra coisa: o deploy publicou um diretório sem Compose.
Quase sempre significa que o passo 4 publicou a saída de um build em vez do
contexto de build. O container continua rodando a versão anterior.

**Verifique o site depois.** Este é o único passo cujo sucesso não se comprova
pelo próprio retorno: o container pode subir e a aplicação não responder. Bata no
domínio e confira o que voltou antes de declarar o deploy pronto.

## 9. Rollback

O `root` vem do bloco do environment no `.cloudez.yaml`, como no passo 5.

```
cloudez_rollback(domain: "<domain>", root: "<root>")                          # volta para a anterior
cloudez_rollback(domain: "<domain>", root: "<root>", to_release_id: "<id>")   # volta para uma específica
```

O servidor mantém as 5 releases mais recentes; o rollback alcança até ali. Alvo
que não existe mais volta `release_not_found` com a lista do que sobrou — não
escolha outro por conta. Se o rollback também falhar (`rollback_failed`), isso é
um incidente — reporte imediatamente com todos os logs, sem tentar mais nada.

**Em aplicação em container, o rollback não termina aqui.** Ele troca o symlink,
e só: o container segue rodando a imagem construída no deploy anterior, então o
site continua servindo o que você acabou de tentar tirar do ar. É preciso rodar
`cloudez_compose_up` para a release de destino reconstruir a imagem a partir
dela — e ela precisa de um `deploy_id`. Se não houver um deploy ativo para essa
release, um `cloudez_begin_deploy` novo apontando para o mesmo `ref`, seguido de
sync + finalize + compose_up, é o caminho que reconstrói e religa tudo.

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

```
cloudez_list_releases(domain: "<domain>", root: "<root>")   # o que está no servidor, qual é a atual
```

Também aqui o destino vem do `cloudez_get_site` — passos 0 a 2 antes.

---

## Nota de implementação

O `root` vem **sempre** do `.cloudez.yaml`, nunca da API: duas fontes para o
destino dos arquivos criariam a pergunta "qual vale?" para a decisão mais
destrutiva daqui, e ela só apareceria quando as duas divergissem.

Todo o control plane já é tool do servidor MCP: `cloudez_begin_deploy`,
`cloudez_finalize_deploy`, `cloudez_compose_up`, `cloudez_list_releases` e
`cloudez_rollback`. O passo 6 é a exceção permanente: o transporte (`cloudez-sync`)
continua local, já que o MCP nunca transporta arquivos.
