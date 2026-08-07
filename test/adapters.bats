#!/usr/bin/env bats
# Adaptadores bin/cloudez-*: config, contrato de erro e maquina de estado.

load helpers/setup

setup() { make_project; }

# ------------------------------------------------------------------ config --

@test "config ausente: config_not_found" {
  rm .cloudez.yaml
  run cloudez-health-check staging
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "config_not_found" ]
}

@test "extensao .yml tambem e aceita" {
  mv .cloudez.yaml .cloudez.yml
  run cloudez-health-check staging
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .healthy)" = "true" ]
}

@test "ambiente inexistente: site_not_found com a lista de ambientes" {
  run cloudez-health-check producao
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "site_not_found" ]
  [[ "$(jq_field "$output" .error.hint)" == *staging* ]]
}

# REGRESSAO: `die` dentro de config_json rodava numa substituicao de comando
# aninhada e o `exit 1` nao propagava, entao o script seguia com a config vazia
# e emitia um segundo erro (site_not_found) contradizendo o primeiro.
@test "YAML invalido emite exatamente um erro" {
  printf 'sites:\n  staging:\n   quebrado\n    indent: [\n' > .cloudez.yaml
  run cloudez-health-check staging
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -s 'length')" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "config_invalid" ]
}

# REGRESSAO: `die` escrevia em stdout; como site_config e chamada dentro de
# $( ), o JSON de erro era capturado na variavel e nunca chegava ao usuario.
@test "erro vai para stderr, nao para stdout" {
  run bash -c 'cloudez-health-check producao 2>/dev/null'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ------------------------------------------------------------ health-check --

@test "health-check 200: healthy e exit 0" {
  MOCK_HTTP_STATUS=200 run cloudez-health-check staging
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .healthy)" = "true" ]
  [ "$(jq_field "$output" .status_code)" = "200" ]
}

@test "health-check 502: nao saudavel e exit 1" {
  MOCK_HTTP_STATUS=502 run cloudez-health-check staging
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .healthy)" = "false" ]
  [ "$(jq_field "$output" .status_code)" = "502" ]
}

# REGRESSAO: `read` retorna nao-zero ao encontrar EOF sem newline final, e o
# `set -e` matava o script antes de imprimir. O -w do curl nao emite \n.
@test "health-check imprime JSON mesmo quando falha" {
  MOCK_HTTP_STATUS=500 run cloudez-health-check staging
  [ -n "$output" ]
  [ "$(jq_field "$output" .url)" = "https://staging.example.com/" ]
}

@test "health-check trata curl que falha na conexao" {
  MOCK_CURL_EXIT=7 run cloudez-health-check staging
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .status_code)" = "0" ]
}

@test "health-check aceita path e status esperado customizados" {
  MOCK_HTTP_STATUS=404 run cloudez-health-check staging /saude 404
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .healthy)" = "true" ]
  [[ "$(jq_field "$output" .url)" == */saude ]]
}

# ------------------------------------------------------------ begin-deploy --

@test "begin-deploy devolve destino rsync com barra final" {
  run cloudez-begin-deploy staging abc1234def K1
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .status)" = "awaiting_upload" ]
  # A barra final significa "o conteudo de"; sem ela o rsync aninha o build.
  [[ "$(jq_field "$output" .rsync.path)" == */ ]]
  [[ "$(jq_field "$output" .release_id)" == *-abc1234 ]]
}

@test "begin-deploy e idempotente na mesma chave" {
  d1=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  d2=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  [ "$d1" = "$d2" ]
}

@test "begin-deploy com chave nova cria deploy novo" {
  d1=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  d2=$(cloudez-begin-deploy staging abc1234def K2 | jq -r .deploy_id)
  [ "$d1" != "$d2" ]
}

@test "begin-deploy propaga falha de ssh como retryable" {
  MOCK_SSH_EXIT=255 MOCK_SSH_STDERR="Permission denied (publickey)" \
    run cloudez-begin-deploy staging abc1234def K1
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "ssh_failed" ]
  [ "$(jq_field "$output" .error.retryable)" = "true" ]
  [[ "$(jq_field "$output" .error.logs)" == *publickey* ]]
}

# -------------------------------------------------------------------- sync --

@test "sync com deploy_id desconhecido: deploy_not_found" {
  run cloudez-sync dpl_inexistente dist
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "deploy_not_found" ]
}

@test "sync com diretorio ausente: build_output_missing" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  run cloudez-sync "$d" nao-existe
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "build_output_missing" ]
}

@test "sync com diretorio vazio: build_output_empty" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist
  run cloudez-sync "$d" dist
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "build_output_empty" ]
}

@test "sync bem-sucedido marca o deploy como uploaded" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  run cloudez-sync "$d" dist
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .status)" = "uploaded" ]
  grep -q "tar xzf - -C '/srv/staging/releases/" "$MOCK_LOG"
}

# "-C dist ." envia o CONTEUDO do diretorio. Sem isso o site sobe aninhado um
# nivel — o mesmo erro que a barra final resolvia no rsync.
@test "sync envia o CONTEUDO do diretorio, nao o diretorio" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  grep -qE 'tar .*-C dist \.$' "$MOCK_LOG"
}

@test "sync aplica os excludes da config no tar" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  grep -q -- '--exclude=node_modules' "$MOCK_LOG"
}

@test "sync propaga falha do transporte" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  MOCK_SSH_EXIT=255 MOCK_SSH_STDERR="Permission denied (publickey)" \
    run cloudez-sync "$d" dist
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "transfer_failed" ]
  [ "$(jq_field "$output" .error.retryable)" = "true" ]
}

# O deploy so avanca para "uploaded" quando o transporte confirma. Sem isso o
# finalize ativaria uma release vazia.
@test "sync que falha nao marca o deploy como uploaded" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  MOCK_SSH_EXIT=255 run cloudez-sync "$d" dist
  [ "$(jq -r .status ".cloudez/state/$d.json")" = "awaiting_upload" ]
}

# ---------------------------------------------------------------- finalize --

@test "finalize antes do sync: upload_incomplete" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  run cloudez-finalize-deploy "$d"
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "upload_incomplete" ]
}

# A troca real usa `mv -T` (GNU coreutils) e roda no servidor Linux, entao o
# mock nao a executa. O que da para afirmar aqui — e que importa — e que o
# comando enviado usa symlink temporario + rename, nunca rm seguido de ln.
@test "finalize envia troca atomica de symlink" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  run cloudez-finalize-deploy "$d"
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .status)" = "succeeded" ]
  grep -q 'mv -Tf' "$MOCK_LOG"
  ! grep -qE "rm -f '?/srv/staging/current" "$MOCK_LOG"
}

# ----------------------------------------------------------------- approve --

@test "approve sem TTY falha: um agente nao pode se auto-aprovar" {
  run bash -c 'cloudez-approve production < /dev/null'
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "no_tty" ]
}
