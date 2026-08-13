#!/usr/bin/env bats
# bin/_yaml.sh: onde mora a config do projeto.
#
# Este arquivo ja cobriu uma cadeia de quatro parsers YAML — yq nas duas
# implementacoes incompativeis, python3 com PyYAML, e ruby. Ela saiu junto com os
# adaptadores de deploy: quem le a config agora e o servidor MCP, em TypeScript,
# e o unico adaptador que ainda precisa do arquivo so precisa saber ONDE ele
# fica.

load helpers/setup

setup() { make_project; }

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
