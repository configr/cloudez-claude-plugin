#!/usr/bin/env bats
# hooks/guard-deploy.sh: a matriz de allow/block.
#
# Convencao: exit 0 libera, exit 2 bloqueia com a razao em stderr.

load helpers/setup

setup() { make_project; }

# ---------------------------------------------------------------- libera ----

@test "comando sem relacao com deploy passa" {
  run guard "$(bash_payload 'ls -la')"
  [ "$status" -eq 0 ]
}

@test "projeto sem config passa" {
  rm .cloudez.yaml
  run guard "$(bash_payload 'cloudez-begin-deploy production abc K1')"
  [ "$status" -eq 0 ]
}

# Falha ABERTA e proposital: bloquear aqui transformaria um erro de indentacao
# em "nenhum comando roda", sem explicacao. Os adaptadores ja abortam com
# mensagem clara. As regras do guard so valem sobre config valida.
@test "config YAML quebrada libera em vez de travar tudo" {
  printf 'guard:\n  [\n' > .cloudez.yaml
  run guard "$(bash_payload 'cloudez-begin-deploy production abc K1')"
  [ "$status" -eq 0 ]
}

@test "staging com arvore limpa passa" {
  run guard "$(bash_payload 'cloudez-begin-deploy staging abc K1')"
  [ "$status" -eq 0 ]
}

# REGRESSAO: o proprio diretorio de estado deixava a arvore suja, entao a
# checagem bloqueava TODO deploy — inclusive staging — em qualquer projeto que
# nao tivesse .cloudez/ no .gitignore.
@test "diretorio de estado nao conta como arvore suja" {
  mkdir -p .cloudez/state
  echo '{}' > .cloudez/state/qualquer.json
  run guard "$(bash_payload 'cloudez-begin-deploy staging abc K1')"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------- bloqueia --

@test "arvore suja bloqueia qualquer deploy" {
  echo "wip" > pendente.txt
  run guard "$(bash_payload 'cloudez-begin-deploy staging abc K1')"
  [ "$status" -eq 2 ]
  [[ "$output" == *"nao commitadas"* ]]
  [[ "$output" == *pendente.txt* ]]
}

@test "rsync direto na raiz de producao bloqueia" {
  run guard "$(bash_payload 'rsync -az dist/ deploy@srv:/srv/production/current/')"
  [ "$status" -eq 2 ]
  [[ "$output" == *"rsync/ssh/scp direto"* ]]
}

@test "ssh direto na raiz de producao bloqueia" {
  run guard "$(bash_payload 'ssh deploy@srv "rm -rf /srv/production/releases"')"
  [ "$status" -eq 2 ]
}

@test "rsync para staging nao e bloqueado pela regra de bypass" {
  run guard "$(bash_payload 'rsync -az dist/ deploy@srv:/srv/staging/releases/x/')"
  [ "$status" -eq 0 ]
}

@test "producao a partir de branch nao permitida bloqueia" {
  git checkout -qb feature/x
  approve production
  run guard "$(bash_payload 'cloudez-begin-deploy production abc K1')"
  [ "$status" -eq 2 ]
  [[ "$output" == *"feature/x"* ]]
}

@test "producao sem aprovacao bloqueia e ensina como aprovar" {
  run guard "$(bash_payload 'cloudez-begin-deploy production abc K1')"
  [ "$status" -eq 2 ]
  [[ "$output" == *"sem aprovacao"* ]]
  # A mensagem precisa trazer o caminho ABSOLUTO: instalado, o plugin vive num
  # diretorio de cache, e bin/ so esta no PATH da tool Bash — nao no terminal
  # do usuario, que e onde a aprovacao tem de ser emitida.
  [[ "$output" == */bin/cloudez-approve* ]]
}

@test "aprovacao expirada bloqueia" {
  approve production "$(git rev-parse HEAD)" "$(( $(date +%s) - 3600 ))"
  run guard "$(bash_payload 'cloudez-begin-deploy production abc K1')"
  [ "$status" -eq 2 ]
  [[ "$output" == *expirou* ]]
}

@test "aprovacao de outro commit bloqueia" {
  approve production "0000000000000000000000000000000000000000"
  run guard "$(bash_payload 'cloudez-begin-deploy production abc K1')"
  [ "$status" -eq 2 ]
  [[ "$output" == *"commit"* ]]
}

@test "commitar depois de aprovar invalida a aprovacao" {
  approve production
  echo "mudanca" > novo.txt
  git add -A && git commit -qm "depois da aprovacao"
  run guard "$(bash_payload 'cloudez-begin-deploy production abc K1')"
  [ "$status" -eq 2 ]
}

# ------------------------------------------------------- producao aprovada --

@test "producao com aprovacao valida passa" {
  approve production
  run guard "$(bash_payload 'cloudez-begin-deploy production abc K1')"
  [ "$status" -eq 0 ]
}

@test "rollback nao exige arvore limpa" {
  approve production
  echo "wip" > pendente.txt
  run guard "$(bash_payload 'cloudez-rollback production')"
  [ "$status" -eq 0 ]
}

# ------------------------------------------------------------- tools MCP ----

@test "tool MCP em producao sem aprovacao bloqueia" {
  run guard "$(mcp_payload cloudez_finalize_deploy production)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"sem aprovacao"* ]]
}

@test "tool MCP em producao com aprovacao passa" {
  approve production
  run guard "$(mcp_payload cloudez_finalize_deploy production)"
  [ "$status" -eq 0 ]
}

@test "tool MCP em staging passa" {
  run guard "$(mcp_payload cloudez_begin_deploy staging)"
  [ "$status" -eq 0 ]
}

# ------------------------------------ deploy_id resolve o ambiente correto --

@test "finalize de um deploy de producao herda as regras de producao" {
  d=$(cloudez-begin-deploy production abc1234def K1 | jq -r .deploy_id)
  run guard "$(bash_payload "cloudez-finalize-deploy $d")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"sem aprovacao"* ]]
}
