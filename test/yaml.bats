#!/usr/bin/env bats
# bin/_yaml.sh: a cadeia de fallback de parsers.
#
# Cada parser e exercitado isoladamente forcando o PATH, porque na pratica cada
# maquina tera um deles — e o bug de um so aparece se ele for o escolhido.

load helpers/setup

setup() {
  make_project
  FIXTURE="$TEST_TMP/amostra.yaml"
  cat > "$FIXTURE" <<'YAML'
escalar: valor
numero: 42
booleano: true
lista: [a, b]
aninhado:
  chave: interna
YAML
}

# yaml_via <PATH> — converte a fixture com o PATH dado
yaml_via() {
  env PATH="$1" /bin/bash -c \
    "source '$PLUGIN_ROOT/bin/_yaml.sh'; yaml_to_json '$FIXTURE'"
}

# only_with <comando> — PATH minimo contendo apenas o parser pedido.
#
# `uname` entra junto porque o ruby do macOS o invoca ao carregar rbconfig; sem
# ele o interpretador nem sobe. Isolar o parser nao pode significar quebrar o
# ambiente minimo de que ele depende.
only_with() {
  local bin="$TEST_TMP/only-$1" c
  mkdir -p "$bin"
  for c in "$1" uname; do
    [ -e "$bin/$c" ] || ln -sf "$(command -v "$c")" "$bin/$c" 2>/dev/null
  done
  printf '%s' "$bin"
}

@test "estrutura completa sobrevive a conversao" {
  run yaml_via "$PATH"
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .escalar)" = "valor" ]
  [ "$(jq_field "$output" .numero)" = "42" ]
  [ "$(jq_field "$output" .booleano)" = "true" ]
  [ "$(jq_field "$output" '.lista | length')" = "2" ]
  [ "$(jq_field "$output" .aninhado.chave)" = "interna" ]
}

@test "parser: ruby" {
  command -v ruby >/dev/null || skip "ruby ausente"
  run yaml_via "$(only_with ruby)"
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .escalar)" = "valor" ]
}

@test "parser: python3 com PyYAML" {
  command -v python3 >/dev/null || skip "python3 ausente"
  python3 -c 'import yaml' 2>/dev/null || skip "PyYAML ausente"
  run yaml_via "$(only_with python3)"
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .escalar)" = "valor" ]
}

# As duas implementacoes populares de `yq` sao incompativeis e compartilham o
# nome do comando. Tentamos as duas sintaxes em vez de parsear --version.
@test "parser: yq (qualquer das duas implementacoes)" {
  command -v yq >/dev/null || skip "yq ausente"
  run yaml_via "$(only_with yq):$(dirname "$(command -v jq)")"
  [ "$status" -eq 0 ]
  [ "$(jq_field "$output" .escalar)" = "valor" ]
}

@test "nenhum parser disponivel devolve codigo 3" {
  run env PATH=/nao-existe /bin/bash -c \
    "source '$PLUGIN_ROOT/bin/_yaml.sh'; yaml_to_json '$FIXTURE'"
  [ "$status" -eq 3 ]
}

@test "YAML invalido devolve codigo 1, nao 3" {
  printf 'a:\n  b: [\n   c\n' > "$FIXTURE"
  run yaml_via "$PATH"
  [ "$status" -eq 1 ]
}

@test "resolve_config prefere .yaml sobre .yml" {
  : > .cloudez.yml
  run bash -c "source '$PLUGIN_ROOT/bin/_yaml.sh'; resolve_config"
  [ "$output" = ".cloudez.yaml" ]
}

@test "resolve_config cai para .yml quando so ele existe" {
  mv .cloudez.yaml .cloudez.yml
  run bash -c "source '$PLUGIN_ROOT/bin/_yaml.sh'; resolve_config"
  [ "$output" = ".cloudez.yml" ]
}

@test "CLOUDEZ_CONFIG sobrepoe a deteccao automatica" {
  run bash -c "CLOUDEZ_CONFIG=custom.yaml; source '$PLUGIN_ROOT/bin/_yaml.sh'; resolve_config"
  [ "$output" = "custom.yaml" ]
}
