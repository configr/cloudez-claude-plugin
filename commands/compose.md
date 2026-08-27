---
description: Escreve o Compose da aplicação — ou a sobreposição de produção, quando já existe um — junto com o usuário
argument-hint: "[diretório]"
allowed-tools: mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_find_compose, mcp__cloudez__cloudez_get_site, mcp__cloudez__cloudez_configure_site, Read, Glob, Grep, Write, Edit, AskUserQuestion
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

## 0. Autenticação, antes de qualquer coisa

Chame `cloudez_auth_status`.

**`authenticated: false`** — **pare aqui.** Conduza o `/cloudez:login` e só volte
depois que ele passar.

Não é opcional por preciosismo: este comando lê o site na Cloudez para saber a
`custom_port`, e é ela que decide a porta que o Compose publica. Sem token, você
escreveria o arquivo com uma porta chutada — e o sintoma seria um deploy verde com
o site respondendo 502, três passos adiante e sem nada que ligue uma coisa à
outra.

Se `verified` for `false` com `authenticated: true`, siga: há token e a Cloudez
não o desmentiu (offline ou API fora).

Nunca peça o token na conversa.

## 1. Já existe um?

```
cloudez_find_compose(directory: "<diretório>")
```

O retorno decide qual dos dois trabalhos é o seu:

| Retorno | O trabalho |
|---|---|
| `compose: false` | Escrever o Compose da aplicação, do zero |
| `compose: true` | **Não sobrescreva.** O arquivo é do usuário, e quase sempre é o de desenvolvimento — é o que ele roda todo dia. Leia, diga o que ele já faz, e leve as diferenças de produção para a sobreposição (passo 4) |

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

## 2. Entender a aplicação

**Leia antes de perguntar.** Perguntar o que está escrito no projeto gasta a
paciência do usuário e sinaliza que você não olhou.

O que procurar, e por quê:

| Pergunta | Onde costuma estar |
|---|---|
| Que runtime é | `package.json`, `requirements.txt`, `go.mod`, `Gemfile`, `composer.json`, `pom.xml`, `Cargo.toml` |
| Como sobe | `scripts.start`, `Procfile`, `main`, `if __name__`, `CMD` de um Dockerfile existente |
| Em que porta escuta | busca por `listen`, `PORT`, `addr`, `bind` no código |
| Precisa de build | `scripts.build`, `tsconfig`, `vite`, `webpack`, um estágio de compilação |
| Precisa de serviços | driver de banco nas dependências (`pg`, `mysql2`, `psycopg`, `redis`). Havendo banco, o passo 3 propõe o container com volume nomeado e OFERECE a instância gerenciada |
| Manda e-mail | `nodemailer`, `sendmail`, `Mail::`, `send_mail`, `SMTP_`/`MAIL_`/`EMAIL_` no ambiente. Havendo envio, o passo 3 aponta para o MTA do servidor — sem conta externa e sem chave de API |
| Roda como que usuário | `USER` e `adduser -u` no Dockerfile. Não-root muda o que a sobreposição precisa fazer — passo 3 |
| Onde escreve em runtime | busca por `writeFile`, `open(`, `mkdir`, caminhos de cache e upload. Todo caminho gravado precisa sobreviver ao deploy, ou ser gravável pelo uid certo |

**Pergunte o que o projeto não responde.** Credenciais, qual banco de verdade,
se aquele Redis é opcional, se o build precisa de variável de ambiente. E
pergunte de uma vez, não uma por mensagem.

## 3. As restrições que não são negociáveis

Estas vêm do ambiente da Cloudez, não da aplicação. Uma aplicação que não as
cumpra não fica no ar, por melhor que o Compose esteja.

Elas valem sobre a configuração **efetiva** de produção — o arquivo base mais a
sobreposição, já mesclados. Onde escrever cada correção é o passo 4; o que segue
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

### Dado que precisa sobreviver vai em VOLUME NOMEADO

O deploy publica em `releases/<id>/` e aponta o symlink `current` para lá. **O
diretório de cada release é apagado** — a retenção mantém as cinco últimas. O
deploy que apaga não tem nada de errado, e é por isso que o dado perdido é tão
caro de diagnosticar: ele some cinco deploys depois de ter sido escrito.

Volume nomeado não mora ali:

```yaml
services:
  app:
    volumes:
      - uploads:/app/uploads
volumes:
  uploads:
```

E vale **igual em desenvolvimento e em produção** — nada de sobreposição para
volume. É o mesmo arquivo, o mesmo comportamento, e uma coisa a menos que pode
divergir entre os dois lugares.

Duas razões para ser o padrão, e as duas foram medidas:

**A permissão se resolve sozinha.** O Docker inicializa o volume a partir do
caminho dentro da IMAGEM, herdando dono e modo de lá. Uma aplicação que roda como
`USER nextjs` escreve sem mais nada. Com bind, quem manda é a permissão do
diretório no host, e o sintoma é 500 na primeira gravação — com o deploy verde.

**E não há nada a semear.** Sem cópia, sem primeira vez, sem o risco de copiar um
datadir enquanto o banco escreve.

**Banco segue esta regra, e com força.** Volume nomeado é o padrão também para o
datadir — a seção de banco, mais abaixo, só acrescenta o que ele obriga (backup) e
a alternativa gerenciada que se OFERECE depois de ter proposto esta.

#### O que isso custa, para você poder dizer ao usuário

**O nome do volume carrega o nome do projeto**: `<projeto>_<volume>`, e o projeto
vem do domínio. Mudou o projeto — migração do Compose v1 para v2, troca de
domínio —, o volume antigo é ORFANADO e a aplicação sobe com um vazio, sem erro
nenhum. Medido: `meusite-com-br_dados` e `meusitecombr_dados` coexistem sem se
enxergar.

**E o dado sai da árvore do site.** Ele vive em `/var/lib/docker/volumes/`, então
um `tar` de `~/<domínio>/` não o contém. Backup precisa ser dump lógico, não cópia
de diretório.

#### A alternativa: bind relativo, ligado a `shared/`

Vale para **arquivo**: upload, mídia, storage. Datadir de banco não entra aqui,
pela razão que a seção de banco explica.

Quando o usuário quiser o dado **visível no host** — para copiar com `tar`,
inspecionar à mão, ou não depender do nome do projeto —, o caminho é o bind
relativo:

```yaml
volumes:
  - ./storage:/app/storage      # o deploy liga isto a shared/storage
```

O deploy lê a configuração **efetiva** (base + sobreposição, já mescladas) e todo
bind relativo que sobreviver vira um diretório em `<root>/shared/`, com o caminho
dentro da release trocado por um symlink refeito a cada deploy — o modelo do
Capistrano. `shared/` é irmão de `releases/`, então a poda não o alcança.

Duas coisas nunca entram, e pelo mesmo motivo — são a aplicação, não o dado:

- a **raiz da release** (`- .:/app`);
- o **`build.context`** de qualquer serviço. Num monorepo a aplicação não está na
  raiz, e `- ./api:/app` com contexto `./api` é a mesma situação uma pasta abaixo.
  O que está *sob* o contexto continua entrando: `./api/uploads` é dado.

Escolhendo este caminho, **a permissão volta a ser problema seu** — é a seção
seguinte, e ela só vale aqui.

Na primeira vez o `shared/` é semeado a partir da release anterior, quando há dado
nela. Diga ao usuário quando o retorno trouxer `compose.shared_migrated`: aquele
deploy **moveu o dado de produção** de lugar.

**Trocar de um caminho para o outro NÃO migra dado.** Volume nomeado e `shared/`
são lugares diferentes, e nenhum dos dois lê o outro: a aplicação sobe apontando
para o novo, que está vazio, sem erro em lugar nenhum. Quem já publicou precisa
copiar o conteúdo com o container parado ANTES do deploy que muda o arquivo — e
isso é ação do usuário, no servidor.

E **não monte o código-fonte no container** (`- .:/app`). Além de apagar o que a
imagem construiu, é o caso que o deploy recusa a compartilhar — se ele fosse para
`shared/`, todo deploy passaria a servir os arquivos do primeiro.

Este é o dev-ismo mais comum de todos, e num arquivo que já existe ele quase
sempre está lá — de propósito, porque localmente é exatamente o que se quer. Não
apague do arquivo do usuário: remova na sobreposição (passo 4).

### O container precisa CONSEGUIR escrever em `shared/`

**Só vale no caminho do bind.** Com volume nomeado o Docker herda dono e modo da
imagem, e nada disto se aplica — é a principal razão de ele ser o padrão.

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

### A aplicação precisa de banco? O padrão é NO CONTAINER, com volume nomeado

**Recomende esta.** O banco fica no mesmo `docker-compose.yml` que o resto, sobe
igual na máquina do usuário e no servidor, e não depende de recurso nenhum
provisionado na conta:

```yaml
services:
  db:
    image: postgres:16
    volumes:
      - dados:/var/lib/postgresql/data
    stop_grace_period: 60s
volumes:
  dados:
```

O volume nomeado não é detalhe aqui: o Postgres roda como o usuário `postgres` da
imagem, e volume nomeado herda essa dona. É o que faz o banco subir sem mais nada.

**O `stop_grace_period: 60s` não é enfeite.** O padrão do Docker são 10 segundos
entre o `SIGTERM` e o `SIGKILL`. Um Postgres com checkpoint grande não termina
nisso, leva `SIGKILL`, e sobe recuperando pelo WAL a cada deploy — funciona, mas é
desligamento sujo virando rotina, e recuperação por WAL é rede de segurança, não
procedimento.

**Datadir de banco NUNCA vai para `shared/`.** O bind relativo do passo 3 é para
arquivo — upload, mídia, storage. Para banco ele junta os dois piores lados: a
permissão passa a depender do diretório no host, e a semeadura do `shared/` copia
arquivo de um datadir que pode estar sendo escrito, produzindo cópia
inconsistente. Se o arquivo do usuário já tiver um `- ./pgdata:/var/lib/...`,
troque por volume nomeado na sobreposição e **avise que aquilo é uma mudança de
lugar do dado** — o banco não migra sozinho.

#### O que isso obriga: backup é seu — e ele se configura em duas chamadas

É o preço desta opção, e ele é real. Não deixe o usuário com a instrução
escrita e nada rodando: **um banco no container sem cron de backup é a opção
padrão pela metade.**

**1. Instalar e provar que funciona**

```
cloudez_install_backup(domain, root, engine, service)
```

Grava `<root>/.cloudez/backup-db.sh` no servidor **e o roda uma vez**. A execução
não é zelo: é o que separa "backup configurado" de "backup que funciona", e a
diferença só apareceria no dia da restauração. Ela prova que o serviço se chama o
que disseram, que o cliente do banco existe naquela imagem e que o container
responde a `exec`.

Se o retorno vier com `verificado: false`, **não agende**. O `log` diz o quê, e
quase sempre é uma destas três: o serviço não se chama `db`, o container não está
no ar, ou o engine não é o que se supôs.

**2. Agendar**

```
cloudez_create_cron(domain, name, command, minute, hour)
```

com o `cron_command` e o `minute` que a tool anterior devolveu. O minuto é
derivado do domínio, e não sorteado: sem isso todo site do servidor dumpa às 03:00
em ponto. A hora padrão é 3.

`cloudez_create_cron` **não é idempotente** — chamar duas vezes cria dois
agendamentos, e o servidor passa a dumpar duas vezes. Se estiver reinstalando,
confira no painel antes.

#### O que o script faz, para você saber o que prometer

Os dumps vão para `<root>/shared/backup/<engine>/`, em `diario/` e `semanal/`,
com retenção de **7 diários e 4 semanais**. `shared/` é irmão de `releases/`,
então a poda de release não os alcança, e sem retenção eles encheriam o disco pelo
mesmo motivo que criou o `KEEP_RELEASES`.

Repare que o DUMP vai para `shared/` mesmo com o banco em volume nomeado: são
coisas diferentes. O volume é onde o banco vive; `shared/backup/` é onde ficam as
cópias, e ali elas são visíveis no host e entram num `tar` do diretório do site.

**O dump é lógico, nunca cópia de arquivo:** `pg_dump`/`mysqldump` contra o
container em pé.

No Postgres é `pg_dump` do banco da aplicação (o `POSTGRES_DB` da imagem). **Duas
coisas ficam de fora, e quem for restaurar precisa saber:** os ROLES — o dump supõe
que o usuário já exista na base de destino — e qualquer outro banco que exista no
mesmo container. Para o arranjo padrão, um serviço com um banco criado pela própria
imagem, os dois são o mesmo banco e não falta nada.

Três coisas que o script recusa a fazer, e que valem ser ditas se alguém perguntar
por que ele é mais que uma linha de `crontab`:

- **não roda a poda antes de o dump novo estar no lugar.** Ao contrário, uma
  semana de falhas apagaria os backups bons um por dia sem escrever nenhum novo;
- **não aceita um dump vazio.** O `gzip` de um erro é um arquivo válido e
  minúsculo; sem um piso sobre o SQL descomprimido, ele entraria na rotação e
  empurraria um backup bom para fora;
- **não confunde o status do `gzip` com o do dump.** Num pipeline o shell só olha
  o último comando, e o dump pode morrer com o `gzip` feliz.

#### Quando alguém perguntar se o backup está rodando

`<root>/shared/backup/<engine>/` tem `ULTIMO_OK` e `ULTIMA_FALHA` — dois arquivos
com data, feitos para serem lidos sem interpretar log. Havendo `ULTIMA_FALHA`, o
`last.log` tem o erro da última execução, e o `history.log` tem uma linha por
execução.

Isso existe porque cron que falha em silêncio é o modo de falha padrão desse tipo
de rotina: o `MAILTO` do crontab pode não estar configurado, e aí ninguém fica
sabendo até precisar restaurar.

### E ofereça a alternativa gerenciada pela Cloudez — perguntando, não decidindo

A Cloudez provisiona a instância no servidor dela e a vincula ao site. É uma
**otimização**, não o caminho padrão: quem escolhe é o usuário, e a pergunta vale
a pena porque o que ela resolve é justamente a obrigação de cima.

| | O que ele ganha | O que ele paga |
|---|---|---|
| **No container** (padrão) | Nada a mais na conta, e o banco vive no mesmo arquivo | O backup é responsabilidade do projeto |
| **Gerenciado pela Cloudez** | Backup, atualização e disco são da Cloudez | É recurso provisionado na conta, e pode ser cobrado |

Confira antes o que a conta tem: `cloudez_list_database_types` lista os engines
habilitados, e a lista é **por empresa** — uma revenda pode ter só um dos dois.
Oferecer `postgresql` a quem não o tem vira erro depois de o usuário já ter
escolhido.

**Nos dois casos o desenvolvimento é igual:** o banco sobe pelo Compose, na
máquina dele. O que muda é só produção.

#### Se ele aceitar

`cloudez_create_database(domain, engine, database_name)`. A cloud e o vínculo com
o site saem do domínio; você não passa id de nada.

**Confirme antes de chamar.** Provisiona recurso na conta, não é idempotente (o
nome é único por cloud) e pode ser cobrado. Diga o engine e o nome, e espere o
aceite.

Em produção o serviço de banco **não sobe**, e a sobreposição faz duas coisas:

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

#### E a credencial, que é onde isto costumava parar

A senha volta no retorno da tool, e **não há onde guardá-la no repositório**: a
sobreposição é versionada, e o que está no `.gitignore` o `cloudez-sync` não
transfere. Um `.env` local nunca chega ao servidor.

O caminho é o arquivo de ambiente do site:

```
cloudez_set_env(domain, root, vars)
```

Grava em `<root>/shared/.cloudez.env`, modo 600, e o deploy o liga dentro de cada
release — o mesmo modelo do resto do `shared/`. Ele MESCLA por chave: gravar o
`DATABASE_URL` não apaga um `SECRET_KEY` que já estava lá.

Monte a string de conexão com o que o `create_database` devolveu (`host`, `port`,
`username`, `password`, `database_name`) e grave-a como a aplicação a espera —
`DATABASE_URL`, `DB_HOST`/`DB_PASS`, o que for o caso do framework.

Para a aplicação enxergá-las, a sobreposição precisa declarar:

```yaml
services:
  app:
    env_file:
      - .cloudez.env
```

**Nessa ordem: `set_env` primeiro, `env_file` depois.** O deploy só liga o arquivo
se ele existir, e declarar o `env_file` antes de gravar as variáveis faz o Compose
recusar o projeto inteiro com "env file not found". Falha barulhenta e de
mensagem clara — mas falha.

O `cloudez_set_env` devolve só os NOMES das variáveis, nunca os valores. E vale
dizer ao usuário que **a senha ficou no transcript desta sessão**, que é um lugar
que ele não consegue limpar.

E confira o alcance: o `host` do usuário do banco decide de onde ele pode
conectar. Um `127.0.0.1` vale para o host, mas o container da aplicação chega pela
rede do Docker, com outro endereço. Se a aplicação não conectar depois de tudo
certo, é aqui.

### A aplicação manda e-mail? Use o MTA do próprio servidor

**Este é o padrão, e não se pergunta.** O servidor onde o Docker roda já tem um
MTA configurado pela Cloudez. Apontar a aplicação para ele evita conta em serviço
externo, chave de API para guardar, e um segredo a mais atravessando o deploy.

O container não enxerga o `localhost` do host — o `localhost` dele é ele mesmo. O
caminho é o gateway da rede do Docker, que o Compose sabe nomear:

```yaml
services:
  app:
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      SMTP_HOST: host.docker.internal
      SMTP_PORT: "25"
```

`host-gateway` é resolvido pelo Docker para o endereço do host na rede do
container — **verificado**: dentro do container, `host.docker.internal` resolve.
Exige Docker 20.10 ou mais novo, que é o caso de qualquer servidor gerenciado hoje.

Os nomes das variáveis são os que a APLICAÇÃO usa: `MAIL_HOST` no Laravel,
`EMAIL_HOST` no Django, `SMTP_HOST` na maioria dos projetos Node. Descubra em vez
de presumir — o padrão errado aqui não dá erro, só não manda e-mail.

**Sem usuário e sem senha.** Relay local não pede autenticação, e é por isso que
isto vai no arquivo versionado sem violar a regra dos segredos: não há segredo
nenhum. Se a aplicação exigir os campos, deixe-os vazios em vez de inventar.

#### O que precisa ser conferido, e ainda não foi

O MTA precisa **escutar na interface da bridge**, e não só em `127.0.0.1`. Um
Postfix com `inet_interfaces = loopback-only` — que é o padrão de muitas
instalações — recusa a conexão vinda do container, e o sintoma é a aplicação
subindo perfeitamente e não mandando e-mail nenhum.

Isto não foi verificado num servidor da Cloudez. Se o e-mail não sair com tudo o
mais certo, é o primeiro lugar a olhar; do host, `ss -lntp | grep :25` mostra em
quais endereços ele escuta.

**Em desenvolvimento isto não vale.** A máquina de quem desenvolve não tem MTA, e
apontar para ela faria o envio falhar em silêncio ou, pior, mandar e-mail de teste
para endereço de verdade. Num arquivo que já existe, o bloco acima vai na
SOBREPOSIÇÃO; localmente o projeto segue com o que já usa — um mailhog, um
`console`, ou nada.

### Sem `container_name`

O `cloudez_compose_up` roda o Compose com `-p <domínio>`, para dois sites no
mesmo servidor não virarem o mesmo projeto. Um `container_name` fixo ignora isso
e volta a colidir entre sites.

### `restart: unless-stopped`

Sem isso a aplicação não volta depois de um reboot do servidor, e o sintoma é um
site que caiu sozinho de madrugada.

### Segredos não entram no arquivo

O Compose vai para o repositório, e o `.cloudez.yml` também. Senha, token e chave
não entram em nenhum dos dois — e se o usuário oferecer um segredo na conversa,
não escreva no arquivo.

**Onde eles entram é `cloudez_set_env`**, que grava em `<root>/shared/.cloudez.env`
no servidor (modo 600) e é ligado dentro de cada release pelo deploy. Não existe
outra rota: um `.env` local está no `.gitignore`, e o que está no `.gitignore` o
`cloudez-sync` não transfere. A sobreposição declara `env_file: [.cloudez.env]`
para a aplicação lê-las — depois de o arquivo existir, nunca antes.

## 4. Onde a correção mora

Se **não havia** Compose, você escreve um, ele já nasce cumprindo o passo 3, e o
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
| `- dados:/app/dados` (volume nomeado) | nada a fazer | deixe: ele não está na release |
| `- ./storage:/app/storage` (bind, caminho alternativo) | nada a fazer | deixe: o deploy liga a `shared/` sozinho |
| `USER` não-root no Dockerfile | não se aplica | `user: "${CLOUDEZ_UID}:${CLOUDEZ_GID}"` — ver passo 3 |

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
preservar. Havendo volume nomeado — e o passo 3 exige que haja, para o dado que
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
`shared/` (passo 3). Isso muda o que a sobreposição precisa fazer com `volumes`:
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

## 5. Propor

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

## 6. Depois de escrever

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
