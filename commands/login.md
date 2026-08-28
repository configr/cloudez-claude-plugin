---
description: Verifica se há um token da Cloudez salvo e, se não houver, cria a conta ou conduz o usuário até o token no painel
allowed-tools: mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_panel_info, mcp__cloudez__cloudez_signup, mcp__cloudez__cloudez_resend_phone_code, mcp__cloudez__cloudez_confirm_phone, Bash(cloudez-login:*), Bash(pbpaste:*), Bash(powershell.exe:*), AskUserQuestion
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

**Peça o endereço do painel dele.** Não presuma nenhum: a Cloudez é white-label, e
cada revenda tem o seu domínio — `cloud.configr.com` é o da Configr, não é "o"
painel. Inventar um manda o usuário para um site que não é o dele.

Se ele não souber qual é, o endereço está no e-mail de boas-vindas da revenda, ou
é o que ele usa para entrar todo dia.

**Confira com `cloudez_panel_info` antes de mandá-lo para lá.** Ele vai colar o
que estiver na barra de endereços — `https://painel.exemplo.com/sites/123`, ou só
`painel.exemplo.com` —, e a tool aceita as duas formas e devolve o host limpo em
`panel_host`. Use esse valor, e não o que ele colou: concatenar em cima do que
veio produz `.../sites/123/account?tab=token`, que não existe.

Se vier `panel_not_found`, o endereço está errado. Diga isso e peça de novo, em
vez de mandá-lo abrir uma página que não vai carregar.

Então, com o `panel_host` da resposta:

```
Abra: https://<panel_host>/account?tab=token
Gere o token e copie (Ctrl+C / Cmd+C).
Me avise quando tiver copiado o token.
```

O "me avise quando tiver copiado" acima pressupõe que **você** vai capturar o
token — o caso do `clipboard_command`, que é o comum. Confira o retorno do
`cloudez_auth_status` **antes** de escrever a mensagem: sem esse campo, quem
executa é o usuário, e a última linha vira o comando do passo 2.2 em vez do aviso.

Errar isso custa uma ida e volta boba: ele copia, avisa, e só então descobre que
ainda falta rodar alguma coisa.

**Siga para o passo 2.**

## Se não tem conta

**Pergunte se ele chegou por alguma revenda** — e deixe claro que "não" e "não
sei" são respostas válidas. Não insista: quem não sabe, não sabe, e o padrão
resolve.

Isso não é formalidade. A Cloudez é white-label, e cadastrar na Configr quem foi
atendido por uma revenda cria a conta **na empresa errada**: os sites nasceriam
fora de quem o trouxe, e o token de um painel não vale no outro.

| A resposta | O painel |
|---|---|
| veio por uma revenda | **peça o domínio dela** |
| não veio, ou não sabe | `cloud.configr.com` — a Configr é o padrão |

Com o host decidido, chame `cloudez_panel_info`. Ela resolve a empresa e diz se
o cadastro está aberto:

- **`register_enabled: false`** — essa revenda não abre cadastro self-service.
  Pare aqui e diga para ele procurar a revenda. Não tente outro painel: criar a
  conta na Configr seria criá-la na empresa errada;
- **`panel_not_found`** — o endereço está errado. Peça de novo;
- **`register_enabled: true`** — siga.

### Colete os dados, um por vez

Use `AskUserQuestion`, **uma pergunta por caixa**, nesta ordem: nome completo,
e-mail, telefone com DDD. Três campos numa mensagem só voltam pela metade, e aí
falta justo o que trava o cadastro.

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

Chame `cloudez_signup` com `panel_host`, `full_name`, `email` e `phone`. Ela cria
a conta, guarda o token desta máquina e dispara o SMS. **Não rode
`cloudez-login`, e não vá para o passo 2**: o token já foi salvo pela tool, e não
passou por aqui em momento nenhum.

Quando falhar, o código diz o que fazer:

| `code` | O que fazer |
|---|---|
| `email_already_registered` | Ele tinha conta e não sabia. Volte ao ramo "Se tem conta" — o token está em `/account?tab=token` |
| `phone_already_used` | A Cloudez aceita um telefone por conta. Peça outro número |
| `signup_rejected` | Mostre a recusa, corrija o campo apontado e chame de novo. A conta **não** foi criada |
| `signup_incomplete` | A conta **foi** criada. **Não chame de novo** — leia abaixo |
| `already_authenticated` | Apareceu um token válido no meio do caminho. Pare e confirme com o usuário antes de trocar de conta |

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

Com `phone_verified: true`, a conta está ativa e o token já está salvo. Diga, nesta
ordem:

1. a conta foi criada na empresa que veio em `company_name`;
2. um e-mail para **definir a senha** foi enviado — é assim que ele entra no
   painel, porque a senha do cadastro é aleatória e ninguém a conhece. Se
   `password_email_sent` vier `false`, diga que falta esse passo e que ele usa o
   "esqueci minha senha" no painel;
3. **ainda falta um servidor.** A conta é nova e não tem cloud nenhuma; deploy
   agora falharia num ponto bem menos claro que aqui. Mande-o iniciar o teste no
   painel, em `https://<panel_host>`.

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
