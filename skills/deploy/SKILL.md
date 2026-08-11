---
name: deploy
description: Faz deploy de um site para a Cloudez — sincronização via tar sobre ssh e ativação atômica da release, com rollback. Use quando o usuário pedir para subir, publicar, fazer deploy ou reverter um site, ou quando pedir para ver as releases de um deploy anterior.
---

# Deploy para a Cloudez

Argumentos recebidos: `$ARGUMENTS` — o environment e, opcionalmente, o diretório
a publicar. Os environments são as chaves de `cloudez:` no `.cloudez.yaml`.

O deploy acontece em três etapas com estado entre elas: registrar a release,
sincronizar os arquivos, ativar. Os adaptadores `cloudez-*` fazem cada etapa e
imprimem JSON — leia esse JSON, não presuma sucesso pelo exit code. Eles estão
no `PATH` enquanto o plugin está ativo; chame pelo nome, sem caminho.

Todos os caminhos abaixo são relativos à raiz do projeto sendo publicado, que
precisa ter um `.cloudez.yaml`. Se não tiver, pare e mande o usuário rodar
`/cloudez:setup <domain> <environment>` — sem os dados de servidor não há deploy,
e eles não são seus para inventar.

## Antes de qualquer coisa

**Environment alvo.** Sem argumento, leia as chaves de `cloudez:` e escolha nesta
ordem: `default`, se existir; senão `staging`, se existir; senão **pergunte** qual
dos environments definidos é o alvo. `production` nunca entra nessa escolha
automática: se o usuário disse "sobe" sem qualificar, não é produção.

**Produção exige confirmação explícita nesta conversa.** "Sobe pra prod",
"publica em produção", "manda pro ar" contam. Uma conclusão sua de que produção
seria o alvo lógico, não conta. Se estiver em dúvida, pergunte antes de rodar
qualquer coisa.

**Working tree limpo.** Rode `git status --porcelain`. Se voltar qualquer coisa,
pare e reporte o que está pendente. O `ref` do deploy precisa apontar para um
commit real — senão o rollback fica sem destino e ninguém sabe o que está no ar.

Colete o SHA com `git rev-parse HEAD`.

## O procedimento

### 1. Decidir o que subir

O diretório publicado vem dos argumentos. Sem ele: se o projeto tem build
(`package.json` com script `build`, por exemplo), rode o build e use o diretório
de saída; se não tem, pergunte ao usuário qual diretório subir.

Não chute a raiz do repositório — ela levaria `.git` e `node_modules` para o
servidor. O `sync` envia o diretório inteiro, sem filtro.

Se o build falhar, **pare** — não sincronize um build quebrado. Mostre o erro e,
se for algo que você consegue corrigir (import faltando, erro de tipo), corrija
e rode de novo antes de seguir.

### 2. Registrar a release

```sh
cloudez-begin-deploy <environment> <sha> <idempotency_key>
```

O `idempotency_key` é um UUID que **você gera uma vez por deploy** (`uuidgen`).
Se precisar repetir o comando por qualquer motivo, reuse a mesma chave — ela é o
que impede um retry seu de virar dois deploys.

Guarde o `deploy_id` do retorno.

### 3. Sincronizar

```sh
cloudez-sync <deploy_id> <diretorio>
```

Falha aqui é quase sempre SSH: chave não configurada, host desconhecido, permissão.
O campo `logs` do erro traz a saída do tar e do ssh. Chave ausente é coisa que só o
usuário resolve — reporte e pare, não tente contornar.

### 4. Ativar

```sh
cloudez-finalize-deploy <deploy_id>
```

Troca o symlink `current` de forma atômica. Se der `activation_failed`, a release
**não** foi ativada e o site continua no ar na versão anterior — reporte e pare.

### 5. Rollback

```sh
cloudez-rollback <environment>              # volta para a anterior
cloudez-rollback <environment> <release_id> # volta para uma específica
```

O servidor mantém as 5 releases mais recentes; o rollback alcança até ali. Se o
rollback também falhar, isso é um incidente — reporte imediatamente com todos os
logs que você tiver, sem tentar mais nada.

## Como reportar

Comece pelo resultado: subiu ou não subiu, em qual ambiente, qual SHA. Depois o
detalhe.

Não descreva os passos que correram bem — o usuário não precisa saber que o
envio funcionou. Descreva o que ele precisa fazer alguma coisa a respeito:
falhas, rollbacks executados, e o domínio para ele conferir (`cloudez.<environment>.domain`
no `.cloudez.yaml`).

Se houve rollback, diga explicitamente **qual versão está no ar agora**.

## Inspeção sem deploy

Quando o usuário só quer saber o estado:

```sh
cloudez-list-releases <environment>   # o que está no servidor, qual é a atual
```

---

## Nota de implementação

Estes adaptadores são temporários. Quando o servidor MCP da Cloudez ficar
pronto, cada `cloudez-*` vira a tool `cloudez_*` correspondente — o formato
de retorno é o mesmo de propósito (veja `docs/mcp-tool-contract.md`), então o
procedimento acima não muda. A exceção é o passo 3: o transporte continua local, já
que o MCP nunca transporta arquivos.
