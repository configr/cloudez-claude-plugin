---
name: compose
description: Escreve o docker-compose da aplicação, ou a sobreposição de produção quando já existe um, junto com o usuário. Use quando ele pedir para criar ou ajustar o docker-compose, containerizar a aplicação, preparar o projeto para rodar em Docker, ou quando pedir para acrescentar um banco de dados ao projeto.
---

# Escrever o Compose da aplicação

Esta skill não contém procedimento. Ela existe para que pedidos em linguagem
natural — "cria o docker-compose", "containeriza essa aplicação", "preciso de um
postgres aqui" — cheguem ao mesmo lugar que `/cloudez:compose`.

**Execute o comando `/cloudez:compose`**, repassando o diretório se o usuário o
tiver mencionado.

Toda a lógica vive em `commands/compose.md`: a leitura do projeto, as restrições
que não se negociam (a porta publicada, o dado que precisa sobreviver à poda de
releases), a decisão entre reescrever e sobrepor quando já existe um Compose, e as
duas opções de banco — que são PERGUNTA ao usuário, e não escolha sua. Se precisar
consultar o procedimento, leia esse arquivo; não reconstrua os passos de memória, e
não os duplique aqui.

Uma fonte só. Duas descrições do mesmo Compose divergem, e a que estiver errada vai
ser justamente a que ninguém está lendo na hora.
