# Contrato das tools MCP — Cloudez

Especificação da interface que o servidor MCP (repositório separado) deve expor
para este plugin. Este documento é a fonte da verdade do contrato: o plugin é
escrito contra ele, e o servidor MCP o implementa.

Status: **implementado**. As vinte e uma tools descritas existem no servidor e
são chamadas pelos comandos do plugin; o que segue em aberto está na seção 7.

Boa parte do que está escrito aqui foi aprendido apanhando — endpoints
confirmados por tentativa, semânticas de escrita que diferem entre si, modos de
falha que só apareceram em deploy real. Quando um trecho parece detalhe
excessivo, é porque custou uma sessão descobri-lo.

**Convenções que valem para tudo abaixo:**

- **O site é identificado pelo `domain`.** Não há `site_id` — um FQDN já é único
  e é o que o usuário sabe de cor.
- **`environment` é um conceito local do plugin**, não do servidor: é a chave
  dentro de `cloudez:` no `.cloudez.yaml` do projeto (`default`, `staging`,
  `production`, ...). Cada environment aponta para um `domain`. As tools MCP
  recebem `domain`; o environment nunca é enviado.
- **Nomes de campos e argumentos em inglês.**

---

## 1. O split: control plane vs data plane

O transporte dos arquivos é `tar` em stream sobre `ssh`, feito localmente pelo
`bin/cloudez-sync`. Isso define a fronteira:

| Camada | Quem faz | O quê |
|---|---|---|
| **Data plane** | `bin/cloudez-sync` (Node), no host do usuário | mover os bytes para o servidor |
| **Control plane** | tools MCP | descobrir o destino, registrar o deploy, ativar a release, rollback |

**O MCP nunca transporta arquivos.** Ele diz *para onde* enviar e *o que fazer
depois que chegou*. Duas razões: conteúdo de arquivo em argumento de tool passa
pelo contexto do modelo (caro, lento, trunca), e o transporte precisa funcionar
sem rede intermediária.

Fluxo completo de um deploy:

```
1. Skill decide o diretório a publicar          (Bash, opcionalmente um build)
2. cloudez_begin_deploy(domain, ref)  ─────────► MCP
   └─ retorna deploy_id + destino ssh
3. tar -c | ssh tar -x  para o release dir      (cloudez-sync, local)
4. cloudez_finalize_deploy(deploy_id) ─────────► MCP
   └─ troca o symlink current
   └─ falhou? cloudez_rollback(domain)
```

---

## 2. Princípios de design

Estas regras existem porque o consumidor é um modelo de linguagem, não um script.

**Read-only e mutating são conjuntos separados.** Tools sem efeito colateral
(`list`, `get`, `status`) podem ir para o allowlist do `settings.json` do usuário
e nunca gerar prompt de permissão. As mutating (`begin`, `finalize`, `rollback`)
sempre pedem confirmação. Não misture as duas responsabilidades numa tool só —
uma tool que "lista e opcionalmente recria" força o usuário a aprovar toda
listagem.

**Toda tool mutating aceita `idempotency_key`.** Modelos repetem chamadas: por
timeout aparente, por retry após erro de rede, por reinterpretar o próprio
histórico. Sem chave de idempotência isso vira deploy duplicado.

Ela é **opcional**, e quem a gera é o **servidor** quando ela não vem. A versão
anterior a exigia do cliente, e o `commands/deploy.md` mandava obtê-la com
`uuidgen` — um binário que o Git Bash do Windows não embarca, então o deploy não
passava daquele passo naquela plataforma. Duas outras coisas pesaram na troca: um
modelo não tem como gerar valor aleatório de forma confiável, e a garantia
dependia de ele *lembrar* de reusar a mesma chave no retry. O que se perde é
estreito — se a chamada tiver sucesso e a resposta não chegar ao modelo, o retry
cria um segundo diretório de release, vazio e podado pela retenção. Quem tem a
chave de uma chamada anterior ainda pode passá-la.

A chave vira **nome de arquivo** em `.cloudez/state/key/`, então ela é validada
(`[A-Za-z0-9][A-Za-z0-9._-]{0,127}`, sem `..`) **antes** de qualquer efeito
colateral: recusá-la depois do `mkdir` remoto deixaria um diretório órfão por um
argumento que estava errado desde o começo. Recusa vira
`invalid_idempotency_key`.

**O retorno é acionável, não um booleano.** `{"ok": true}` cega o modelo. Todo
retorno de erro deve conter o suficiente para o Claude corrigir e tentar de novo
sozinho — stderr do comando, código de saída, logs. É isso que fecha o loop
autônomo.

**A `description` diz *quando* chamar, não só o que faz.** Modelos recentes são
conservadores em disparar tools. `"Cria um deploy"` rende bem menos que
`"Chame após o build passar, para registrar a release e obter o destino do
envio. Não chame se o working tree tiver alterações não commitadas."`

**Nomes prefixados com `cloudez_`.** Evita colisão com outros MCP servers no
mesmo ambiente e deixa a origem óbvia no log de tool calls.

---

## 3. Tools

### 3.1 `cloudez_auth_status` — read-only

Diz se há um token utilizável nesta máquina. É a tool que aposenta o
`cloudez-login --check`: o gate de autenticação deixa de ser um adaptador em
shell e passa a ser o MCP, que é quem realmente usa a credencial.

Não recebe nem devolve o token — veja a seção 5.

```jsonc
// input
{ "type": "object", "properties": {}, "additionalProperties": false }
```

```jsonc
// output
{
  "authenticated": true,
  "source": "file",                  // "env" | "file" | "none"
  "token_file": "/home/ana/.cloudez/token",
  "verified": true,                  // false quando a API não pôde confirmar
  "panel_host": "cloud.configr.com"  // ausente se cloudez_panel_info nunca confirmou um aqui (§3.15)
}
```

A distinção entre `authenticated` e `verified` é a mesma da tabela na seção 5, e
é contrato: `authenticated: true, verified: false` significa "há um token e a
Cloudez não desmentiu" — offline ou API fora. Reportar `authenticated: false` aí
mandaria o usuário refazer um login que já estava correto.

**`authenticated: true` não é fato para relatar ao usuário — é só o sinal para
seguir com o que ele pediu, em silêncio.** O procedimento existia só no
`/cloudez:setup` (seu passo 0 já checava e seguia calado); outros pontos que
checavam autenticação como pré-requisito de uma tarefa diferente reproduziam a
frase da seção 5 ("diga de onde veio o token") fora do contexto para o qual ela
foi escrita — que é `/cloudez:login` sendo o próprio pedido do usuário. Contrato
explícito agora: falar sobre autenticação só quando ela FALTAR (então o caminho
é o `/cloudez:login`), ou quando checar login for o pedido em si.

`panel_host`, quando presente, é o que `cloudez_panel_info` (§3.15) confirmou
numa chamada anterior — de QUALQUER comando, não só do que gravou; a gravação é
efeito colateral daquela tool, não uma tool à parte. Quem chama confere este
campo antes de perguntar o painel ao usuário: um painel já confirmado nesta
máquina não precisa ser perguntado de novo a cada conversa.

Quando não há token — ou quando a Cloudez o recusou —, o retorno traz **os
comandos prontos desta máquina**, e não só um conselho genérico:

```jsonc
{
  "authenticated": false,
  "source": "none",
  "token_file": "/home/ana/.cloudez/token",
  "verified": false,
  "hint": "Peça ao usuário para gerar o token no painel e COPIAR. Quando ele confirmar, rode: ...",
  "login_command": "/home/ana/.claude/plugins/cloudez/bin/cloudez-login",
  "claude_code_command": "! /home/ana/.claude/plugins/cloudez/bin/cloudez-login",
  "clipboard_command": "pbpaste | /home/ana/.claude/plugins/cloudez/bin/cloudez-login --stdin",
  "warning": "Não peça o token na conversa: colado aqui, ele fica no transcript da sessão."
}
```

`clipboard_command` só aparece quando há clipboard **verificado**: `pbpaste` no
macOS e `powershell.exe Get-Clipboard` no Windows. A via X11/Wayland foi
removida — não por estar errada, mas por nunca ter sido exercitada, e num fluxo
de credencial um comando não verificado custa mais do que a conveniência que
entrega. Os três `*_command` só aparecem quando o adaptador foi localizado: o
servidor confere que o arquivo existe antes de citá-lo, porque um caminho
inventado manda o usuário a um "arquivo não encontrado" sem pista da causa.

Isso substitui o `cloudez-login --hint`, que fazia o mesmo cálculo do lado shell.
Ele existia porque "o MCP não tem como saber onde o plugin está" — o que deixou
de ser verdade quando o servidor passou a ser distribuído **dentro** do plugin
(`${CLAUDE_PLUGIN_ROOT}/mcp/cloudez-mcp.mjs`, com `CLOUDEZ_PLUGIN_ROOT` injetado
no ambiente pelo `.mcp.json`). O que se ganha é a chamada de Bash que separava
"não há token" de "e o que eu faço".

O modelo **não** deve pedir o token na conversa.

---

### 3.2 `cloudez_list_sites` — read-only

Busca sites da conta por um termo. **Não existe listagem completa**, e a ausência
é decisão: devolver a conta inteira significa percorrer todas as páginas da API e
despejar o resultado no contexto do modelo — caro dos dois lados, e pior quanto
maior a conta, que é justamente quando alguém precisa procurar.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "query": { "type": "string", "description": "Parte do domínio ou do nome" }
  },
  "required": ["query"],
  "additionalProperties": false
}
```

```jsonc
// output
{
  "sites": [
    { "domain": "meusite.com.br", "name": "meusite", "stack": "static" }
  ],
  "total": 42,                       // o que a API declara ter, quando declara
  "truncated": "…"                   // só quando a listagem parou antes do fim
}
```

**Endpoint:** `GET /v3/website/?domain=<termo>` — o mesmo do `cloudez_get_site`.

O filtro daquele endpoint casa **parcialmente**: é por isso que o `get_site`
confere igualdade exata por conta própria depois, e é o que aqui vira a
funcionalidade. `claude` encontra `claudetest.cloudez.io` e
`claudetestdocker.cloudez.io`.

**O resultado da API não é refiltrado no cliente.** Refiltrar só poderia remover
algo que o servidor considerou casamento — se ele buscar num campo que não
lemos, descartaríamos um acerto legítimo, e o usuário veria "não achei" sobre o
site dele.

**A busca segue o `next` até o fim**, com um teto de páginas para uma API que
responda sempre a mesma página não virar laço. Atingido o teto, o retorno traz
`truncated` — **parar em silêncio faria o modelo afirmar que um domínio não
existe na conta quando ele só estava depois do corte**, que é o oposto do que
esta tool existe para fazer.

Do `next` aproveita-se apenas `pathname` e `search`. Ele vem como URL absoluta, e
seguir o host que veio no corpo da resposta seria deixar a API escolher para onde
mandamos o token.

**Esta tool não serve para verificar se um domínio existe.** Para isso é o
`cloudez_get_site`, que filtra no servidor e não depende de a lista caber. Item
sem domínio é descartado, como lá e pela mesma razão.

---

### 3.3 `cloudez_get_site` — read-only

Detalhes de um site, incluindo o alvo de sincronização. Tem duas funções:

1. **Confirmar que o domínio existe na conta**, antes de o `/cloudez:setup`
   escrever um `.cloudez.yaml` para ele. É o que impede um domínio com typo de
   virar uma config que só falha no deploy, longe da causa. Esta é a razão de o
   setup exigir autenticação: sem token não há como saber se o site existe.
2. **Fornecer o destino ssh a cada deploy.** O bloco `ssh` saiu do
   `.cloudez.yaml`. Quem o resolve é o `cloudez_begin_deploy`, uma vez, gravando
   host, usuário e porta no estado do deploy — os passos seguintes leem de lá, e
   nenhum deles recebe o destino por argumento ou por ambiente. Uma cópia do host
   num arquivo versionado envelhece — se a Cloudez mover o site de servidor, o
   valor escrito segue apontando para o antigo e o deploy vai para o lugar errado
   sem reclamar.

   As variáveis `CLOUDEZ_SSH_HOST`, `CLOUDEZ_SSH_USER` e `CLOUDEZ_SSH_PORT`
   citadas em versões anteriores deste contrato **não existem mais**: nada no
   plugin as lê.

Campo que a API não trouxer **some do retorno**, em vez de virar `null`, string
vazia ou um default plausível. O bloco `ssh` só sai inteiro: meio bloco faria o
usuário preencher o resto à mão sem desconfiar do que veio da API. Um `host`
inventado não falha na tool, falha num deploy contra um servidor que não é o
dele.

O domínio é normalizado para minúsculas antes da consulta, como no
`cloudez-setup`: o domínio vira caminho no servidor, e caminho diferencia
maiúscula onde o DNS não diferencia.

**Endpoint na API da Cloudez:**

```
GET /v3/website/?domain=meusite.com.br
```

É uma **coleção filtrada**, não um recurso por path, e isso muda duas coisas em
relação a um `GET /v3/website/<domínio>/`:

- **"Não existe" chega como lista vazia com `200`**, não como `404`. Um `404`
  nesta rota significa rota errada — ver seção 4.
- **O resultado do filtro precisa ser conferido, não aceito.** Não está
  confirmado se `?domain=` é comparação exata ou parcial. Se for parcial,
  `claudetest.com.br` casa também com `staging.claudetest.com.br`, e pegar o
  primeiro item devolveria um site que o usuário não pediu — erro que só
  apareceria no deploy. A implementação filtra por igualdade exata do domínio
  antes de escolher.

A resposta é aceita tanto paginada (`{count, next, previous, results}`) quanto
como array puro: ligar a paginação um dia não pode quebrar o setup de todo mundo.

**A configuração de cada site vem numa lista de pares**, não em campos de topo:

```jsonc
{
  "name": "claudetest",
  "values": [
    { "slug": "domain", "value": "claudetest.com.br" },
    { "slug": "stack",  "value": "static" }
  ],
  "cloud": { "fqdn": "srv-12.cloudez.io" },
  "user":  { "username": "deploy", "has_ssh": true }
}
```

Para os campos de configuração em geral, `values` vence o campo de topo quando os
dois existem: é onde mora a configuração efetiva.

**O domínio é a exceção: as duas origens contam.** Um site é reconhecido tanto
pelo atributo `domain` do recurso quanto pelo `value` da entrada com
`slug: "domain"`, e casar por qualquer uma basta. Preferir uma delas faria a
busca falhar justamente quando o usuário digita o domínio que está na outra — e
ele não tem como saber qual das duas o painel mostrou. O `name` nunca entra nessa
comparação.

Quando as duas divergem, o candidato sai com o `domain` principal (o de `values`)
e as demais em `other_domains`, para o usuário reconhecer o site por qualquer uma.
Origens iguais não viram duplicata.

**Três desfechos, e a diferença entre eles é quem decide:**

**Item que não declara domínio em nenhuma das duas origens é descartado antes de
qualquer decisão.** A busca inteira gira em torno de comparar domínios: um item
sem domínio não casa, não é oferecível ao usuário e não tem como ser confirmado
por ele. Só poderia virar palpite.

| Resposta da API | Retorno | Quem decide |
|---|---|---|
| nenhum item com domínio (inclusive lista vazia) | erro `site_not_found` | ninguém: terminal |
| algum domínio, de qualquer origem, igual ao pedido | `{match: "exact", site}` | o usuário confirma |
| só domínios aproximados | `{match: "candidates", requested_domain, candidates}` | o usuário escolhe |

Uma resposta cheia de itens sem domínio cai no mesmo `site_not_found` de uma
busca vazia: em ambos o usuário não tem o que escolher, e distinguir os dois lhe
daria uma informação sobre a qual não pode agir.

A tool **não escolhe** no terceiro caso, e isso é contrato, não zelo: um site
escolhido por conta própria é um deploy no lugar errado, descoberto tarde. Ela
devolve os candidatos com o domínio de cada um, e o `/cloudez:setup` pergunta.

```jsonc
// input
{ "type": "object", "properties": { "domain": { "type": "string" } },
  "required": ["domain"], "additionalProperties": false }
```

```jsonc
// output — match exato, com ssh utilizável
{
  "match": "exact",
  "site": {
    "domain": "meusite.com.br",
    "name": "meusite",
    "stack": "claude",
    "app_root_path": "claude/current",
    "custom_port": "3000",
    "temporary_address": "meusite-com-br.srv-12.cloudez.io",
    "ssh": {
      "host": "srv-12.cloudez.io",
      "port": 22,
      "user": "deploy"
    },
    "current_release": "20260807T143000Z-a1b2c3d"
  }
}
```

> Nenhuma credencial no retorno. A chave SSH vive no ambiente do usuário
> (`~/.ssh/`), não passa pelo MCP nem pelo contexto do modelo.

**O destino do ssh não vem de `values`.** Ele mora em dois objetos do recurso:

| Campo na API | Vira |
|---|---|
| `cloud.fqdn` | `ssh.host` — o servidor onde o site está hospedado |
| `user.username` | `ssh.user` |
| `user.has_ssh` | porteiro: `false` impede o bloco `ssh` de existir |
| `user.authorized_keys` | lido pelo `cloudez_authorize_ssh_key` (seção 3.5) |
| `user.id` | necessário para escrever no usuário |

A porta não vem no recurso. O default é `22`.

**`has_ssh: false` não é ausência de dado, é recusa** — e os dois pedem respostas
opostas. Por isso, quando não há bloco `ssh`, o retorno traz `ssh_unavailable`
explicando qual dos dois casos é:

```jsonc
// output — o usuário não tem ssh liberado
{
  "match": "exact",
  "site": {
    "domain": "meusite.com.br",
    "ssh_unavailable": "O usuário 'deploy' não tem SSH liberado nesta conta (has_ssh: false). O deploy não é possível até que o acesso SSH seja habilitado no painel da Cloudez. Preencher host e usuário à mão não resolve."
  }
}
```

Sem essa distinção, um usuário sem SSH liberado receberia o pedido de preencher
`ssh.host` e `ssh.user` na config à mão — e o deploy falharia depois com permissão
negada, longe da causa. Nenhum valor digitado contorna um `has_ssh: false`.

**`cloudez_get_site` não devolve `root`.** O destino da publicação vem sempre do
`.cloudez.yaml` do projeto, e ter uma segunda fonte para ele seria criar a
pergunta "qual vale?" para a informação mais destrutiva deste plugin — pergunta
que só apareceria quando as duas divergissem, que é tarde.

O `root` da config é o diretório que contém `releases/`, `current` e `shared/`.
Um `~/` inicial significa "relativo ao `$HOME` do usuário ssh"; o plugin o remove
antes de montar comandos remotos, porque dentro de aspas simples o shell do
servidor não expande til.

O `cloudez-setup` grava `~/<domain>/www/claude`: o document root do site na
Cloudez é `~/<domain>/www`, e a estrutura de releases fica num subdiretório dele
para o deploy não tomar conta do `www` inteiro e apagar o que já estivesse lá.

A consequência prática é que **o document root no painel da Cloudez precisa
apontar para `<root>/current`** — com o default acima, `~/<domain>/www/claude/current`.
Deixado em `~/<domain>/www`, o site segue servindo o conteúdo antigo e o deploy
não tem efeito visível: sem erro em lugar nenhum, que é o pior formato de falha.

---

### 3.4 `cloudez_configure_site` — **mutating**

Ajusta os dois valores do site de que o deploy depende: o `app_root_path` — o
diretório que o servidor web entrega, relativo a `~/<domain>/www` — e a
`custom_port` — a porta do host para onde o nginx da Cloudez encaminha `/`.

Existe por causa de duas falhas silenciosas, e elas são diferentes:

- **document root errado**: o deploy publica em `<root>/current`, e com o `root`
  que o `cloudez-setup` grava isso é `claude/current`. Apontando para outro
  lugar, o deploy roda inteiro, sem erro nenhum, e o site continua servindo o
  conteúdo antigo — o usuário só descobre comparando o que publicou com o que o
  navegador mostra;
- **porta errada**: o container sobe, o deploy se declara bem-sucedido, e o site
  responde **502** — o nginx encaminha para uma porta onde não há ninguém
  escutando.

**Os dois num PATCH só, e isso não é economia de round-trip.** São
pré-requisitos da mesma publicação: em chamadas separadas, a segunda falhando
deixa o site com metade da configuração e nada no retorno dizendo isso.

**A invariante da porta não é um número fixo.** É `custom_port` == porta que o
Compose do projeto publica. O `3000` é o default de quando somos nós que
escrevemos o Compose; num projeto que já tem um, quem manda é o arquivo, e é a
Cloudez que se ajusta. Foi por isso que esta tool deixou de tratar só do
document root.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "domain": { "type": "string" },
    "app_root_path": { "type": "string", "description": "Relativo a ~/<domain>/www. Normalmente 'claude/current'." },
    "custom_port": { "type": "string", "description": "Porta do host que o nginx encaminha para '/'. Default do plugin: '3000'." }
  },
  "required": ["domain"],
  "additionalProperties": false
}
```

Passe só o que quiser alterar. O que já estiver correto não gasta escrita.

```jsonc
// output
{ "domain": "meusite.com.br",
  "app_root_path": "claude/current", "custom_port": "3000",
  "previous_app_root_path": "public_html",
  "changed": ["app_root_path"] }
```

`changed` é a **lista** dos slugs efetivamente escritos, e não um booleano: com
dois campos, "mudou" sozinho não diz qual. Lista vazia significa que tudo já
estava correto e nenhuma escrita foi feita.

**Sem `idempotency_key`, e a exceção é deliberada.** A regra da seção 2 existe
porque as outras mutating criam recursos, e repetir cria dois. Esta atribui
valores fixos: repetir dá no mesmo. A chave existiria só para cumprir
formalidade.

**O corpo do `PATCH` repete a forma em que a configuração é lida:**

```jsonc
PATCH /v3/website/<id>/
{ "values": [ { "slug": "app_root_path", "value": "claude/current" },
              { "slug": "custom_port",   "value": "3000" } ] }
```

**A tool relê o site depois de escrever**, e a releitura confere três coisas:

1. **cada valor mudou de fato.** Uma escrita que se declara bem-sucedida sem ter
   efeito é pior do que uma que falha: manda o usuário fazer deploy confiante numa
   configuração errada, e o sintoma que volta é "publiquei e o site não mudou",
   o mais difícil de ligar à causa;
2. **nenhum outro slug sumiu.** Sob a semântica confirmada isso nunca dispara —
   e é por isso que fica: se um dia disparar, a API mudou de comportamento, e o
   sintoma seria a configuração do site apagada em silêncio por um comando que só
   queria ajustar dois valores;
3. **o site ainda é encontrável pelo domínio.** Se a busca deixar de achá-lo logo
   depois da escrita, isso **não** vira `site_not_found`: ele respondeu um
   instante antes, e o erro mandaria o usuário procurar no painel um problema que
   a ferramenta pode ter causado.

**A tool não decide sozinha.** Quem chama precisa ter perguntado ao usuário: a
mudança vale na hora, e até o primeiro deploy o diretório `claude/current` ainda
não existe no servidor — um site que já estava no ar fica fora dele nesse
intervalo.

---


### 3.5 `cloudez_authorize_ssh_key` — **mutating**

Acrescenta uma chave pública SSH às chaves autorizadas do usuário da conta, para
que o deploy consiga conectar. Sem isso o `sync` falha com permissão negada — no
meio do deploy, depois de o build já ter rodado.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "domain": { "type": "string" },
    "public_key": { "type": "string", "description": "Linha completa da chave pública" }
  },
  "required": ["domain", "public_key"],
  "additionalProperties": false
}
```

```jsonc
// output
{ "domain": "meusite.com.br", "username": "deploy",
  "added": true, "authorized_key_count": 2 }
```

`added: false` significa que a chave já estava autorizada e nada foi escrito.

**Endpoint:**

```
PATCH /v3/cloud-user/<id>/
{ "authorized_keys": "<texto multilinha, uma chave por linha>" }
```

> **As duas escritas desta API têm semânticas opostas, e confundi-las apaga
> dados.** O `values` do site (seção 3.4) é **atualização**: mandar um item mexe
> só naquele slug. O `authorized_keys` do cloud-user é **substituição**: o que
> for enviado troca o campo inteiro. Antes de acrescentar qualquer escrita nova
> ao servidor, confirme de qual lado ela está.

**O campo não tem semântica de append.** O que for enviado **substitui** o
conteúdo inteiro. Acrescentar uma chave é, obrigatoriamente:

```
ler o valor atual  ->  montar o texto completo com a nova no fim  ->  PATCH
```

Mandar só a chave nova apaga as de todo mundo. Isso não é cuidado opcional: é a
única forma correta de usar este endpoint.

**Esta é a operação mais privilegiada do servidor**, e uma regra vale acima de
todas as outras aqui: **nunca remover uma chave que já estava lá.** O campo é
compartilhado por quem mais tenha acesso à conta, e uma escrita descuidada tira
o acesso de outras pessoas — possivelmente de todas, e possivelmente sem ninguém
perceber até precisar entrar.

Disso saem três decisões:

- **o valor atual vai inteiro, literal**, com a chave nova numa linha no fim.
  Remontá-lo só a partir do que sabemos interpretar descartaria linhas que não
  reconhecemos — opções de `authorized_keys`, comentários, tipos de chave novos —
  e descartar ali é remover acesso;
- **a releitura confere que nenhuma chave anterior sumiu**, além de conferir que
  a nova entrou. A leitura inicial pode ter vindo incompleta, e perder uma chave
  alheia em silêncio é o pior desfecho possível desta tool;
- **a comparação ignora o comentário** (`ana@maquina`). Ele é livre e muda ao
  trocar de máquina; comparar a linha inteira faria a mesma chave virar uma
  segunda entrada idêntica.

**Chave pública não é segredo** — existe para ser distribuída. Nada aqui toca a
chave privada, e a `description` da tool instrui explicitamente a nunca enviar
arquivo sem `.pub`.

**Quem chama precisa ter perguntado ao usuário.** Autorizar uma chave concede
acesso SSH permanente à conta a partir daquela máquina; não é o mesmo que
escrever um arquivo local.

**O `added: true` não significa que o ssh já funciona.** A escrita e a releitura
confirmam o estado *na conta*; chegar ao servidor do site é um passo assíncrono da
Cloudez, em geral abaixo de um minuto e eventualmente mais. Nesse intervalo o
servidor responde `Permission denied (publickey)` — indistinguível de chave
errada. Por isso a tool não tenta confirmar o acesso conectando: um teste
imediato falharia quase sempre e transformaria um sucesso em erro. Quem chama
avisa o usuário e, se o deploy seguinte falhar assim, tenta novamente em alguns
minutos.

---

### 3.6 `cloudez_begin_deploy` — **mutating**

Registra a intenção de deploy e devolve o diretório de release onde o transporte
deve escrever. Não move nenhum byte.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "domain": { "type": "string" },
    "ref": {
      "type": "string",
      "description": "Git SHA (preferido) ou tag identificando o que está sendo enviado"
    },
    "idempotency_key": {
      "type": "string",
      "pattern": "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$",
      "description": "OPCIONAL — omitida, o servidor gera um UUID. Repetir a mesma chave devolve o mesmo deploy_id em vez de criar outro."
    },
    "note": { "type": "string", "description": "Descrição livre (opcional)" }
  },
  "required": ["domain", "ref"],
  "additionalProperties": false
}
```

```jsonc
// output
{
  "deploy_id": "dpl_9f8e7d",
  "release_id": "20260807T143000Z-a1b2c3d",
  "status": "awaiting_upload",
  "ssh": {
    "host": "srv-12.cloudez.io",
    "port": 22,
    "user": "deploy",
    "path": "~/meusite.com.br/www/claude/releases/20260807T143000Z-a1b2c3d/"
  },
  "expires_at": "2026-08-07T15:30:00Z"
}
```

O bloco se chama `ssh` porque é isso que ele é: as coordenadas de uma sessão
ssh. Ele já se chamou `rsync`, quando o transporte era rsync — o nome ficou
errado quando o transporte virou `tar` sobre `ssh`, e nome errado em contrato
sobrevive por anos.

O `path` retornado **sempre termina em `/`** — significa "conteúdo de", não "o
diretório em si", e a diferença entre `dist/` e `dist` é uma fonte clássica de
deploy aninhado um nível errado.

---

### 3.7 `cloudez_finalize_deploy` — **mutating**

Ativa a release já sincronizada: troca o symlink `current` de forma atômica e
limpa releases antigas.

```jsonc
// input
{
  "type": "object",
  "properties": { "deploy_id": { "type": "string" } },
  "required": ["deploy_id"],
  "additionalProperties": false
}
```

```jsonc
// output — sucesso
{
  "deploy_id": "dpl_9f8e7d",
  "status": "succeeded",
  "release_id": "20260807T143000Z-a1b2c3d",
  "previous_release_id": "20260806T101500Z-0f9e8d7",
  "duration_ms": 4210
}
```

```jsonc
// output — falha (is_error na resposta MCP)
{
  "deploy_id": "dpl_9f8e7d",
  "status": "failed",
  "error": {
    "code": "activation_failed",
    "message": "Falha ao trocar o symlink current.",
    "logs": "ln: failed to create symbolic link: Permission denied\n"
  },
  "rollback_available": true
}
```

O campo `logs` é o que permite o Claude diagnosticar sem intervenção. Trunque no
**fim** se precisar (as últimas linhas são as que importam) e informe quantas
linhas foram cortadas.

**`previous_release_id` é omitido quando não há release anterior**, e não
enviado como `""`. É o caso do primeiro deploy de um site, então é comum, não
exceção. String vazia sobrevive a um teste de existência de campo e falha num
teste de valor; ausente, os dois concordam — e é a mesma regra que o resto do
contrato segue.

Dois campos opcionais aparecem quando a ativação mexeu no que já estava no
servidor, e os dois precisam ser repassados ao usuário:

| Campo | Quando | O que significa |
|---|---|---|
| `replaced_directory` | `current` era um diretório, não um symlink | O document root anterior foi **movido** para esse caminho, nunca apagado |
| `pruned_replaced` | havia diretórios substituídos antigos demais | Quantos foram apagados; os mais recentes ficam |

O segundo apaga conteúdo do usuário, e por isso é reportado em vez de
silencioso: acumular cópias inteiras do document root é ruim, mas apagá-las sem
avisar é pior.

`activation_failed` precisa significar que a release **não** entrou: o site
continua na versão anterior. Uma falha que deixa o site num estado intermediário
não pode compartilhar código com essa.

---

### 3.8 `cloudez_compose_build` — **mutating**

Constrói a imagem da release sincronizada: `docker compose build` no diretório
`releases/<release_id>`, **antes** da troca do symlink.

Existe pela **ordem**, não pela operação. Construir depois de ativar — como o
`compose_up` fazia sozinho — deixa o servidor num estado misto durante o build
inteiro: os arquivos novos já estão no disco e o container ainda serve os
antigos. Num projeto real isso são minutos. Pior: um build que quebra deixa esse
estado para trás, com a release ativada e o site na versão velha, e nada no
retorno desfaz isso. Construindo antes, o site segue coerente na versão anterior
enquanto o build roda, e **build quebrado é deploy que não começou**.

```jsonc
// input
{ "type": "object", "properties": { "deploy_id": { "type": "string" } },
  "required": ["deploy_id"], "additionalProperties": false }
```

```jsonc
// output — o estado do deploy acrescido de `compose.built`
{ "deploy_id": "dpl_9f8e7d", "status": "uploaded",
  "compose": { "project": "meusite-com-br", "built": true, "containers": [] } }
```

**Lê `releases/<release_id>`, nunca `current`.** Era a dependência do symlink que
obrigava a ordem antiga: com o caminho explícito, "construir antes" deixa de
significar "construir a release anterior", e a regra se inverte sem perder nada.

**Aceita `uploaded` e `succeeded`; recusa `awaiting_upload`** com
`upload_incomplete`. Sem o sync o diretório da release está vazio e não há
contexto de build. `succeeded` é aceito de propósito: reconstruir uma release já
ativa é exatamente o que o rollback em container precisa (§3.12).

**`compose_build_failed` é código separado de `compose_failed`**, e a divisão é
por quem consegue agir: falha de **build** é quase sempre do projeto (Dockerfile,
dependência, contexto), e falha de **up** é quase sempre do servidor (socket do
Docker, iptables, porta ocupada). Um código só mandaria procurar no lugar errado
metade das vezes. `compose_missing` e `docker_missing` significam aqui o mesmo
que no `compose_up`, e o `docker.sock` negado é diagnosticado nos dois — o build
também fala com o daemon.

**O passo é opcional.** Sem ele o `compose_up` reconstrói, o que continua
correto; só se perde a garantia acima. O que **não** é opcional é a
correspondência do nome de projeto: as duas metades derivam o `-p` do mesmo
domínio, e é por essa tag que o `up` encontra a imagem que o build produziu.

---

### 3.9 `cloudez_compose_up` — **mutating**

Sobe o container da release ativa: `docker compose up -d` no servidor. Só faz
sentido em site cuja aplicação roda em container.

Existe porque **publicar arquivos não põe uma aplicação em container no ar.** O
nginx da Cloudez encaminha `/` para uma porta local (127.0.0.1:3000 por padrão,
na `custom_port` do site) e
quem escuta ali é o container do usuário. Sem este passo o deploy termina em
`succeeded` e o site responde 502 no primeiro deploy, ou segue servindo a release
anterior nos seguintes — falha invisível para quem lê o JSON de retorno.

```jsonc
// input
{ "type": "object", "properties": { "deploy_id": { "type": "string" } },
  "required": ["deploy_id"], "additionalProperties": false }
```

```jsonc
// output — o estado do deploy acrescido de `compose`
{ "deploy_id": "dpl_9f8e7d", "status": "succeeded",
  "compose": {
    "project": "meusite-com-br",
    "containers": [
      { "name": "meusite-com-br-web-1", "state": "running",
        "ports": "127.0.0.1:3000->3000/tcp" }
    ]
  } }
```

**Roda depois do `finalize`, nunca antes.** É este passo que troca o container em
serviço, e invertida a ordem ele subiria a release anterior. Chamar com o deploy
em qualquer estado que não seja `succeeded` falha com `activation_incomplete`.

**`--build` só quando a imagem não foi construída antes.** Com
`compose.built: true` no estado — a marca que o `cloudez_compose_build` (§3.8)
deixa — o `up` sobe a imagem pronta e o container é recriado em segundos. Sem a
marca ele reconstrói, e o fallback não é cosmético: subir sem `--build` quando
nada foi construído reaproveitaria em silêncio a imagem do deploy **anterior**
nos projetos cujo compose fixa um `image:`, e o site serviria código velho com
JSON de sucesso.

**O nome do projeto vem do domínio, não do diretório**, e isso é correção de bug.
Sem `-p`, o Compose nomeia o projeto pelo diretório — que aqui é sempre `current`.
O daemon do Docker é um só para todos os sites da máquina, então dois sites deste
plugin no mesmo servidor virariam o mesmo projeto: o deploy de um derrubaria os
containers do outro, e o `--remove-orphans` terminaria o serviço. A consequência
aceita é sobrepor um `name:` que o usuário tenha no compose dele — perder o nome
escolhido é barato, derrubar o site de outra pessoa não é.

**De onde vem o domínio, já que esta tool recebe só `deploy_id`:** o
`cloudez_begin_deploy` persiste o `domain` no estado do deploy, e é dali que o
`compose_up` o lê — fonte autoritativa. Quando o estado não o tem (deploys cujo
`begin` foi o adaptador shell, que nunca gravou o campo, ou estados anteriores a
esta tool), o **primeiro segmento do `root`** serve de origem: o `cloudez-setup`
grava `root` como `~/<domain>/www/claude`, então esse segmento É o domínio e a
derivação produz o mesmo nome de projeto — não orfana um container já no ar.
Exigir o `domain` no estado com hard-fail foi uma regressão da porta shell→MCP: o
adaptador shell nunca precisou dele no estado porque lia do `.cloudez.yaml`.

**O `state` de cada container faz parte do retorno** porque `up` bem-sucedido não
é aplicação no ar: um container em `restarting` ou `exited` é deploy fracassado
com JSON de sucesso. Quem chama confere.

**`recreated` responde o que o `state` não responde:** algum container foi
trocado por este `up`? Quando o conteúdo publicado é idêntico ao do deploy
anterior, a imagem sai idêntica e o Compose corretamente não recria nada — e aí a
release ativa e o que o container serve passam a ser coisas diferentes, com
`state: running` afirmando o mesmo nos dois casos. Foi observado na prática: um
`up` devolvendo `running` para um container de seis horas antes, e provar isso
exigiu um `docker inspect` à mão, fora do fluxo. A medição é o conjunto de IDs de
`ps -q` antes e depois, agregado por projeto e não por container. O campo **some**
quando não foi possível medir — `false` afirmaria "não recriou" sem ter medido.

**O inventário de containers é separado da saída do build por um marcador**, não
pelo formato das linhas. Os dois saem no mesmo fluxo, e no build vai tudo que os
passos `RUN` imprimiram: um filtro por contagem de campos aceitaria qualquer
linha de log com o mesmo número de separadores, e ela viraria um container
fantasma com `state` inventado — que quem chama foi instruído a conferir. É a
mesma regra que vale para `CURRENT`, `MOVED` e `PRUNED` nos outros adaptadores.

Erros próprios, e a divisão é por **quem consegue agir**:

| Código | Causa | Quem resolve |
|---|---|---|
| `compose_missing` | a release não tem arquivo de Compose | o usuário — quase sempre publicou a saída de um build em vez do contexto |
| `docker_missing` | o servidor não tem `docker compose` nem `docker-compose` | a Cloudez |
| `compose_failed` + `docker.sock` negado | o usuário do site não está no grupo `docker` | a Cloudez |
| `compose_failed` + `iptables: No chain/target/match` | as chains do Docker sumiram do host; nenhuma porta publicada funciona | a Cloudez (`systemctl restart docker`) |

Os dois últimos vêm com `hint` explicando a ação, porque a mensagem crua do
Docker aponta para o lugar errado: permissão no socket parece problema de
arquivo, e o erro de iptables parece problema de rede do container. Nenhum dos
dois se resolve no projeto — e o contorno óbvio para o segundo, `network_mode:
host`, troca um defeito do servidor por um acoplamento permanente a ele.

**O rollback também precisa desta tool.** Ele troca o symlink e só; a imagem
continua sendo a do deploy anterior, e o site segue servindo o que se tentou tirar
do ar. Voltar uma release é `cloudez_rollback` seguido de `cloudez_compose_build`
e `cloudez_compose_up`, ambos com o `deploy_id` da release de destino.

---

### 3.10 `cloudez_get_deploy_status` — read-only

Consulta o estado de um deploy. Usado para polling quando `finalize` é
assíncrono, e para inspeção posterior.

```jsonc
// input
{ "type": "object", "properties": { "deploy_id": { "type": "string" } },
  "required": ["deploy_id"], "additionalProperties": false }
```

```jsonc
// output
{
  "deploy_id": "dpl_9f8e7d",
  "domain": "meusite.com.br",
  "status": "succeeded",   // awaiting_upload | finalizing | succeeded | failed | rolled_back
  "release_id": "20260807T143000Z-a1b2c3d",
  "ref": "a1b2c3d",
  "started_at": "2026-08-07T14:30:00Z",
  "finished_at": "2026-08-07T14:30:04Z",
  "logs": "..."
}
```

---

### 3.11 `cloudez_list_releases` — read-only

Necessária para o rollback ser dirigível pelo modelo (escolher para qual release
voltar) e para auditoria.

```jsonc
// input
{ "type": "object", "properties": { "domain": { "type": "string" } },
  "required": ["domain"], "additionalProperties": false }
```

```jsonc
// output
{
  "domain": "meusite.com.br",
  "releases": [
    { "release_id": "20260807T143000Z-a1b2c3d", "ref": "a1b2c3d",
      "deployed_at": "2026-08-07T14:30:04Z", "current": true },
    { "release_id": "20260806T101500Z-0f9e8d7", "ref": "0f9e8d7",
      "deployed_at": "2026-08-06T10:15:02Z", "current": false }
  ]
}
```

O servidor retém as releases mais recentes (o plugin em shell mantém 5). Quando
o alvo de um rollback já foi limpo, `rollback` precisa falhar com
`release_not_found` e listar o que sobrou — não escolher outra por conta.

---

### 3.12 `cloudez_rollback` — **mutating**

Volta o symlink `current` para uma release anterior.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "domain": { "type": "string" },
    "to_release_id": {
      "type": "string",
      "description": "Release alvo. Se omitido, volta para a imediatamente anterior."
    },
  },
  "required": ["domain"],
  "additionalProperties": false
}
```

```jsonc
// output
{ "domain": "meusite.com.br", "status": "rolled_back",
  "from_release_id": "20260807T143000Z-a1b2c3d",
  "to_release_id": "20260806T101500Z-0f9e8d7" }
```

**Sem `idempotency_key`, pela mesma razão da 3.4.** Esta tool ATRIBUI um valor —
o symlink `current` aponta para a release escolhida —, então repetir dá no mesmo.
A chave chegou a estar declarada no schema da tool com o handler a ignorando, que
é o pior dos dois mundos: pedia ao modelo um argumento que não fazia nada.

---

### 3.13 `cloudez_health_check` — read-only

Faz uma requisição HTTP ao site e devolve o que voltou. **Única tool que fala com
o site, e não com a API** — e a única que não manda credencial nenhuma: o que se
busca é o que qualquer visitante veria.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "domain": { "type": "string" },
    "path": { "type": "string", "description": "Padrão: /" },
    "expect_status": { "type": "number", "description": "Sem ele, 2xx e 3xx contam como saudável" },
    "attempts": { "type": "number", "description": "Padrão 3, máximo 10" }
  },
  "required": ["domain"],
  "additionalProperties": false
}
```

```jsonc
// output
{
  "url": "https://meusite.com.br/",
  "final_url": "https://meusite.com.br/home",   // só quando houve redirecionamento
  "healthy": true,
  "status_code": 200,
  "latency_ms": 214,
  "attempts": 1,
  "body_sha256": "9f86d0…",
  "body_excerpt": "<!doctype html>…"
}
```

**Um `200` não prova que o deploy surtiu efeito.** A release anterior também
responde `200`, e foi exatamente assim que um `app_root_path` errado passou por
deploy bem-sucedido enquanto o site servia o conteúdo antigo.

Por isso existe o `body_sha256`. Comparado com o de uma chamada **antes** do
deploy, ele é o único sinal independente de stack sobre a publicação ter mudado
alguma coisa. Não é prova — uma release pode legitimamente não alterar a página
consultada —, mas "o corpo é byte a byte o mesmo de antes" é um alerta que
nenhum código de status dá. O hash cobre o corpo **inteiro**, não o trecho: duas
páginas que só divergem depois do limite pareceriam iguais.

**Repete também em resposta ruim, não só em erro de conexão.** Um container
recém-recriado responde `502` pelo nginx da frente enquanto sobe — resposta HTTP
válida, e o caso exato para o qual a repetição existe. Parar no primeiro `502`
reportaria falha num deploy que deu certo. O `attempts` usado volta no retorno:
precisar de três diz algo sobre a aplicação que uma resposta imediata não diz.

**Tenta `https` e cai para `http`.** Site recém-criado pode ainda não ter
certificado, e falhar aí seria reportar como quebrado algo que só espera o TLS.

**Site fora do ar não é erro de tool.** É a resposta à pergunta, e devolvê-la
como resultado preserva a latência e as tentativas — que é o que distingue
"morreu" de "está subindo".

---

### 3.14 `cloudez_check_dns` — read-only

Compara para onde o domínio resolve com o servidor onde a Cloudez hospeda o site.

**Pergunta diferente do `cloudez_health_check`**, e é por isso que são duas tools:
aquele diz se o site **responde**; este diz se o **DNS do domínio já chegou aqui**.
As duas precisam de resposta ao fim de um deploy, e nenhuma implica a outra — o
site pode responder pelo endereço temporário com o DNS ainda apontando para outro
lugar, e pode apontar certo e mesmo assim estar fora do ar.

Existe porque o caso mais comum de "o deploy falhou" não é falha nenhuma: é o
primeiro deploy de um domínio recém-apontado, em que o endereço oficial ainda não
resolve e o usuário conclui que a publicação não funcionou.

```jsonc
// input
{
  "type": "object",
  "properties": { "domain": { "type": "string" } },
  "required": ["domain"],
  "additionalProperties": false
}
```

```jsonc
// output — o DNS já resolve para o servidor
{ "domain": "meusite.com.br",
  "points_to_server": true, "method": "dns",
  "dns": { "domain_ips": ["203.0.113.10"], "server_host": "srv-12.cloudez.io",
           "server_ips": ["203.0.113.10"], "matches": true } }
```

```jsonc
// output — atrás de CDN: o DNS não bate, o header confirma. Está tudo certo.
{ "domain": "meusite.com.br",
  "points_to_server": true, "method": "header",
  "dns": { "domain_ips": ["104.21.5.7"], "server_host": "srv-12.cloudez.io",
           "server_ips": ["203.0.113.10"], "matches": false },
  "header": { "present": true, "status_code": 200 },
  "note": "... a requisição chega à Cloudez mesmo assim ..." }
```

```jsonc
// output — nenhuma das duas confirmou
{ "domain": "meusite.com.br",
  "points_to_server": false, "method": "none",
  "dns": { "domain_ips": [], "server_host": "srv-12.cloudez.io",
           "server_ips": ["203.0.113.10"], "matches": false },
  "header": { "present": false, "error": "getaddrinfo ENOTFOUND" },
  "note": "... ou o registro ainda não foi criado, ou a propagação não terminou ..." }
```

**Duas checagens, e a segunda existe porque a primeira erra.** Comparar o A/AAAA do
domínio com o IP do servidor responde bem no caso simples e erra no comum: um
domínio atrás de Cloudflare resolve para o proxy, não para o servidor, e o site
funciona. Só com DNS isso é indistinguível de um domínio apontado para o lugar
errado.

O header `cez-verify` é servido pela Cloudez: recebê-lo prova que a requisição ao
domínio chegou nela, com CDN na frente ou sem. É consultado **só quando o DNS não
bate** — quando bate, não há o que desempatar e não se gasta uma requisição ao site
do usuário. Qualquer código de status serve; um 502 com o header presente é
justamente o caso que interessa distinguir.

O campo `method` diz qual das duas decidiu:

| `method` | O que significa |
|---|---|
| `dns` | O domínio resolve para o IP do servidor. Caminho direto |
| `header` | O DNS não bate, mas o domínio devolveu o `cez-verify`. Há CDN ou proxy na frente, e **está tudo certo** — não relate como problema de DNS |
| `none` | Nenhuma das duas confirmou. O `note` diz se é propagação pendente, apontamento errado, ou checagem que não conseguiu verificar |

**Dois campos de texto, e eles têm leitores diferentes.** O `note` é a explicação
inteira, para quem for diagnosticar. O `summary` é UMA linha, pronta para exibir ao
usuário no fim do deploy — vem daqui em vez de resumida por quem chama, para a
saída ser a mesma toda vez.

O `summary` nunca afirma mais do que se sabe: quando a checagem é que ficou cega
(o servidor do site não resolveu), ele diz isso, e não que o domínio está errado.

Resolve A e AAAA. Ausência de registro não é erro: "não resolve" é uma resposta, e
a mais comum logo depois de apontar um domínio novo — deixar a exceção subir faria
o deploy terminar em erro por causa de um DNS que ainda vai propagar.

---

### 3.15 `cloudez_panel_info` — **mutating**

Diz de que empresa é um endereço de painel e se ela abre cadastro. **Única tool
que responde antes de existir conta**, e a única que não manda token nenhum
contra a API da Cloudez.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "panel_host": { "type": "string", "description": "Host ou URL inteira do painel" }
  },
  "required": ["panel_host"],
  "additionalProperties": false
}
```

```jsonc
// output
{
  "panel_host": "cloud.configr.com",
  "company_name": "Configr",
  "company_code": "cfg",
  "register_enabled": true
}
```

**A Cloudez é white-label e nenhum domínio é presumido.** `cloud.configr.com` é o
painel da Configr, não "o" painel. Resolver o host antes de mandar o usuário para
uma página evita dois erros que só apareceriam tarde: o endereço digitado errado,
que hoje só falha no navegador, e o cadastro na empresa errada, que nasceria com
os sites fora de quem atendeu o usuário.

`register_enabled: false` é a revenda que desligou o cadastro self-service. Não é
erro: é a resposta, e o caminho passa a ser procurar a revenda.

**Esta tool nunca traz `trial_ia_plan_id`, mesmo quando a revenda tem plano
trial configurado.** Confirmado contra a API real: `company/theme` só devolve
esse campo para quem consulta **autenticado**, e `cloudez_panel_info` é
propositalmente anônimo — é a única tool que responde antes de existir conta.
Quem lê `trial_ia_plan_id` é `cloudez_get_trial_plan` (§3.19), que chama o
mesmo endpoint com o token da conta já autenticada. Foi exatamente essa
diferença que causou `trial_plan_unavailable` numa conta que tinha o plano
configurado: a primeira versão desta tool reaproveitava a consulta anônima do
cadastro para isso, e o campo nunca aparecia.

**Confirmado com sucesso, o `panel_host` sai gravado localmente** (o mesmo
arquivo que `cloudez_auth_status`, §3.1, devolve em `panel_host`), por isso a
tool é `mutating` e não `read-only`. Isto era uma tool separada,
`cloudez_remember_panel_host`, chamada explicitamente por quem invocava esta
— e na prática ela ficava de fora com frequência: é um passo sem efeito
visível na resposta do turno em que acontece, e esse é exatamente o tipo de
passo que instrução em prosa não garante de forma confiável. Virou efeito
colateral desta tool porque `cloudez_panel_info` já é chamada sempre que há um
`panel_host` para confirmar — remover o segundo passo remove a chance de
esquecê-lo. A gravação falhando não invalida a consulta: o `panel_host` já foi
confirmado contra a API antes de a gravação ser tentada.

**O arquivo é `~/.cloudez/panel_host`, irmão do `token`, mas sem `chmod 0600`**
— não é segredo, só o endereço do painel; a permissão default do diretório do
usuário já basta. Grava o host já normalizado (protocolo, caminho e
maiúsculas fora), nunca o que o usuário colou. Idempotente: gravar de novo
sobrescreve, nunca acumula — um `panel_host` novo (o usuário mudou de revenda,
ou corrigiu o que informou antes) simplesmente substitui o anterior. Não tem
relação com autenticação: o token continua exigindo o fluxo do
`/cloudez:login` inteiro; isto só evita repetir a pergunta do painel.

---

### 3.16 `cloudez_signup` — **mutating**

Cria a conta, guarda o token desta máquina e dispara o SMS de ativação.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "panel_host": { "type": "string" },
    "full_name": { "type": "string" },
    "email": { "type": "string" },
    "phone": { "type": "string", "description": "Com DDD; sem país, 10 ou 11 dígitos viram +55" }
  },
  "required": ["panel_host", "full_name", "email", "phone"],
  "additionalProperties": false
}
```

```jsonc
// output
{
  "account_created": true,
  "company_name": "Configr",
  "token_saved": true,
  "phone_id": 77,
  "code_sent": true,
  "warning": "…"        // só quando o SMS não pôde ser disparado
}
```

**Nem a senha nem o token aparecem no retorno.** A conta nasce com uma senha
aleatória gerada dentro da tool e descartada: ela não vai para o retorno, para
`hint` nem para log. Quem define a senha de verdade é o usuário, pelo e-mail que
o `cloudez_confirm_phone` manda ao fim da validação. Não existe, em momento
nenhum do fluxo, uma senha que o modelo conheça.

**O cadastro devolve JWT e o servidor autentica por `Token`.** São credenciais
diferentes; a troca acontece dentro desta tool e o resultado vai para o disco
pelo mesmo `saveToken` do `cloudez-login`.

**NÃO é idempotente, e `signup_incomplete` não é convite a repetir.** Esse código
significa que a conta **foi criada** e uma etapa posterior falhou. Uma segunda
chamada só devolveria `email_already_registered`. O caminho é recuperar a senha
pelo painel, não cadastrar de novo.

**`email_already_registered` é conta anterior, e a API o levanta antes de olhar o
telefone.** Nada foi criado e nenhum SMS saiu nessa tentativa. Essa conta pode
estar com o telefone pendente, e aí o painel trava na tela de validação antes de
liberar o token — o `hint` diz para avisar disso, porque sem token não há como
chamar `cloudez_confirm_phone` e resolver daqui.

**A unicidade do telefone só vale para número já verificado.** O filtro da API é
`is_verified=True`: cadastrar um número que existe em outra conta mas nunca foi
validado **passa**. `phone_already_used` só aparece contra número verificado.

**O país do telefone é validado antes do POST.** Fora de `+1`, `+44`, `+55` e
`+351` a Cloudez não envia SMS e não avisa: a conta nasceria esperando um código
que nunca foi mandado.

**`code_sent` diz que a Cloudez aceitou enviar**, não que o SMS chegou. A entrega
não é observável daqui.

---

### 3.17 `cloudez_resend_phone_code` — **mutating**

Reenvia o código de seis dígitos para o telefone da conta. Existe porque o
cadastro cria o telefone mas **não** dispara o SMS: na API, o sinal que enviaria
o código está desligado, e quem envia é este endpoint.

```jsonc
// input
{
  "type": "object",
  "properties": { "phone_id": { "type": "number" } },
  "required": ["phone_id"],
  "additionalProperties": false
}
```

```jsonc
// output
{ "phone_id": 77, "code_sent": true }
```

Idempotente: reenviar manda o mesmo código de novo, e não cria nada. Só tem
efeito enquanto o telefone não estiver verificado.

---

### 3.18 `cloudez_confirm_phone` — **mutating**

Valida o código do SMS, confere que o telefone ficou verificado e manda o e-mail
para o usuário definir a senha. É o passo que fecha o cadastro.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "phone_id": { "type": "number" },
    "code": { "type": "string", "description": "Seis dígitos, só números" }
  },
  "required": ["phone_id", "code"],
  "additionalProperties": false
}
```

```jsonc
// output
{
  "phone_verified": true,
  "password_email_sent": true,
  "warning": "…"        // só quando o e-mail de senha não saiu
}
```

**Relê antes de afirmar.** O `PATCH` da API responde `200` mesmo quando nada foi
verificado — basta o código vir vazio. Quem responde pelo `phone_verified` é a
releitura, e uma divergência vira `phone_not_verified`, não sucesso.

**Código errado é `sms_code_invalid`, e não erro de rede.** O `PATCH` leva um
campo só, então um `400` ali é sempre sobre o código. Sair como
`upstream_unavailable` faria o modelo repetir a mesma chamada errada.

**Falha no e-mail de senha não derruba a verificação.** Ela já aconteceu e não se
desfaz; virar erro apagaria um fato observado. O retorno traz
`password_email_sent: false` e o `warning` diz o que fazer.

---

### 3.19 `cloudez_get_trial_plan` — read-only

Diz se o painel informado tem um plano de teste grátis configurado, e devolve
o `trial_ia_plan_id` que `cloudez_setup_trial_cloud` (§3.20) exige como
entrada — **chame sempre antes dela**, nunca depois. Existe separada porque o
primeiro bug real do provisionamento (ver abaixo) só era diagnosticável lendo
código, quando a consulta ainda ficava embutida dentro da tool que provisiona.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "panel_host": { "type": "string", "description": "O mesmo panel_host passado a cloudez_signup" }
  },
  "required": ["panel_host"],
  "additionalProperties": false
}
```

```jsonc
// output
{
  "panel_host": "cloud.configr.com",
  "company_name": "Configr",
  "trial_ia_plan_id": 51799   // ausente quando a revenda não tem plano trial configurado
}
```

**Endpoint:** `GET /v3/company/theme/<panel_host>/`, o MESMO que
`cloudez_panel_info` (§3.15) usa, mas consultado **autenticado** — com
`Authorization: Token <token>`, não anônimo. Essa diferença é contrato, não
detalhe: `company/theme` só devolve `trial_ia_plan_id` para quem consulta com
token; a versão pública (`cloudez_panel_info`) nunca traz este campo.

**Bug real, encontrado testando contra a API de produção:** a primeira versão
de `cloudez_setup_trial_cloud` reaproveitava a consulta ANÔNIMA do cadastro (a
mesma que `cloudez_panel_info` faz) e por isso falhava com
`trial_plan_unavailable` mesmo em empresas com o plano configurado. Corrigido
passando o token da conta autenticada nessa chamada específica — e extraído
para esta tool própria depois, para o próximo diagnóstico não depender de ler
código de novo.

Não é fixo nem sobreponível por ambiente: é POR EMPRESA, lido de novo a cada
chamada.

**Só se chama dentro do cadastro de conta nova**, logo após `cloudez_signup`
ou `cloudez_confirm_phone` — nunca em resposta a um pedido solto de
"contratar um cloud" numa conta que já existe, mesmo sem cloud nenhuma: trial
é o que uma conta nova ganha de graça, não uma opção para quem já tem conta.
Ausência de `trial_ia_plan_id` (revenda sem plano trial configurado) e
"contratar cloud numa conta existente" levam ao mesmo lugar — não há tool: a
contratação é manual, em `<panel_host>/clouds/create` (ver §3.23).

---

### 3.20 `cloudez_setup_trial_cloud` — **mutating**

Contrata o cloud de teste gratuito da conta autenticada — o que antes era um
passo manual no painel ("iniciar o teste"). Só provisiona: não descobre nada
sozinha, nem sobre o painel nem sobre o plano. Chamada uma vez, logo depois de
`cloudez_get_trial_plan` (§3.19) devolver um `trial_ia_plan_id`, para a conta
recém-criada não ficar sem onde hospedar: sem nenhuma cloud, o
`/cloudez:setup` falharia num ponto bem menos claro que este.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "trial_ia_plan_id": { "type": "number", "description": "Id devolvido por cloudez_get_trial_plan" }
  },
  "required": ["trial_ia_plan_id"],
  "additionalProperties": false
}
```

```jsonc
// output
{
  "cloud_created": true,
  "cloud": { "id": 12, "fqdn": "srv-12.cloudez.io" }   // forma não confirmada, ver abaixo
}
```

**Endpoint:**

```
POST /v3/cloud/setup/
{ "plan_type": 51799, "lifespan_months": 1 }
```

Autenticado como o resto da API v3, com `Authorization: Token <token>` — **não**
o `jwt` do exemplo original desta rota, que era da troca de credencial do
cadastro. Confirmado contra a API real: o Token persistido funciona.

**`trial_ia_plan_id` PRECISA vir de `cloudez_get_trial_plan` (§3.19), nunca de
um número lembrado ou inventado por quem chama.** Não é só rigor: em
`cloudsetup.py` da API, `plan_type` aceita QUALQUER `PlanType` ativo da
empresa — pago inclusive, sem filtro nenhum de trial — e só vira trial porque
o id específico que `cloudez_get_trial_plan` devolve aponta para o
`cloud_size.is_trial=true` daquela empresa. Um id errado aqui não falha
bonito: contrata outra coisa, com fatura de verdade. Por isso esta tool não
resolve o id sozinha (evitaria repassar o valor por quem chama, mas abriria
essa mesma brecha) — só valida que é um inteiro positivo antes do POST, com
`invalid_argument` se não for.

A ausência de `trial_ia_plan_id` no retorno de `cloudez_get_trial_plan` — a
revenda não tem plano trial configurado — **não é algo que esta tool
detecta**: quem chama confere isso ANTES, olhando o retorno da §3.19, e nem
tenta o provisionamento se o campo não vier.

**O corpo de retorno não foi observado além do plano trial confirmado**, então
a tool não extrai campos nomeados — o que a API devolver sai inteiro em
`cloud`, e a tool não afirma que `id` ou `fqdn` vão sempre estar lá.

**Não é idempotente, e a tool não confere se a conta já tem cloud antes de
provisionar.** Chamar duas vezes cria duas clouds. A descrição da tool instrui
quem chama a rodá-la uma vez só, logo após o cadastro.

**Não é resposta para "contratar um cloud" fora do cadastro** — nem para uma
conta antiga sem cloud nenhuma. Trial é benefício de conta nova; contratação
paga não tem tool, de propósito (§3.23): é dinheiro de verdade e escolha de
plano do usuário, não algo que se decida por ele. A orientação nesse caso é
sempre a mesma, manual: abrir `<panel_host>/clouds/create` no painel.

**Provisionar demora — visto na prática, mais que os 10s padrão de qualquer
outra chamada.** Por isso o POST usa um timeout próprio, de 120s
(`CLOUDEZ_CLOUD_SETUP_TIMEOUT`, em segundos, se precisar mudar). Confirmado
contra a API de produção: um teste real abortou por timeout em 10s e a
Cloudez **criou o cloud mesmo assim** — o cliente só não recebeu a resposta a
tempo.

**Por isso uma falha DEPOIS do POST não é `upstream_unavailable` genérico.** O
resto do contrato marca timeout como `retryable: true` (seção 4), e aqui isso
seria perigoso: reportar retryable incentivaria repetir uma chamada que talvez
já tenha criado o cloud, resultando numa SEGUNDA. Qualquer falha depois de
enviado o POST vira `cloud_setup_unconfirmed`, com `retryable: false` e o
`hint` mandando conferir `cloudez_list_clouds` (§3.22) antes de decidir se
repete.

**Dois motivos de recusa (400) são reconhecidos por nome, em vez de virarem
`invalid_argument` cru.** Confirmado contra a API real — os dois vieram
**juntos**, num único 400, contra uma conta que já tinha cloud trial:

```jsonc
// corpo real observado
{
  "user": ["Limite de cloud alcançado, por favor contate o suporte"],
  "plan_type": ["user already has a free trial"]
}
```

| Campo do 400 | Vira | Por quê |
|---|---|---|
| `plan_type` contendo "already has a free trial" | `trial_already_exists` | a conta já tem o cloud; não é dado errado, é estado. Confira `cloudez_list_clouds` antes de qualquer coisa |
| `user` (sem o `plan_type` acima) | `cloud_limit_reached` | limite de clouds da conta; a própria Cloudez pede para contatar o suporte, não é algo que o plugin resolve |

`plan_type` é conferido primeiro — é o motivo mais específico dos dois, e é o
que apareceu junto com `user` no caso real. Sem casar nenhum dos dois padrões,
cai no `invalid_argument` genérico da seção 4, com o corpo inteiro no
`message` — não trava o reconhecimento, só deixa de nomear o motivo.

---

### 3.21 `cloudez_create_site` — **mutating**

Cria um site novo, sempre do tipo `claude` — o único que este plugin publica.
Existe porque, até esta tool, o `/cloudez:setup` só encontrava e configurava um
site que já existia; um domínio ausente da conta encerrava o comando com a
instrução de criar pelo painel primeiro. Verificado contra o código real da API
(`WebsiteCreateSerializer`), não contra um servidor de produção.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "cloud": { "type": "number", "description": "Id da cloud onde criar o site" },
    "domain": { "type": "string", "description": "FQDN da aplicação" }
  },
  "required": ["cloud", "domain"],
  "additionalProperties": false
}
```

```jsonc
// output — o mesmo shape de cloudez_get_site
{
  "domain": "meusite.com.br",
  "stack": "claude",
  "ssh": { "host": "srv-24923.cloudez.io", "port": 22, "user": "deploy" }
}
```

**Endpoint:**

```
POST /v3/website/
{ "cloud": 24923, "type": "claude", "values": [{ "slug": "domain", "value": "meusite.com.br" }] }
```

**`cloud` é o id inteiro de um `Node`** (o que `cloudez_list_clouds`, §3.22,
devolve), não um objeto. **`type` aceita o slug diretamente** — `"claude"` — a
API resolve pelo slug quando o valor não é numérico.

**O `domain` é único por CLOUD, não por conta.** O mesmo domínio pode existir
em duas clouds diferentes sem conflito — a checagem de unicidade da API é
contra os outros sites da mesma cloud. Um `invalid_argument` no domínio
significa "já existe um site com esse domínio NAQUELA cloud".

**Não há pré-checagem de tipo habilitado, ao contrário do engine de banco em
`cloudez_create_database`.** Uma versão anterior listava `GET /v3/website-type/`
antes do POST, no mesmo padrão do banco. Removida: essa rota pode OCULTAR um
tipo habilitado (campo `is_company_owner_only` da API, para tipos que não
devem aparecer na lista de escolha do painel mas continuam criáveis) sem que
isso signifique que a conta não pode criá-lo — `WebsiteCreateSerializer` nunca
aplica esse filtro, só a listagem aplica. Um pré-check contra a listagem dava
falso negativo justamente no caso de uso deste plugin: `claude` é candidato a
ficar oculto do painel de propósito, exatamente para não aparecer como opção
manual ali. Sem o pré-check, um tipo genuinamente não habilitado na empresa
chega como `invalid_argument` vindo direto da API (seção 4), só que depois do
POST em vez de antes.

**A Cloudez cria um usuário ssh automaticamente**, a menos que um `user` seja
passado no corpo — esta tool nunca passa. O site criado já sai com
`user.has_ssh: true`, então `cloudez_authorize_ssh_key` (§3.5) funciona nele
sem passo extra.

**`app_root_path` e `custom_port` não são passados na criação.** Ficam para o
`/cloudez:setup` configurar depois com `cloudez_configure_site` (§3.4), como já
faz para um site que já existia — não há necessidade de duplicar essa lógica
aqui.

**A tool relê pela mesma busca do `cloudez_get_site` depois do POST**, em vez
de confiar cegamente no 201: se o site criado não aparecer na busca pelo
domínio enviado, falha com `upstream_unavailable` em vez de afirmar sucesso.

**Criar o site demora mais que o timeout padrão (10s) — visto na prática, o
mesmo problema do `cloudez_setup_trial_cloud` (§3.20).** Por isso o POST usa o
mesmo timeout de 120s (`CLOUDEZ_WEBSITE_CREATE_TIMEOUT`, em segundos, se
precisar mudar), e uma falha DEPOIS de enviado o POST não vira
`upstream_unavailable` genérico: vira `site_creation_unconfirmed`, com
`retryable: false` e o `hint` mandando conferir `cloudez_get_site` com o
mesmo domínio antes de repetir — reportar retryable incentivaria uma segunda
tentativa que esbarraria no domínio já existir, um 400 confuso sem essa
distinção.

**Não é idempotente.** Chamar de novo com o mesmo domínio na mesma cloud falha
(domínio já existe); chamar com o mesmo domínio em OUTRA cloud cria um
segundo site. A tool não confere se já existe um site equivalente antes de
criar — quem chama confirma com o usuário antes de repetir.

---

### 3.22 `cloudez_list_clouds` — read-only

Lista as clouds (servidores, model `Node` na API) da conta autenticada, para
escolher o `cloud` de `cloudez_create_site` (§3.21).

```jsonc
// input
{ "type": "object", "properties": {}, "additionalProperties": false }
```

```jsonc
// output
{
  "clouds": [
    { "id": 24923, "name": "meu-servidor", "fqdn": "srv-24923.cloudez.io",
      "is_default": true, "websites_count": 2 }
  ],
  "truncated": "…"   // só quando há mais clouds do que a primeira página trouxe
}
```

**Endpoint:** `GET /v3/cloud/?page_size=20` — já escopado pela API ao usuário
autenticado (ou à empresa/time dele), sem precisar de `company_id`.

**Sem loop de paginação, ao contrário do `cloudez_list_sites` (§3.2).** Uma
conta tem tipicamente poucas clouds — o trial cria uma só —, então a página
máxima (20) cobre o caso comum. Havendo mais, `truncated` avisa em vez de
afirmar que a lista é completa.

**`name` é `nickname`, ou `name`, ou um placeholder** — a API pode não trazer
nenhum dos dois preenchido. Item sem `id` válido é descartado, pela mesma razão
de `cloudez_get_site`: não haveria como ser escolhido pelo usuário.

---

### 3.23 Fora do escopo, por enquanto

Uma tool saiu desta proposta junto com a feature correspondente do plugin. Fica
registrada para não ser redescoberta do zero:

- **`cloudez_get_logs`** — logs de app/erro/acesso do servidor. Útil para o
  modelo diagnosticar um deploy que subiu quebrado, mas nada no procedimento
  atual chama. Se voltar: `{domain, kind, lines, since}` → `{content,
  lines_returned, truncated}`.
- **Contratar um cloud pago** — decisão deliberada, não lacuna a preencher.
  É dinheiro de verdade saindo da conta do usuário, e a escolha de plano e o
  pagamento não são algo que se decida por ele. Toda orientação de contratação
  fora do trial de cadastro (§3.19, §3.20) aponta para o mesmo lugar, manual:
  `<panel_host>/clouds/create` — não o domínio raiz do painel, que não leva
  direto à contratação.

Hooks pós-deploy (restart, cache clear) também saíram: o `finalize` não roda mais
comando nenhum no servidor além da troca do symlink. Veja a pendência 2.

---

## 4. Modelo de erro

Erros de tool retornam com `is_error: true` no resultado MCP e um corpo
estruturado — o mesmo shape que os adaptadores em `bin/` já imprimem em stderr:

```jsonc
{
  "error": {
    "code": "site_not_found",
    "message": "Nenhum site com o domínio 'meusite.com.br' nesta conta.",
    "retryable": false,
    "hint": "Use cloudez_list_sites para ver os domínios disponíveis."
  }
}
```

**`site_not_found` significa "não está nesta conta", nunca "a rota não existe".**
A distinção importa porque as duas chegam como `404` e levam a conversas opostas:
a primeira manda o usuário conferir o painel, a segunda é bug do servidor MCP.
A Cloudez separa as duas no corpo — veja o apêndice A:

```
recurso inexistente ->  {"detail": "Not found."}     string, com ponto
rota inexistente    ->  {"detail": ["Not found"]}    lista, sem ponto
```

Uma rota errada precisa virar `upstream_unavailable` com um `hint` dizendo que
nada foi concluído sobre o domínio. Sem isso, um path errado no servidor reporta
que todos os sites do usuário sumiram da conta.

**Todo `400` de toda tool autenticada carrega o campo que a Cloudez recusou na
própria `message`.** A API segue o formato do DRF — `{"campo": ["mensagem"]}`
ou `{"non_field_errors": [...]}` —, e o cliente HTTP (`src/api.ts`) lê isso e
compõe `"A API da Cloudez respondeu 400 — campo: mensagem."` em vez do genérico
`"A API da Cloudez respondeu 400."` de antes. Encontrado testando
`cloudez_setup_trial_cloud` contra produção: uma conta que já tinha cloud trial
recebia `invalid_argument` sem dizer por quê, e a causa real (`plan_type: já
existe uma cloud trial nesta conta`, ou o que a API disser) ficava presa no
corpo, nunca chegando ao `message`. Vale para qualquer tool que escreva via
`apiPost`/`apiPatch`/`apiGet` — não é específico do cloud.

Códigos previstos:

| `code` | `retryable` | Significado |
|---|---|---|
| `invalid_argument` | não | a Cloudez recusou o corpo enviado; `message` traz o campo e a razão quando o 400 os nomeia |
| `site_not_found` | não | domínio não existe na conta |
| `not_authenticated` | não | nenhum token configurado na máquina |
| `token_invalid` | não | a Cloudez recusou o token (expirado ou revogado) |
| `deploy_not_found` | não | `deploy_id` inválido ou expirado |
| `upload_incomplete` | não | `finalize` chamado antes do transporte terminar |
| `activation_failed` | não | a troca do symlink falhou; o site segue na versão anterior |
| `release_not_found` | não | alvo de rollback não existe mais no servidor |
| `permission_denied` | não | token sem escopo para este site |
| `rate_limited` | sim | inclua `retry_after_seconds` |
| `upstream_unavailable` | sim | API da Cloudez fora |
| `panel_not_found` | não | o host informado não responde como painel da Cloudez |
| `register_disabled` | não | a revenda desligou o cadastro self-service |
| `email_already_registered` | não | já existe conta com esse e-mail nessa empresa |
| `phone_already_used` | não | telefone já verificado em outra conta da mesma empresa |
| `signup_rejected` | não | a Cloudez recusou um campo do cadastro; a conta NÃO foi criada |
| `signup_incomplete` | não | a conta FOI criada e uma etapa seguinte falhou; não repita |
| `already_authenticated` | não | já há token válido no disco; cadastrar sobrescreveria a conta atual |
| `sms_code_invalid` | não | os seis dígitos não batem com o que foi enviado |
| `phone_not_verified` | não | a API aceitou o código e a releitura diz que o telefone segue sem verificação |
| `cloud_setup_unconfirmed` | não | o POST de `cloudez_setup_trial_cloud` falhou depois de enviado; o cloud pode ter sido criado mesmo assim — confira `cloudez_list_clouds` antes de repetir |
| `trial_already_exists` | não | a conta já tem um cloud trial; confira `cloudez_list_clouds` em vez de criar outro |
| `cloud_limit_reached` | não | limite de clouds da conta; a Cloudez pede para contatar o suporte |
| `site_creation_unconfirmed` | não | o POST de `cloudez_create_site` falhou depois de enviado; o site pode ter sido criado mesmo assim — confira `cloudez_get_site` com o mesmo domínio antes de repetir |

O campo `retryable` importa: sem ele o modelo ou desiste de erro transitório ou
insiste em erro permanente.

---

## 5. Credenciais e escopo

O token da Cloudez **nunca** é argumento de tool e nunca entra no contexto do
modelo. Ele tem uma fonte da verdade:

```
~/.cloudez/token      # 0600, escrito por bin/cloudez-login
CLOUDEZ_TOKEN         # sobrepõe o arquivo (CI, headless)
```

**A única forma de obter o token é gerá-lo no painel da Cloudez** e informá-lo ao
`bin/cloudez-login`. Login por e-mail e senha foi explorado e **abandonado** — veja
o apêndice A, que guarda o que já foi descoberto da API para não ser redescoberto
do zero.

**O servidor MCP lê esse arquivo**, com a variável de ambiente como sobreposição —
a mesma precedência que os adaptadores em `bin/` aplicam. O plugin não repassa o
token ao servidor; os dois leem o mesmo lugar.

**O servidor lê o token a cada chamada, nunca na inicialização.** Um servidor
stdio é um processo longo: sobe junto com a sessão do Claude Code e só morre com
ela. Um token lido uma vez no boot congela o estado de autenticação pelo resto da
sessão — o usuário que rodar `cloudez-login` no meio dela continuaria vendo "não
autenticado", sem nenhuma pista do motivo. É um `readFile` de poucos bytes por
tool call, irrelevante perto do request HTTP que vem depois.

Pela mesma razão, **o token não é injetado via `env` no `.mcp.json`**: o ambiente
do subprocesso é fixado no spawn, o que recria o congelamento acima, e um
`CLOUDEZ_TOKEN` obsoleto no shell do usuário venceria o arquivo para sempre. Em
ambiente headless, prefira escrever o arquivo a exportar a variável.

**O token nunca é argumento de tool, nem opcionalmente.** Um servidor em stdio
não tem terminal de controle e portanto não pode coletar segredo nenhum; a
tentação é aceitá-lo como argumento, e isso o colocaria no transcript da sessão —
exatamente o que a exigência de TTY no `cloudez-login` existe para impedir. O
`cloudez-login` coleta, o MCP consome.

Quem escreve o arquivo é um comando que **exige TTY**: rodado pela tool Bash de um
agente, ele falha. Um token colado na conversa entra no transcript da sessão, que
o usuário não controla e não consegue limpar.

A verificação do token distingue três respostas. Isto é contrato, não detalhe de
implementação — o plugin depende dessa distinção:

| Resposta | Significado |
|---|---|
| 2xx | token válido |
| 401 / 403 | recusado; exige login novo |
| offline, 404, 5xx | inconclusivo; o plugin segue e reporta `verified: false` |

A chave SSH usada pelo transporte é do usuário, em `~/.ssh/`. O MCP nunca a vê.

---

## 6. Convenções

- **Versionamento:** mudança incompatível de schema vira tool nova
  (`cloudez_begin_deploy_v2`), não alteração silenciosa. Tool definitions ficam
  no contexto do modelo o tempo todo; quebrar o schema quebra sessões em curso.
- **Timestamps:** ISO 8601 em UTC, sempre com `Z`.
- **`release_id`:** `YYYYMMDDTHHMMSSZ-<sha7>` — ordenável lexicograficamente e
  rastreável ao commit.

---

## 7. Pendências

O que segue aberto, e o que a prática já respondeu. As respostas ficam aqui, e
não apagadas, porque uma pergunta removida volta a ser feita.

1. **`cloudez_find_compose` e `cloudez_list_local_ssh_keys` não têm seção aqui.**
   As duas existem, são chamadas pelos comandos, e entraram depois desta seção 3
   sem passar por ela. O `find_compose` ficou mais relevante agora que devolve as
   portas publicadas — é dele que sai a porta com que a `custom_port` da 3.4 tem
   de bater. Documentar as duas é dívida deste contrato, não do servidor.
2. **A Cloudez emite tokens com escopo?** Um token que alcance staging mas não
   produção daria à seção 5 um token por environment, limitando estrago. Hoje é um
   token de usuário, gerado no painel, com acesso a tudo que a conta acessa.
3. ~~**Os dados de SSH (`host`, `user`, `port`) e o `root` estão disponíveis na
   API, a partir do domínio?**~~ **Path confirmado:**
   `GET /v3/website/?domain=<domínio>` (sobreponível por `CLOUDEZ_API_SITE_PATH`,
   com `{domain}` interpolado).

   **Estrutura confirmada:** a configuração vem em `values`, como pares
   `slug`/`value`, e o domínio é o de `slug: "domain"` ou do atributo `domain`.
   O destino do ssh vem de `cloud.fqdn`, `user.username` e `user.has_ssh`.

   **O `PATCH` do site está confirmado** (seção 3.4): `values` com o par
   `slug`/`value`, tratado como **atualização** — mandar um item mexe só naquele
   slug.

   **As chaves autorizadas estão confirmadas** (seção 3.5):
   `PATCH /v3/cloud-user/<id>/` com `authorized_keys`, sem semântica de append.
   Sobreponível por `CLOUDEZ_API_CLOUD_USER_PATCH_PATH`. O `<id>` é o `user.id`
   que vem na resposta do *website*: são recursos de rotas diferentes, mas a
   mesma numeração — verificado contra a API real.

   **Este caminho já rodou de ponta a ponta contra a Cloudez**, com a chave indo
   parar na conta certa. Isso exercita, junto, o `cloudez_auth_status`, o
   `cloudez_get_site` e o mapeamento de `user`. O que ainda não foi exercitado
   contra a API real é o `cloudez_configure_site` e o deploy em si.

   **Faltam os slugs de `stack` e `current_release`**, hoje assumidos com esses
   nomes e não verificados. Campo não reconhecido some do retorno em vez de virar
   palpite, e nenhum dos dois bloqueia deploy: são informativos. O `root` saiu da
   lista de vez — vem sempre da config local.

   Também vale confirmar se `?domain=` é filtro exato ou parcial — a
   implementação assume o pior caso e confere por igualdade.
4. ~~**A Cloudez suporta o padrão de releases + symlink?**~~ **Sim.** Deploys e
   rollbacks rodaram contra servidor real, várias vezes. O `begin`/`finalize`
   continua em duas etapas, e o rollback troca o symlink.
5. ~~**Alguma stack precisa de restart/reload depois da troca do symlink?**~~
   **Container precisa; estático não.** É por isso que existe o
   `cloudez_compose_up` (seção 3.9) e não um campo no `finalize`: a troca do
   symlink diz ao Docker QUAL código usar, e subir o container é um passo
   próprio, com falhas próprias.
6. ~~**O `finalize` é síncrono?**~~ **É.** Nenhuma execução real precisou de
   polling. O `cloudez_get_deploy_status` segue especificado e não implementado,
   por não ter consumidor: o deploy termina dentro da própria chamada.
7. ~~**Quantas releases o servidor retém?**~~ **A retenção é nossa**, não do
   servidor: `KEEP_RELEASES = 5` no `finalize`, mais `KEEP_REPLACED = 2` para os
   diretórios `.current-<release_id>` postos de lado.

Restou aberta apenas a **1**. As demais foram respondidas por uso, não por
consulta — e é por isso que ficam registradas: quem ler o contrato sem esta
seção perguntaria de novo.

---

## Apêndice A — login por e-mail e senha (explorado e abandonado)

Esta rota foi implementada, testada contra a API real e **removida** em favor de
um token gerado no painel. O registro fica aqui porque o que foi descoberto custou
requisições e vale para quem retomar o assunto — inclusive para o servidor MCP, se
ele for autenticar usuários.

**`POST /auth/login/`** — o próprio endpoint declara o contrato em `OPTIONS`
(`{"name": "Custom Login"}`):

| Campo | Obrigatório |
|---|---|
| `password` | sim |
| `company` | sim — **UUID** da empresa |
| `email` | não (ou `username`) |

Nenhum campo de segundo fator, e nenhum endpoint dedicado a 2FA responde:
`/auth/2fa/`, `/auth/otp/`, `/auth/mfa/`, `/auth/two-factor/`, `/auth/login/2fa/` e
`/auth/token/` são todos 404. Um código de 2FA, se existir, entra por um caminho
que não achamos.

**O UUID da empresa** sai de `GET /v3/company/theme/<domínio-do-painel>/`, consulta
**aberta** (sem autenticação), no campo `code`:

```jsonc
// GET /v3/company/theme/cloud.configr.com/
{ "name": "Configr", "slug": "configr",
  "code": "5278e21e-e651-4883-8370-c61162f58d61",   // <- o company do login
  "brand_primary_color": "#6811BF", "logo_primary": "https://…", … }
```

O domínio é o do **painel**, não o do site publicado. Domínio desconhecido responde
`404 {"detail":"Not found."}` — note que rota inexistente responde
`{"detail": ["Not found"]}`, em lista e sem ponto: dá para distinguir os dois.

**O que ficou sem confirmação:** onde o token aparece na resposta `200` do login.
Só uma credencial válida responde isso, e a implementação removida tentava `token`,
`key` e `auth_token`. Uma tentativa com senha deliberadamente errada confirmou o
resto do caminho: a API aceitou o payload e respondeu
`400 {"detail": "Unable to log in with provided credentials."}`.

**Por que foi abandonado:** um login interativo exige TTY, e a tool Bash do agente
não tem terminal de controle (`/dev/tty` responde `Device not configured`). Isso
valeria a pena se a alternativa fosse pior — mas gerar um token no painel resolve
o mesmo problema sem a senha do usuário passar por lugar nenhum, e o 2FA, que só
funciona com terminal, deixa de ser um problema.
