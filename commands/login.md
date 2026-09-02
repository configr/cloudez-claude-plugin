---
description: Verifica se há um token da Cloudez salvo e, se não houver, cria a conta ou conduz o usuário até o token no painel
allowed-tools: mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_panel_info, mcp__cloudez__cloudez_remember_panel_host, mcp__cloudez__cloudez_signup, mcp__cloudez__cloudez_resend_phone_code, mcp__cloudez__cloudez_confirm_phone, mcp__cloudez__cloudez_get_trial_plan, mcp__cloudez__cloudez_setup_trial_cloud, mcp__cloudez__cloudez_list_clouds, Bash(cloudez-login:*), Bash(pbpaste:*), Bash(powershell.exe:*), AskUserQuestion
---

Chame a tool `cloudez_auth_status`. Ela é quem responde pelo estado da
autenticação — o MCP é o único que usa o token contra a API — e, quando não há
autenticação, **já traz os comandos prontos desta máquina**: ela sabe onde o
plugin foi instalado e o que existe aqui de clipboard.

**`authenticated: true`** — diga de onde veio o token (`source`: `file` ou `env`)
e pare. Se `verified` for `false`, avise que não foi possível confirmar o token
com a API (o campo `warning` explica) — não trate como erro, mas não afirme que
está tudo certo.

**`authenticated: false`** — há dois caminhos, e eles não se parecem. Quem já tem
conta pega o token no painel, e **você não pode fazer isso por ele**. Quem não
tem conta se cadastra aqui mesmo, e aí é você quem executa quase tudo.

# 1. Ele já tem conta?

**Pergunte.** É a bifurcação do comando inteiro, e não dá para deduzir do
ambiente.

## Se tem conta

**Se `cloudez_auth_status` já trouxe `panel_host`, use-o direto — não pergunte
de novo.** É o mesmo painel que outro comando já confirmou nesta máquina
antes, e reperguntar o que já se sabe é o tipo de atrito que faz o usuário
achar que nada fica salvo.

Sem `panel_host` na resposta, **peça o endereço do painel dele.** Não presuma
nenhum: a Cloudez é white-label, e cada revenda tem o seu domínio —
`cloud.configr.com` é o da Configr, não é "o" painel. Inventar um manda o
usuário para um site que não é o dele.

Se ele não souber qual é, o endereço está no e-mail de boas-vindas da revenda, ou
é o que ele usa para entrar todo dia.

**Confira com `cloudez_panel_info` antes de mandá-lo para lá.** Ele vai colar o
que estiver na barra de endereços — `https://painel.exemplo.com/sites/123`, ou só
`painel.exemplo.com` —, e a tool aceita as duas formas e devolve o host limpo em
`panel_host`. Use esse valor, e não o que ele colou: concatenar em cima do que
veio produz `.../sites/123/account?tab=token`, que não existe.

Se vier `panel_not_found`, o endereço está errado. Diga isso e peça de novo, em
vez de mandá-lo abrir uma página que não vai carregar.

**Confirmado — seja porque veio de `cloudez_auth_status`, seja porque acabou
de sair de `cloudez_panel_info` — grave antes de seguir, não pule este passo
mesmo sem efeito visível na resposta de agora:**

```
cloudez_remember_panel_host(panel_host: "<panel_host>")
```

Gravar de novo o que já estava salvo não tem custo: a tool é idempotente. Sem
essa chamada, a próxima conversa pergunta o painel de novo, como se nada
tivesse sido salvo.

Então, com o `panel_host`:

```
Abra: https://<panel_host>/account?tab=token
Gere o token e copie (Ctrl+C / Cmd+C).
Me avise quando tiver copiado o token.
```

**Mande só isso.** Não repita de volta qual painel ele escolheu — ele acabou de
dizer —, e não antecipe telas que ele talvez nem veja. Se o painel pedir alguma
coisa antes do token, como validar o telefone, ele conta e você responde na hora.
Explicar de antemão o que *pode* acontecer transforma três linhas num parágrafo
que ninguém pediu, e enterra a única frase que importa: você está esperando o
token.

O "me avise quando tiver copiado" acima pressupõe que **você** vai capturar o
token — o caso do `clipboard_command`, que é o comum. Confira o retorno do
`cloudez_auth_status` **antes** de escrever a mensagem: sem esse campo, quem
executa é o usuário, e a última linha vira o comando do passo 2.2 em vez do aviso.

Errar isso custa uma ida e volta boba: ele copia, avisa, e só então descobre que
ainda falta rodar alguma coisa.

**Siga para o passo 2.**

## Se não tem conta

**A conta nasce sempre na Configr**, em `cloud.configr.com`. Não pergunte se
ele veio por alguma revenda, e não peça o domínio de painel nenhum aqui: quem
precisar de conta numa revenda entra pelo ramo "Se tem conta", com o painel
dela.

### Colete os dados, um por vez

Pergunte **em texto, uma pergunta por mensagem**, nesta ordem: nome completo,
e-mail, telefone com DDD. Três campos numa mensagem só voltam pela metade, e aí
falta justo o que trava o cadastro.

**Não use `AskUserQuestion` para esses três.** Ela exige de 2 a 4 opções por
pergunta, e nome, e-mail e telefone são texto livre: a chamada é recusada pelo
schema com `Invalid tool parameters`, e você perde um turno até cair na pergunta
em texto. Ela serve nas escolhas de verdade deste comando — "já tem conta?", "os
dados estão certos?" —, e só nelas.

Não peça senha, e não aceite se ele oferecer. O cadastro não tem esse campo: a
conta nasce com uma senha aleatória que ninguém conhece, e ele define a dele pelo
e-mail que chega no fim deste fluxo. Senha colada aqui ficaria no transcript da
sessão sem ter servido para nada.

### Confirme antes de cadastrar

Repita os três de volta e espere ele confirmar. É a última parada antes de uma
conta existir de verdade, e o telefone é onde isso importa mais: sem código de
país, um número de 10 ou 11 dígitos é lido como **brasileiro**. Para quem está em
Portugal, isso está errado, e ele só descobriria quando o SMS não chegasse.

Se ele corrigir alguma coisa, refaça a confirmação com o valor novo.

### Cadastre

Chame `cloudez_signup` com `panel_host: "cloud.configr.com"`, `full_name`,
`email` e `phone`. Ela cria a conta, guarda o token desta máquina e dispara o
SMS. **Não rode `cloudez-login`, e não vá para o passo 2**: o token já foi
salvo pela tool, e não passou por aqui em momento nenhum.

Quando falhar, o código diz o que fazer:

| `code` | O que fazer |
|---|---|
| `email_already_registered` | Ele tinha conta e não sabia. Volte ao ramo "Se tem conta", com `cloud.configr.com`. **Não diga que a conta foi criada agora** — ela é anterior, e nenhum SMS saiu desta tentativa |
| `phone_already_used` | A Cloudez aceita um telefone por conta. Peça outro número |
| `signup_rejected` | Mostre a recusa, corrija o campo apontado e chame de novo. A conta **não** foi criada |
| `signup_incomplete` | A conta **foi** criada. **Não chame de novo** — leia abaixo |
| `already_authenticated` | Apareceu um token válido no meio do caminho. Pare e confirme com o usuário antes de trocar de conta |
| `panel_not_found` ou `register_disabled` | Inesperado para `cloud.configr.com` — não é a revenda errada, é falha da própria Configr. Mostre o erro ao usuário em vez de tentar outro painel |

O `signup_incomplete` é o único que engana. Ele parece um erro de "não deu
certo", mas significa que a conta existe e uma etapa posterior falhou. Repetir só
devolve `email_already_registered` e deixa o usuário achando que não tem conta
nenhuma. O caminho é o que o `hint` diz: definir a senha pelo link de recuperação
do painel e pegar o token por lá.

### Confirme o SMS

Com `code_sent: true`, peça os seis dígitos e chame `cloudez_confirm_phone` com o
`phone_id` do retorno. Não afirme que o SMS chegou: o que a tool observou é que a
Cloudez aceitou enviar, e a entrega ela não vê.

- **não chegou** — `cloudez_resend_phone_code` com o mesmo `phone_id`;
- **`sms_code_invalid`** — o código não bate. Confira os dígitos com ele; se
  desconfiar que leu um SMS antigo, reenvie e peça o novo;
- **`code_sent: false` no signup** — o `warning` diz o que houve. Tente o reenvio
  antes de pedir qualquer código.

### Feche

Com `phone_verified: true`, a conta está ativa e o token já está salvo. Chame
`cloudez_get_trial_plan` com `panel_host: "cloud.configr.com"` — o mesmo do
cadastro. Sem `trial_ia_plan_id` no retorno, a Configr não tem plano trial
configurado: **não chame `cloudez_setup_trial_cloud`**, siga direto para a
frase de fechamento abaixo — é o caso "sem trial disponível", não "trial
falhou".

Com o `trial_ia_plan_id`, chame `cloudez_setup_trial_cloud` passando esse
mesmo id, para contratar o cloud de teste grátis da conta. **A contratação do
teste é sempre feita por esta tool — nunca é algo que o cliente faz por conta
própria no painel.** Diferente da contratação paga (ver `/cloudez:setup`),
que é deliberadamente manual porque envolve dinheiro e escolha de plano do
usuário, o teste grátis não tem opção manual equivalente neste fluxo: se a
tool não conseguir, o caminho é o suporte da Cloudez, não o painel.

**Não repita a chamada se ela falhar.** Não é idempotente: se o provisionamento
tiver ocorrido apesar do erro reportado, uma segunda chamada cria um SEGUNDO
cloud.

- **`cloud_setup_unconfirmed`** — a chamada falhou DEPOIS de enviada (visto na
  prática: provisionar demora, e um timeout não significa que nada foi criado).
  Chame `cloudez_list_clouds` antes de dizer qualquer coisa ao usuário: se o
  cloud já aparecer lá, trate como sucesso; se ele realmente não existir, trate
  como o caso "trial falhou" da frase de fechamento abaixo.
- **`trial_already_exists`** — a conta já tem um cloud. Chame `cloudez_list_clouds`
  e trate como sucesso: não é erro, é a conta já pronta para o próximo passo.
- **`cloud_limit_reached`** — limite de clouds da conta. Não é algo que se
  resolve por aqui: diga ao usuário para contatar o suporte da Cloudez.

**Feche em uma ou duas frases curtas, não numeradas.** O usuário não precisa do
passo a passo interno — só do que muda para ele. No caminho feliz:

> Sua conta foi criada com sucesso. Acesse seu e-mail para definir sua senha —
> é assim que você entra no painel.

Não é preciso mencionar `company_name` nem o cloud/servidor separadamente
quando os dois passos deram certo: "conta criada com sucesso" já cobre.

Só acrescente algo além disso quando um dos dois **não** deu certo:

- `password_email_sent: false` — troque a frase do e-mail: diga que falta
  esse passo e que ele usa "esqueci minha senha" no painel;
- sem `trial_ia_plan_id` (esta revenda não tem plano trial configurado) —
  diga que não há teste grátis disponível, e que para ter um cloud é preciso
  contratar um plano em `https://cloud.configr.com/clouds/create`. Isso é
  contratação paga, não o teste — a distinção importa porque é a única vez
  neste comando em que mandar o cliente ao painel é a resposta certa;
- `cloudez_setup_trial_cloud` falhou e `cloudez_list_clouds` confirmou que o
  cloud não existe — diga que a conta foi criada mas o teste grátis não pôde
  ser provisionado, e peça para ele contatar o suporte da Cloudez. **Não**
  mande para o painel: contratar o teste não é algo que o cliente faz sozinho.

# 2. Capturar o token

**Este passo é só de quem já tinha conta.** Quem se cadastrou pelo passo 1 já
está autenticado.

Daqui em diante nada mudou, e a razão é a que importa: **o token não passa pelo
seu contexto em nenhum dos caminhos.**

Use os campos da resposta do `cloudez_auth_status`, nesta ordem:

**1. Se vier `clipboard_command`** — é o caminho melhor, e **quem executa é você**.

Peça só uma coisa ao usuário: que copie o token e avise. Nada além disso.

**Não mostre o comando a ele.** Exibir o `pbpaste | ... --stdin` faz parecer que
ele é que deve rodá-lo, e aí ou ele executa sem precisar, ou fica esperando para
ver quem vai primeiro. A instrução tem de terminar em "me avise quando tiver
copiado o token" e mais nada — o pipe é assunto seu.

**Espere a confirmação** antes de rodar. Rodar `pbpaste` antes é ler o clipboard
dele sem motivo — e se houver outra coisa lá, esse conteúdo vai para a API da
Cloudez como candidato a token.

Confirmado, rode o `clipboard_command` como ele veio, sem reescrever o caminho.

**2. Se não vier `clipboard_command`, ou o passo 1 falhar** — repasse o
`claude_code_command` e peça para ele **enviar como mensagem**:

```
! /caminho/absoluto/bin/cloudez-login
```

O `!` executa no terminal da sessão, onde existe TTY. Não tente o modo
interativo pela tool Bash: ali não há terminal de controle (`/dev/tty` responde
`Device not configured`) e o comando falha com `no_tty`.

**3. Se nenhum dos dois vier** — o plugin não foi localizado nesta máquina. É o
que o `hint` diz; não invente um caminho.

**Nunca monte o pipe você mesmo.** `echo "<token>" | cloudez-login --stdin` só é
possível se você conhece o token — e se conhece, ele já vazou para o contexto e
para o transcript. O `--stdin` é seguro porque quem executa não vê o valor: use o
`clipboard_command` da resposta, um arquivo, ou `$CLOUDEZ_TOKEN`, nunca um
literal.

O token vem do painel da Cloudez — é a única forma de autenticar quem já tem
conta. Se ele pedir login com e-mail e senha, diga que foi descontinuado
(`--password` responde `password_login_disabled`).

**Nunca peça o token na conversa.** Nem "cole aqui que eu salvo", nem em pedaços,
nem "só os últimos caracteres". O que passa por aqui fica no meu contexto e no
transcript da sessão — um lugar que o usuário não controla e não consegue limpar.
O prompt do `cloudez-login` roda no terminal dele, não ecoa o que é digitado, e
salva com permissão 0600.

Vale para a senha do painel também, com ainda mais força: ela não tem uso nenhum
neste fluxo. Se ele oferecer, recuse e siga para o token.

# 3. Confirmar

Depois que ele disser que fez, chame `cloudez_auth_status` de novo. O MCP relê o
token a cada chamada, então não é preciso reiniciar nada. Se continuar falhando:

- `authenticated: false` com `message` sobre recusa — a Cloudez rejeitou o token.
  Errado, expirado ou revogado: ele gera outro na mesma página do passo 1. Você
  não resolve isso;
- `authenticated: false` com `source: none` — nada foi salvo. Vale conferir se
  ele usou o `!` e se o comando terminou sem erro.
