---
description: Escreve o Compose da aplicação — ou a sobreposição de produção, quando já existe um — junto com o usuário
argument-hint: "[diretório]"
allowed-tools: mcp__cloudez__cloudez_find_compose, mcp__cloudez__cloudez_get_site, mcp__cloudez__cloudez_configure_site, Read, Glob, Grep, Write, Edit, AskUserQuestion
---

Escrever o Compose de uma aplicação que você não conhece. **Não há receita**: o
arquivo depende do que a aplicação é, como ela sobe e do que ela precisa em
volta. O que existe são restrições do ambiente, que valem para todos, e uma
leitura do projeto, que é diferente em cada caso.

São dois arquivos possíveis, e qual deles você escreve é a primeira decisão:

- **`docker-compose.yml`** (ou qualquer das quatro grafias), quando o projeto não
  tem nenhum. Vale nos dois lugares e nasce pronto para produção;
- **`docker-compose.cloudez.yml`**, a sobreposição, quando já existe um. O deploy
  a mescla no servidor com `-f`; localmente ela não é lida, e o usuário segue
  rodando `docker compose up` sem argumento nenhum.

Isto é uma conversa, não uma geração. Você propõe, o usuário corrige, e o
arquivo só é escrito quando ele concordar.

## 0. Já existe um?

```
cloudez_find_compose(directory: "<diretório>")
```

O retorno decide qual dos dois trabalhos é o seu:

| Retorno | O trabalho |
|---|---|
| `compose: false` | Escrever o Compose da aplicação, do zero |
| `compose: true` | **Não sobrescreva.** O arquivo é do usuário, e quase sempre é o de desenvolvimento — é o que ele roda todo dia. Leia, diga o que ele já faz, e leve as diferenças de produção para a sobreposição (passo 3) |

`compose: true` é o caso comum, e "arrumar" o arquivo é o erro. Quem já tem um
Compose rodando escolheu aquilo: mexer ali quebra a máquina dele para consertar o
servidor. Se ele **pedir** mudança no arquivo base, trate como edição — mostre o
antes e o depois do trecho, e mexa só no que ele pediu.

Se vier `ignored`, avise: há mais de um arquivo base, e o Compose usa só o `file`.

Se vier **`cloudez_file`**, já existe uma sobreposição. Leia-a antes de afirmar
qualquer coisa: é ela que descreve produção, e o arquivo base sozinho descreve a
máquina do usuário.

Se vier **`cloudez_ambiguous`**, pare. Há duas grafias da sobreposição no mesmo
diretório e o deploy falha com `compose_overlay_ambiguous` — de propósito, porque
escolher uma poria produção no ar com a configuração do arquivo que ninguém
escolheu. Diga quais são e peça para o usuário apagar uma.

**E confira a porta**, que é o que decide se a aplicação vai responder. O retorno
traz `ports`, lido do arquivo: cada item tem o `published` (porta do host) e o
`service` que o publica.

Compare com a `custom_port` do site (`cloudez_get_site`). Três casos:

| O que você vê | O que fazer |
|---|---|
| batem | Diga que está tudo certo e siga |
| **divergem** | Duas saídas, e as duas preservam o arquivo do usuário. **Pergunte** qual: (a) a Cloudez passa a apontar para a porta do Compose — `cloudez_configure_site(domain, custom_port: "<published do Compose>")`; ou (b) a sobreposição publica na `custom_port` que já existe, com `ports: !override`. (a) quando o número não importa a ninguém; (b) quando a `custom_port` é fixa por algum motivo |
| nenhum `published` | O Compose só declara a porta do container. O Docker publica numa porta alta aleatória, que muda a cada `up`, e o nginx não tem para onde apontar. Corrija **na sobreposição**, com o mapeamento completo — não no arquivo do usuário, que localmente está certo assim |

As `ports` do retorno vêm do arquivo **base**. Havendo `cloudez_file`, a porta que
produção publica pode ser outra: a sobreposição substitui a lista inteira quando
usa `!override`. Leia as duas antes de comparar com a `custom_port`.

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

Elas valem sobre a configuração **efetiva** de produção — o arquivo base mais a
sobreposição, já mesclados. Onde escrever cada correção é o passo 3; o que segue
é o que precisa ser verdade no fim.

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

### Dado que precisa sobreviver vai para `shared/`

O deploy publica em `releases/<id>/` e aponta o symlink `current` para lá. **O
diretório de cada release é apagado** — a retenção mantém as cinco últimas. O
deploy que apaga não tem nada de errado, e é por isso que o dado perdido é tão
caro de diagnosticar: ele some cinco deploys depois de ter sido escrito.

`shared/` é irmão de `releases/`, então a poda nunca o alcança:

```
claude/
├── releases/20260820T…/     ← apagado na poda
│   └── storage → ../../shared/storage
├── current → releases/20260820T…/
└── shared/
    └── storage/             ← o dado mora aqui
```

Na prática, **bind relativo**:

```yaml
volumes:
  - ./storage:/app/storage      # o deploy liga isto a shared/storage
```

O deploy lê a configuração **efetiva** (base + sobreposição, já mesclada), e todo
bind relativo que sobreviver vira um diretório em `shared/`, com o caminho dentro
da release trocado por um symlink — refeito a cada deploy. É o modelo do
Capistrano.

Duas coisas nunca entram, e pelo mesmo motivo — são a aplicação, não o dado:

- a **raiz da release** (`- .:/app`);
- o **`build.context`** de qualquer serviço. Num monorepo a aplicação não está na
  raiz, e `- ./api:/app` com contexto `./api` é a mesma situação uma pasta abaixo.
  O que está *sob* o contexto continua entrando: `./api/uploads` é dado.

Na primeira vez, o conteúdo que a release traz **semeia** o `shared/` — um
projeto que versiona `storage/` com estrutura dentro não quebra. Dali em diante
quem manda é o `shared/`, e o que a release trouxer é descartado. Tem de ser
assim: se a release pudesse sobrescrever, todo deploy apagaria produção.

**Isto só acontece com sobreposição presente.** É ela que liga o mecanismo. Se o
projeto tem dado que precisa sobreviver e você está escrevendo o Compose do zero,
escreva também a sobreposição — sem ela o bind relativo continua apontando para
dentro da release, e a poda leva o dado.

E **não monte o código-fonte no container** (`- .:/app`). Além de apagar o que a
imagem construiu, é o caso que o deploy recusa a compartilhar — se ele fosse para
`shared/`, todo deploy passaria a servir os arquivos do primeiro.

Este é o dev-ismo mais comum de todos, e num arquivo que já existe ele quase
sempre está lá — de propósito, porque localmente é exatamente o que se quer. Não
apague do arquivo do usuário: remova na sobreposição (passo 3).

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

## 3. Onde a correção mora

Se **não havia** Compose, você escreve um, ele já nasce cumprindo o passo 2, e o
resto desta seção não se aplica: um arquivo só, igual nos dois lugares.

Se **já havia**, o arquivo é de desenvolvimento e você não vai tocar nele. As
diferenças de produção vão para `docker-compose.cloudez.yml`, na raiz, ao lado do
arquivo base. O deploy roda `-f <base> -f <sobreposição>` no servidor; na máquina
do usuário nada muda.

### O trabalho é SUBTRAIR, não acrescentar

Esta é a parte contraintuitiva, e errá-la produz um deploy que roda inteiro sem
erro nenhum e põe desenvolvimento no ar.

O merge do Compose **substitui escalares e mapas, mas ACUMULA listas** — e os
dev-ismos perigosos moram justamente nas listas:

| No arquivo do usuário | O merge simples resolve? | O que escrever na sobreposição |
|---|---|---|
| `command: npm run dev` | sim, substitui | `command: npm start` |
| `environment: {NODE_ENV: development}` | sim, é mapa | `environment: {NODE_ENV: production}` |
| falta `restart: unless-stopped` | sim, é acréscimo | `restart: unless-stopped` |
| `build: {target: dev}` | **não** | `build: {target: !reset null}` |
| `ports: ["3000:3000"]` | **não**, acumula | `ports: !override` com o mapeamento certo |
| `volumes: [".:/app"]` | **não**, acumula | `!reset` ou `!override` — ver abaixo |
| serviço só de dev (Adminer, Mailhog) | **não**, não há como remover | `profiles: ["dev"]` no serviço |
| `- ./storage:/app/storage` | nada a fazer | deixe: o deploy liga a `shared/` sozinho |

Acrescentar `127.0.0.1:3000:3000` a um `3000:3000` que já existe deixa os **dois**
publicados: conflito de porta, e a aplicação exposta por fora do nginx do mesmo
jeito. `!override` troca a lista inteira, `!reset` apaga o campo.

Em `volumes`, escolha com cuidado: `!reset null` só serve quando não há nada a
preservar. Havendo volume nomeado — e o passo 2 exige que haja, para o dado que
sobrevive —, use `!override` listando o que fica:

```yaml
services:
  db:
    volumes: !override
      - dados:/var/lib/postgresql/data     # fica
      # o `- ./seed:/seed` do arquivo do usuário some
```

O `profiles: ["dev"]` merece nota, porque é o único jeito de **desligar** um
serviço: o deploy nunca ativa perfil nenhum, então um serviço que ganhou perfil
na sobreposição simplesmente não sobe em produção. O serviço continua existindo
para quem roda localmente.

### O exemplo inteiro

Arquivo do usuário, que você não toca:

```yaml
services:
  app:
    build: { context: ., target: dev }
    command: npm run dev
    ports: ["3000:3000"]
    volumes: [".:/app"]
    environment: { NODE_ENV: development }
```

`docker-compose.cloudez.yml`:

```yaml
services:
  app:
    build:
      target: !reset null
    command: npm start
    ports: !override
      - "127.0.0.1:3000:3000"
    volumes: !reset null
    environment:
      NODE_ENV: production
    restart: unless-stopped
```

### O que sobrevive ao deploy

Os binds relativos que você **deixar** na configuração efetiva viram diretórios em
`shared/` (passo 2). Isso muda o que a sobreposição precisa fazer com `volumes`:
ela não remove tudo, remove o que é *fonte* e preserva o que é *dado*.

```yaml
services:
  app:
    volumes: !override
      - ./storage:/app/storage     # fica: vira shared/storage
      # o `- .:/app` do arquivo do usuário não é repetido, e some
```

Um `!reset null` seco em `volumes` também apaga o bind de dado — use quando não
houver nenhum a preservar.

Depois do deploy, `compose.shared` diz o que foi ligado e `compose.shared_created`
o que nasceu ali. Um diretório reaparecendo em `shared_created` num deploy que não
é o primeiro significa que alguém apagou o de `shared/`.

### A versão do Compose no servidor

`!reset` e `!override` exigem Docker Compose **2.24+**. Num servidor mais velho o
deploy falha com erro de tag desconhecida — o `cloudez_compose_build` traduz isso
no hint, e a correção é da Cloudez, não do projeto. Não tente contornar: sem as
tags não há como remover nada, e o merge deixa passar exatamente os três campos
que mais doem.

## 4. Propor

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

## 5. Depois de escrever

Diga ao usuário, nesta ordem:

1. que o arquivo precisa ser **commitado**. Não porque senão ele não sobe — o
   deploy envia o diretório de trabalho, e um arquivo não versionado vai junto —
   mas justamente por isso: sem commit, o servidor passa a rodar uma configuração
   que não está no repositório, e o próximo clone publica outra coisa;
2. **onde** você escreveu, e por quê: no arquivo base, se não havia nenhum; na
   sobreposição, se havia. Diga explicitamente que o arquivo dele não foi
   alterado — é a garantia de que o `docker compose up` local continua igual;
3. o que a sobreposição **remove**, item a item. Um `!reset` que o usuário não
   entendeu é uma configuração que sumiu de produção sem explicação;
4. quais diretórios vão para `shared/`, e que o conteúdo versionado deles só é
   usado na PRIMEIRA vez — depois disso quem manda é o servidor;
5. que a porta publicada e a `custom_port` do site precisam continuar iguais — se
   você alterou uma delas aqui, diga qual e por quê;
6. que o deploy é `/cloudez:deploy`, e que o passo de verificação vai dizer se a
   aplicação respondeu de verdade.

Não rode o deploy por conta própria. Escrever o arquivo e publicar são decisões
diferentes, e a segunda é do usuário.
