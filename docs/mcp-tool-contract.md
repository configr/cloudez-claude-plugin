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

### 3.1 `cloudez_list_sites` — read-only

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

### 3.2 `cloudez_get_site` — read-only

Detalhes de um site, incluindo o alvo de sincronização. **É a tool que aposenta o
bloco `ssh` da config local** (veja o roadmap no README): hoje host, user e port
são digitados à mão no `.cloudez.yaml`, e a intenção é buscá-los aqui pelo
domínio.

```jsonc
// input
{ "type": "object", "properties": { "domain": { "type": "string" } },
  "required": ["domain"], "additionalProperties": false }
```

```jsonc
// output
{
  "domain": "meusite.com.br",
  "name": "meusite",
  "stack": "static",
  "ssh": {
    "host": "srv-12.cloudez.io",
    "port": 22,
    "user": "deploy"
  },
  "root": "~/meusite.com.br/www",
  "current_release": "20260807T143000Z-a1b2c3d"
}
```

> Nenhuma credencial no retorno. A chave SSH vive no ambiente do usuário
> (`~/.ssh/`), não passa pelo MCP nem pelo contexto do modelo.

O `root` é o diretório que contém `releases/`, `current` e `shared/` — o
document root do site precisa apontar para `<root>/current`. Um `~/` inicial
significa "relativo ao `$HOME` do usuário ssh"; o plugin o remove antes de
montar comandos remotos, porque dentro de aspas simples o shell do servidor não
expande til. Quando o `.cloudez.yaml` define `root`, o valor local vence.

---

### 3.3 `cloudez_begin_deploy` — **mutating**

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
    "path": "~/meusite.com.br/www/releases/20260807T143000Z-a1b2c3d/"
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

### 3.4 `cloudez_finalize_deploy` — **mutating**

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

### 3.5 `cloudez_get_deploy_status` — read-only

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

### 3.6 `cloudez_list_releases` — read-only

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

### 3.7 `cloudez_rollback` — **mutating**

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

### 3.8 Fora do escopo, por enquanto

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

Códigos previstos:

| `code` | `retryable` | Significado |
|---|---|---|
| `site_not_found` | não | domínio não existe na conta |
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

- O token da Cloudez vive em **variável de ambiente do processo MCP**, nunca em
  argumento de tool, nunca no contexto do modelo.
- Tokens **separados por ambiente**. `CLOUDEZ_TOKEN_STAGING` e
  `CLOUDEZ_TOKEN_PRODUCTION`. Um token de staging que consegue derrubar produção
  apaga a separação entre os dois.
- A chave SSH usada pelo transporte é do usuário, em `~/.ssh/`. O MCP nunca a vê.

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

1. **Os dados de SSH (`host`, `user`, `port`) e o `root` estão disponíveis na
   API, a partir do domínio?** É a pendência que mais importa: hoje eles são
   digitados à mão em cada `.cloudez.yaml`, e `cloudez_get_site` é o que elimina
   isso.
2. **A Cloudez suporta o padrão de releases + symlink?** Se o deploy for direto
   no document root (sem `releases/` e `current`), `begin`/`finalize` colapsam em
   uma tool só `cloudez_deploy(domain, ref)` e o rollback precisa de outra
   estratégia (backup do diretório anterior, ou re-deploy do SHA antigo).
3. **Alguma stack precisa de restart/reload depois da troca do symlink?** Para
   site estático, não — e é por isso que os hooks saíram do plugin. Se `php` ou
   `node` precisarem, isso vira uma tool própria (`cloudez_restart(domain)`), não
   um campo de configuração no `finalize`.
4. **O `finalize` é síncrono?** Se demorar mais que ~30s, precisa ser assíncrono
   com polling via `cloudez_get_deploy_status`.
5. **Quantas releases o servidor retém?** O plugin em shell mantém 5. Se o
   servidor tiver limite próprio, `list_releases` precisa refleti-lo.
