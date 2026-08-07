---
name: deploy
description: Faz deploy de um site para a Cloudez — build local, sincronização via tar sobre ssh, ativação da release com verificação de saúde e rollback automático. Use quando o usuário pedir para subir, publicar, fazer deploy ou reverter um site, ou quando pedir para verificar o estado de um deploy anterior.
---

# Deploy para a Cloudez

Argumentos recebidos: `$ARGUMENTS` — normalmente o ambiente (`staging` ou
`production`). Vazio significa `staging`.

O deploy acontece em quatro etapas com estado entre elas: registrar a release,
sincronizar os arquivos, ativar, verificar. Os adaptadores `cloudez-*` fazem
cada etapa e imprimem JSON — leia esse JSON, não presuma sucesso pelo exit code.
Eles estão no `PATH` enquanto o plugin está ativo; chame pelo nome, sem caminho.

Todos os caminhos abaixo são relativos à raiz do projeto sendo publicado, que
precisa ter um `.cloudez.yaml` (modelo em `cloudez.example.yaml`).

## Antes de qualquer coisa

**Ambiente alvo.** `staging` salvo se o usuário disser produção. Se ele disse
"sobe" sem qualificar, é staging — não infira produção.

**Produção exige confirmação explícita nesta conversa.** "Sobe pra prod",
"publica em produção", "manda pro ar" contam. Uma conclusão sua de que produção
seria o alvo lógico, não conta. Se estiver em dúvida, pergunte antes de rodar
qualquer coisa.

**Produção também exige aprovação assinada, e ela não é sua para dar.** Um hook
bloqueia o deploy até existir uma aprovação válida. Você não consegue emiti-la:
`cloudez-approve` exige TTY e falha quando executado pela tool Bash — de
propósito.

Quando o bloqueio aparecer, ele já traz o caminho absoluto do comando. Repasse
esse caminho ao usuário para ele rodar **no terminal dele** — `bin/` só está no
`PATH` da tool Bash, não no shell dele, então o caminho relativo não serve.

A aprovação vale 15 minutos e **só para o commit atual**. Se você commitar
qualquer coisa depois dela, ela é invalidada e precisa ser reemitida — não trate
isso como bug, é o desenho. Não tente contornar o bloqueio de nenhuma forma;
reporte e espere.

**Working tree limpo.** Rode `git status --porcelain`. Se voltar qualquer coisa,
pare e reporte o que está pendente. O `ref` do deploy precisa apontar para um
commit real — senão o rollback fica sem destino e ninguém sabe o que está no ar.

Colete o SHA com `git rev-parse HEAD`.

## O procedimento

### 1. Build

Leia `.cloudez.yaml` para o comando e o diretório de saída — os campos são
`sites.<env>.build.command` e `sites.<env>.build.output_dir`.

Rode o build. Se falhar, **pare** — não tente sincronizar um build quebrado.
Mostre o erro e, se for algo que você consegue corrigir (import faltando, erro
de tipo), corrija e rode de novo antes de seguir.

### 2. Registrar a release

```sh
cloudez-begin-deploy <env> <sha> <idempotency_key>
```

O `idempotency_key` é um UUID que **você gera uma vez por deploy** (`uuidgen`).
Se precisar repetir o comando por qualquer motivo, reuse a mesma chave — ela é o
que impede um retry seu de virar dois deploys.

Guarde o `deploy_id` do retorno.

### 3. Sincronizar

```sh
cloudez-sync <deploy_id> <output_dir>
```

Falha aqui é quase sempre SSH: chave não configurada, host desconhecido, permissão.
O campo `logs` do erro traz a saída do tar e do ssh. Chave ausente é coisa que só o
usuário resolve — reporte e pare, não tente contornar.

### 4. Ativar

```sh
cloudez-finalize-deploy <deploy_id>
```

Troca o symlink `current` e roda o hook pós-deploy. Dois erros distintos:

- `activation_failed` — a release **não** foi ativada; o site continua no ar na
  versão anterior. Reporte e pare.
- `hook_failed` — a release **foi** ativada mas o hook quebrou; o site pode estar
  fora. Vá direto para o rollback (passo 6), depois reporte com os `logs`.

### 5. Verificar

```sh
cloudez-health-check <env>
```

Sai com código 1 quando não está saudável. **Um deploy sem health check não está
terminado** — não reporte sucesso antes deste passo.

Se falhar, faça rollback antes de reportar.

### 6. Rollback

```sh
cloudez-rollback <env>              # volta para a anterior
cloudez-rollback <env> <release_id> # volta para uma específica
```

Depois de reverter, rode o health check de novo para confirmar que o site voltou.
Se o rollback também falhar, isso é um incidente — reporte imediatamente com
todos os logs que você tiver, sem tentar mais nada.

## Como reportar

Comece pelo resultado: subiu ou não subiu, em qual ambiente, qual SHA. Depois o
detalhe.

Não descreva os passos que correram bem — o usuário não precisa saber que o
envio funcionou. Descreva o que ele precisa fazer alguma coisa a respeito:
falhas, rollbacks executados, e a URL para conferir.

Se houve rollback, diga explicitamente **qual versão está no ar agora**.

## Inspeção sem deploy

Quando o usuário só quer saber o estado:

```sh
cloudez-list-releases <env>   # o que está no servidor, qual é a atual
cloudez-health-check <env>    # o site está de pé?
```

---

## Nota de implementação

Estes adaptadores são temporários. Quando o servidor MCP da Cloudez ficar
pronto, cada `cloudez-*` vira a tool `cloudez_*` correspondente — o formato
de retorno é o mesmo de propósito (veja `docs/mcp-tool-contract.md`), então o
procedimento acima não muda. A exceção é o passo 3: o transporte continua local, já
que o MCP nunca transporta arquivos.
