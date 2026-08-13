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
# O template precisa ser YAML valido desde o primeiro byte: um arquivo gerado que
# nao parseia manda o usuario depurar indentacao que ele nao escreveu.
#
# Afirmado por estrutura, e nao com um parser: o conversor YAML->JSON em shell
# saiu junto com os adaptadores de deploy, e quem le a config agora e o MCP. Sao
# quatro linhas deterministicas, entao a forma exata basta.
@test "o template gerado tem a estrutura esperada, e so o environment pedido" {
  rm .cloudez.yaml
  cloudez-setup meusite.com.br homolog >/dev/null
  [ "$(sed -n 1p .cloudez.yaml)" = "cloudez:" ]
  [ "$(sed -n 2p .cloudez.yaml)" = "  homolog:" ]
  [ "$(sed -n 3p .cloudez.yaml)" = "    domain: meusite.com.br" ]
  [ "$(sed -n 4p .cloudez.yaml)" = "    root: ~/meusite.com.br/www/claude" ]
  [ "$(wc -l < .cloudez.yaml)" -eq 4 ]
  ! grep -q "staging\|production" .cloudez.yaml
}

# O bloco ssh saiu da config: uma copia do host num arquivo versionado envelhece
# quando a Cloudez move o site de servidor.
@test "o template gerado nao traz bloco ssh" {
  rm .cloudez.yaml
  cloudez-setup meusite.com.br staging >/dev/null
  ! grep -qE "ssh|host|user|port" .cloudez.yaml
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

# O ambiente vence: a config pode ter um host antigo, de antes de a Cloudez mover
# o site de servidor, e o valor recem-buscado na API e o que vale.
# Sem destino, o erro precisa dizer o que falta. Um erro de ssh generico mandaria
# o usuario depurar chave e rede em vez do que realmente falta.
# O til nao pode chegar ao servidor: os comandos remotos vao entre aspas simples
# e o shell de la nao o expande — criaria um diretorio chamado `~`. Caminho
# relativo resolve a partir do $HOME do usuario ssh, que e o que `~/` significa.
# Obrigatorio e explicito: sem root o adaptador para, em vez de adivinhar um
# destino a partir do dominio.
# `paths.root` era o nome antigo. Ignorar em silencio publicaria no lugar errado.
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

# O bloco raiz virou `cloudez`. Config antiga precisa de erro nomeado, senao o
# usuario recebe site_not_found com lista de ambientes vazia e procura o
# problema no lugar errado.
# REGRESSAO: `die` dentro de config_json rodava numa substituicao de comando
# aninhada e o `exit 1` nao propagava, entao o script seguia com a config vazia
# e emitia um segundo erro (site_not_found) contradizendo o primeiro.
# REGRESSAO: `die` escrevia em stdout; como site_config e chamada dentro de
# $( ), o JSON de erro era capturado na variavel e nunca chegava ao usuario.
@test "sync com deploy_id desconhecido: deploy_not_found" {
  run cloudez-sync dpl_inexistente dist
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "deploy_not_found" ]
}

@test "sync com diretorio ausente: build_output_missing" {
  d=$(deploy_state dpl_test)
  run cloudez-sync "$d" nao-existe
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "build_output_missing" ]
}

@test "sync com diretorio vazio: build_output_empty" {
  d=$(deploy_state dpl_test)
  mkdir -p dist
  run cloudez-sync "$d" dist
  [ "$status" -eq 1 ]
  [ "$(jq_field "$output" .error.code)" = "build_output_empty" ]
}

@test "sync bem-sucedido marca o deploy como uploaded" {
  d=$(deploy_state dpl_test)
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
  d=$(deploy_state dpl_test)
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
  d=$(deploy_state dpl_test)
  mkdir -p dist && touch dist/index.html
  run cloudez-sync "$d" dist
  [ "$status" -eq 0 ]
  grep -q 'tar-env COPYFILE_DISABLE=1' "$MOCK_LOG"
}

@test "sync envia o CONTEUDO do diretorio, nao o diretorio" {
  d=$(deploy_state dpl_test)
  mkdir -p dist && touch dist/index.html
  cloudez-sync "$d" dist >/dev/null
  grep -qE 'tar .*-C dist \.$' "$MOCK_LOG"
}

@test "sync propaga falha do transporte" {
  d=$(deploy_state dpl_test)
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
  d=$(deploy_state dpl_test)
  mkdir -p dist && touch dist/index.html
  MOCK_SSH_EXIT=255 run cloudez-sync "$d" dist
  [ "$(jq -r .status ".cloudez/state/$d.json")" = "awaiting_upload" ]
}

# ---------------------------------------------------------------- finalize --

# ------------------------------------------------------------------ poda ---

# Um `.current-*` e o document root que o usuario tinha, posto de lado por nos —
# apagar isso e apagar conteudo dele. Por isso o numero e separado do das
# releases, e menor.
# Apagar conteudo do usuario nao pode ser silencioso.
# String vazia nao e o mesmo que ausente: `""` passa por um teste de existencia
# de campo e falha num teste de valor. Ausente, os dois concordam. No primeiro
# deploy de um site nao ha release anterior, entao este e o caso comum.
# `.cloudez/state/` e um arquivo por deploy mais um por chave de idempotencia,
# incluindo os que falharam. Sem TTL cresce para sempre no repositorio de quem
# publica com frequencia.
# A chave de idempotencia e o que impede um retry de virar um segundo deploy.
# Podar uma chave recente quebraria justamente a garantia que ela existe para dar.
# A troca real usa `mv -T` (GNU coreutils) e roda no servidor Linux, entao o
# mock nao a executa. O que da para afirmar aqui — e que importa — e que o
# comando enviado usa symlink temporario + rename, nunca rm seguido de ln.
# O ALVO do link e relativo ao DIRETORIO DO LINK. Com root vindo de `~/` — que e
# o que o setup gera — o root e relativo ao $HOME, e usa-lo como alvo produz
# `current -> <root>/releases/<id>` resolvido a partir de `<root>/`, ou seja um
# link quebrado. `ln` nao reclama, `ls` nao reclama, e o site responde 404 depois
# de um deploy que se declarou bem-sucedido.
#
# Este cenario PRECISA de root relativo: com um root absoluto o alvo errado
# ainda resolveria, e foi por isso que o bug passou pela suite — o fixture
# padrao usa /srv/staging.
# `current` pode ser um diretorio de verdade — o site que ja estava no ar antes
# do plugin. `mv -T` de um link sobre um diretorio nao substitui, entao sem
# tratar isso o primeiro deploy morre em activation_failed sem dizer o motivo.
#
# O mock de ssh nao executa o comando remoto (mv -T e GNU, nao roda no macOS do
# desenvolvedor), entao estes testes afirmam sobre o comando ENVIADO. E a mesma
# estrategia dos outros testes de ativacao.
# A condicao PRECISA das duas metades. Um symlink que aponta para diretorio
# tambem satisfaz -d, e e exatamente o que o nosso current e depois do primeiro
# deploy: com `-d` sozinho, todo deploy seguinte moveria o link valido para
# .current.old e derrubaria o site entre um comando e outro.
# O diretorio e movido, nunca apagado: e o conteudo que estava no ar.
# Ter posto conteudo do usuario de lado precisa chegar a quem chamou, senao vira
# um diretorio orfao que so aparece quando alguem for olhar o servidor.
# O stderr do ssh nao pode entrar na lista. `StrictHostKeyChecking=accept-new`
# imprime um aviso na PRIMEIRA conexao a um host — o cenario do primeiro deploy —
# e com `2>&1` ele virava uma release.
# A linha do marcador nunca pode aparecer como release. O filtro de antes era
# posicional (`tail -n +2`): bastava uma linha inesperada na frente para ele
# descartar a errada e promover o CURRENT.
# O estrago real acontecia aqui: o rollback escolhe a primeira release que nao e
# a atual, entao o ruido virava o ALVO. O symlink apontava para um caminho
# inexistente, o site respondia 404, e o adaptador reportava rolled_back.
# Falha continua reportando o stderr: separar as duas coisas nao pode custar o
# diagnostico.
# Ordem invertida nao e detalhe de estilo: o build le `current`, entao rodar
# antes do finalize construiria a imagem a partir da release ANTERIOR, e o
# deploy publicaria arquivos novos servindo codigo velho sem sinal disso.
