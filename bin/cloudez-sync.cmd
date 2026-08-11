@echo off
rem Launcher Windows. Par do script POSIX — quem chama usa "cloudez-sync" sem
rem extensao e o PATHEXT resolve para este arquivo aqui.
rem
rem Como no par POSIX, o alvo sai do nome do arquivo (%~n0) com o prefixo
rem "cloudez-" removido, entao o mesmo conteudo serve a qualquer comando.
rem
rem O `exit /b %ERRORLEVEL%` no final nao e detalhe: sem ele o codigo de saida
rem do binario nao chega a quem chamou e uma falha passa por sucesso.

setlocal

set "NAME=%~n0"
if /i "%NAME:~0,8%"=="cloudez-" set "NAME=%NAME:~8%"

set "LIBEXEC=%~dp0"
if exist "%~dp0..\libexec\" set "LIBEXEC=%~dp0..\libexec\"

set "ARCH=amd64"
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "ARCH=arm64"

set "EXE=%LIBEXEC%%NAME%-windows-%ARCH%.exe"

if not exist "%EXE%" (
  echo cloudez: binario '%NAME%' ausente ^(%EXE%^). >&2
  echo cloudez: rode build.sh no diretorio do plugin. >&2
  exit /b 1
)

"%EXE%" %*
exit /b %ERRORLEVEL%
