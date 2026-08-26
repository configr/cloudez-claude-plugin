---
name: deploy
description: Faz deploy de um site para a Cloudez — sincronização via tar sobre ssh e ativação atômica da release. Use quando o usuário pedir para subir, publicar ou fazer deploy de um site. Para reverter um deploy ou ver as releases no servidor, a skill é a de rollback.
---

# Deploy para a Cloudez

Esta skill não contém procedimento. Ela existe para que pedidos em linguagem
natural — "sobe o site", "publica em staging", "manda pra produção" — cheguem ao
mesmo lugar que `/cloudez:deploy`.

**Reverter não é aqui.** Esta skill encaminha para o `/cloudez:deploy`, e o
rollback autônomo é outro comando; o bloco de rollback do `deploy.md` existe só
para a queda no meio de um deploy, que acontece dentro daquele fluxo. Pedido de
reversão vai para a skill `rollback`, e quem faz esse pedido costuma estar com o
site fora do ar — mandá-lo para o comando errado custa caro.

**Execute o comando `/cloudez:deploy`**, repassando o environment e o diretório
se o usuário os tiver mencionado.

Toda a lógica do deploy vive em `commands/deploy.md`: autenticação, escolha do
environment, confirmação do site na Cloudez, build, identificação da release,
as três etapas do deploy e o rollback. Se precisar consultar o procedimento, leia esse
arquivo — não reconstrua os passos de memória, e não os duplique aqui.

Uma fonte só. Duas descrições do mesmo deploy divergem, e a que estiver errada
vai ser justamente a que ninguém está lendo na hora.
