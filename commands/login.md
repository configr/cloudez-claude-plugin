---
description: Verifica se há um token da Cloudez salvo e, se não houver, conduz o usuário até ele no painel e faz o login
allowed-tools: mcp__cloudez__cloudez_auth_status, Bash(cloudez-login:*), Bash(pbpaste:*), Bash(powershell.exe:*), AskUserQuestion
---

Chame a tool `cloudez_auth_status`. Ela é quem responde pelo estado da
autenticação — o MCP é o único que usa o token contra a API — e, quando não há
autenticação, **já traz os comandos prontos desta máquina**: ela sabe onde o
plugin foi instalado e o que existe aqui de clipboard.

**`authenticated: true`** — diga de onde veio o token (`source`: `file` ou `env`)
e pare. Se `verified` for `false`, avise que não foi possível confirmar o token
com a API (o campo `warning` explica) — não trate como erro, mas não afirme que
está tudo certo.

**`authenticated: false`** — o usuário precisa fazer o login, e **você não pode
fazer por ele**. São duas etapas: achar o token no painel (passo 1) e capturá-lo
sem que ele passe por aqui (passo 2).

# 1. Achar o token no painel

Antes existia só "gere o token no painel da Cloudez", e o comando parava aí. Para
quem nunca viu o painel, isso é um beco: ele não sabe em que página procurar, e
metade das vezes nem tem conta ainda.

## Ele já tem conta?

**Pergunte.** É a bifurcação do passo inteiro, e não dá para deduzir do ambiente.

### Se tem conta

**Peça o endereço do painel dele.** Não presuma nenhum: a Cloudez é white-label, e
cada revenda tem o seu domínio — `cloud.configr.com` é o da Configr, não é "o"
painel. Inventar um manda o usuário para um site que não é o dele.

Se ele não souber qual é, o endereço está no e-mail de boas-vindas da revenda, ou
é o que ele usa para entrar todo dia.

**Normalize o que ele colar.** Ele vai mandar o que tiver na barra de endereços —
`https://painel.exemplo.com/sites/123`, ou só `painel.exemplo.com`. Extraia o
**host** e monte a URL a partir dele. Concatenar em cima do que ele colou produz
`.../sites/123/account?tab=token`, que não existe.

Então diga, com o domínio dele já aplicado:

```
Abra: https://<host>/account?tab=token
Gere o token e copie (Ctrl+C / Cmd+C).
```

### Se não tem conta

**Mande criar em https://cloud.configr.com/register.** Este endereço é da Configr,
e é o padrão de quem está começando — não o repita para quem já tem conta em outra
revenda.

Diga o que vai acontecer, para ele não travar esperando algo que não vem por aqui:

1. ele preenche o cadastro no site;
2. chega um **e-mail para definir a senha** — o plugin não participa dessa etapa;
3. definida a senha, ele entra no painel.

**Espere ele confirmar que definiu a senha.** Não siga por conta própria: entre o
cadastro e a senha há uma ida ao e-mail, e o tempo disso é dele.

Confirmado, o painel é `cloud.configr.com` e o caminho é o mesmo de quem já tinha
conta:

```
Abra: https://cloud.configr.com/account?tab=token
Gere o token e copie (Ctrl+C / Cmd+C).
```

**Não peça e-mail nem telefone.** O cadastro é preenchido por ele, no site da
Configr. Pedir aqui traria dado pessoal para o transcript sem nenhum uso: não há
tool que crie conta, e criar conta em nome de outra pessoa não é coisa que este
comando faça.

# 2. Capturar o token

Daqui em diante nada mudou, e a razão é a que importa: **o token não passa pelo
seu contexto em nenhum dos caminhos.**

Use os campos da resposta do `cloudez_auth_status`, nesta ordem:

**1. Se vier `clipboard_command`** — é o caminho melhor, e você mesmo pode
executar. Quando ele confirmar que copiou, rode o `clipboard_command` (algo como
`pbpaste | /caminho/bin/cloudez-login --stdin`).

Espere a confirmação. Rodar `pbpaste` antes é ler o clipboard dele sem motivo — e
se houver outra coisa lá, esse conteúdo vai para a API da Cloudez como candidato
a token.

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

O token vem do painel da Cloudez — é a única forma de autenticar. Se ele pedir
login com e-mail e senha, diga que foi descontinuado (`--password` responde
`password_login_disabled`).

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
