---
name: login
description: Autentica o usuário na Cloudez — confere se já há token salvo e, não havendo, cria a conta ou conduz até o token no painel. Use quando o usuário pedir para entrar, autenticar, fazer login na Cloudez, conectar a conta, trocar de token, criar conta, se cadastrar, ou quando disser que não tem conta, que o token expirou ou que não está conseguindo autenticar.
---

# Login na Cloudez

Esta skill não contém procedimento. Ela existe para que pedidos em linguagem
natural — "faz login na cloudez", "meu token expirou", "conecta minha conta" —
cheguem ao mesmo lugar que `/cloudez:login`.

**Execute o comando `/cloudez:login`.**

Toda a lógica vive em `commands/login.md`: a verificação do token que já existe, a
ramificação entre quem tem e quem não tem conta, o cadastro com confirmação por
SMS, o caminho até a página certa do painel — que é o do usuário, porque a Cloudez
é white-label — e a captura do token sem que ele passe pela conversa. Se precisar
consultar o procedimento, leia esse arquivo; não reconstrua os passos de memória,
e não os duplique aqui.

Uma fonte só. Duas descrições do mesmo login divergem, e a que estiver errada vai
ser justamente a que ninguém está lendo na hora.
