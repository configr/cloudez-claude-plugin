# Contrato das tools MCP — Cloudez

Especificação da interface que o servidor MCP (repositório separado) deve expor
para este plugin. Este documento é a fonte da verdade do contrato: o plugin é
escrito contra ele, e o servidor MCP o implementa.

Status: **proposta**. As seções marcadas com ⚠️ dependem de confirmação sobre o
que a API da Cloudez suporta hoje.

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
`cmd/sync/`. Isso define a fronteira:

| Camada | Quem faz | O quê |
|---|---|---|
| **Data plane** | `cmd/sync` (Go), no host do usuário | mover os bytes para o servidor |
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
3. tar -c | ssh tar -x  para o release dir      (cmd/sync, local)
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
  "verified": true                   // false quando a API não pôde confirmar
}
```

A distinção entre `authenticated` e `verified` é a mesma da tabela na seção 5, e
é contrato: `authenticated: true, verified: false` significa "há um token e a
Cloudez não desmentiu" — offline ou API fora. Reportar `authenticated: false` aí
mandaria o usuário refazer um login que já estava correto.

Quando não há token, o retorno traz um `hint` mandando pedir ao usuário que rode
`! cloudez-login` no terminal. O modelo **não** deve pedir o token na conversa.

---

### 3.2 `cloudez_list_sites` — read-only

Lista os sites/aplicações da conta.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "query": { "type": "string", "description": "Filtro por nome ou domínio (opcional)" }
  },
  "additionalProperties": false
}
```

```jsonc
// output
{
  "sites": [
    {
      "domain": "meusite.com.br",
      "name": "meusite",
      "stack": "static",             // "static" | "php" | "node" | ...
      "current_release": "20260807T143000Z-a1b2c3d"
    }
  ]
}
```

---

### 3.3 `cloudez_get_site` — read-only

Detalhes de um site, incluindo o alvo de sincronização. Tem duas funções:

1. **Confirmar que o domínio existe na conta**, antes de o `/cloudez:setup`
   escrever um `.cloudez.yaml` para ele. É o que impede um domínio com typo de
   virar uma config que só falha no deploy, longe da causa. Esta é a razão de o
   setup exigir autenticação: sem token não há como saber se o site existe.
2. **Fornecer o destino ssh a cada deploy.** O bloco `ssh` saiu do
   `.cloudez.yaml`: quem publica busca host e usuário aqui e os passa aos
   adaptadores em `CLOUDEZ_SSH_HOST`, `CLOUDEZ_SSH_USER` e `CLOUDEZ_SSH_PORT`.
   Uma cópia do host num arquivo versionado envelhece — se a Cloudez mover o
   site de servidor, o valor escrito segue apontando para o antigo e o deploy
   vai para o lugar errado sem reclamar.

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
    "stack": "static",
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

### 3.4 `cloudez_set_app_root_path` — **mutating**

Altera o `app_root_path` do site: o diretório que o servidor web entrega,
relativo a `~/<domain>/www`.

Existe por causa de uma falha silenciosa. O deploy publica em `<root>/current`, e
com o `root` que o `cloudez-setup` grava isso é `claude/current`. Se o
`app_root_path` apontar para outro lugar, o deploy roda inteiro, sem erro nenhum,
e o site continua servindo o conteúdo antigo — o usuário só descobre comparando o
que publicou com o que o navegador mostra.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "domain": { "type": "string" },
    "app_root_path": { "type": "string", "description": "Relativo a ~/<domain>/www. Normalmente 'claude/current'." }
  },
  "required": ["domain", "app_root_path"],
  "additionalProperties": false
}
```

```jsonc
// output
{ "domain": "meusite.com.br", "app_root_path": "claude/current",
  "previous_app_root_path": "public_html", "changed": true }
```

`changed: false` significa que o valor já estava correto e nenhuma escrita foi
feita.

**Sem `idempotency_key`, e a exceção é deliberada.** A regra da seção 2 existe
porque as outras mutating criam recursos, e repetir cria dois. Esta atribui um
valor fixo: repetir dá no mesmo. A chave existiria só para cumprir formalidade.

**O corpo do `PATCH` repete a forma em que a configuração é lida:**

```jsonc
PATCH /v3/website/<id>/
{ "values": [ { "slug": "app_root_path", "value": "claude/current" } ] }
```

**A tool relê o site depois de escrever**, e a releitura confere três coisas:

1. **o valor mudou de fato.** Uma escrita que se declara bem-sucedida sem ter
   efeito é pior do que uma que falha: manda o usuário fazer deploy confiante num
   document root errado, e o sintoma que volta é "publiquei e o site não mudou",
   o mais difícil de ligar à causa;
2. **nenhum outro slug sumiu.** Sob a semântica confirmada isso nunca dispara —
   e é por isso que fica: se um dia disparar, a API mudou de comportamento, e o
   sintoma seria a configuração do site apagada em silêncio por um comando que só
   queria ajustar o document root;
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
      "description": "UUID gerado pelo cliente. Repetir a chave devolve o mesmo deploy_id em vez de criar outro."
    },
    "note": { "type": "string", "description": "Descrição livre (opcional)" }
  },
  "required": ["domain", "ref", "idempotency_key"],
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

`activation_failed` precisa significar que a release **não** entrou: o site
continua na versão anterior. Uma falha que deixa o site num estado intermediário
não pode compartilhar código com essa.

---

### 3.8 `cloudez_get_deploy_status` — read-only

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

### 3.9 `cloudez_list_releases` — read-only

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

### 3.10 `cloudez_rollback` — **mutating**

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
    "idempotency_key": { "type": "string" }
  },
  "required": ["domain", "idempotency_key"],
  "additionalProperties": false
}
```

```jsonc
// output
{ "domain": "meusite.com.br", "status": "rolled_back",
  "from_release_id": "20260807T143000Z-a1b2c3d",
  "to_release_id": "20260806T101500Z-0f9e8d7" }
```

---

### 3.11 Fora do escopo, por enquanto

Duas tools saíram desta proposta junto com as features correspondentes do
plugin. Ficam registradas para não serem redescobertas do zero:

- **`cloudez_health_check`** — verificação HTTP pós-deploy. O plugin não faz mais
  health check (nem rollback automático a partir dele), então especificar a tool
  seria pedir trabalho para ninguém consumir. Se voltar, volta como read-only:
  `{domain, path, expect_status}` → `{healthy, status_code, latency_ms,
  body_excerpt}`.
- **`cloudez_get_logs`** — logs de app/erro/acesso do servidor. Útil para o
  modelo diagnosticar um deploy que subiu quebrado, mas nada no procedimento
  atual chama. Se voltar: `{domain, kind, lines, since}` → `{content,
  lines_returned, truncated}`.

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

Códigos previstos:

| `code` | `retryable` | Significado |
|---|---|---|
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

## 7. ⚠️ Pendências para o time do MCP

Confirmar antes de implementar:

1. **A Cloudez emite tokens com escopo?** Um token que alcance staging mas não
   produção daria à seção 5 um token por environment, limitando estrago. Hoje é um
   token de usuário, gerado no painel, com acesso a tudo que a conta acessa.
2. ~~**Os dados de SSH (`host`, `user`, `port`) e o `root` estão disponíveis na
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
   contra a API real é o `cloudez_set_app_root_path` e o deploy em si.

   **Faltam os slugs de `stack` e `current_release`**, hoje assumidos com esses
   nomes e não verificados. Campo não reconhecido some do retorno em vez de virar
   palpite, e nenhum dos dois bloqueia deploy: são informativos. O `root` saiu da
   lista de vez — vem sempre da config local.

   Também vale confirmar se `?domain=` é filtro exato ou parcial — a
   implementação assume o pior caso e confere por igualdade.
3. **A Cloudez suporta o padrão de releases + symlink?** Se o deploy for direto
   no document root (sem `releases/` e `current`), `begin`/`finalize` colapsam em
   uma tool só `cloudez_deploy(domain, ref)` e o rollback precisa de outra
   estratégia (backup do diretório anterior, ou re-deploy do SHA antigo).
4. **Alguma stack precisa de restart/reload depois da troca do symlink?** Para
   site estático, não — e é por isso que os hooks saíram do plugin. Se `php` ou
   `node` precisarem, isso vira uma tool própria (`cloudez_restart(domain)`), não
   um campo de configuração no `finalize`.
5. **O `finalize` é síncrono?** Se demorar mais que ~30s, precisa ser assíncrono
   com polling via `cloudez_get_deploy_status`.
6. **Quantas releases o servidor retém?** O plugin em shell mantém 5. Se o
   servidor tiver limite próprio, `list_releases` precisa refleti-lo.

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
