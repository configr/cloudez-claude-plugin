---
description: Sobe o site localmente — pelo dev server do projeto, ou em container — e abre no navegador do Claude Code
argument-hint: "[diretório]"
allowed-tools: mcp__cloudez__cloudez_find_compose, Glob, Grep, mcp__Claude_Browser__preview_start, mcp__Claude_Browser__preview_logs, mcp__Claude_Browser__preview_list, mcp__Claude_Browser__preview_stop, Read, Write, AskUserQuestion
---

Subir a aplicação na máquina do usuário e abrir no painel de navegador, para ele
ver o que mudou antes de publicar.

Argumento recebido: `$ARGUMENTS` — o diretório do projeto. Sem ele, o atual.

**Não é um deploy, e não fala com a Cloudez.** Nenhuma tool daqui toca a conta, o
servidor ou o estado de deploy. Se o usuário quiser publicar, o comando é o
`/cloudez:deploy`.

## O que sobe é a configuração de DESENVOLVIMENTO

Nunca a de produção. Num Compose, um `docker compose up` sem argumento lê só o
arquivo base — a sobreposição (`docker-compose.cloudez.yml`) não entra, porque
ninguém passa `-f` aqui.

Isso importa em duas direções, e as duas merecem ser ditas ao usuário:

- o que ele vê aqui **não** é o que vai ao ar. Bind mount do fonte, porta em
  `0.0.0.0`, `command` de dev — tudo o que a sobreposição remove continua valendo
  localmente;
- e por isso mesmo o que funciona aqui pode falhar lá. Este comando não substitui
  o passo de verificação do `/cloudez:deploy`.

**No caminho do dev server (abaixo) o aviso é mais forte ainda**, porque ali nem o
Dockerfile é executado: o que roda é o Node da máquina do usuário, com as
dependências dela. Passar aqui diz menos sobre produção do que passar no
container.

## 1. Decidir o que subir

Duas leituras, e elas decidem o caminho:

```
cloudez_find_compose(directory: "<diretório>")
```

**`compose: false` — pare.** Este plugin publica aplicação em container: sem
Compose não há o que este comando prepare para o deploy. Ofereça o
`/cloudez:compose`.

Depois, **leia o `package.json`** do diretório.

| O que você encontra | O caminho |
|---|---|
| `scripts.dev` no `package.json` | **dev server** — `npm run dev`. É a exceção, e a seção seguinte explica |
| sem `scripts.dev` | **container** — `docker compose up --build` |

### A exceção: projeto Node roda pelo dev server

Num projeto Node — Next, Vite, Remix —, subir o container para desenvolver é o
pior dos dois mundos: `--build` refaz a imagem a cada alteração, e o que se quer
localmente é recarregar em um segundo. O `npm run dev` dá hot reload; o container
dá um `npm ci` completo por mudança de uma linha.

**Isto vale só aqui.** O deploy não muda em nada: no servidor continua sendo o
Dockerfile e o Compose, com a sobreposição por cima. A exceção é do ambiente de
desenvolvimento, não do projeto.

Três coisas a conferir antes de propor:

**As dependências estão instaladas?** Sem `node_modules`, o dev server morre na
primeira linha. Se faltar, diga ao usuário para rodar `npm ci` antes — não instale
por conta própria, é a máquina dele e o comando pode levar minutos.

**A aplicação depende de outros serviços?** Se o Compose tiver mais de um serviço
— banco, redis, fila —, o `npm run dev` sobe só a aplicação e os outros ficam de
fora. O arranjo certo é híbrido: os serviços de apoio pelo Compose
(`docker compose up -d <serviço>`) e a aplicação pelo npm. Diga isso ao usuário e
proponha os dois.

**Em que porta o dev server escuta?** Ela **não** é o `published` do Compose —
aquela é a porta do container, e aqui não há container. Leia o script: `next dev`
sem argumento é 3000, `vite` é 5173. Se o script não fixar a porta, prefira fixá-la
no comando (`next dev -p 3000`, `vite --port 5173`), para o que está no
`launch.json` não poder divergir do que a aplicação abre. E **declare a
suposição** quando tiver feito uma.

### A porta, no caminho do container

O retorno do `find_compose` traz `ports`, e o que interessa é o **`published`** —
a porta do host, não a do container:

| O que você vê | O que fazer |
|---|---|
| um `published` | É o endereço: `http://localhost:<published>` |
| vários serviços com `published` | **Pergunte** qual é a aplicação. Um deles pode ser banco ou painel auxiliar |
| nenhum `published` | **Pare.** O Compose só declara a porta do container, e o Docker publica numa porta alta aleatória que muda a cada `up`. Não há endereço estável para abrir. Isto se corrige no arquivo — ofereça o `/cloudez:compose` |

Ignore o `cloudez_file` aqui: ele descreve produção, e não é lido neste caminho.
Se vier `parse_error`, diga que o arquivo não pôde ser lido e **não afirme nada
sobre a porta**.

## 2. Propor o `.claude/launch.json`

O painel de navegador sobe servidores declarados em `.claude/launch.json`. E aqui
está a armadilha, verificada na prática: **ele lê esse arquivo no diretório da
SESSÃO, não no do projeto que você vai subir.** Pedir para rodar um projeto de
outra pasta e escrever o arquivo lá dentro produz um erro pedindo o arquivo no
diretório da sessão — o alvo do comando não entra nessa conta.

São dois casos, então.

**A sessão está aberta no projeto** — o comum. O arquivo é do projeto, e a
entrada depende do caminho decidido no passo 1.

Dev server:

```json
{
  "version": "0.0.1",
  "configurations": [
    {
      "name": "cloudez-local",
      "runtimeExecutable": "npm",
      "runtimeArgs": ["run", "dev"],
      "port": 3000
    }
  ]
}
```

Container:

```json
{
  "version": "0.0.1",
  "configurations": [
    {
      "name": "cloudez-local",
      "runtimeExecutable": "docker",
      "runtimeArgs": ["compose", "up", "--build"],
      "port": 3001
    }
  ]
}
```

Diga ao usuário que este arquivo costuma ser versionado: quem trabalha no mesmo
repositório ganha o comando de graça.

**O diretório é outro** — quando o argumento aponta para fora da sessão. O arquivo
tem de ficar no diretório da sessão assim mesmo, e quem aponta para o projeto é a
própria ferramenta:

```json
"runtimeArgs": ["--prefix", "<diretório>", "run", "dev"]
```

```json
"runtimeArgs": [
  "compose",
  "-f", "<diretório>/docker-compose.yml",
  "--project-directory", "<diretório>",
  "up", "--build"
]
```

Use o nome de arquivo que o `find_compose` devolveu em `file`, não
`docker-compose.yml` presumido. E **diga que o arquivo não é do projeto** — ele
vai parar num diretório que não tem relação com o site, e versioná-lo ali não faz
sentido.

### O que não varia

O `port` é o do passo 1, **sempre**, e nunca um número presumido: o `published` do
Compose no caminho do container, o do dev server no outro. Errar aqui dá página em
branco — o painel abre num endereço onde não há nada.

No caminho do dev server não há `-C` nem `-p`, mas o problema do diretório é o
mesmo — e a solução também. Projeto fora da sessão usa `--prefix`, que roda o
script com o diretório de trabalho na pasta apontada (verificado):

```json
"runtimeArgs": ["--prefix", "<diretório>", "run", "dev"]
```

O `--build` é deliberado: sem ele o `up` reaproveita a imagem da última vez, e o
usuário olharia para o código anterior achando que está vendo o novo. É o mesmo
erro que o `--build` do `cloudez_compose_up` evita no servidor.

**Nunca ponha `-p`.** Sem ele, o Compose nomeia o projeto pelo diretório, que é o
que se quer numa máquina de desenvolvimento. Um `-p` fixo no `launch.json` faria
dois projetos diferentes virarem o MESMO projeto Compose na máquina do usuário, e
subir um derrubaria o container do outro — o mesmo bug que o deploy evita no
servidor derivando o nome do domínio.

**Leia antes de escrever.** Se o arquivo já existir, não o sobrescreva: pode ter
outras configurações do usuário. Acrescente a entrada, e se já houver uma
apontando para este projeto, use a que existe em vez de criar uma segunda.

**Espere o aceite.** É arquivo do usuário, e este comando não é o dono dele.

## 3. Subir e abrir

```
preview_start(name: "cloudez-local")
```

Ele sobe o que o passo 2 declarou e abre o painel.

O dev server responde em segundos. **O container não**: o primeiro `up` leva o
tempo do build da imagem, que num projeto Node é minuto — **avise antes**, senão o
silêncio parece travamento.

Se o retorno trouxer `reused: true`, o servidor já estava de pé: não houve build,
e o que está na tela pode ser de antes da última alteração. Diga isso.

## 4. Quando não responde

```
preview_logs(serverId: "<do retorno>", level: "error")
```

É onde o build do Docker aparece. Os três casos comuns:

| Sintoma | Quase sempre é |
|---|---|
| falha no build | O mesmo que falharia no deploy: Dockerfile, dependência, contexto. Corrija e suba de novo |
| `port is already allocated` | Outra coisa já ocupa a porta do host — inclusive um `up` anterior deste mesmo projeto. `preview_list` mostra o que está de pé |
| sobe, mas a página não carrega | A aplicação escuta em `127.0.0.1` DENTRO do container, e o mapeamento não alcança. Precisa ser `0.0.0.0` — a mesma restrição do passo 2 do `/cloudez:compose` |
| `Cannot find module` ou `command not found: next` | Caminho do dev server sem `npm ci`. As dependências não estão instaladas |
| a página abre mas falha ao buscar dados | Caminho do dev server num projeto com serviços de apoio: o banco não subiu junto. Suba-o pelo Compose |

Para derrubar: `preview_stop(serverId)`.

## Se o painel de navegador não existir

As tools `preview_*` são do Claude Code, não deste plugin, e nem todo cliente as
tem. Faltando elas, **não falhe**: diga a porta e a URL
(`http://localhost:<published>`), diga que o comando para subir é
`docker compose up --build` no diretório do projeto, e siga. O usuário abre no
navegador dele.

O mesmo vale se o `preview_start` devolver erro de painel: o valor deste comando
é achar a porta certa e subir a coisa certa, e isso continua valendo sem tela.
