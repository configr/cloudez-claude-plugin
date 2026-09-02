---
name: hire-cloud
description: Contrata uma cloud (servidor) nova na Cloudez. Use quando o usuário pedir para contratar, comprar, adicionar ou provisionar uma cloud/servidor novo, fora do cadastro de conta — onde o trial já resolve isso sozinho.
---

# Contratar uma cloud na Cloudez

Esta skill não contém procedimento. Ela existe para que pedidos em linguagem
natural — "quero contratar uma cloud", "preciso de um servidor novo", "como
eu contrato mais uma cloud" — cheguem ao mesmo lugar que
`/cloudez:hire-cloud`.

## Antes de encaminhar: o usuário está autenticado?

Chame `cloudez_auth_status`. Com `authenticated: false`, **execute o
`/cloudez:login` primeiro** e só depois siga para o comando desta skill.

Isto vive na skill, e não só no comando, pela mesma razão do
`/cloudez:setup`: quem chega em linguagem natural pode nunca ter feito login,
e descobrir a falta de token no meio do procedimento custa uma conversa
interrompida no pior lugar.

**Execute o comando `/cloudez:hire-cloud`.**

Toda a lógica vive em `commands/hire-cloud.md`: o painel — perguntado só
quando ainda não há um lembrado nesta máquina —, o aviso de que este comando
é sempre contratação paga, e o antes/depois de `cloudez_list_clouds` para
achar a cloud nova. Se precisar consultar o procedimento, leia esse arquivo;
não reconstrua os passos de memória, e não os duplique aqui.

Uma fonte só. Duas descrições do mesmo procedimento divergem, e a que estiver
errada vai ser justamente a que ninguém está lendo na hora.
