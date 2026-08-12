---
description: Verifica se há um token da Cloudez salvo e, se não houver, conduz o login
allowed-tools: mcp__cloudez__cloudez_auth_status, Bash(cloudez-login:*), Bash(pbpaste:*), Bash(wl-paste:*), Bash(xclip:*), Bash(xsel:*)
---

Chame a tool `cloudez_auth_status`. Ela é quem responde pelo estado da
autenticação: o MCP é o único que usa o token contra a API, então é a única
resposta que vale.

**`authenticated: true`** — já autenticado. Diga de onde veio o token (`source`:
`file` ou `env`) e pare. Se `verified` for `false`, avise que não foi possível
confirmar o token com a API (o campo `warning` explica) — não trate como erro,
mas não afirme que está tudo certo.

**`authenticated: false`** — o usuário precisa fazer o login, e **você não pode
fazer por ele**.

Rode `cloudez-login --hint` para obter os comandos prontos desta máquina — o
caminho de instalação do plugin e o utilitário de clipboard variam, e é por isso
que essa dica vem do shell e não do MCP. Ele não lê token nem chama a API.

Ofereça os dois caminhos, **nesta ordem**:

**1. Se vier `clipboard_command`** — é o caminho melhor, e você mesmo pode executar:
peça para ele gerar o token no painel da Cloudez e **copiar**. Quando ele
confirmar que copiou, rode o `clipboard_command` do erro (algo como
`pbpaste | /caminho/bin/cloudez-login --stdin`).

Espere a confirmação. Rodar `pbpaste` antes é ler o clipboard dele sem motivo — e
se houver outra coisa lá, esse conteúdo vai para a API da Cloudez como candidato a
token.

**2. Se não vier `clipboard_command`, ou o passo 1 falhar** — repasse o
`claude_code_command` (o caminho com `!` na frente) e peça para ele **enviar como
mensagem**:

```
! /caminho/absoluto/bin/cloudez-login
```

O `!` executa no terminal da sessão, onde existe TTY. Não tente o modo interativo
pela tool Bash: ali não há terminal de controle (`/dev/tty` responde
`Device not configured`) e o comando falha com `no_tty`.

**Nunca monte o pipe você mesmo.** `echo "<token>" | cloudez-login --stdin` só é
possível se você conhece o token — e se conhece, ele já vazou para o contexto e
para o transcript. O `--stdin` é seguro porque quem executa não vê o valor: use
`pbpaste`, um arquivo, ou `$CLOUDEZ_TOKEN`, nunca um literal.

O token vem do painel da Cloudez — é a única forma de autenticar. Se ele pedir
login com e-mail e senha, diga que foi descontinuado (`--password` responde
`password_login_disabled`).

**Nunca peça o token na conversa.** Nem "cole aqui que eu salvo", nem em pedaços,
nem "só os últimos caracteres". O que passa por aqui fica no meu contexto e no
transcript da sessão — um lugar que o usuário não controla e não consegue limpar.
O prompt do `cloudez-login` roda no terminal dele, não ecoa o que é digitado, e
salva com permissão 0600.

Depois que ele disser que fez, chame `cloudez_auth_status` de novo para
confirmar. O MCP relê o token a cada chamada, então não é preciso reiniciar nada.
Se continuar falhando:

- `authenticated: false` com `hint` sobre recusa — a Cloudez rejeitou o token.
  Errado, expirado ou revogado: ele gera outro no painel. Você não resolve isso;
- `authenticated: false` com `source: none` — nada foi salvo. Vale conferir se
  ele usou o `!` e se o comando terminou sem erro.
