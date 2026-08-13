---
description: Volta o site para uma release anterior, com verificação de que ele voltou ao ar
argument-hint: "[environment] [release_id]"
allowed-tools: mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_get_site, mcp__cloudez__cloudez_list_releases, mcp__cloudez__cloudez_rollback, mcp__cloudez__cloudez_compose_build, mcp__cloudez__cloudez_compose_up, mcp__cloudez__cloudez_health_check, Read, Grep, AskUserQuestion
---

Argumentos recebidos: `$ARGUMENTS` — o environment e, opcionalmente, a release
de destino.

Este comando é para quando **alguma coisa já deu errado**. Trate-o assim: vá
direto ao ponto, não proponha investigar a causa antes de devolver o site ao ar,
e não peça confirmações que não mudam o resultado.

Duas coisas, porém, não se pulam por pressa: **confirmar o alvo** e **verificar
depois**. Um rollback para a release errada troca um site quebrado por outro, e
um rollback não verificado é o pior estado possível para se declarar resolvido.

O projeto precisa de um `.cloudez.yaml`. Sem ele não há `root`, e sem `root` não
há o que voltar — pare e diga isso.

**Não exija working tree limpo.** Diferente do deploy, aqui nada é publicado a
partir do que está no disco local: as releases já estão no servidor. Exigir
árvore limpa só impediria o rollback exatamente quando alguém está no meio de uma
correção às pressas.

## 0. Autenticação

Chame `cloudez_auth_status`. Se vier `authenticated: false`, **pare** e conduza o
`/cloudez:login`.

## 1. Environment

As chaves de `cloudez:` no `.cloudez.yaml`. Sem argumento: `default`, se existir;
senão `staging`; senão **pergunte**.

Ao contrário do deploy, **`production` pode ser escolhido sem cerimônia extra
quando o usuário o nomeou** — quem pede rollback em produção está apagando um
incêndio. O que ainda exige confirmação é o **alvo** (passo 3), não o ambiente.
Mas continue não *deduzindo* produção: se o usuário não disse, pergunte.

## 2. Confirmar o site

```
cloudez_get_site(domain: "<domain>")
```

Guarde o `stack`: **`container_docker` muda o procedimento** — nesse caso o passo
5 é obrigatório, e sem ele o rollback não surte efeito nenhum.

## 3. Escolher o alvo, e confirmar

```
cloudez_list_releases(domain: "<domain>", root: "<root do .cloudez.yaml>")
```

A lista vem da mais nova para a mais velha, com `current: true` na que está no
ar. O servidor guarda as 5 mais recentes.

**Mostre a lista ao usuário e confirme o destino antes de trocar qualquer coisa**
— inclusive quando ele passou o `release_id` como argumento, porque um id digitado
à mão erra fácil. Se ele não indicou destino, proponha a imediatamente anterior à
atual.

O `release_id` é `<timestamp>-<sha7>`: o sufixo é o commit, e é o que permite ao
usuário reconhecer para onde está voltando. Diga o sha, não só o timestamp.

Alvo que não existe mais volta `release_not_found` com a lista do que sobrou.
**Não escolha outro por conta própria** — quem pediu uma release específica tinha
um motivo, e o vizinho na lista não é substituto dela.

## 4. Voltar o symlink

```
cloudez_rollback(domain: "<domain>", root: "<root>", to_release_id: "<alvo>")
```

Passe o `to_release_id` sempre, mesmo quando for a imediatamente anterior: o
alvo já foi confirmado no passo 3, e explicitá-lo faz o retorno ser conferível
contra o que o usuário aprovou.

Se falhar com `rollback_failed`, **isso é incidente** — reporte na hora, com
todos os logs, sem tentar mais nada. O site está num estado que você não
conhece.

**Em site tradicional, o rollback termina aqui.** Vá para o passo 6.

## 5. Reconstruir o container — só em `container_docker`

**Sem este passo o rollback não fez nada de visível.** O `cloudez_rollback` troca
o symlink e só; o container continua rodando a imagem construída no deploy que
você está tentando desfazer, e o site segue servindo exatamente aquilo. Já foi
observado: `status: rolled_back` com o `to_release_id` correto, e o site
inalterado.

Você precisa do `deploy_id` da release de destino. Ele está no estado local:
procure em `.cloudez/state/*.json` o arquivo cujo `release_id` seja o alvo.

```
cloudez_compose_build(deploy_id: "<deploy_id do alvo>")
cloudez_compose_up(deploy_id: "<deploy_id do alvo>")
```

O `compose_build` aceita release já ativa de propósito, justamente para este
caso. Confira o `compose.recreated` do `up`: **`false` aqui é problema** — quer
dizer que o container não foi trocado, e o rollback não chegou a acontecer de
fato.

**Se não houver estado local para essa release** — máquina diferente, ou estado
podado depois de 7 dias —, não há `deploy_id` para passar, e as duas tools não
têm como ser chamadas. O caminho então é `/cloudez:deploy` no commit
correspondente (o sha está no `release_id`), que refaz a release e o container.
Diga isso ao usuário em vez de tentar contornar.

## 6. Verificar que o site voltou

```
cloudez_health_check(domain: "<domain>")
```

**Isto não é opcional.** Voltar o symlink é o remédio, não a confirmação.

- **`healthy: false`** — o rollback não resolveu. Reporte imediatamente como
  incidente em aberto e diga qual release está ativa agora. Não tente uma segunda
  release por conta própria.
- **`healthy: true`** — informe o `body_sha256`. Se o usuário souber o conteúdo
  esperado da release antiga, é o que confirma que é ela mesma no ar.

## Como reportar

Comece por **qual versão está no ar agora** — release_id e sha. É a única coisa
que a pessoa do outro lado precisa saber primeiro.

Depois: de onde veio, se o container foi recriado (em site de container), e o
resultado do health check.

Se o rollback falhou em qualquer ponto, diga **em que estado o site ficou** e o
que você não tentou. Num incidente, o que ficou por fazer vale tanto quanto o que
foi feito.

---

## Nota de implementação

O passo 10 do `commands/deploy.md` descreve este mesmo procedimento, e é
duplicação deliberada: um rollback disparado no meio de um deploy que falhou
acontece dentro daquele fluxo, e o modelo não tem como invocar outro comando dali.
**Os dois precisam mudar juntos.**
