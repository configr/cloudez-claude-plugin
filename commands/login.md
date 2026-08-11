---
description: Verifica se há um token da Cloudez salvo e, se não houver, conduz o login
allowed-tools: Bash(cloudez-login:*)
---

Rode:

```sh
cloudez-login --check
```

**Exit 0** — já autenticado. Diga de onde veio o token (`source`: `file` ou
`env`) e pare. Se `verified` for `false`, avise que não foi possível confirmar o
token com a API (o campo `warning` explica) — não trate como erro, mas não afirme
que está tudo certo.

**Exit 1 com `not_authenticated` ou `token_invalid`** — o usuário precisa fazer o
login, e **você não pode fazer por ele**.

O erro traz o comando pronto no campo `claude_code_command` — o caminho absoluto
com `!` na frente. Repasse exatamente isso e peça para ele **enviar como mensagem**:

```
! /caminho/absoluto/bin/cloudez-login
```

O `!` executa no terminal da sessão, onde existe TTY. Não tente rodar sem o `!`
pela tool Bash: ali não há terminal de controle nenhum (`/dev/tty` responde
`Device not configured`), e o comando falha com `no_tty`. Fora do Claude Code, é
rodar o mesmo caminho no terminal dele.

O token vem do painel da Cloudez — é a única forma de autenticar. Se ele pedir
login com e-mail e senha, diga que foi descontinuado (`--password` responde
`password_login_disabled`).

**Nunca peça o token na conversa.** Nem "cole aqui que eu salvo", nem em pedaços,
nem "só os últimos caracteres". O que passa por aqui fica no meu contexto e no
transcript da sessão — um lugar que o usuário não controla e não consegue limpar.
O prompt do `cloudez-login` roda no terminal dele, não ecoa o que é digitado, e
salva com permissão 0600.

Depois que ele disser que fez, rode `cloudez-login --check` de novo para
confirmar. Se continuar falhando:

- `token_invalid` — a Cloudez recusou. Token errado, expirado ou revogado: ele
  gera outro no painel. Você não resolve isso;
- `not_authenticated` — nada foi salvo. Vale conferir se ele usou o `!` e se o
  comando terminou sem erro.
