---
description: Sobe o site localmente em container e abre no navegador do Claude Code
argument-hint: "[diretório]"
allowed-tools: mcp__cloudez__cloudez_find_compose, mcp__Claude_Browser__preview_start, mcp__Claude_Browser__preview_logs, mcp__Claude_Browser__preview_list, mcp__Claude_Browser__preview_stop, Read, Write, AskUserQuestion
---

Subir a aplicação na máquina do usuário e abrir no painel de navegador, para ele
ver o que mudou antes de publicar.

Argumento recebido: `$ARGUMENTS` — o diretório do projeto. Sem ele, o atual.

**Não é um deploy, e não fala com a Cloudez.** Nenhuma tool daqui toca a conta, o
servidor ou o estado de deploy. Se o usuário quiser publicar, o comando é o
`/cloudez:deploy`.

## O que sobe é a configuração de DESENVOLVIMENTO

Um `docker compose up` sem argumento lê só o arquivo base. A sobreposição de
produção (`docker-compose.cloudez.yml`) **não entra** — ninguém passa `-f` aqui,
e é assim que ela foi desenhada.

Isso importa em duas direções, e as duas merecem ser ditas ao usuário quando o
projeto tiver sobreposição:

- o que ele vê aqui **não** é o que vai ao ar. Bind mount do fonte, porta em
  `0.0.0.0`, `command` de dev — tudo o que a sobreposição remove continua valendo
  localmente;
- e por isso mesmo o que funciona aqui pode falhar lá. Este comando não substitui
  o passo de verificação do `/cloudez:deploy`.

## 1. Achar o Compose e a porta

```
cloudez_find_compose(directory: "<diretório>")
```

**`compose: false` — pare.** Não há o que subir. Ofereça o `/cloudez:compose`.

A porta é o que decide se o navegador vai encontrar alguma coisa. O retorno traz
`ports`, e o que interessa é o **`published`** — a porta do host, não a do
container:

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

**A sessão está aberta no projeto** — o comum. O arquivo é do projeto, o compose
é encontrado pelo diretório atual, e a entrada é a mais simples:

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
tem de ficar no diretório da sessão assim mesmo, e quem aponta para o projeto são
as flags do próprio Compose:

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

O `port` é o `published` do passo 1, **sempre** — não o da aplicação dentro do
container, e nunca um número presumido.

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

Ele sobe o container e abre o painel. O primeiro `up` de um projeto leva o tempo
do build da imagem, que num projeto Node é minuto, não segundo — **avise antes**,
senão o silêncio parece travamento.

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

Para derrubar: `preview_stop(serverId)`.

## Se o painel de navegador não existir

As tools `preview_*` são do Claude Code, não deste plugin, e nem todo cliente as
tem. Faltando elas, **não falhe**: diga a porta e a URL
(`http://localhost:<published>`), diga que o comando para subir é
`docker compose up --build` no diretório do projeto, e siga. O usuário abre no
navegador dele.

O mesmo vale se o `preview_start` devolver erro de painel: o valor deste comando
é achar a porta certa e subir a coisa certa, e isso continua valendo sem tela.
