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
| Precisa de serviços | driver de banco nas dependências (`pg`, `mysql2`, `psycopg`, `redis`). Havendo banco, o passo 2 tem DUAS opções a oferecer — não escolha por ele |
| Roda como que usuário | `USER` e `adduser -u` no Dockerfile. Não-root muda o que a sobreposição precisa fazer — passo 2 |
| Onde escreve em runtime | busca por `writeFile`, `open(`, `mkdir`, caminhos de cache e upload. Todo caminho gravado precisa sobreviver ao deploy, ou ser gravável pelo uid certo |

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

Vale para todo site em container, com sobreposição ou sem — o bind relativo
aponta para dentro da release de qualquer jeito.

Na primeira vez o `shared/` é **semeado**, e a fonte importa. Num site que já
rodava, o dado de produção está na release **anterior** — é lá que o container no
ar vem escrevendo —, e é de lá que ele vem. Num site novo não há anterior, e a
fonte é o que a release traz, para um projeto que versiona `storage/` com
estrutura dentro não quebrar.

Dali em diante quem manda é o `shared/`, e o que a release trouxer é descartado.
Tem de ser assim: se a release pudesse sobrescrever, todo deploy apagaria
produção.

Diga isso ao usuário quando o retorno trouxer `compose.shared_migrated`: aquele
deploy **moveu o dado de produção** para um lugar novo. É a operação mais
consequente que o deploy faz sem ninguém ter pedido.

E **não monte o código-fonte no container** (`- .:/app`). Além de apagar o que a
imagem construiu, é o caso que o deploy recusa a compartilhar — se ele fosse para
`shared/`, todo deploy passaria a servir os arquivos do primeiro.

Este é o dev-ismo mais comum de todos, e num arquivo que já existe ele quase
sempre está lá — de propósito, porque localmente é exatamente o que se quer. Não
apague do arquivo do usuário: remova na sobreposição (passo 3).

### O container precisa CONSEGUIR escrever em `shared/`

Esta é a que mais custa a aparecer, porque o deploy fica verde inteiro.

Os diretórios de `shared/` são criados no servidor pelo **usuário SSH do site**.
Uma imagem bem feita roda como **não-root**, com um uid próprio — 1001 é o mais
comum. Os dois números não coincidem, e o kernel decide pelo número: o container
**lê e não escreve**. O sintoma é 500 na primeira gravação, que costuma ser dias
depois do deploy, quando o primeiro usuário tenta enviar alguma coisa.

**Verifique no Dockerfile.** Se houver `USER` apontando para alguém que não é
root, o problema existe:

```dockerfile
RUN addgroup -S nodejs -g 1001 && adduser -S nextjs -u 1001
USER nextjs
```

A correção vai na **sobreposição**, e faz o container rodar com a identidade dona
do `shared/`:

```yaml
services:
  app:
    user: "${CLOUDEZ_UID}:${CLOUDEZ_GID}"
```

O deploy exporta as duas variáveis antes de chamar o Compose, com o `id -u` e o
`id -g` do usuário SSH — e devolve o valor em `compose.host_uid`.

**Não crave o número.** Cada environment é um site com seu próprio usuário SSH, e
um uid literal no arquivo versionado só estaria certo para um deles. As variáveis
resolvem no servidor, a cada deploy.

E isto só funciona **na sobreposição**: localmente o `docker compose up` não lê
esse arquivo, e as variáveis não existem na máquina do usuário. Pôr o `user:` no
arquivo base faria o Compose interpolar para `user: ':'` — inválido, e o Compose
apenas **avisa**, não falha.

**A ressalva.** Rodando com outro uid, o processo deixa de ser dono do que a
imagem construiu. Todo caminho que a aplicação escreve DENTRO da imagem — e não
só o de dados — precisa ser revisto: o Next em modo standalone grava em
`/app/.next/cache`, que pertence ao usuário da imagem. Se o projeto tiver um
caminho assim, ele também precisa de volume, ou a aplicação quebra em outro lugar.

Vale saber, para pesar: **volume nomeado não tem esse problema** — o Docker copia
a dona do caminho da imagem na primeira montagem, e por isso "funcionava antes".
Ele também não é alcançado pela poda, que só apaga `releases/<id>`. O que o
`shared/` compra sobre ele é o dado visível no host: backup por `tar`, inspeção
direta, e imunidade à renomeação do projeto do Compose. É uma troca, não um
upgrade — e o preço dela é exatamente esta seção.

### A aplicação precisa de banco? São DUAS opções, e quem escolhe é o usuário

Não decida sozinho. As duas têm custo, e o custo cai sobre ele:

| | Onde o banco roda em produção | O que ele ganha | O que ele paga |
|---|---|---|---|
| **Gerenciado pela Cloudez** | Instância da Cloudez, fora do Compose | Backup, atualização e disco são da Cloudez | É recurso provisionado na conta, e pode ser cobrado |
| **No container** | Container seu, com o dado em `shared/` | Nada a mais na conta | O backup passa a ser responsabilidade do projeto |

Confira antes o que a conta tem: `cloudez_list_database_types` lista os engines
habilitados, e a lista é **por empresa** — uma revenda pode ter só um dos dois.
Oferecer `postgresql` a quem não o tem vira erro depois de o usuário já ter
escolhido.

**Nos dois casos o desenvolvimento é igual:** o banco sobe pelo Compose, na
máquina dele. O que muda é só produção.

#### Opção 1 — gerenciado pela Cloudez

`cloudez_create_database(domain, engine, database_name)`. A cloud e o vínculo com
o site saem do domínio; você não passa id de nada.

**Confirme antes de chamar.** Provisiona recurso na conta, não é idempotente (o
nome é único por cloud) e pode ser cobrado. Diga o engine e o nome, e espere o
aceite.

Em produção, o serviço de banco **não sobe**, e a sobreposição faz duas coisas:

```yaml
services:
  app:
    # A aplicação passa a apontar para a instância da Cloudez.
    depends_on: !reset null
  db:
    profiles: ["dev"]
```

O `depends_on: !reset null` **não é opcional**. Sem ele o Compose recusa o projeto
inteiro com `service "app" depends on undefined service "db": invalid compose
project` — verificado. Um serviço com perfil inativo não existe para quem depende
dele, e o erro derruba tudo, não só o banco.

**A senha volta no retorno da tool.** Ela não pode ir para o
`docker-compose.cloudez.yml`, que é versionado. Ponha-a onde a aplicação a leia
sem passar pelo git, e **diga ao usuário que ela ficou no transcript desta
sessão** — é um lugar que ele não consegue limpar.

E confira o alcance: o `host` do usuário do banco decide de onde ele pode
conectar. Um `127.0.0.1` vale para o host, mas o container da aplicação chega pela
rede do Docker, com outro endereço. Se a aplicação não conectar depois de tudo
certo, é aqui.

#### Opção 2 — no container, com o dado em `shared/`

É o caminho que o passo 2 já descreve: bind relativo, que o deploy liga a
`shared/`. Nada muda no Compose além do que já está escrito ali.

O que muda é a obrigação: **banco no container exige backup**, e ele não vem de
graça como na opção 1. Os dumps vão para

```
<root>/shared/backup/<engine>/
```

com retenção de **7 diários e 4 semanais** — `shared/` é irmão de `releases/`, então
a poda de release não os alcança, e sem retenção eles enchem o disco do servidor
pelo mesmo motivo que criou o `KEEP_RELEASES`.

**O dump é lógico, nunca cópia de arquivo:** `pg_dump`/`mysqldump` contra o
container em pé. Copiar o datadir de um banco em uso produz cópia inconsistente —
e é por isso que a semeadura do `shared/` nunca pode partir de um datadir vivo.

E acrescente, para todo serviço de banco:

```yaml
services:
  db:
    stop_grace_period: 60s
```

O padrão do Docker são 10 segundos entre o `SIGTERM` e o `SIGKILL`. Um Postgres
com checkpoint grande não termina nisso, leva `SIGKILL` e sobe recuperando pelo
WAL a cada deploy — funciona, mas é desligamento sujo virando rotina, e
recuperação por WAL é rede de segurança, não procedimento.

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
| `volumes: [".:/app"]` | **não** (ver abaixo) | `!reset` ou `!override` |
| serviço só de dev (Adminer, Mailhog) | **não**, não há como remover | `profiles: ["dev"]` no serviço |
| serviço de banco, com a opção 1 | **não** | `profiles: ["dev"]` no banco **e** `depends_on: !reset null` em quem depende dele |
| `- ./storage:/app/storage` | nada a fazer | deixe: o deploy liga a `shared/` sozinho |
| `USER` não-root no Dockerfile | não se aplica | `user: "${CLOUDEZ_UID}:${CLOUDEZ_GID}"` — ver passo 2 |

Acrescentar `127.0.0.1:3000:3000` a um `3000:3000` que já existe deixa os **dois**
publicados: conflito de porta, e a aplicação exposta por fora do nginx do mesmo
jeito. `!override` troca a lista inteira, `!reset` apaga o campo.

As duas listas não se comportam igual, e a diferença importa na hora de escrever:

- **`ports` acumula de verdade.** Todo mapeamento novo se soma aos que já
  existem, e não há como remover um sem `!override`;
- **`volumes` mescla por ALVO dentro do container.** Declarar `./dados:/app/x`
  substitui um `dados:/app/x` do arquivo base, porque o alvo é o mesmo. O que
  sobrevive é o que tem alvo *diferente* — e é exatamente o caso do `- .:/app`,
  que continua montado a menos que você o remova com `!reset` ou `!override`.

Na prática a conduta é a mesma para as duas: seja explícito. Contar com a
substituição por alvo funciona até alguém acrescentar uma linha com outro alvo ao
arquivo base, e aí ela vaza para produção sem ninguém perceber.

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

Depois do deploy, `compose.shared` diz o que foi ligado, `compose.shared_created`
o que nasceu ali e `compose.shared_migrated` o que veio da release anterior. Um
diretório reaparecendo em `shared_created` num deploy que não é o primeiro
significa que alguém apagou o de `shared/`.

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
5. se você pôs `user:` na sobreposição, diga por quê em uma linha — sem isso o
   container não escreveria no `shared/` — e que o uid efetivo vem em
   `compose.host_uid` no retorno do deploy;
6. que a porta publicada e a `custom_port` do site precisam continuar iguais — se
   você alterou uma delas aqui, diga qual e por quê;
7. que o deploy é `/cloudez:deploy`, e que o passo de verificação vai dizer se a
   aplicação respondeu de verdade.

Não rode o deploy por conta própria. Escrever o arquivo e publicar são decisões
diferentes, e a segunda é do usuário.
