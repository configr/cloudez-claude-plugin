---
description: Contrata uma cloud (servidor) nova na Cloudez, sempre pelo painel — não há tool de pagamento. Use quando o usuário pedir para contratar, comprar ou adicionar uma cloud/servidor, fora do cadastro de conta, onde o trial já resolve isso sozinho.
allowed-tools: mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_panel_info, mcp__cloudez__cloudez_remember_panel_host, mcp__cloudez__cloudez_list_clouds, AskUserQuestion
---

## 0. Autenticação, antes de qualquer coisa

Chame `cloudez_auth_status`.

**`authenticated: false`** — pare aqui. Conduza o `/cloudez:login` e só volte
depois que ele passar: contratar sem conta não faz sentido, é a conta que
paga. Depois do login, reinicie este comando do passo 0.

**`authenticated: true` não é algo para relatar ao usuário.** Siga direto
para o passo 1, em silêncio — dizer "você está autenticado" aqui é ruído: o
usuário só quer contratar a cloud, não um relatório de credencial.

## 1. O painel

Se a resposta do passo 0 já trouxe `panel_host`, use-o direto — **não
pergunte de novo.** É o mesmo painel que outro comando já confirmou nesta
máquina antes.

Sem `panel_host` na resposta, pergunte o endereço que o usuário usa para
entrar na Cloudez, **em texto, não com `AskUserQuestion`** — ela exige de 2 a
4 opções, e o endereço do painel é texto livre: a chamada é recusada pelo
schema com `Invalid tool parameters`, e o turno se perde até cair na
pergunta em texto mesmo. `AskUserQuestion` serve só para "qual cloud, se vier
mais de uma" no passo 3. Não presuma nenhum painel: a Cloudez é white-label,
cada revenda tem o seu domínio — `cloud.configr.com` é o da Configr, não é
"o" painel.

Confirme com `cloudez_panel_info`. Se vier `panel_not_found`, o endereço
está errado — diga isso e peça de novo, em vez de seguir com um painel que
não existe.

**Confirmado, grave o painel antes de seguir — não pule este passo, mesmo
sem efeito visível na resposta de agora:**

```
cloudez_remember_panel_host(panel_host: "<panel_host>")
```

Sem essa chamada, a próxima conversa — aqui ou em qualquer outro comando
deste plugin — pergunta o painel de novo, como se nada tivesse sido salvo.

## 2. Sem teste grátis aqui

Este comando é sempre contratação **paga**. Se o usuário perguntar por teste
grátis, ou parecer esperar que este fluxo ofereça um: não ofereça, e não
existe caminho manual para ele pelo painel. O único jeito de ganhar o trial é
o `/cloudez:login`, no cadastro de uma conta nova — automático, uma vez, e
não é algo que se repete nem se contrata depois.

## 3. Contratar

Guarde os `id` que `cloudez_list_clouds()` devolve agora — é o retrato de
antes, contra o qual vai comparar depois de o usuário confirmar.

Mande:

```
Abra: https://<panel_host>/clouds/create
Contrate o plano que preferir. Quando terminar, me avise.
```

**Espere a confirmação dele antes de conferir.** Contratar e provisionar
levam um tempo que este comando não controla — não há como saber daqui
quando terminou, e não existe polling automático: quem avisa é o usuário.

Confirmado, chame `cloudez_list_clouds()` de novo e compare com o retrato de
antes:

- **Uma cloud nova** (o caso comum) — diga qual é (`name`, `fqdn`) e que está
  pronta. Se o pedido original envolvia um site, ofereça seguir com
  `/cloudez:setup` usando essa cloud;
- **Nenhuma nova ainda** — diga que a contratação pode ainda estar
  processando, e pergunte se ele quer que confira de novo. Não repita
  sozinho em loop;
- **Mais de uma nova** — pergunte qual, mostrando `name` e `fqdn` de cada uma.
