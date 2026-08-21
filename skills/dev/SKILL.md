---
name: dev
description: Sobe o site do usuário localmente — pelo dev server do projeto quando for Node, ou em container — e abre no navegador do Claude Code. Use quando ele pedir para rodar, subir, testar ou ver o site na máquina dele — "roda aqui", "abre no navegador", "quero ver antes de publicar" — e não para publicar, que é a skill de deploy.
---

# Rodar o site localmente

Esta skill não contém procedimento. Ela existe para que pedidos em linguagem
natural — "roda o site aqui", "abre isso no navegador", "quero ver como ficou
antes de subir" — cheguem ao mesmo lugar que `/cloudez:dev`.

**Execute o comando `/cloudez:dev`**, repassando o diretório se o usuário o tiver
mencionado.

Toda a lógica vive em `commands/dev.md`: decidir entre dev server e container,
achar a porta certa de cada um, o `.claude/launch.json`, subir pelo painel de
navegador e ler os logs quando não responde. Se precisar consultar o procedimento, leia esse arquivo — não
reconstrua os passos de memória, e não os duplique aqui.

**Não confunda com publicar.** "Sobe o site" é ambíguo em português: pode ser
rodar aqui ou pôr no ar. Na dúvida, pergunte — o `/cloudez:deploy` mexe no que
está em produção, e este comando não toca a Cloudez.

Uma fonte só. Duas descrições do mesmo procedimento divergem, e a que estiver
errada vai ser justamente a que ninguém está lendo na hora.
