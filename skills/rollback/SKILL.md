---
name: rollback
description: Volta o site para uma release anterior, com verificação de que ele voltou ao ar. Use quando o usuário pedir para reverter, voltar a versão anterior, desfazer o último deploy, ou disser que o site quebrou depois de publicar. Também quando pedir para ver as releases que estão no servidor.
---

# Voltar o site para uma release anterior

Esta skill não contém procedimento. Ela existe para que pedidos em linguagem
natural — "volta a versão anterior", "desfaz o último deploy", "o site quebrou,
reverte" — cheguem ao mesmo lugar que `/cloudez:rollback`.

**Execute o comando `/cloudez:rollback`**, repassando o environment e o
`release_id` se o usuário os tiver mencionado.

Toda a lógica vive em `commands/rollback.md`: a confirmação do alvo, o limite das
5 releases que o servidor mantém, e — o que mais importa em site de container — a
reconstrução da imagem depois de trocar o symlink, sem a qual o rollback não surte
efeito nenhum. Se precisar consultar o procedimento, leia esse arquivo; não
reconstrua os passos de memória, e não os duplique aqui.

Quem chega aqui costuma estar com o site fora do ar. Vá direto ao comando.
