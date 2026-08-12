#!/usr/bin/env bats
# Adaptadores bin/cloudez-*: config, contrato de erro e maquina de estado.

load helpers/setup

setup() { make_project; }

# ------------------------------------------------------------------- setup --

@test "setup sem argumentos: missing_domain" {
  rm .cloudez.yaml
  run cloudez-setup
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "missing_domain" ]
  [ ! -f .cloudez.yaml ]
}

# O environment decide para onde o deploy vai. Sem padrao: um template criado
# para o environment errado e pior do que template nenhum.
@test "setup sem environment: missing_environment" {
  rm .cloudez.yaml
  run cloudez-setup staging.example.com
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "missing_environment" ]
  [ ! -f .cloudez.yaml ]
}

# O dominio identifica o site E vira caminho no servidor. URL colada com
# protocolo ou caminho e o erro mais provavel aqui, e passaria batido.
@test "setup recusa dominio que nao e FQDN" {
  rm .cloudez.yaml
  for d in https://x.example.com x.example.com/path 'x.example.com?a=1' \
           x.example.com:8080 localhost -x.example.com "x .example.com"; do
    run cloudez-setup "$d" staging
    [ "$status" -eq 1 ]
    [ "$(jq_field "$output" .error.code)" = "invalid_domain" ]
    [ ! -f .cloudez.yaml ]
  done
}

# O environment vira chave YAML por interpolacao. Um nome com espaco ou
# dois-pontos geraria um arquivo quebrado que o usuario nao escreveu.
@test "setup com nome de environment invalido nao gera arquivo" {
  rm .cloudez.yaml
  run cloudez-setup staging.example.com "prod: uction"
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "invalid_environment" ]
  [ ! -f .cloudez.yaml ]
}

@test "setup cria o template quando nao ha config" {
  rm .cloudez.yaml
  run cloudez-setup staging.example.com staging
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .status)" = "created" ]
  [ "$(jq_field "$output" .path)" = ".cloudez.yaml" ]
  [ "$(jq_field "$output" .domain)" = "staging.example.com" ]
  [ "$(jq_field "$output" .environment)" = "staging" ]
  [ -f .cloudez.yaml ]
}

# O template precisa ser YAML valido desde o primeiro byte: um arquivo gerado
# que nao parseia manda o usuario depurar indentacao que ele nao escreveu.
#
# O bloco raiz e `cloudez`, e dentro dele so o environment pedido.
@test "o template gerado parseia sob cloudez, com so o environment pedido" {
  rm .cloudez.yaml
  cloudez-setup meusite.com.br homolog >/dev/null
  json=$(bash -c "source '$PLUGIN_ROOT/bin/_yaml.sh'; yaml_to_json .cloudez.yaml")
  [ "$(jq_field "$json" '.cloudez | keys | join(",")')" = "homolog" ]
  [ "$(jq_field "$json" .sites)" = "null" ]
  [ "$(jq_field "$json" .cloudez.homolog.domain)" = "meusite.com.br" ]
  [ "$(jq_field "$json" .cloudez.homolog.root)" = "~/meusite.com.br/www/claude" ]
}

# O identificador do site e o dominio; site_id saiu da config.
@test "o template gerado nao traz site_id" {
  rm .cloudez.yaml
  cloudez-setup meusite.com.br staging >/dev/null
  ! grep -q site_id .cloudez.yaml
}

# O destino fica explicito na config, nunca derivado em tempo de deploy.
@test "o template gerado traz root explicito, logo abaixo de domain" {
  rm .cloudez.yaml
  cloudez-setup meusite.com.br staging >/dev/null
  grep -q 'root: ~/meusite.com.br/www/claude$' .cloudez.yaml
  [ "$(grep -n 'domain:' .cloudez.yaml | cut -d: -f1)" \
    -lt "$(grep -n 'root:' .cloudez.yaml | cut -d: -f1)" ]
}

# Nada sobra para o usuario preencher: o destino ssh vem do cloudez_get_site, e o
# root ja sai escrito. Um TODO no arquivo seria trabalho que ninguem precisa
# fazer.
@test "o template gerado nao deixa TODO nenhum" {
  rm .cloudez.yaml
  run cloudez-setup meusite.com.br staging
  ! grep -q TODO .cloudez.yaml
  [ "$(jq_field "$output" .todo)" = "null" ]
}

# O bloco ssh saiu da config: uma copia do host num arquivo versionado envelhece
# quando a Cloudez move o site de servidor, e o deploy iria para o antigo sem
# reclamar.
@test "o template gerado nao traz bloco ssh" {
  rm .cloudez.yaml
  cloudez-setup meusite.com.br staging >/dev/null
  ! grep -q ssh .cloudez.yaml
  json=$(bash -c "source '$PLUGIN_ROOT/bin/_yaml.sh'; yaml_to_json .cloudez.yaml")
  [ "$(jq_field "$json" .cloudez.staging.ssh)" = "null" ]
}

# O arquivo gerado nao leva comentario: o que precisa ser dito ao usuario e dito
# na conversa pelo /cloudez:setup, nao num texto dentro da config que ninguem
# rele e que envelhece sozinho.
@test "o template gerado nao tem comentario nenhum" {
  rm .cloudez.yaml
  cloudez-setup meusite.com.br staging >/dev/null
  ! grep -q '#' .cloudez.yaml
  [ "$(head -c 8 .cloudez.yaml)" = "cloudez:" ]
}

# DNS nao diferencia maiuscula, mas o caminho no servidor diferencia.
@test "setup normaliza o dominio para minusculas" {
  rm .cloudez.yaml
  run cloudez-setup MeuSite.COM.BR staging
  [ "$(jq_field "$output" .domain)" = "meusite.com.br" ]
  grep -q 'domain: meusite.com.br' .cloudez.yaml
  grep -q 'root: ~/meusite.com.br/www/claude$' .cloudez.yaml
}

# ----------------------------------------------------------------- pubkey ---
#
# A chave PRIVADA nunca e aberta: o par dela e o que autentica o usuario, e um
# adaptador que a le e um adaptador que pode vaza-la.

setup_keys() {
  KEYDIR="$TEST_TMP/ssh"
  mkdir -p "$KEYDIR"
  export CLOUDEZ_SSH_DIR="$KEYDIR"
}

@test "pubkey lista as chaves publicas, sem tocar na privada" {
  setup_keys
  printf 'ssh-ed25519 AAAAC3ANA ana@maquina\n' > "$KEYDIR/id_ed25519.pub"
  printf 'PRIVADA-NAO-PODE-SAIR\n' > "$KEYDIR/id_ed25519"
  run cloudez-pubkey
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" '.keys | length')" = "1" ]
  [ "$(jq_field "$output" '.keys[0].key')" = "ssh-ed25519 AAAAC3ANA" ]
  [ "$(jq_field "$output" '.keys[0].comment')" = "ana@maquina" ]
  [[ "$output" != *PRIVADA* ]]
}

# O `key` sai sem o comentario: e por ele que se compara com o que a conta ja
# tem, e o comentario muda de maquina para maquina sem a chave mudar.
@test "pubkey separa o material do comentario" {
  setup_keys
  printf 'ssh-rsa AAAAB3BETO\n' > "$KEYDIR/sem_comentario.pub"
  run cloudez-pubkey
  [ "$(jq_field "$output" '.keys[0].key')" = "ssh-rsa AAAAB3BETO" ]
  [ "$(jq_field "$output" '.keys[0].comment')" = "" ]
}

@test "pubkey ignora .pub que nao contem chave" {
  setup_keys
  printf 'ssh-ed25519 AAAAC3ANA ana\n' > "$KEYDIR/boa.pub"
  printf 'isto nao e uma chave\n' > "$KEYDIR/ruim.pub"
  run cloudez-pubkey
  [ "$(jq_field "$output" '.keys | length')" = "1" ]
}

@test "pubkey lista varias chaves" {
  setup_keys
  printf 'ssh-ed25519 AAAAC3ANA ana\n' > "$KEYDIR/a.pub"
  printf 'ssh-rsa AAAAB3BETO beto\n' > "$KEYDIR/b.pub"
  run cloudez-pubkey
  [ "$(jq_field "$output" '.keys | length')" = "2" ]
}

@test "pubkey sem chave nenhuma: no_public_key" {
  setup_keys
  run cloudez-pubkey
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "no_public_key" ]
  [[ "$(jq_field "$output" .error.hint)" == *ssh-keygen* ]]
}

@test "pubkey sem diretorio .ssh: no_ssh_dir" {
  CLOUDEZ_SSH_DIR="$TEST_TMP/nao-existe" run cloudez-pubkey
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "no_ssh_dir" ]
}

# ------------------------------------------------------------- destino ssh ---
#
# O destino saiu da config e passou a vir do cloudez_get_site, via ambiente. O
# bloco `ssh` continua aceito como fallback para .cloudez.yaml escritos antes da
# mudanca — e os testes de root/deploy deste arquivo ainda o usam, entao o
# fallback esta coberto por eles.

# config_sem_ssh — config no formato que o setup gera hoje
config_sem_ssh() {
  printf 'cloudez:\n  staging:\n    domain: staging.example.com\n    root: /srv/staging\n' > .cloudez.yaml
}

@test "destino ssh vem do ambiente quando a config nao tem bloco ssh" {
  config_sem_ssh
  CLOUDEZ_SSH_HOST=srv-9.cloudez.io CLOUDEZ_SSH_USER=deployer \
    run cloudez-begin-deploy staging abc1234def K1
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .ssh.host)" = "srv-9.cloudez.io" ]
  [ "$(jq_field "$output" .ssh.user)" = "deployer" ]
  [ "$(jq_field "$output" .ssh.port)" = "22" ]
  grep -q 'deployer@srv-9.cloudez.io' "$MOCK_LOG"
}

@test "CLOUDEZ_SSH_PORT sobrepoe o 22 padrao" {
  config_sem_ssh
  CLOUDEZ_SSH_HOST=srv-9.cloudez.io CLOUDEZ_SSH_USER=deployer CLOUDEZ_SSH_PORT=2222 \
    run cloudez-begin-deploy staging abc1234def K1
  [ "$(jq_field "$output" .ssh.port)" = "2222" ]
  grep -q '\-p 2222' "$MOCK_LOG"
}

# O ambiente vence: a config pode ter um host antigo, de antes de a Cloudez mover
# o site de servidor, e o valor recem-buscado na API e o que vale.
@test "ambiente vence o bloco ssh da config" {
  make_config 'domain: staging.example.com
root: /srv/staging
ssh: {host: antigo.example.com, user: velho, port: 22}'
  CLOUDEZ_SSH_HOST=novo.cloudez.io CLOUDEZ_SSH_USER=deployer \
    run cloudez-begin-deploy staging abc1234def K1
  [ "$(jq_field "$output" .ssh.host)" = "novo.cloudez.io" ]
  ! grep -q antigo.example.com "$MOCK_LOG"
}

# Sem destino, o erro precisa dizer o que falta. Um erro de ssh generico mandaria
# o usuario depurar chave e rede em vez do que realmente falta.
@test "sem destino em lugar nenhum: missing_ssh_target" {
  config_sem_ssh
  run cloudez-begin-deploy staging abc1234def K1
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "missing_ssh_target" ]
  [[ "$(jq_field "$output" .error.hint)" == *cloudez_get_site* ]]
}

# ------------------------------------------------------------------- root ---

# make_config <yaml_do_site> — reescreve a config com um unico environment staging
make_config() {
  { printf 'cloudez:\n  staging:\n'; printf '%s\n' "$1" | sed 's/^/    /'; } > .cloudez.yaml
}

# O til nao pode chegar ao servidor: os comandos remotos vao entre aspas simples
# e o shell de la nao o expande — criaria um diretorio chamado `~`. Caminho
# relativo resolve a partir do $HOME do usuario ssh, que e o que `~/` significa.
@test "til inicial em root e removido, nunca enviado" {
  make_config 'domain: staging.example.com
root: ~/staging.example.com/www
ssh: {host: srv.example.com, user: deploy, port: 22}'
  run cloudez-begin-deploy staging abc1234def K1
  [ "$status" -eq 0 ]
  [[ "$(jq_field "$output" .ssh.path)" == staging.example.com/www/releases/* ]]
  ! grep -q '~' "$MOCK_LOG"
}

@test "root absoluto continua absoluto" {
  run cloudez-begin-deploy staging abc1234def K1
  [ "$status" -eq 0 ]
  [[ "$(jq_field "$output" .ssh.path)" == /srv/staging/releases/* ]]
}

# Obrigatorio e explicito: sem root o adaptador para, em vez de adivinhar um
# destino a partir do dominio.
@test "sem root: config_invalid, mesmo com domain definido" {
  make_config 'domain: staging.example.com
ssh: {host: srv.example.com, user: deploy, port: 22}'
  run cloudez-list-releases staging
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "config_invalid" ]
  [[ "$(jq_field "$output" .error.message)" == *root* ]]
}

# `paths.root` era o nome antigo. Ignorar em silencio publicaria no lugar errado.
@test "paths.root antigo nao e aceito como root" {
  make_config 'domain: staging.example.com
paths: {root: /srv/antigo}
ssh: {host: srv.example.com, user: deploy, port: 22}'
  run cloudez-begin-deploy staging abc1234def K1
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "config_invalid" ]
}

# Config existente carrega host, usuario e caminho que nao dao para adivinhar de
# volta. Sobrescrever seria destrutivo, entao rodar de novo nao faz nada.
@test "setup nao sobrescreve config existente" {
  printf 'cloudez: {producao: {root: /srv/x}}\n' > .cloudez.yaml
  run cloudez-setup meusite.com.br staging
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .status)" = "exists" ]
  grep -q producao .cloudez.yaml
  ! grep -q TODO .cloudez.yaml
}

@test "setup respeita o .cloudez.yml existente em vez de criar um .yaml" {
  mv .cloudez.yaml .cloudez.yml
  run cloudez-setup meusite.com.br staging
  [ "$(jq_field "$output" .status)" = "exists" ]
  [ "$(jq_field "$output" .path)" = ".cloudez.yml" ]
  [ ! -f .cloudez.yaml ]
}

@test "setup acrescenta .cloudez/ ao gitignore" {
  rm .cloudez.yaml .gitignore
  run cloudez-setup meusite.com.br staging
  [ "$(jq_field "$output" .gitignore)" = "updated" ]
  grep -qx '\.cloudez/' .gitignore
}

@test "setup nao duplica a linha do gitignore" {
  rm .cloudez.yaml
  run cloudez-setup meusite.com.br staging
  [ "$(jq_field "$output" .gitignore)" = "already" ]
  [ "$(grep -c '^\.cloudez/$' .gitignore)" -eq 1 ]
}

# ------------------------------------------------------------------ config --

@test "config ausente: config_not_found" {
  rm .cloudez.yaml
  run cloudez-list-releases staging
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "config_not_found" ]
}

@test "extensao .yml tambem e aceita" {
  mv .cloudez.yaml .cloudez.yml
  run cloudez-list-releases staging
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .environment)" = "staging" ]
}

@test "ambiente inexistente: site_not_found com a lista de ambientes" {
  run cloudez-list-releases producao
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "site_not_found" ]
  [[ "$(jq_field "$output" .error.hint)" == *staging* ]]
}

# O bloco raiz virou `cloudez`. Config antiga precisa de erro nomeado, senao o
# usuario recebe site_not_found com lista de ambientes vazia e procura o
# problema no lugar errado.
@test "bloco sites antigo: config_invalid citando cloudez" {
  printf 'sites:\n  staging:\n    root: /srv/staging\n' > .cloudez.yaml
  run cloudez-list-releases staging
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "config_invalid" ]
  [[ "$(jq_field "$output" .error.message)" == *cloudez* ]]
}

# REGRESSAO: `die` dentro de config_json rodava numa substituicao de comando
# aninhada e o `exit 1` nao propagava, entao o script seguia com a config vazia
# e emitia um segundo erro (site_not_found) contradizendo o primeiro.
@test "YAML invalido emite exatamente um erro" {
  printf 'cloudez:\n  staging:\n   quebrado\n    indent: [\n' > .cloudez.yaml
  run cloudez-list-releases staging
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -s 'length')" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "config_invalid" ]
}

# REGRESSAO: `die` escrevia em stdout; como site_config e chamada dentro de
# $( ), o JSON de erro era capturado na variavel e nunca chegava ao usuario.
@test "erro vai para stderr, nao para stdout" {
  run bash -c 'cloudez-list-releases producao 2>/dev/null'
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ------------------------------------------------------------ begin-deploy --

@test "begin-deploy devolve destino ssh com barra final" {
  run cloudez-begin-deploy staging abc1234def K1
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .status)" = "awaiting_upload" ]
  # A barra final significa "o conteudo de"; sem ela o build sobe aninhado.
  [[ "$(jq_field "$output" .ssh.path)" == */ ]]
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

# ---------------------------------------------------------------- rollback --

@test "rollback sem release anterior: no_previous_release" {
  run cloudez-rollback staging
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "no_previous_release" ]
}
