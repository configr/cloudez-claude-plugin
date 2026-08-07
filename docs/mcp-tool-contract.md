# Contrato das tools MCP — Cloudez

Especificação da interface que o servidor MCP (repositório separado) deve expor
para este plugin. Este documento é a fonte da verdade do contrato: o plugin é
escrito contra ele, e o servidor MCP o implementa.

Status: **proposta**. As seções marcadas com ⚠️ dependem de confirmação sobre o
que a API da Cloudez suporta hoje.

---

## 1. O split: control plane vs data plane

O transporte dos arquivos é `rsync`/`scp`. Isso define a fronteira:

| Camada | Quem faz | O quê |
|---|---|---|
| **Data plane** | `rsync` via Bash, no host do usuário | mover os bytes do build para o servidor |
| **Control plane** | tools MCP | descobrir o destino, registrar o deploy, ativar a release, ler logs, rollback |

**O MCP nunca transporta arquivos.** Ele diz *para onde* enviar e *o que fazer
depois que chegou*. Duas razões: conteúdo de arquivo em argumento de tool passa
pelo contexto do modelo (caro, lento, trunca), e `rsync` já resolve delta,
retomada e permissões melhor do que qualquer coisa que reimplementaríamos.

Fluxo completo de um deploy:

```
1. Skill roda build local                          (Bash)
2. cloudez_begin_deploy(site_id, ref)  ───────────► MCP
   └─ retorna deploy_id + destino rsync
3. rsync -az ./dist/ user@host:/path/releases/xyz/ (Bash)
4. cloudez_finalize_deploy(deploy_id)  ───────────► MCP
   └─ troca symlink, restart, cache clear
5. cloudez_health_check(site_id)       ───────────► MCP
   └─ falhou? cloudez_rollback(site_id)
```

---

## 2. Princípios de design

Estas regras existem porque o consumidor é um modelo de linguagem, não um script.

**Read-only e mutating são conjuntos separados.** Tools sem efeito colateral
(`list`, `get`, `status`, `logs`, `health_check`) podem ir para o allowlist do
`settings.json` do usuário e nunca gerar prompt de permissão. As mutating
(`begin`, `finalize`, `rollback`, `restart`) sempre pedem confirmação. Não
misture as duas responsabilidades numa tool só — uma tool que "lista e opcionalmente
recria" força o usuário a aprovar toda listagem.

**Toda tool mutating aceita `idempotency_key`.** Modelos repetem chamadas: por
timeout aparente, por retry após erro de rede, por reinterpretar o próprio
histórico. Sem chave de idempotência isso vira deploy duplicado.

**O retorno é acionável, não um booleano.** `{"ok": true}` cega o modelo. Todo
retorno de erro deve conter o suficiente para o Claude corrigir e tentar de novo
sozinho — logs de build, stderr do comando, código de saída. É isso que fecha o
loop autônomo.

**A `description` diz *quando* chamar, não só o que faz.** Modelos recentes são
conservadores em disparar tools. `"Cria um deploy"` rende bem menos que
`"Chame após o build passar, para registrar a release e obter o destino rsync.
Não chame se o working tree tiver alterações não commitadas."`

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
      "site_id": "site_a1b2c3",
      "name": "meusite",
      "domain": "meusite.com.br",
      "environment": "production",   // "production" | "staging"
      "stack": "static",             // "static" | "php" | "node" | ...
      "current_release": "20260807T143000Z-a1b2c3d"
    }
  ]
}
```

---

### 3.2 `cloudez_get_site` — read-only

Detalhes de um site, incluindo o alvo de sincronização.

```jsonc
// input
{ "type": "object", "properties": { "site_id": { "type": "string" } },
  "required": ["site_id"], "additionalProperties": false }
```

```jsonc
// output
{
  "site_id": "site_a1b2c3",
  "name": "meusite",
  "domain": "meusite.com.br",
  "environment": "production",
  "stack": "static",
  "ssh": {
    "host": "srv-12.cloudez.io",
    "port": 22,
    "user": "deploy"
  },
  "paths": {
    "root": "/home/deploy/apps/meusite",
    "current": "/home/deploy/apps/meusite/current",
    "releases": "/home/deploy/apps/meusite/releases",
    "shared": "/home/deploy/apps/meusite/shared"
  },
  "current_release": "20260807T143000Z-a1b2c3d",
  "health_url": "https://meusite.com.br/"
}
```

> Nenhuma credencial no retorno. A chave SSH vive no ambiente do usuário
> (`~/.ssh/`), não passa pelo MCP nem pelo contexto do modelo.

---

### 3.3 `cloudez_begin_deploy` — **mutating**

Registra a intenção de deploy e devolve o diretório de release onde o `rsync`
deve escrever. Não move nenhum byte.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "site_id": { "type": "string" },
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
  "required": ["site_id", "ref", "idempotency_key"],
  "additionalProperties": false
}
```

```jsonc
// output
{
  "deploy_id": "dpl_9f8e7d",
  "release_id": "20260807T143000Z-a1b2c3d",
  "status": "awaiting_upload",
  "rsync": {
    "host": "srv-12.cloudez.io",
    "port": 22,
    "user": "deploy",
    "path": "/home/deploy/apps/meusite/releases/20260807T143000Z-a1b2c3d/"
  },
  "expires_at": "2026-08-07T15:30:00Z"
}
```

O `path` retornado **sempre termina em `/`** — o `rsync` trata isso como
"conteúdo de", não "o diretório em si", e a diferença entre `dist/` e `dist`
é uma fonte clássica de deploy aninhado errado.

---

### 3.4 `cloudez_finalize_deploy` — **mutating**

Ativa a release já sincronizada: troca o symlink `current`, roda os hooks
pós-deploy (restart, cache clear, migrations) e retorna o resultado.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "deploy_id": { "type": "string" },
    "run_hooks": { "type": "boolean", "default": true }
  },
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
  "url": "https://meusite.com.br/",
  "duration_ms": 4210,
  "hooks": [
    { "name": "restart", "exit_code": 0, "output": "service reloaded" }
  ]
}
```

```jsonc
// output — falha (ainda HTTP 200 do ponto de vista da tool; is_error na resposta MCP)
{
  "deploy_id": "dpl_9f8e7d",
  "status": "failed",
  "error": {
    "code": "hook_failed",
    "message": "post-deploy hook 'restart' exited with code 1",
    "hook": "restart",
    "exit_code": 1,
    "logs": "nginx: [emerg] invalid parameter in /etc/nginx/sites/meusite.conf:12\n"
  },
  "rollback_available": true
}
```

O campo `logs` é o que permite o Claude diagnosticar e corrigir sem
intervenção. Trunque no **fim** se precisar (as últimas linhas são as que
importam) e informe quantas linhas foram cortadas.

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
  "site_id": "site_a1b2c3",
  "status": "succeeded",   // awaiting_upload | finalizing | succeeded | failed | rolled_back
  "release_id": "20260807T143000Z-a1b2c3d",
  "ref": "a1b2c3d",
  "started_at": "2026-08-07T14:30:00Z",
  "finished_at": "2026-08-07T14:30:04Z",
  "logs": "..."
}
```

---

### 3.6 `cloudez_health_check` — read-only

Verificação HTTP do site após o deploy. Read-only porque não altera estado.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "site_id": { "type": "string" },
    "path": { "type": "string", "default": "/" },
    "expect_status": { "type": "integer", "default": 200 },
    "timeout_ms": { "type": "integer", "default": 10000 }
  },
  "required": ["site_id"],
  "additionalProperties": false
}
```

```jsonc
// output
{
  "healthy": false,
  "url": "https://meusite.com.br/",
  "status_code": 502,
  "latency_ms": 1840,
  "body_excerpt": "502 Bad Gateway"
}
```

---

### 3.7 `cloudez_get_logs` — read-only

```jsonc
// input
{
  "type": "object",
  "properties": {
    "site_id": { "type": "string" },
    "kind": { "type": "string", "enum": ["app", "error", "access"], "default": "error" },
    "lines": { "type": "integer", "default": 100, "maximum": 1000 },
    "since": { "type": "string", "description": "ISO 8601 (opcional)" }
  },
  "required": ["site_id"],
  "additionalProperties": false
}
```

```jsonc
// output
{ "site_id": "site_a1b2c3", "kind": "error", "lines_returned": 100, "truncated": true,
  "content": "..." }
```

---

### 3.8 `cloudez_rollback` — **mutating**

Volta o symlink `current` para uma release anterior.

```jsonc
// input
{
  "type": "object",
  "properties": {
    "site_id": { "type": "string" },
    "to_release_id": {
      "type": "string",
      "description": "Release alvo. Se omitido, volta para a imediatamente anterior."
    },
    "idempotency_key": { "type": "string" }
  },
  "required": ["site_id", "idempotency_key"],
  "additionalProperties": false
}
```

```jsonc
// output
{ "site_id": "site_a1b2c3", "status": "rolled_back",
  "from_release_id": "20260807T143000Z-a1b2c3d",
  "to_release_id": "20260806T101500Z-0f9e8d7",
  "url": "https://meusite.com.br/" }
```

---

### 3.9 `cloudez_list_releases` — read-only

Necessária para o rollback ser dirigível pelo modelo (escolher para qual
release voltar) e para auditoria.

```jsonc
// output
{
  "site_id": "site_a1b2c3",
  "releases": [
    { "release_id": "20260807T143000Z-a1b2c3d", "ref": "a1b2c3d",
      "deployed_at": "2026-08-07T14:30:04Z", "current": true },
    { "release_id": "20260806T101500Z-0f9e8d7", "ref": "0f9e8d7",
      "deployed_at": "2026-08-06T10:15:02Z", "current": false }
  ]
}
```

---

## 4. Modelo de erro

Erros de tool retornam com `is_error: true` no resultado MCP e um corpo
estruturado:

```jsonc
{
  "error": {
    "code": "site_not_found",
    "message": "Nenhum site com id 'site_xxx' nesta conta.",
    "retryable": false,
    "hint": "Use cloudez_list_sites para obter os ids válidos."
  }
}
```

Códigos previstos:

| `code` | `retryable` | Significado |
|---|---|---|
| `site_not_found` | não | id inválido |
| `deploy_not_found` | não | `deploy_id` inválido ou expirado |
| `upload_incomplete` | não | `finalize` chamado antes do rsync terminar |
| `hook_failed` | não | hook pós-deploy falhou — veja `logs` |
| `permission_denied` | não | token sem escopo para este site/ambiente |
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
  anula todo o resto dos guard-rails.
- A chave SSH usada pelo `rsync` é do usuário, em `~/.ssh/`. O MCP nunca a vê.

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

1. **A Cloudez suporta o padrão de releases + symlink?** Se o deploy for
   direto no document root (sem `releases/` e `current`), `begin`/`finalize`
   colapsam em uma tool só `cloudez_deploy(site_id, ref)` e o rollback precisa
   de outra estratégia (backup do diretório anterior, ou re-deploy do SHA
   antigo a partir do git).
2. **Existe hook pós-deploy configurável** (restart/cache clear) ou isso precisa
   virar tool separada `cloudez_restart(site_id)`?
3. **O `finalize` é síncrono?** Se demorar mais que ~30s, precisa ser assíncrono
   com polling via `cloudez_get_deploy_status`.
4. **Os dados de SSH (`host`, `user`, `port`, `paths`) estão disponíveis na API**
   ou o plugin precisa recebê-los por configuração local?
5. **Há limite de releases retidas** no servidor? Se sim, `list_releases`
   precisa refletir isso e `rollback` precisa falhar com erro claro quando o
   alvo já foi limpo.
