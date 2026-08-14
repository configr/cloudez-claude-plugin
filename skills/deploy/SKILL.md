---
name: deploy
description: Faz deploy de um site para a Cloudez — sincronização via tar sobre ssh e ativação atômica da release, com rollback. Use quando o usuário pedir para subir, publicar, fazer deploy ou reverter um site, ou quando pedir para ver as releases de um deploy anterior.
---

# Deploy para a Cloudez

Esta skill não contém procedimento. Ela existe para que pedidos em linguagem
natural — "sobe o site", "publica em staging", "volta a versão anterior" —
cheguem ao mesmo lugar que `/cloudez:deploy`.

**Execute o comando `/cloudez:deploy`**, repassando o environment e o diretório
se o usuário os tiver mencionado.

Toda a lógica do deploy vive em `commands/deploy.md`: autenticação, escolha do
environment, confirmação do site na Cloudez, build, identificação da release,
as três etapas do deploy e o rollback. Se precisar consultar o procedimento, leia esse
arquivo — não reconstrua os passos de memória, e não os duplique aqui.

Uma fonte só. Duas descrições do mesmo deploy divergem, e a que estiver errada
vai ser justamente a que ninguém está lendo na hora.
