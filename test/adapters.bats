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

# ---------------------------------------------------------------- compose ---
#
# A ordem de busca e a MESMA do `docker compose`. Reportar um arquivo que o
# Compose nao vai usar descreveria uma aplicacao diferente da que sobe.

@test "compose: projeto sem arquivo nenhum" {
  run cloudez-compose
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .compose)" = "false" ]
  [ "$(jq_field "$output" .file)" = "null" ]
}

@test "compose: encontra o nome legado" {
  touch docker-compose.yml
  run cloudez-compose
  [ "$(jq_field "$output" .compose)" = "true" ]
  [ "$(jq_field "$output" .file)" = "docker-compose.yml" ]
}

# compose.yaml e o nome que a spec atual prefere, e vence os legados.
@test "compose: respeita a precedencia do proprio Compose" {
  touch docker-compose.yml docker-compose.yaml compose.yml compose.yaml
  run cloudez-compose
  [ "$(jq_field "$output" .file)" = "compose.yaml" ]
}

# Um arquivo editado que nunca entra em nada e caro de diagnosticar.
@test "compose: reporta os que serao ignorados" {
  touch compose.yaml docker-compose.yml
  run cloudez-compose
  [ "$(jq_field "$output" '.ignored | join(",")')" = "docker-compose.yml" ]
}

@test "compose: sem ambiguidade, nao ha campo ignored" {
  touch compose.yaml
  run cloudez-compose
  [ "$(jq_field "$output" 'has("ignored")')" = "false" ]
}

# O deploy publica um diretorio, que nem sempre e a raiz do projeto.
@test "compose: aceita um diretorio como argumento" {
  mkdir -p build && touch build/compose.yaml
  run cloudez-compose build
  [ "$(jq_field "$output" .compose)" = "true" ]
  [ "$(jq_field "$output" .directory)" = "build" ]
}

@test "compose: diretorio inexistente e erro nomeado" {
  run cloudez-compose nao-existe
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "dir_not_found" ]
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
# O tar do macOS empacota metadados AppleDouble — `._index.html`, `._style.css`,
# um `._.` por diretorio. Nao quebram o site, mas viajam em toda release e sujam
# o servidor. COPYFILE_DISABLE=1 resolve na origem; fora do macOS o tar ignora a
# variavel, entao nao ha condicional por plataforma.
# O diretorio publicado deixou de ser sempre um build: numa aplicacao em
# container o que se envia e o CONTEXTO, que costuma ser a raiz do repositorio.
# Sem exclusao, todo deploy levaria o historico inteiro do git pela rede.
@test "sync exclui o .git do que empacota" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  run cloudez-sync "$d" dist
  [ "$status" -eq 0 ]
  grep -q -- '--exclude .git' "$MOCK_LOG"
}

# Este roda o tar DE VERDADE, nao o mock. O comportamento de --exclude difere
# entre bsdtar (macOS) e GNU tar (Linux), e a matriz do CI cobre os dois: um
# padrao que funcione so num deles passaria despercebido de outra forma.
#
# O que precisa sobreviver importa tanto quanto o que precisa sair: uma exclusao
# por prefixo levaria .gitignore e .github/ junto.
@test "o padrao de exclusao pega .git e poupa .gitignore e .github" {
  mkdir -p ctx/.git/objects ctx/sub/.git ctx/.github ctx/src
  touch ctx/.git/config ctx/.git/objects/abc ctx/sub/.git/x \
        ctx/.github/w.yml ctx/.gitignore ctx/src/app.js ctx/Dockerfile ctx/compose.yaml

  # PATH reduzido: `tar` no PATH da suite e o MOCK, que nao empacota nada. Sem
  # isto o teste passa vazio, afirmando sobre uma listagem que nunca existiu.
  real_tar() { PATH=/usr/bin:/bin tar "$@"; }
  listagem=$(real_tar -czf - --exclude .git -C ctx . | real_tar -tzf -)

  [ "$(printf '%s\n' "$listagem" | grep -c '/\.git/')" -eq 0 ]
  printf '%s\n' "$listagem" | grep -q '\./\.gitignore'
  printf '%s\n' "$listagem" | grep -q '\./\.github/'
  printf '%s\n' "$listagem" | grep -q '\./Dockerfile'
  printf '%s\n' "$listagem" | grep -q '\./compose\.yaml'
}

@test "sync desliga os metadados AppleDouble do macOS" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  run cloudez-sync "$d" dist
  [ "$status" -eq 0 ]
  grep -q 'tar-env COPYFILE_DISABLE=1' "$MOCK_LOG"
}

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

# ------------------------------------------------------------------ poda ---

# Um `.current-*` e o document root que o usuario tinha, posto de lado por nos —
# apagar isso e apagar conteudo dele. Por isso o numero e separado do das
# releases, e menor.
@test "a poda alcanca os diretorios .current-*, nao so releases/" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  cloudez-finalize-deploy "$d" >/dev/null
  # Especifico do comando de PODA. Um grep solto por ".current-" casaria com a
  # ativacao, que tambem cita o nome — e passaria mesmo sem poda nenhuma.
  grep -q "ls -1dt '/srv/staging/.current-'" "$MOCK_LOG"
  grep -q "ls -1dt '/srv/staging/releases/'" "$MOCK_LOG"
}

# Apagar conteudo do usuario nao pode ser silencioso.
@test "poda de .current-* e reportada no JSON" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  MOCK_SSH_STDOUT='PRUNED 3' run cloudez-finalize-deploy "$d"
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .pruned_replaced)" = "3" ]
}

@test "sem poda, o campo nao aparece" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  run cloudez-finalize-deploy "$d"
  [ "$(jq_field "$output" .pruned_replaced)" = "null" ]
}

# String vazia nao e o mesmo que ausente: `""` passa por um teste de existencia
# de campo e falha num teste de valor. Ausente, os dois concordam. No primeiro
# deploy de um site nao ha release anterior, entao este e o caso comum.
@test "sem release anterior, previous_release_id nao aparece" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  run cloudez-finalize-deploy "$d"
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" 'has("previous_release_id")')" = "false" ]
}

@test "com release anterior, previous_release_id aparece" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  MOCK_SSH_STDOUT='20260101T000000Z-aaaaaaa' run cloudez-finalize-deploy "$d"
  [ "$(jq_field "$output" .previous_release_id)" = "20260101T000000Z-aaaaaaa" ]
}

# `.cloudez/state/` e um arquivo por deploy mais um por chave de idempotencia,
# incluindo os que falharam. Sem TTL cresce para sempre no repositorio de quem
# publica com frequencia.
@test "estado local antigo e podado" {
  # O caminho padrao do _lib.sh, relativo a raiz do projeto publicado.
  state=.cloudez/state
  mkdir -p "$state/key"
  printf '{}' > "$state/antigo.json"
  printf 'x' > "$state/key/CHAVE_ANTIGA"
  touch -t 202501010000 "$state/antigo.json" "$state/key/CHAVE_ANTIGA"

  cloudez-begin-deploy staging abc1234def K_NOVA >/dev/null
  [ ! -f "$state/antigo.json" ]
  [ ! -f "$state/key/CHAVE_ANTIGA" ]
}

# A chave de idempotencia e o que impede um retry de virar um segundo deploy.
# Podar uma chave recente quebraria justamente a garantia que ela existe para dar.
@test "estado recente sobrevive a poda" {
  state=.cloudez/state
  d1=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  d2=$(cloudez-begin-deploy staging abc1234def K2 | jq -r .deploy_id)
  [ -f "$state/$d1.json" ]
  [ -f "$state/key/K1" ]
  # E a idempotencia continua valendo depois da poda ter rodado.
  d1_again=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  [ "$d1_again" = "$d1" ]
  [ "$d2" != "$d1" ]
}

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

# O ALVO do link e relativo ao DIRETORIO DO LINK. Com root vindo de `~/` — que e
# o que o setup gera — o root e relativo ao $HOME, e usa-lo como alvo produz
# `current -> <root>/releases/<id>` resolvido a partir de `<root>/`, ou seja um
# link quebrado. `ln` nao reclama, `ls` nao reclama, e o site responde 404 depois
# de um deploy que se declarou bem-sucedido.
#
# Este cenario PRECISA de root relativo: com um root absoluto o alvo errado
# ainda resolveria, e foi por isso que o bug passou pela suite — o fixture
# padrao usa /srv/staging.
@test "o alvo do current e relativo, com root vindo de ~/" {
  make_config 'domain: staging.example.com
root: ~/staging.example.com/www/claude
ssh: {host: srv.example.com, user: deploy, port: 22}'
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  run cloudez-finalize-deploy "$d"
  [ "$status" -eq 0 ]
  grep -qE "ln -sfn 'releases/[0-9TZ]+-abc1234'" "$MOCK_LOG"
  ! grep -q "ln -sfn 'staging.example.com/www/claude/releases" "$MOCK_LOG"
}

# `current` pode ser um diretorio de verdade — o site que ja estava no ar antes
# do plugin. `mv -T` de um link sobre um diretorio nao substitui, entao sem
# tratar isso o primeiro deploy morre em activation_failed sem dizer o motivo.
#
# O mock de ssh nao executa o comando remoto (mv -T e GNU, nao roda no macOS do
# desenvolvedor), entao estes testes afirmam sobre o comando ENVIADO. E a mesma
# estrategia dos outros testes de ativacao.
@test "a ativacao trata current que e diretorio, nao symlink" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  run cloudez-finalize-deploy "$d"
  [ "$status" -eq 0 ]
  grep -q "mv '/srv/staging/current'" "$MOCK_LOG"
  # O destino leva o release_id: nome fixo teria que decidir o que fazer quando
  # ja estivesse ocupado, e as duas saidas sao ruins.
  grep -qE "mv '/srv/staging/current' '/srv/staging/\.current-[0-9TZ]+-abc1234'" "$MOCK_LOG"
}

# A condicao PRECISA das duas metades. Um symlink que aponta para diretorio
# tambem satisfaz -d, e e exatamente o que o nosso current e depois do primeiro
# deploy: com `-d` sozinho, todo deploy seguinte moveria o link valido para
# .current.old e derrubaria o site entre um comando e outro.
@test "o guard exige diretorio E nao-symlink" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  cloudez-finalize-deploy "$d" >/dev/null
  grep -q "\[ ! -L '/srv/staging/current' \]" "$MOCK_LOG"
}

# O diretorio e movido, nunca apagado: e o conteudo que estava no ar.
@test "a ativacao nunca apaga o current" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  cloudez-finalize-deploy "$d" >/dev/null
  ! grep -qE "rm -rf '?/srv/staging/current" "$MOCK_LOG"
}

# Ter posto conteudo do usuario de lado precisa chegar a quem chamou, senao vira
# um diretorio orfao que so aparece quando alguem for olhar o servidor.
@test "diretorio movido e reportado no JSON" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  MOCK_SSH_STDOUT='MOVED /srv/staging/.current-20260101T000000Z-abc1234' \
    run cloudez-finalize-deploy "$d"
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .replaced_directory)" = "/srv/staging/.current-20260101T000000Z-abc1234" ]
}

@test "sem diretorio movido, o campo nao aparece" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  run cloudez-finalize-deploy "$d"
  [ "$(jq_field "$output" .replaced_directory)" = "null" ]
}

@test "o alvo do current no rollback tambem e relativo" {
  make_config 'domain: staging.example.com
root: ~/staging.example.com/www/claude
ssh: {host: srv.example.com, user: deploy, port: 22}'
  # Formato que o cloudez-list-releases espera: CURRENT na primeira linha, uma
  # release por linha depois.
  MOCK_SSH_STDOUT='CURRENT 20260102T000000Z-bbbbbbb
20260102T000000Z-bbbbbbb
20260101T000000Z-aaaaaaa' \
    run cloudez-rollback staging 20260101T000000Z-aaaaaaa
  [ "$status" -eq 0 ]
  grep -qE "ln -sfn 'releases/20260101T000000Z-aaaaaaa'" "$MOCK_LOG"
  ! grep -q "ln -sfn 'staging.example.com/www/claude/releases" "$MOCK_LOG"
}

# ---------------------------------------------------------------- rollback --

# O stderr do ssh nao pode entrar na lista. `StrictHostKeyChecking=accept-new`
# imprime um aviso na PRIMEIRA conexao a um host — o cenario do primeiro deploy —
# e com `2>&1` ele virava uma release.
@test "aviso no stderr do ssh nao vira release" {
  MOCK_SSH_STDOUT='CURRENT 20260102T000000Z-bbbbbbb
20260102T000000Z-bbbbbbb
20260101T000000Z-aaaaaaa' \
  MOCK_SSH_STDERR_FIRST='Warning: Permanently added the host to the list of known hosts.' \
    run cloudez-list-releases staging
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" '.releases | length')" = "2" ]
  [[ "$output" != *Warning* ]]
}

# A linha do marcador nunca pode aparecer como release. O filtro de antes era
# posicional (`tail -n +2`): bastava uma linha inesperada na frente para ele
# descartar a errada e promover o CURRENT.
@test "a linha CURRENT nunca vira release" {
  MOCK_SSH_STDOUT='CURRENT 20260102T000000Z-bbbbbbb
20260102T000000Z-bbbbbbb' \
  MOCK_SSH_STDERR_FIRST='ruido antes de tudo' \
    run cloudez-list-releases staging
  [ "$(jq_field "$output" '.releases | length')" = "1" ]
  [ "$(jq_field "$output" '.releases[0].release_id')" = "20260102T000000Z-bbbbbbb" ]
  [[ "$output" != *CURRENT* ]]
}

# O estrago real acontecia aqui: o rollback escolhe a primeira release que nao e
# a atual, entao o ruido virava o ALVO. O symlink apontava para um caminho
# inexistente, o site respondia 404, e o adaptador reportava rolled_back.
@test "rollback nao escolhe ruido do stderr como alvo" {
  MOCK_SSH_STDOUT='CURRENT 20260102T000000Z-bbbbbbb
20260102T000000Z-bbbbbbb
20260101T000000Z-aaaaaaa' \
  MOCK_SSH_STDERR_FIRST='Warning: Permanently added the host to the list of known hosts.' \
    run cloudez-rollback staging
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .to_release_id)" = "20260101T000000Z-aaaaaaa" ]
  ! grep -q "releases/Warning" "$MOCK_LOG"
}

# Falha continua reportando o stderr: separar as duas coisas nao pode custar o
# diagnostico.
@test "falha de ssh ainda traz o stderr nos logs" {
  MOCK_SSH_EXIT=255 MOCK_SSH_STDERR='ssh: connect to host porta 22: Connection refused' \
    run cloudez-list-releases staging
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "ssh_failed" ]
  [[ "$(jq_field "$output" .error.logs)" == *"Connection refused"* ]]
}

@test "rollback sem release anterior: no_previous_release" {
  run cloudez-rollback staging
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "no_previous_release" ]
}

# ------------------------------------------------------------- compose-up --
#
# Publicar arquivos nao poe uma aplicacao em container no ar: o nginx da Cloudez
# encaminha para uma porta local e quem escuta ali e o container. Sem este passo
# o deploy termina em `succeeded` com o site em 502 — falha que so aparece no
# navegador.

# Ordem invertida nao e detalhe de estilo: o build le `current`, entao rodar
# antes do finalize construiria a imagem a partir da release ANTERIOR, e o
# deploy publicaria arquivos novos servindo codigo velho sem sinal disso.
@test "compose-up antes do finalize: activation_incomplete" {
  d=$(cloudez-begin-deploy staging abc1234def K1 | jq -r .deploy_id)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  run cloudez-compose-up "$d"
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "activation_incomplete" ]
}

# O daemon do Docker e UM SO para todos os sites da maquina. Sem `-p`, o Compose
# nomeia o projeto pelo diretorio — sempre `current` —, e o deploy de um site
# derrubaria o container de outro, com `--remove-orphans` terminando o servico.
@test "o projeto do compose vem do dominio, nunca do diretorio" {
  d=$(finalized_deploy)
  run cloudez-compose-up "$d"
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .compose.project)" = "staging-example-com" ]
  grep -q -- "-p 'staging-example-com'" "$MOCK_LOG"
  ! grep -qE -- "-p 'current'" "$MOCK_LOG"
}

@test "compose-up roda em current e reconstroi a imagem" {
  d=$(finalized_deploy)
  run cloudez-compose-up "$d"
  [ "$status" -eq 0 ]
  grep -q "cd '/srv/staging/current'" "$MOCK_LOG"
  # Sem --build o compose reaproveita a imagem anterior e o deploy nao muda nada.
  grep -q -- "up -d --build" "$MOCK_LOG"
}

# Um container em `restarting` e deploy fracassado com JSON de sucesso: quem
# chama precisa do estado para conferir, nao so do exit code.
@test "os containers do ps entram no JSON" {
  d=$(finalized_deploy)
  MOCK_SSH_STDOUT=$'#8 exporting layers done\nPS\tweb-1\trunning\t0.0.0.0:8080->80/tcp' \
    run cloudez-compose-up "$d"
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" '.compose.containers | length')" = "1" ]
  [ "$(jq_field "$output" .compose.containers[0].name)"  = "web-1" ]
  [ "$(jq_field "$output" .compose.containers[0].state)" = "running" ]
  [ "$(jq_field "$output" .compose.containers[0].ports)" = "0.0.0.0:8080->80/tcp" ]
}

# O build imprime TUDO que os passos `RUN` produziram, e o inventario sai do
# mesmo fluxo. Um filtro por contagem de campos aceitaria qualquer linha com dois
# tabs — e ferramenta com saida tabular dentro de um RUN produz varias. O
# fantasma nao seria so ruido: o commands/deploy.md manda conferir o `state`
# desses containers.
@test "linha de build com tabs nao vira container fantasma" {
  d=$(finalized_deploy)
  MOCK_SSH_STDOUT=$'#12 [build 3/5]\tRUN npm ci\t142.3s\nPS\tweb-1\trunning\t0.0.0.0:8080->80/tcp' \
    run cloudez-compose-up "$d"
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" '.compose.containers | length')" = "1" ]
  [ "$(jq_field "$output" .compose.containers[0].name)" = "web-1" ]
}

# Aviso de conexao do ssh, que aparece no primeiro deploy a um host novo.
@test "aviso do ssh nao vira container" {
  d=$(finalized_deploy)
  MOCK_SSH_STDERR_FIRST='Warning: Permanently added the host to the list of known hosts.' \
  MOCK_SSH_STDOUT=$'PS\tweb-1\trunning\t0.0.0.0:8080->80/tcp' \
    run cloudez-compose-up "$d"
  [ "$(jq_field "$output" '.compose.containers | length')" = "1" ]
}

# Sem compose na release, quase sempre o passo 4 publicou a saida de um build em
# vez do contexto. Erro nomeado em vez de log de docker para o usuario decifrar.
@test "release sem arquivo de compose: compose_missing" {
  d=$(finalized_deploy)
  MOCK_SSH_EXIT=3 run cloudez-compose-up "$d"
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "compose_missing" ]
}

@test "servidor sem docker compose: docker_missing" {
  d=$(finalized_deploy)
  MOCK_SSH_EXIT=4 run cloudez-compose-up "$d"
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "docker_missing" ]
}

# Os dois modos de falha abaixo sao acao da Cloudez, nao do projeto, e a mensagem
# crua do Docker nao diz isso: "permission denied ... docker.sock" parece
# problema de arquivo, e o erro de iptables parece problema de rede do container.
@test "socket negado vira hint sobre o grupo docker" {
  d=$(finalized_deploy)
  MOCK_SSH_EXIT=1 \
    MOCK_SSH_STDERR='permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock' \
    run cloudez-compose-up "$d"
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "compose_failed" ]
  [[ "$(jq_field "$output" .error.hint)" == *"grupo 'docker'"* ]]
}

@test "iptables quebrado vira hint sobre reiniciar o daemon" {
  d=$(finalized_deploy)
  MOCK_SSH_EXIT=1 \
    MOCK_SSH_STDERR='iptables failed: iptables --wait -t nat -A DOCKER: iptables: No chain/target/match by that name.' \
    run cloudez-compose-up "$d"
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "compose_failed" ]
  [[ "$(jq_field "$output" .error.hint)" == *"systemctl restart docker"* ]]
}
