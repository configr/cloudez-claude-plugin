---
description: Volta o site para uma release anterior, com verificação de que ele voltou ao ar
argument-hint: "[environment] [release_id]"
allowed-tools: mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_panel_info, mcp__cloudez__cloudez_signup, mcp__cloudez__cloudez_resend_phone_code, mcp__cloudez__cloudez_confirm_phone, mcp__cloudez__cloudez_get_site, mcp__cloudez__cloudez_list_releases, mcp__cloudez__cloudez_rollback, mcp__cloudez__cloudez_compose_build, mcp__cloudez__cloudez_compose_up, mcp__cloudez__cloudez_health_check, Read, Grep, AskUserQuestion
---

Argumentos recebidos: `$ARGUMENTS` — o environment e, opcionalmente, a release
de destino.

Este comando é para quando **alguma coisa já deu errado**. Trate-o assim: vá
direto ao ponto, não proponha investigar a causa antes de devolver o site ao ar,
e não peça confirmações que não mudam o resultado.

Duas coisas, porém, não se pulam por pressa: **confirmar o alvo** e **verificar
depois**. Um rollback para a release errada troca um site quebrado por outro, e
um rollback não verificado é o pior estado possível para se declarar resolvido.

O projeto precisa de um `.cloudez.yaml`. Sem ele não há domínio, e sem domínio não
há o que voltar — pare e diga isso.

**Não exija working tree limpo, nem repositório git.** Nada aqui é publicado a
partir do disco local: as releases já estão no servidor. Exigir árvore limpa só
impediria o rollback exatamente quando alguém está no meio de uma correção às
pressas.

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

Confirme o `stack`: este plugin só publica `claude` (e o anterior, `container_docker`). O passo 5 é
obrigatório — sem ele o rollback troca o symlink e não surte efeito nenhum, porque
quem responde é o container, que continua rodando a imagem antiga.

## 3. Escolher o alvo, e confirmar

```
cloudez_list_releases(domain: "<domain>")   # `root:` só se o .cloudez.yaml o tiver
```

> **Não passe `root`.** O diretório do site no servidor é sempre
> `~/<domain>/www/claude`, e as tools o derivam do domínio — ele saiu do
> `.cloudez.yaml` porque a Cloudez RENOMEIA o diretório quando o domínio do site
> muda, e um valor escrito passaria a apontar para o que deixou de existir.
>
> A exceção é config antiga: havendo `root:` no bloco do environment, **passe-o** —
> ele vence o derivado, e ignorá-lo publicaria noutro lugar sem avisar. Não
> reescreva o arquivo do usuário para tirá-lo.

A lista vem da mais nova para a mais velha, com `current: true` na que está no
ar. O servidor guarda as 5 mais recentes.

**Mostre a lista ao usuário e confirme o destino antes de trocar qualquer coisa**
— inclusive quando ele passou o `release_id` como argumento, porque um id digitado
à mão erra fácil. Se ele não indicou destino, proponha a imediatamente anterior à
atual.

O `release_id` é `<timestamp>-<sufixo>`, e o sufixo é o que permite ao usuário
reconhecer para onde está voltando — diga-o, não só o timestamp. A primeira
letra diz de onde ele veio:

- **`g1a2b3c`** — commit do git. É o que a pessoa reconhece; se ela souber o
  commit, sabe o que está voltando.
- **`c9f8e7d`** — hash do conteúdo publicado, de um deploy feito fora de um
  repositório git (ou com a árvore suja). Não tem como ser cruzado com o
  histórico: o que o identifica é o próprio conteúdo.

Não trate um `c` como anomalia nem sugira ao usuário que aquela release é menos
confiável. As duas foram publicadas do mesmo jeito; o que muda é só qual
identificador estava disponível na hora.

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

## 5. Reconstruir o container

**Sem este passo o rollback não fez nada de visível.** O `cloudez_rollback` troca
o symlink e só; o container continua rodando a imagem construída no deploy que
você está tentando desfazer, e o site segue servindo exatamente aquilo. Já foi
observado: `status: rolled_back` com o `to_release_id` correto, e o site
inalterado.

Você precisa do `deploy_id` da release de destino. Ele está no estado local:
procure em `~/.cloudez/state/*.json` o arquivo cujo `release_id` seja o alvo.

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
têm como ser chamadas. O caminho então é `/cloudez:deploy` a partir do conteúdo
correspondente, que refaz a release e o container. Diga isso ao usuário em vez de
tentar contornar.

Com sufixo `g`, o commit está no próprio `release_id` e o caminho é dar checkout
nele. Com sufixo `c` **não há como recuperar o conteúdo a partir do id** — ele
identifica, não armazena. Diga isso claramente: o usuário precisa saber de que
diretório aquela release saiu, e essa informação não está no servidor.

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

Comece por **qual versão está no ar agora** — o `release_id` inteiro. É a única
coisa que a pessoa do outro lado precisa saber primeiro. Quando o sufixo for `g`,
mencione o commit junto: é o que ela reconhece.

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
