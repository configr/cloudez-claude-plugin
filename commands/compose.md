---
description: Escreve o docker-compose.yml da aplicação, junto com o usuário
argument-hint: "[diretório]"
allowed-tools: mcp__cloudez__cloudez_find_compose, mcp__cloudez__cloudez_get_site, mcp__cloudez__cloudez_configure_site, Read, Glob, Grep, Write, Edit, AskUserQuestion
---

Escrever o Compose de uma aplicação que você não conhece. **Não há receita**: o
arquivo depende do que a aplicação é, como ela sobe e do que ela precisa em
volta. O que existe são restrições do ambiente, que valem para todos, e uma
leitura do projeto, que é diferente em cada caso.

Isto é uma conversa, não uma geração. Você propõe, o usuário corrige, e o
arquivo só é escrito quando ele concordar.

## 0. Já existe um?

```
cloudez_find_compose(directory: "<diretório>")
```

**`compose: true`** — não sobrescreva. Leia o arquivo e diga o que ele já faz.
Se o usuário quer mudança, trate como edição: mostre o antes e o depois do
trecho, e mexa só no que ele pediu.

Se vier `ignored`, avise: há mais de um arquivo, e o Compose usa só o `file`.

**E confira a porta**, que é o que decide se a aplicação vai responder. O retorno
traz `ports`, lido do arquivo: cada item tem o `published` (porta do host) e o
`service` que o publica.

Compare com a `custom_port` do site (`cloudez_get_site`). Três casos:

| O que você vê | O que fazer |
|---|---|
| batem | Diga que está tudo certo e siga |
| **divergem** | **Pergunte** ao usuário se quer que a Cloudez passe a apontar para a porta do Compose. Se ele aceitar, `cloudez_configure_site(domain, custom_port: "<published do Compose>")`. **Não** altere o arquivo dele: quem já tem um Compose rodando escolheu aquela porta, e mudá-la mexe no que funciona |
| nenhum `published` | O Compose só declara a porta do container. O Docker publica numa porta alta aleatória, que muda a cada `up`, e o nginx não tem para onde apontar. **Isto precisa ser corrigido no arquivo** — ofereça o mapeamento completo |

Se vier `parse_error` em vez de `ports`, diga que o arquivo existe mas não pôde
ser lido, mostre a mensagem, e **não afirme nada sobre a porta**. Não saber é
diferente de estar certo.

## 1. Entender a aplicação

**Leia antes de perguntar.** Perguntar o que está escrito no projeto gasta a
paciência do usuário e sinaliza que você não olhou.

O que procurar, e por quê:

| Pergunta | Onde costuma estar |
|---|---|
| Que runtime é | `package.json`, `requirements.txt`, `go.mod`, `Gemfile`, `composer.json`, `pom.xml`, `Cargo.toml` |
| Como sobe | `scripts.start`, `Procfile`, `main`, `if __name__`, `CMD` de um Dockerfile existente |
| Em que porta escuta | busca por `listen`, `PORT`, `addr`, `bind` no código |
| Precisa de build | `scripts.build`, `tsconfig`, `vite`, `webpack`, um estágio de compilação |
| Precisa de serviços | driver de banco nas dependências (`pg`, `mysql2`, `psycopg`, `redis`) |

**Pergunte o que o projeto não responde.** Credenciais, qual banco de verdade,
se aquele Redis é opcional, se o build precisa de variável de ambiente. E
pergunte de uma vez, não uma por mensagem.

## 2. As restrições que não são negociáveis

Estas vêm do ambiente da Cloudez, não da aplicação. Uma aplicação que não as
cumpra não fica no ar, por melhor que o Compose esteja.

### A porta publicada e a `custom_port` do site são a MESMA

O nginx da Cloudez encaminha `/` do domínio para uma porta do host — qual, está na
`custom_port` do site. A aplicação precisa responder exatamente nela. Divergência
entre as duas dá **502** num deploy que rodou inteiro e sem erro nenhum.

**Escrevendo um arquivo novo, use 3000**, que é o default deste plugin e o que o
`/cloudez:setup` grava:

```yaml
ports:
  - "127.0.0.1:3000:3000"     # 3000 no host  ←  3000 dentro do container
```

Os dois lados são independentes, e coincidirem aqui é sorte do caso comum: 3000 é
o default deste plugin no host e também o que boa parte dos frameworks Node escuta
por padrão. Uma aplicação que escute em 8000 fica assim:

```yaml
ports:
  - "127.0.0.1:3000:8000"     # 3000 no host  ←  8000 dentro do container
```

**Num arquivo que já existe, quem manda é o arquivo.** Se ele publica em 3000, a
Cloudez é que se ajusta (passo 0) — não o contrário. Mexer na porta de uma
aplicação que já roda é alterar o que funciona para satisfazer uma convenção
nossa.

O número da direita é o da aplicação — descubra, não presuma. Se ela lê `PORT`
do ambiente, defina explicitamente em vez de torcer pelo padrão dela.

### Dentro do container, escute em `0.0.0.0`

Esta é a confusão mais cara aqui, porque os dois lados pedem coisas **opostas**:

- **no host**, publique em `127.0.0.1` — publicar em `0.0.0.0` deixaria a
  aplicação acessível direto pelo IP do servidor, por fora do nginx, sem TLS e
  sem as regras dele;
- **dentro do container**, escute em `0.0.0.0` — escutar em `127.0.0.1` ali
  significa "só quem está dentro deste container", e o mapeamento de porta nunca
  alcança.

O sintoma dos dois erros é diferente: o primeiro funciona e é inseguro; o
segundo dá **502** e parece problema de rede.

Muitos frameworks escutam em `localhost` por padrão em desenvolvimento. Confira,
e ajuste no comando de start ou por variável de ambiente.

### Dado que precisa sobreviver vai em volume nomeado

O deploy publica em `releases/<id>/` e aponta o symlink `current` para lá. **O
diretório de cada release é apagado** — a retenção mantém as cinco últimas.

Então:

```yaml
volumes:
  - dados:/var/lib/postgresql/data      # sobrevive ao deploy
# - ./dados:/var/lib/postgresql/data    # SOME quando a release for podada
```

Um bind mount relativo aponta para dentro da release atual. Ele funciona no
primeiro deploy, e no sexto o diretório já não existe.

Pelo mesmo motivo, **não monte o código-fonte no container** (`- .:/app`). Além
de apagar o que a imagem construiu, prende o container a um diretório que vai
ser podado.

### Sem `container_name`

O `cloudez_compose_up` roda o Compose com `-p <domínio>`, para dois sites no
mesmo servidor não virarem o mesmo projeto. Um `container_name` fixo ignora isso
e volta a colidir entre sites.

### `restart: unless-stopped`

Sem isso a aplicação não volta depois de um reboot do servidor, e o sintoma é um
site que caiu sozinho de madrugada.

### Segredos não entram no arquivo

O Compose vai para o repositório. Senha, token e chave saem por variável de
ambiente ou pelo painel da Cloudez — e se o usuário oferecer um segredo na
conversa, não escreva no arquivo.

## 3. Propor

Mostre o Compose **inteiro** antes de escrever, e explique as escolhas que não
são óbvias: por que aquela porta interna, por que aquele volume, por que aquele
serviço extra existe ou não.

Diga o que você **presumiu** e o que **não conseguiu descobrir**. Uma presunção
declarada o usuário corrige em dez segundos; uma escondida vira um deploy que
falha por motivo que ninguém liga ao arquivo.

Se a aplicação precisar de um `Dockerfile` e não houver um, ele faz parte da
proposta — um `build:` sem Dockerfile não sobe.

**Espere o aceite.** Só então escreva, na raiz do contexto de build, junto do
Dockerfile.

## 4. Depois de escrever

Diga ao usuário, nesta ordem:

1. que o arquivo precisa ser **commitado** — o deploy publica o que está no git,
   e um Compose não versionado não chega ao servidor;
2. que a porta publicada e a `custom_port` do site precisam continuar iguais — se
   você alterou uma delas aqui, diga qual e por quê;
3. que o deploy é `/cloudez:deploy`, e que o passo de verificação vai dizer se a
   aplicação respondeu de verdade.

Não rode o deploy por conta própria. Escrever o arquivo e publicar são decisões
diferentes, e a segunda é do usuário.
