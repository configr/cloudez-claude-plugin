---
description: Faz deploy de um site para a Cloudez, com ativação atômica da release e rollback
argument-hint: "[environment] [diretório]"
allowed-tools: mcp__Claude_Browser__preview_start, mcp__cloudez__cloudez_auth_status, mcp__cloudez__cloudez_panel_info, mcp__cloudez__cloudez_signup, mcp__cloudez__cloudez_resend_phone_code, mcp__cloudez__cloudez_confirm_phone, mcp__cloudez__cloudez_get_site, mcp__cloudez__cloudez_find_compose, mcp__cloudez__cloudez_health_check, mcp__cloudez__cloudez_check_dns, mcp__cloudez__cloudez_begin_deploy, mcp__cloudez__cloudez_finalize_deploy, mcp__cloudez__cloudez_compose_build, mcp__cloudez__cloudez_compose_up, mcp__cloudez__cloudez_list_releases, mcp__cloudez__cloudez_rollback, Bash(cloudez-sync:*), Bash(git:*), Bash(npm:*), Bash(pnpm:*), Bash(yarn:*), Read, AskUserQuestion
---

Argumentos recebidos: `$ARGUMENTS` — o environment e, opcionalmente, o diretório
a publicar.

Dez passos, em três fases: **preparar** (nada muda), **publicar** (há estado no
servidor a partir daqui) e **confirmar** (ativar não é publicar). A fase do meio é
uma transação com estado entre os passos: registrar a release, sincronizar os
arquivos, construir, ativar, subir.

As pontas de control plane — `cloudez_begin_deploy`, `cloudez_finalize_deploy`,
`cloudez_compose_build` e `cloudez_compose_up` — são **tools do MCP**; o transporte
do meio (`cloudez-sync`) segue local, porque o MCP nunca move bytes. Tanto a tool quanto o adaptador
devolvem JSON estruturado — **leia esse JSON, não presuma sucesso pelo exit code
nem por a chamada ter retornado.** O único adaptador em shell que resta é o
transporte, `cloudez-sync`; ele está no `PATH` enquanto o plugin está ativo,
chame pelo nome, sem caminho.

Os passos dizem **o que fazer**. O **apêndice**, no fim, diz **por que** cada trava
existe — quase tudo lá é defeito que já aconteceu. Não precisa ler para executar,
mas leia a entrada antes de afrouxar qualquer regra: a maioria parece excesso de
zelo até você conhecer o caso que a criou.

Todos os caminhos são relativos à raiz do projeto sendo publicado, que precisa
ter um `.cloudez.yaml`. Se não tiver, pare e mande o usuário rodar
`/cloudez:setup <domain> <environment>` — sem os dados de servidor não há deploy,
e eles não são seus para inventar.

# Preparar

Nada aqui muda nada — são as três leituras que dizem o que publicar, para onde, e
como o site estava antes. Se alguma falhar, o deploy não começou.

## 0. Autenticação, antes de qualquer coisa

Chame `cloudez_auth_status`. É a primeira coisa que este comando faz, antes de ler
o `.cloudez.yaml`, antes de escolher environment, antes de qualquer pergunta.

**`authenticated: false`** — **pare aqui, de verdade.** Não pergunte o
environment, não peça confirmação de produção, não adiante nenhum passo da
seção 1 "para ganhar tempo". Já aconteceu de o comando anunciar que ia parar,
seguir perguntando, arrancar um "sim, produção" do usuário e só então repetir que
faltava autenticar — duas perguntas para nada, e uma confirmação de produção dada
antes de existir deploy possível.

Conduza o `/cloudez:login` e só volte quando `cloudez_auth_status` responder
`authenticated: true`. Ele pergunta se o usuário tem conta e ramifica: quem **não**
tem é cadastrado por aqui mesmo, pelas tools de cadastro, sem nada para rodar no
terminal; quem **tem** precisa pegar o token no painel, e aí o comando é dele —
peça para rodar `/cloudez:login`, porque a captura do token exige o
`cloudez-login` e o clipboard, que este comando não tem permissão para tocar.

Nunca peça o token na conversa. O procedimento completo mora em `commands/login.md`
e é lá que ele deve ser lido ou alterado — não o reescreva aqui.

## 1. O alvo: qual environment, qual site

### Environment

Os environments são as chaves de `cloudez:` no `.cloudez.yaml`. Sem argumento,
escolha nesta ordem: `default`, se existir; senão `staging`, se existir; senão
**pergunte** qual dos environments definidos é o alvo.

`production` nunca entra nessa escolha automática: se o usuário disse "sobe" sem
qualificar, não é produção.

**Produção exige confirmação explícita nesta conversa.** "Sobe pra prod",
"publica em produção", "manda pro ar" contam. Uma conclusão sua de que produção
seria o alvo lógico, não conta. Em dúvida, pergunte antes de rodar qualquer
coisa.

Se o environment pedido não existir no arquivo, **pare** e liste os que existem.

### Confirmar o site na Cloudez

Do bloco do environment, pegue o `domain` e busque o site:

```
cloudez_get_site(domain: "<domain>")
```

**`match: "exact"`** — é o alvo. O bloco `ssh` do retorno (`host`, `user`,
`port`) é informativo: serve para você dizer ao usuário para onde o deploy vai.
**Você não repassa esses valores a ninguém** — o `cloudez_begin_deploy` resolve o
destino sozinho pelo `domain` e o grava no estado do deploy, e é de lá que o
`cloudez-sync`, o `finalize` e o `compose_up` o leem.

Eles não estão no `.cloudez.yaml` de propósito — [A1](#a1).

**`match: "candidates"` ou `site_not_found`** — **pare.** O `domain` veio de um
arquivo versionado: se não casa exatamente com um site da conta, a config está
errada ou aponta para outra conta, e isso se corrige no `.cloudez.yaml`, não
escolhendo um vizinho aqui. Liste os candidatos, quando houver, para o usuário
entender o que existe.

**`ssh_unavailable` dizendo que o usuário não tem SSH liberado (`has_ssh:
false`)** — **pare.** O deploy é impossível até o acesso ser habilitado no painel
da Cloudez, e nenhum valor no `.cloudez.yaml` contorna isso. Sincronizar assim
falharia com permissão negada no meio do caminho.

**`upstream_unavailable`** — leia o `hint`. Se disser que a **rota** não existe,
o problema é o endpoint do servidor MCP: não afirme que o site sumiu da conta.

## 2. O que publicar

### O commit, se houver git

**Nem todo projeto é um repositório git, e o deploy não depende de um.** O que
identifica a release é o hash do conteúdo publicado, coletado no passo 3.

Rode `git rev-parse HEAD` **uma vez**. Se falhar — não é repositório, ou não há
commit — siga sem `ref`; não é erro e não merece comentário ao usuário.

Se houver repositório, rode também `git status --porcelain`. Saída não vazia
significa que o commit **não descreve** o que vai ao ar: há mudanças no disco
que o `ref` não representa. Isso **não interrompe o deploy** — o hash do conteúdo
identifica a release corretamente de qualquer forma. Avise o usuário em uma
linha, dizendo que o `release_id` vai sair marcado pelo conteúdo, e siga.

Isto já foi um bloqueio — [A2](#a2).

### O diretório

O diretório publicado vem dos argumentos. Sem ele, confirme onde está o Compose:

```
cloudez_find_compose(directory: "<diretório candidato>")
```

**`compose: false` — pare.** Este plugin publica aplicação em container, e só. Sem
Compose o deploy publicaria arquivos que ninguém executa. Ofereça o
`/cloudez:compose`, que escreve o arquivo junto com o usuário.

Publique o **diretório do arquivo de Compose**, que é o contexto de build — em
geral a raiz do projeto. É lá que estão o `Dockerfile` e o `compose`, e sem eles
não há o que subir do outro lado.

**Não rode o build local.** Quem constrói a imagem é o Docker, a partir do
`Dockerfile`; rodar `npm run build` aqui e publicar o `dist/` mandaria um
diretório sem `Dockerfile` e sem `compose`, e o container não teria como existir.

O `sync` exclui o `.git`, então publicar a raiz não carrega o histórico do
repositório. O resto vai inteiro: o que não deve entrar na imagem é assunto do
`.dockerignore`, aplicado no build.

## 3. Medir antes

### Como o site responde agora

```
cloudez_health_check(domain: "<domain>", attempts: 1)
```

**Guarde o `body_sha256`.** É a referência: comparado com o de depois, ele é o
único sinal independente de stack sobre a publicação ter mudado alguma coisa.

Sem ela, o passo 9 só consegue dizer que o site responde — e a release anterior
também responde. [A3](#a3).

Uma falha aqui **não interrompe o deploy**: site fora do ar antes de publicar é
justamente o que se está tentando consertar. Só registre e siga.

**Guarde só o `body_sha256`.** O `attempts: 1` é deliberado, e por isso
`latency_ms` e `attempts` **não são comparáveis** com os do passo 9 — [A4](#a4).

### O hash do que vai subir

```
cloudez-sync --hash-only <diretório decidido no passo 2>
```

Devolve `content_sha256`, `files` e `bytes`. **Guarde o `content_sha256`** — é o
que identifica a release, com ou sem git.

Roda sobre o diretório do passo 2, depois do build e antes de qualquer coisa
tocar a rede. Não envia nada; só lê. Cobre **exatamente** o conjunto que o
`cloudez-sync` transmite: o transporte recebe esta mesma lista, então não há duas
regras para divergirem.

### O que fica de fora

Sempre o `.git`. Além dele, os padrões de **`.gitignore`** e **`.cloudezignore`**
da raiz do diretório publicado, nesta ordem — o último padrão que casa decide,
como no git, então o `.cloudezignore` consegue desfazer com `!` o que o
`.gitignore` excluiu.

O `.dockerignore` **não** é lido, e isso é decisão e não esquecimento: ali é
correto excluir o `Dockerfile` e o `docker-compose.yml`, porque o Docker os recebe
por outro caminho — mas o deploy publica o diretório para construir depois, no
servidor. Respeitá-lo faria todo site em container falhar com `compose_missing`.

Havendo algum dos dois arquivos, o retorno traz `ignored` com as `sources` lidas,
quantos caminhos foram podados (`pruned`) e quais (`paths`). **Mencione ao
usuário** o que foi podado quando não for óbvio: um `dist/` no `.gitignore` que o
servidor precisava é o tipo de coisa que só aparece como 404 depois.

### Quando os números não fecham

**Erro `build_output_empty`** — o diretório não tem nada publicável. A mensagem
diz qual das duas causas é: só `.git`, ou padrão amplo demais. No primeiro caso,
quase sempre o passo 2 apontou para a raiz de um repositório sem build em vez do
diretório de saída; volte ao passo 2. No segundo, o padrão é do usuário e ele
precisa saber qual arquivo o causou.

Se `files` ou `bytes` ainda vierem absurdos para o projeto (dezenas de milhares
de arquivos para o que o projeto é), **pare e confirme com o usuário** antes de
publicar. Com os dois arquivos de padrão em uso isso ficou raro — mas um projeto
sem `.gitignore` continua mandando `node_modules` inteiro.

# Publicar

A partir daqui há estado no servidor. Cada passo devolve JSON — **leia o JSON**,
não presuma sucesso por a chamada ter retornado.

## 4. Registrar a release

```
cloudez_begin_deploy(
  domain: "<domain>",
  // `root` só quando o .cloudez.yaml do projeto o tiver — ver a nota abaixo.
  content_sha256: "<content_sha256 do passo 3>",
  ref: "<sha do passo 2, se houver>",
  environment: "<environment>"
)
```

**`content_sha256` vai sempre.** O `ref` vai só quando o passo 2 conseguiu o
commit — omita o campo fora de um repositório, não mande string vazia.

O `release_id` que volta é `<timestamp>-<sufixo>`, e a letra do sufixo diz de
onde ele veio: `g1a2b3c` é commit, `c9f8e7d` é conteúdo. Use o `release_id` do
retorno ao falar com o usuário; não o monte por conta própria.

**Erro `release_unidentifiable`** — a chamada foi sem os dois. Volte ao passo 3;
não invente um `ref`.

A tool resolve o destino ssh sozinha, pelo `domain` (o mesmo `cloudez_get_site`
do passo 1) — **não passe host, user nem port**. O `root`, quando existir, vem do `.cloudez.yaml`
(o bloco do environment): é a única fonte dele, e a tool não o busca na API de
propósito.

Este passo **já conecta por ssh** — ele prepara o diretório de release no
servidor. Uma falha de permissão aqui volta como `ssh_failed` (retryable), o
mesmo caso descrito no passo 5, com a mesma exceção para a chave recém-autorizada.

**Não passe `idempotency_key`.** O servidor gera uma. O campo existe para um
retry não virar um segundo deploy, e ele aceita a sua se você tiver a mesma chave
de uma chamada anterior — mas **não invente uma**: você não tem como gerar valor
aleatório de forma confiável, e uma chave repetida por engano devolve um deploy
antigo em vez de criar o novo.

[A5](#a5) conta por que isto já foi obrigatório e deixou de ser.

Guarde o `deploy_id` do retorno. O destino ssh já foi gravado no estado do
deploy, e é de lá que o `cloudez-sync` o lê no passo 5.

> **Não passe `root`.** O diretório do site no servidor é sempre
> `~/<domain>/www/claude`, e as tools o derivam do domínio — ele saiu do
> `.cloudez.yaml` porque a Cloudez RENOMEIA o diretório quando o domínio do site
> muda, e um valor escrito passaria a apontar para o que deixou de existir.
>
> A exceção é config antiga: havendo `root:` no bloco do environment, **passe-o** —
> ele vence o derivado, e ignorá-lo publicaria noutro lugar sem avisar. Não
> reescreva o arquivo do usuário para tirá-lo.

## 5. Sincronizar

```sh
cloudez-sync <deploy_id> <diretorio>
```

**Este é o único que não leva as variáveis**, e não é esquecimento — [A6](#a6).

Falha aqui é quase sempre SSH: chave não configurada, host desconhecido,
permissão. O campo `logs` do erro traz a saída do `tar` e do `ssh`. Chave ausente
é coisa que só o usuário resolve — reporte e pare, não tente contornar.

**Uma exceção, antes de reportar chave ausente.** Se a chave desta máquina
acabou de ser autorizada — pelo `/cloudez:setup` ou pelo painel —, um `Permission
denied (publickey)` é esperado: a conta registra a autorização na hora, mas
propagá-la até o servidor do site leva um tempo, em geral menos de um minuto e
eventualmente mais. Diga isso ao usuário e **tente novamente em alguns minutos**,
reusando a mesma `idempotency_key`. Só trate como chave ausente se continuar
falhando depois disso — mandá-lo conferir o cadastro que ele acabou de fazer o
faz procurar defeito onde não há.

## 6. Construir a imagem



```
cloudez_compose_build(deploy_id: "<deploy_id>")
```

Roda `docker compose build` no **diretório da release**, com o symlink ainda
apontando para a versão anterior.

**Antes do `finalize`, e é o ponto todo:** aqui, build quebrado é deploy que não
começou. [A7](#a7).

**`compose_build_failed`** é falha do **projeto**: Dockerfile, dependência,
contexto. Leia o `hint`, que traz a saída do build. Corrija e recomece o deploy;
nada foi ativado. É diferente do `compose_failed` do passo 8, que é quase sempre
do servidor.

`compose_missing` e `docker_missing` significam aqui o mesmo que no passo 8.

Pular este passo **não quebra o deploy**: o passo 8 reconstrói sozinho. Só perde
a garantia acima.

## 7. Ativar

```
cloudez_finalize_deploy(deploy_id: "<deploy_id>")
```

Troca o symlink `current` de forma atômica. Se der `activation_failed`, a release
**não** foi ativada e o site continua no ar na versão anterior — reporte e pare.

Se vier `replaced_directory` no retorno, o `current` era um **diretório de
verdade** e não um symlink: o site já tinha conteúdo antes de o plugin entrar.
Ele foi **movido**, nunca apagado, para o caminho que o campo informa. **Diga
isso ao usuário** — é conteúdo dele posto de lado, e só ele decide se ainda
serve para alguma coisa. Sem esse aviso vira um diretório órfão no servidor que
só aparece quando alguém for olhar.

Se vier `pruned_replaced`, esse número de diretórios substituídos **antigos** foi
apagado para o servidor não acumular cópias inteiras do document root. Reporte
também: é conteúdo do usuário, e apagar em silêncio seria pior do que acumular.
Os dois mais recentes sempre ficam.

`previous_release_id` **não aparece** quando não havia release anterior — é o
caso do primeiro deploy do site. Campo ausente, não string vazia.

Este passo também grava o **manifesto da release** no servidor, em
`<root>/.cloudez/deploys/<release_id>.json`: release, commit, hash do conteúdo e
a hora do servidor. É o que responde "o que está no ar e de qual commit veio" a
quem não tem o estado local — inclusive a outra pessoa da equipe.

O campo **`manifest`** do retorno traz o caminho gravado. Ele só aparece quando a
escrita deu certo, então a **ausência dele é informação**: o deploy segue válido
(a escrita é best-effort e não invalida uma release já ativada), mas aquele
servidor ficou sem registro do que está rodando. **Mencione ao usuário quando
faltar** — em silêncio, um manifesto que nunca foi gravado é indistinguível de um
gravado, e ninguém descobre até precisar dele.

## 8. Subir o container

Publicar os arquivos não põe uma aplicação em container no ar — [A9](#a9).

```
cloudez_compose_up(deploy_id: "<deploy_id>")
```

Roda `docker compose up -d` na release recém-ativada. **Depois do `finalize`,
nunca antes** — é este passo que troca o container em serviço, e invertida a
ordem ele subiria a release anterior.

Se o passo 6 rodou, a imagem já existe e o `up` só recria o container: segundos,
em vez do build inteiro. Se não rodou, ele reconstrói com `--build` — o caminho
antigo, correto e mais lento.

O retorno traz `compose.project` e `compose.containers`, com `name`, `state` e
`ports` de cada um. **Confira o `state`**: um container em `restarting` ou
`exited` é deploy fracassado com JSON de sucesso.

**Confira também o `compose.recreated`.** Ele diz se algum container foi de fato
trocado. `false` significa que o Compose não recriou nada — o conteúdo saiu
idêntico ao do deploy anterior, então a imagem saiu idêntica. Costuma ser
legítimo (republicar o mesmo conteúdo), mas é a diferença entre "a release nova está
servindo" e "a release nova está no disco". O `state` responde `running` nos dois
casos. Quando vier `false` e o deploy deveria ter mudado alguma coisa, cruze com
o `body_sha256` do passo 9.

O `project` vem do domínio, não do diretório, e sobrepõe um `name:` do usuário —
[A8](#a8).

Erros que **não se resolvem no projeto** e cujo `hint` você deve repassar como
está — os dois são ação da Cloudez, não do usuário:

- **`compose_failed` com permissão negada no `docker.sock`** — o usuário do site
  não está no grupo `docker`;
- **`compose_failed` com `iptables: No chain/target/match`** — as chains do
  Docker sumiram do host e nenhuma porta publicada funciona. Não tente contornar
  com `network_mode: host`: resolve o sintoma e amarra o projeto a um defeito
  daquele servidor.

**`compose_missing`** é outra coisa: o deploy publicou um diretório sem Compose.
Quase sempre significa que o passo 2 publicou a saída de um build em vez do
contexto de build. O container continua rodando a versão anterior.

**Verifique o site depois.** Este é o único passo cujo sucesso não se comprova
pelo próprio retorno: o container pode subir e a aplicação não responder. Bata no
domínio e confira o que voltou antes de declarar o deploy pronto.

# Confirmar

Ativar não é publicar. O que decide é o site responder — e o usuário saber onde
ver o resultado.

## 9. Verificar que o site responde

Ativar a release, ou subir o container, **não prova que a aplicação está no ar**.
Este é o passo que fecha essa lacuna.

```
cloudez_health_check(domain: "<domain>")
```

Ele tenta mais de uma vez por padrão. Um container recém-recriado leva segundos
para escutar, e uma checagem única logo depois do deploy pega o intervalo em que
ele ainda está subindo.

**`healthy: false`** — o deploy **fracassou**, mesmo com todos os passos
anteriores em `succeeded`. Reporte assim, sem suavizar. O que o `status_code`
sugere:

| Sintoma | Provável causa |
|---|---|
| `502` em site container | O container não está escutando. Confira o `state` do passo 8 e os logs do build |
| `404` | O document root aponta para o lugar errado, ou o symlink `current` está quebrado |
| sem `status_code`, com `error` | DNS, TLS ou o servidor fora — pode não ter relação com o deploy |

Ofereça o rollback (passo 10, e em site container o passo 8 de novo depois dele).

**`healthy: true`, mas `body_sha256` igual ao do passo 3** — o site responde e
está servindo **exatamente o mesmo conteúdo de antes do deploy**. Não afirme que
a publicação deu certo. Diga isso ao usuário e pergunte se a release deveria ter
alterado a página consultada: pode ser legítimo — nem toda release muda a home —
ou pode ser um deploy que não surtiu efeito.

**`attempts` maior que 1** — vale mencionar. A aplicação demorou a subir, e isso
é informação sobre ela que só este passo revela.

**Não compare `latency_ms` nem `attempts` com os do passo 3** — o único campo
comparável entre os dois passos é o `body_sha256`. [A4](#a4).

### Onde ver a versão nova

São dois endereços, e eles falham por motivos diferentes ([A10](#a10)):

```
cloudez_check_dns(domain: "<domain>")
```

O `temporary_address` veio do `cloudez_get_site` do passo 1. **Não guarde esse
valor** — releia sempre. [A11](#a11).

**Abra o site no navegador**, em vez de deixar o endereço como texto para o
usuário copiar:

```
preview_start(url: "https://<endereço>")
```

O endereço é **o oficial quando ele veio ✅**, e o temporário quando não. É a
diferença entre mostrar o site onde ele de fato vai viver e mostrar um endereço de
passagem — e quando o oficial ainda não responde, abrir o temporário é a única
forma de o usuário ver a versão nova agora.

Um link em texto obriga o usuário a sair da conversa para conferir o próprio
deploy. O painel de navegador é a mesma ferramenta que o `/cloudez:dev` usa para
mostrar a versão local, e ver as duas do mesmo jeito é o que torna a comparação
possível.

Feche o relato com este bloco, exatamente nesta forma:

```
Nova versão da aplicação disponível em:
  https://<temporary_address>   ✅
  https://<domain>              ✅  ou  ⚠️
```

O bloco continua, mesmo com o navegador aberto: ele carrega o que a página não
mostra — QUAIS dos dois endereços responderam, e que o ⚠️ é do DNS e não da
aplicação. O navegador entrega o link; o bloco entrega o diagnóstico.

**Quando o oficial vier ⚠️**, acrescente duas linhas logo abaixo — a primeira
sempre igual, a segunda vinda do `summary` do retorno, **sem reescrever**:

```
⚠️  Use o endereço temporário por enquanto.
    <summary>
```

A primeira linha é a única acionável, e é fixa de propósito: o usuário não precisa
ler o resto para saber o que fazer agora. E ela fala só de **ação**, nunca de
causa — [A13](#a13).

O `summary` já vem em uma linha, pronto para exibir. O `note` é outra coisa: é a
explicação inteira, para quando alguém for diagnosticar. **Não cole o `note` no
bloco** e não resuma o `summary` por conta própria — a saída ser igual toda vez é
o motivo de ele existir.

**O endereço temporário é sempre ✅** quando o passo 9 deu `healthy: true`: ele
aponta para o servidor por construção, sem depender de DNS de ninguém. E ele
aparece **sempre**, inclusive quando o oficial está ✅ — é o endereço que continua
funcionando se o DNS mudar depois.

**O oficial depende do `points_to_server`:**

| Retorno | Marca | O que dizer |
|---|---|---|
| `true`, `method: "dns"` | ✅ | Nada. Os dois funcionam |
| `true`, `method: "header"` | ✅ | Nada. O domínio está atrás de um CDN e chega à Cloudez assim mesmo. **Não mencione DNS** — está tudo certo |
| `false` | ⚠️ | **Leia o `note`**, que diz qual dos três casos é: registro ainda não propagado, apontado para o lugar errado, ou checagem que não conseguiu verificar. Repasse o que ele diz, e use o endereço temporário enquanto isso |

A tabela tinha uma quarta linha, que existia porque "resolve para outro lugar" era
indistinguível entre CDN e erro de configuração. O header `cez-verify` desempata
isso, e a linha deixou de ser necessária — [A12](#a12).

Se o site não tem `temporary_address`, mostre só o oficial — não invente um
endereço nem prometa que existe.

## 10. Rollback

Fora de um deploy, isto é o `/cloudez:rollback` — que confirma o alvo com o
usuário e verifica o resultado. Aqui está inline porque um rollback disparado no
meio de um deploy que falhou acontece dentro deste fluxo, e não há como invocar
outro comando daqui. **Os dois textos precisam mudar juntos.**

O `root`, se o `.cloudez.yaml` o tiver, vem do bloco do environment, como no
passo 4. Não tendo, omita: a tool o deriva do domínio.

```
cloudez_rollback(domain: "<domain>", root: "<root>")                          # volta para a anterior
cloudez_rollback(domain: "<domain>", root: "<root>", to_release_id: "<id>")   # volta para uma específica
```

O servidor mantém as 5 releases mais recentes; o rollback alcança até ali. Alvo
que não existe mais volta `release_not_found` com a lista do que sobrou — não
escolha outro por conta. Se o rollback também falhar (`rollback_failed`), isso é
um incidente — reporte imediatamente com todos os logs, sem tentar mais nada.

**Em aplicação em container, o rollback não termina aqui.** Ele troca o symlink,
e só: o container segue rodando a imagem construída no deploy anterior, então o
site continua servindo o que você acabou de tentar tirar do ar. É preciso
reconstruir a imagem a partir da release de destino — `cloudez_compose_build`
seguido de `cloudez_compose_up`, ambos com o `deploy_id` dela. O
`cloudez_compose_build` aceita release já ativa justamente para isto.

Se não houver um deploy ativo para essa release, um `cloudez_begin_deploy` novo
com os mesmos identificadores (o `content_sha256` do passo 3, e o `ref` se
houver), seguido de sync + compose_build + finalize + compose_up, é o caminho
que reconstrói e religa tudo.

**Rode o passo 9 de novo depois do rollback.** Voltar o symlink é o remédio, não
a confirmação — e um rollback que não devolve o site ao ar é o pior estado
possível para se declarar resolvido.

## Como reportar

Comece pelo resultado: subiu ou não subiu, em qual ambiente, qual `release_id`.
Depois o detalhe.

Diga o `release_id` inteiro, não só o sufixo: é o que o usuário vai digitar num
rollback. Quando houver commit, mencione-o junto — a pessoa reconhece o commit,
não o hash de conteúdo.

Não descreva os passos que correram bem — o usuário não precisa saber que o envio
funcionou. Descreva o que ele precisa fazer alguma coisa a respeito: falhas e
rollbacks executados.

O bloco de endereços do passo 9 fecha o relato, e não se resume nem se substitui:
é por ele que o usuário sabe onde olhar.

Se houve rollback, diga explicitamente **qual versão está no ar agora**.

## Inspeção sem deploy

Quando o usuário só quer saber o estado:

```
cloudez_list_releases(domain: "<domain>", root: "<root>")   # o que está no servidor, qual é a atual
```

Também aqui o destino vem do `cloudez_get_site` — passos 1 a 2 antes.

---

## Nota de implementação

Havendo `root` no `.cloudez.yaml`, ele vem **sempre** de lá, nunca da API: duas fontes para o
destino dos arquivos criariam a pergunta "qual vale?" para a decisão mais
destrutiva daqui, e ela só apareceria quando as duas divergissem.

Todo o control plane já é tool do servidor MCP: `cloudez_begin_deploy`,
`cloudez_finalize_deploy`, `cloudez_compose_build`, `cloudez_compose_up`,
`cloudez_list_releases` e
`cloudez_rollback`. O passo 5 é a exceção permanente: o transporte (`cloudez-sync`)
continua local, já que o MCP nunca transporta arquivos.

# Apêndice — por que cada trava existe

Os passos acima dizem **o que fazer**. Isto diz **por que**, e quase tudo aqui é
defeito que já aconteceu — não precaução teórica.

Ler não é obrigatório para executar o deploy. Mas antes de remover, afrouxar ou
"simplificar" qualquer regra dos passos, leia a entrada dela: a maioria parece
excesso de zelo até você conhecer o caso que a criou.

<a id="a1"></a>

### A1 — Por que o destino ssh não mora no .cloudez.yaml

Uma cópia do host num arquivo versionado envelhece: se a Cloudez mover o site de
servidor, o valor escrito continua apontando para o antigo, e o deploy vai para o
lugar errado sem reclamar. Buscá-los a cada deploy é o que evita isso.

É a mesma razão pela qual o `temporary_address` também não é guardado ([A11](#a11)).

<a id="a2"></a>

### A2 — Por que árvore suja não bloqueia mais o deploy

Era a razão certa na época: o `ref` era a única referência da release, e um commit
que não correspondia ao disco deixava o rollback sem destino confiável.

Com o hash do conteúdo essa preocupação deixou de existir, e parar o deploy passou
a custar mais do que resolvia — a árvore suja costuma ser exatamente a correção às
pressas que se está tentando publicar.

<a id="a3"></a>

### A3 — Por que medir o site ANTES de publicar

Foi assim que um `app_root_path` errado passou por deploy bem-sucedido enquanto o
site servia o conteúdo velho: todos os passos em `succeeded`, o site no ar, e nada
publicado.

O `body_sha256` é o único sinal independente de stack sobre a publicação ter
mudado alguma coisa.

<a id="a4"></a>

### A4 — Por que as duas medições de saúde não são comparáveis

O `attempts: 1` aqui é assimétrico em relação ao passo 9, que usa o padrão. Lá as
tentativas existem porque um container recém-recriado leva segundos para escutar;
aqui não há nada subindo, e insistir só atrasaria o deploy quando o site já está
fora do ar.

A consequência é que a diferença de latência entre as duas medições não diz nada
sobre a aplicação. Na prática a primeira requisição a um domínio vem bem mais lenta
que as seguintes — cache frio de borda e handshake de TLS, não o seu deploy. **Não
apresente essa queda ao usuário como melhora.**

<a id="a5"></a>

### A5 — Por que não se inventa uma idempotency_key

O campo já foi obrigatório, com o valor vindo de `uuidgen`. O binário não existe no
subconjunto que o Git Bash do Windows embarca, então o deploy simplesmente não
passava deste passo naquela plataforma.

Hoje o servidor gera a chave. Ele aceita a sua se você tiver a mesma de uma chamada
anterior — mas uma chave repetida por engano devolve um deploy antigo em vez de
criar o novo, e você não tem como gerar valor aleatório de forma confiável.

<a id="a6"></a>

### A6 — Por que o sync não recebe host, user nem port

O `begin_deploy` resolveu o destino uma vez e o gravou no estado do deploy, e é de
lá que o `sync` o lê.

Passá-las de novo aqui não teria efeito — e se uma delas viesse diferente, o envio
iria para um servidor e a ativação para outro.

<a id="a7"></a>

### A7 — Por que o build vem ANTES do finalize

Enquanto o build roda — e num projeto de verdade ele leva minutos — o site inteiro
segue no ar coerente: symlink antigo, container antigo.

Construindo depois de ativar, como era antes, o servidor passa o build inteiro num
estado misto: arquivos novos no disco, container servindo os antigos. E se o build
quebra, esse estado FICA — o deploy retorna erro com a release já ativada, e o site
continua na versão velha sem nada que o desfaça.

O build lê `releases/<release_id>` explicitamente, nunca `current`. Era justamente a
dependência do symlink que obrigava a ordem antiga.

<a id="a8"></a>

### A8 — Por que o nome do projeto Compose vem do domínio

O daemon do Docker é um só para todos os sites da máquina, e o nome derivado do
diretório seria `current` para todos eles.

Dois sites deste plugin no mesmo servidor viravam o mesmo projeto Compose, e o
deploy de um derrubava o container do outro.

<a id="a9"></a>

### A9 — Por que o passo 8 existe

O nginx da Cloudez encaminha `/` para uma porta local, e quem escuta ali é o
container do usuário.

Sem este passo o deploy termina em `succeeded` com o site respondendo **502** no
primeiro deploy, ou servindo a **release anterior** nos seguintes — falha que não
aparece em nenhum JSON de retorno, só no navegador.

<a id="a10"></a>

### A10 — Por que o bloco de endereços fecha o deploy

Um deploy que termina sem dizer onde olhar obriga o usuário a adivinhar.

No caso mais comum — o primeiro deploy de um domínio recém-apontado — o endereço
oficial ainda não funciona, e ele conclui que o deploy falhou quando não falhou.

<a id="a11"></a>

### A11 — Por que o temporary_address não é guardado

Ele muda quando a Cloudez move o site, e uma cópia num arquivo do projeto
envelheceria em silêncio.

É a mesma razão pela qual o bloco `ssh` saiu do `.cloudez.yaml` ([A1](#a1)) — dado
derivado do servidor não se copia para o projeto.

<a id="a12"></a>

### A12 — Por que a verificação do domínio tem DUAS checagens

Comparar o A/AAAA do domínio com o IP do servidor responde bem no caso simples e
erra no caso comum: um domínio atrás de Cloudflare resolve para o **proxy**, não
para o servidor, e o site funciona perfeitamente.

Só com DNS, esse cenário é **indistinguível** de um domínio apontado para o lugar
errado. A saída era mostrar ⚠️ e perguntar ao usuário se havia CDN na frente — ou
seja, pedir que ele fizesse o diagnóstico por nós, no fim de um deploy que deu
certo.

O header `cez-verify` é servido pela Cloudez, então recebê-lo prova que a
requisição ao domínio **chegou** num servidor dela, com CDN na frente ou sem. Ele
só é consultado quando o DNS não bate: quando bate, não há o que desempatar e não
se gasta uma requisição ao site do usuário.

Qualquer código de status serve. Um **502 com o header presente** é justamente o
caso que interessa distinguir — o tráfego chegou, e o problema é a aplicação;
dizer "o DNS não aponta" ali mandaria procurar no lugar errado.

<a id="a13"></a>

### A13 — Por que a linha de alerta fala de ação, e não de causa

A linha fixa diz "use o endereço temporário por enquanto", e não "o domínio não
chega ao servidor". A diferença importa num dos três casos.

Quando o servidor do site não resolve, quem está cega é a **checagem** — não há
informação sobre o domínio. Uma linha fixa que afirmasse causa estaria errada ali,
e mandaria o usuário mexer num DNS que pode estar perfeito.

É o mesmo exagero que o `cez-verify` acabou de eliminar do caso do CDN ([A12](#a12)),
e reintroduzi-lo numa linha fixa desfaria o ganho. A causa vai no `summary`, que é
escrito por caso e admite não saber quando não sabe.
