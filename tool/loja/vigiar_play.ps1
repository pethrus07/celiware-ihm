<#
.SYNOPSIS
  Avisa quando o Ware IoT for aprovado e aparecer na Google Play.
.DESCRIPTION
  A página pública do app na loja dá 404 enquanto ele está em revisão e passa
  a abrir (200) quando o Google aprova (a publicação gerenciada está
  desligada, então aprovado = publicado). Uma tarefa do Agendador do Windows
  roda este script de hora em hora; quando a página abre, ele mostra uma
  janela de aviso, abre a página no navegador, deixa um arquivo na Área de
  Trabalho e apaga a própria tarefa.

  Não usa login, conta nem credencial: só olha a página pública.
.EXAMPLE
  pwsh tool/loja/vigiar_play.ps1 -Instalar   # cria a tarefa (de hora em hora)
  pwsh tool/loja/vigiar_play.ps1             # confere uma vez agora
  pwsh tool/loja/vigiar_play.ps1 -Remover    # apaga a tarefa
#>
param([switch]$Instalar, [switch]$Remover)
$ErrorActionPreference = "Stop"
$Tarefa = "Ware IoT - vigiar aprovacao na Play"
$Url = "https://play.google.com/store/apps/details?id=com.celiware.ihm&hl=pt_BR"
$Pasta = Join-Path $env:LOCALAPPDATA "ware-iot"
$Log = Join-Path $Pasta "vigia-play.log"

if ($Remover) {
  Unregister-ScheduledTask -TaskName $Tarefa -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Tarefa removida."
  return
}

if ($Instalar) {
  # O script roda de uma cópia fora do repositório, para não depender da pasta do projeto.
  New-Item -ItemType Directory -Force $Pasta | Out-Null
  $destino = Join-Path $Pasta "vigiar_play.ps1"
  Copy-Item $PSCommandPath $destino -Force
  # conhost --headless: roda sem piscar janela de hora em hora.
  $acao = New-ScheduledTaskAction -Execute "conhost.exe" `
    -Argument "--headless pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$destino`""
  $gatilho = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 30)
  $config = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  Register-ScheduledTask -TaskName $Tarefa -Action $acao -Trigger $gatilho -Settings $config `
    -Description "Confere de hora em hora se o Ware IoT já está na Google Play (tool/loja/vigiar_play.ps1)." -Force | Out-Null
  Write-Host "Tarefa '$Tarefa' criada: confere de hora em hora, por até 30 dias."
  return
}

New-Item -ItemType Directory -Force $Pasta | Out-Null
try {
  $codigo = (Invoke-WebRequest -Uri $Url -Method Get -SkipHttpErrorCheck -TimeoutSec 30 -UserAgent "Mozilla/5.0").StatusCode
} catch {
  $codigo = "erro: $($_.Exception.Message)"
}
"$(Get-Date -Format 'yyyy-MM-dd HH:mm')  $codigo" | Add-Content $Log -Encoding utf8

if ($codigo -eq 200) {
  $aviso = Join-Path ([Environment]::GetFolderPath("Desktop")) "WARE IOT APROVADO NA PLAY.txt"
  "O Ware IoT apareceu na Google Play em $(Get-Date -Format 'dd/MM/yyyy HH:mm'):`r`n$Url" | Set-Content $aviso -Encoding utf8
  Start-Process $Url
  Add-Type -AssemblyName PresentationFramework
  [System.Windows.MessageBox]::Show("O Ware IoT foi aprovado e já está na Google Play.", "Ware IoT", "OK", "Information") | Out-Null
  Unregister-ScheduledTask -TaskName $Tarefa -Confirm:$false -ErrorAction SilentlyContinue
}
