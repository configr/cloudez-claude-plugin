---
name: setup
description: Cria o .cloudez.yaml do projeto para um domínio e environment, e confere o que o site precisa ter configurado na Cloudez. Use quando o usuário pedir para configurar o projeto para a Cloudez, apontar o projeto para um domínio, preparar um environment novo (staging, produção), ou quando perguntar por que o deploy não encontra a configuração.
---

# Configurar o projeto para a Cloudez

Esta skill não contém procedimento. Ela existe para que pedidos em linguagem
natural — "configura esse projeto pra cloudez", "aponta pro meusite.com.br",
"cria um environment de staging" — cheguem ao mesmo lugar que `/cloudez:setup`.

**Execute o comando `/cloudez:setup`**, repassando o domínio e o environment se o
usuário os tiver mencionado.

Toda a lógica vive em `commands/setup.md`: a confirmação do domínio contra a API
antes de escrever qualquer coisa, o formato do arquivo, e a conferência do que o
site precisa ter no painel — o tipo `container_docker`, o `app_root_path`, a
`custom_port` e a chave SSH desta máquina. Esse último bloco é o que evita a falha
mais confusa do plugin, então não o pule. Se precisar consultar o procedimento,
leia esse arquivo; não reconstrua os passos de memória, e não os duplique aqui.

Uma fonte só. Duas descrições do mesmo setup divergem, e a que estiver errada vai
ser justamente a que ninguém está lendo na hora.
