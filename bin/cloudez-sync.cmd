@echo off
rem Launcher Windows. Par do script Node ao lado — quem chama usa "cloudez-sync"
rem sem extensao e o PATHEXT resolve para este arquivo aqui.
rem
rem Existe porque no Windows o shebang nao vale nada: o `#!/usr/bin/env node` do
rem arquivo vizinho funciona no Git Bash e em POSIX, mas quem chama pelo cmd ou
rem pelo PowerShell precisa que alguem invoque o node explicitamente.
rem
rem Como na versao que invocava um .exe, o alvo sai do NOME deste arquivo (%~n0),
rem entao o mesmo conteudo serve a qualquer comando futuro sem uma copia editada.
rem A diferenca e que agora o alvo e o script irmao, e nao um binario em libexec/.
rem
rem O `exit /b %ERRORLEVEL%` no final nao e detalhe: sem ele o codigo de saida do
rem node nao chega a quem chamou e uma falha passa por sucesso.

setlocal

set "ALVO=%~dp0%~n0"

if not exist "%ALVO%" (
  echo cloudez: script '%~n0' ausente ^(%ALVO%^). >&2
  exit /b 1
)

rem O node e pre-requisito do plugin, mas a mensagem precisa dizer isso: sem ela o
rem cmd responde "node nao e reconhecido", que nao aponta para ca.
where node >nul 2>nul
if errorlevel 1 (
  echo cloudez: node nao encontrado no PATH. O plugin exige Node 20 ou mais novo. >&2
  exit /b 1
)

node "%ALVO%" %*
exit /b %ERRORLEVEL%
