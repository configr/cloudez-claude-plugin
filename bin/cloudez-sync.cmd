@echo off
rem Launcher Windows: quem chama "cloudez-sync" sem extensao cai aqui pelo
rem PATHEXT. Existe porque o shebang do script Node vizinho nao vale nada
rem no cmd nem no PowerShell.
rem
rem O alvo sai do nome deste arquivo (%~n0), entao o mesmo conteudo serve a
rem qualquer comando futuro sem copia editada.
rem
rem O `exit /b %ERRORLEVEL%` final propaga o codigo de saida do node; sem
rem ele uma falha passaria por sucesso.

setlocal

set "ALVO=%~dp0%~n0"

if not exist "%ALVO%" (
  echo cloudez: script '%~n0' ausente ^(%ALVO%^). >&2
  exit /b 1
)

rem Sem esta mensagem, o cmd so responde "node nao e reconhecido", que
rem nao aponta para o Node ser pre-requisito do plugin.
where node >nul 2>nul
if errorlevel 1 (
  echo cloudez: node nao encontrado no PATH. O plugin exige Node 20 ou mais novo. >&2
  exit /b 1
)

node "%ALVO%" %*
exit /b %ERRORLEVEL%
