# Testes do bin/cloudez-sync.cmd, o launcher Windows.
#
# Fora do bats de propósito: não há bash garantido no runner Windows, e o que se
# afirma aqui é sobre o comportamento do próprio `cmd`, não sobre o plugin.
#
# O launcher é a única peça do plugin que roda numa plataforma sem nenhuma outra
# cobertura. Os binários são compilados para windows/amd64 e windows/arm64 e
# versionados, mas até aqui ninguém os tinha executado.

$ErrorActionPreference = 'Continue'

$raiz = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cmd  = Join-Path $raiz 'bin\cloudez-sync.cmd'

$falhas = 0

function Verifica($nome, $condicao, $detalhe) {
  if ($condicao) {
    Write-Host "ok    $nome"
  } else {
    Write-Host "FALHA $nome"
    if ($detalhe) { Write-Host "      $detalhe" }
    $script:falhas += 1
  }
}

Verifica 'o launcher existe' (Test-Path $cmd) $cmd

# ── propagação do código de saída ──────────────────────────────────────────
#
# O `exit /b %ERRORLEVEL%` no fim do .cmd é o que faz o código do binário chegar
# a quem chamou. Sem ele o launcher sai 0 e uma falha de transporte passa por
# deploy bem-sucedido — a mesma classe de erro silencioso que o resto do plugin
# persegue.
#
# `cloudez-sync` sem argumentos sai com 2, e é justamente por não ser 0 nem 1
# que ele serve aqui: distingue "propagou" de "engoliu" e de "errou por conta
# própria".

$saida = & $cmd 2>&1
$codigo = $LASTEXITCODE

Verifica 'propaga o codigo de saida do binario' ($codigo -eq 2) "esperado 2, veio $codigo"
Verifica 'chegou a executar o binario' ("$saida" -match 'uso: cloudez-sync') "saida: $saida"

# ── resolução do nome pelo %~n0 ────────────────────────────────────────────
#
# O alvo sai do próprio nome do arquivo, com o prefixo `cloudez-` removido, para
# o mesmo conteúdo servir a qualquer comando futuro. Copiado com outro nome, o
# launcher tem de procurar OUTRO binário.

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("cloudez-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
Copy-Item $cmd (Join-Path $temp 'cloudez-inexistente.cmd')

$saida = & (Join-Path $temp 'cloudez-inexistente.cmd') 2>&1
$codigo = $LASTEXITCODE

Verifica 'binario ausente sai 1' ($codigo -eq 1) "esperado 1, veio $codigo"
Verifica 'o nome do alvo vem do arquivo, sem o prefixo' ("$saida" -match "inexistente") "saida: $saida"
Verifica 'a mensagem diz o que fazer' ("$saida" -match 'build\.sh') "saida: $saida"

# Sem `..\libexec` ao lado, o launcher cai para o próprio diretório — e não pode
# procurar num caminho com `cloudez-` no nome do binário.
Verifica 'o alvo nao carrega o prefixo cloudez-' (-not ("$saida" -match 'cloudez-inexistente-windows')) "saida: $saida"

Remove-Item -Recurse -Force $temp

if ($falhas -gt 0) {
  Write-Host ""
  Write-Host "$falhas falha(s)"
  exit 1
}

Write-Host ""
Write-Host 'launcher Windows OK'
