# Testes do bin/cloudez-sync.cmd, o launcher Windows.
#
# Fora do bats de propósito: não há bash garantido no runner Windows, e o que se
# afirma aqui é sobre o comportamento do próprio `cmd`, não sobre o plugin.
#
# O launcher é a única peça do plugin que roda numa plataforma sem nenhuma outra
# cobertura. Ele deixou de invocar um `.exe` em libexec/ e passou a invocar o
# script Node irmão — o que MUDOU foi o alvo, não a razão de existir: no Windows o
# shebang não vale nada, e quem chama pelo cmd ou pelo PowerShell precisa que
# alguém chame o node explicitamente.

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
# O `exit /b %ERRORLEVEL%` no fim do .cmd é o que faz o código do node chegar a
# quem chamou. Sem ele o launcher sai 0 e uma falha de transporte passa por deploy
# bem-sucedido — a mesma classe de erro silencioso que o resto do plugin persegue.
#
# `cloudez-sync` sem argumentos sai com 2, e é justamente por não ser 0 nem 1 que
# ele serve aqui: distingue "propagou" de "engoliu" e de "errou por conta própria".

$saida = & $cmd 2>&1
$codigo = $LASTEXITCODE

Verifica 'propaga o codigo de saida do script' ($codigo -eq 2) "esperado 2, veio $codigo"
Verifica 'chegou a executar o script' ("$saida" -match 'uso: cloudez-sync') "saida: $saida"

# ── resolução do nome pelo %~n0 ────────────────────────────────────────────
#
# O alvo sai do próprio nome do arquivo, para o mesmo conteúdo servir a qualquer
# comando futuro sem uma cópia editada. Copiado com outro nome e sem o script
# irmão ao lado, o launcher tem de procurar OUTRO alvo e falhar dizendo qual.
#
# Antes o alvo era `libexec\<nome-sem-prefixo>-windows-<arch>.exe`; hoje é o irmão
# `bin\<nome>`. A propriedade testada é a mesma: o nome do arquivo decide, não uma
# string fixa dentro dele.

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("cloudez-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $temp | Out-Null
Copy-Item $cmd (Join-Path $temp 'cloudez-inexistente.cmd')

$saida = & (Join-Path $temp 'cloudez-inexistente.cmd') 2>&1
$codigo = $LASTEXITCODE

Verifica 'alvo ausente sai 1' ($codigo -eq 1) "esperado 1, veio $codigo"
Verifica 'o nome do alvo vem do arquivo' ("$saida" -match 'cloudez-inexistente') "saida: $saida"
Verifica 'a mensagem diz o que falta' ("$saida" -match 'ausente') "saida: $saida"

# O alvo é o irmão de mesmo nome, e não um binário por plataforma: uma mensagem
# falando de libexec ou de arquitetura significaria que o .cmd velho ficou para
# trás numa cópia.
Verifica 'o alvo nao e mais um binario por plataforma' (-not ("$saida" -match 'libexec|windows-amd64|windows-arm64')) "saida: $saida"

Remove-Item -Recurse -Force $temp

if ($falhas -gt 0) {
  Write-Host ""
  Write-Host "$falhas falha(s)"
  exit 1
}

Write-Host ""
Write-Host 'launcher Windows OK'

# `exit 0` explícito, e não queda pelo fim do arquivo.
#
# Sem ele o script herda o $LASTEXITCODE do último comando nativo — que aqui é o
# .cmd copiado, saindo 1 DE PROPÓSITO no teste de alvo ausente. O `shell: pwsh` do
# Actions propaga esse valor, então o job falhava depois de imprimir que tudo
# passou.
#
# É a mesma inversão que este arquivo existe para caçar no launcher, do outro
# lado: lá o risco é uma falha sair 0, aqui foi um sucesso sair 1.
exit 0
