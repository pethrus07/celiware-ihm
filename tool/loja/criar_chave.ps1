<#
.SYNOPSIS
  Cria a chave de upload do Ware IoT (Play Store) e o android/key.properties.
.DESCRIPTION
  Uma vez, para sempre (docs/PUBLICACAO.md, passos 5 e 6). Quem roda digita a
  senha; ela nunca aparece na tela nem vai para a linha de comando do keytool
  (vai por variável de ambiente, -storepass:env).

  - A chave (.jks) fica FORA do repositório, em ~/chaves/ware-iot-upload.jks.
  - android/key.properties (ignorado pelo git) aponta para ela.
  - Nunca sobrescreve: se a chave ou o key.properties já existem, para.

  Depois de rodar: guardar o .jks e a senha no cofre de credenciais, mais uma
  cópia do .jks fora deste computador. Perder a chave obriga a pedir a troca
  ao Google; vazar permite publicar como a Celiware.
.PARAMETER Ensaio
  Só para conferir o script: cria uma chave descartável na pasta indicada em
  -Pasta, com senha de teste, e NÃO escreve o key.properties.
.EXAMPLE
  pwsh tool/loja/criar_chave.ps1
#>
param(
  [switch]$Ensaio,
  # Sem perguntar: sorteia uma senha forte e a grava em <Pasta>\ware-iot-upload-SENHA.txt
  # (só o dono lê), para ir ao cofre e depois ser apagada. Nunca imprime a senha.
  [switch]$GerarSenha,
  [string]$Pasta = (Join-Path $env:USERPROFILE "chaves")
)
$ErrorActionPreference = "Stop"
$raiz = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$props = Join-Path $raiz "android\key.properties"
$jks = Join-Path $Pasta "ware-iot-upload.jks"

# keytool: o do JDK do JAVA_HOME (o mesmo que o Gradle usa) ou o do PATH.
$keytool = if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\keytool.exe"))) {
  Join-Path $env:JAVA_HOME "bin\keytool.exe"
} else { (Get-Command keytool -ErrorAction Stop).Source }

if (Test-Path $jks) { throw "Já existe uma chave em $jks. Não sobrescrevo: use a que existe ou apague de propósito." }
if (-not $Ensaio -and (Test-Path $props)) { throw "Já existe $props. Não sobrescrevo." }

if ($Ensaio) {
  $senha = "ensaio-descartavel-123"
} elseif ($GerarSenha) {
  # 24 caracteres sorteados pelo gerador criptográfico, sem símbolos que confundem ao copiar.
  $alfabeto = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789".ToCharArray()
  $bytes = [byte[]]::new(24)
  [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
  $senha = -join ($bytes | ForEach-Object { $alfabeto[$_ % $alfabeto.Length] })
} else {
  Write-Host ""
  Write-Host "Senha da chave de upload do Ware IoT (12 caracteres ou mais)." -ForegroundColor Cyan
  Write-Host "Ela vai para o cofre de credenciais junto com o arquivo .jks."
  $s1 = Read-Host "Senha" -AsSecureString
  $s2 = Read-Host "Repita a senha" -AsSecureString
  $txt = { param($s) [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) }
  $senha = & $txt $s1
  if ($senha -ne (& $txt $s2)) { throw "As duas senhas não batem. Nada foi criado." }
  if ($senha.Length -lt 12) { throw "Senha curta demais (mínimo 12). Nada foi criado." }
}

if (-not (Test-Path $Pasta)) {
  New-Item -ItemType Directory -Path $Pasta | Out-Null
  # Só o dono da conta Windows lê a pasta.
  icacls $Pasta /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
}

$env:WAREIOT_SENHA_CHAVE = $senha
try {
  & $keytool -genkeypair -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 `
    -alias upload -keystore $jks `
    -dname "CN=Celiware, O=Celiware Solucoes Tecnologicas Ltda, C=BR" `
    -storepass:env WAREIOT_SENHA_CHAVE -keypass:env WAREIOT_SENHA_CHAVE 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path $jks)) { throw "O keytool não criou a chave (código $LASTEXITCODE)." }
  $sha = (& $keytool -list -v -keystore $jks -alias upload -storepass:env WAREIOT_SENHA_CHAVE) |
    Select-String "SHA256:" | Select-Object -First 1
} finally {
  Remove-Item Env:\WAREIOT_SENHA_CHAVE -ErrorAction SilentlyContinue
}

if (-not $Ensaio) {
  $caminho = $jks -replace '\\', '/'
  @(
    "# Gerado por tool/loja/criar_chave.ps1 em $(Get-Date -Format 'dd/MM/yyyy HH:mm'). NUNCA vai para o git."
    "storeFile=$caminho"
    "storePassword=$senha"
    "keyAlias=upload"
    "keyPassword=$senha"
  ) | Set-Content $props -Encoding utf8
  if ($GerarSenha) {
    @(
      "Senha da chave de upload do Ware IoT (arquivo $jks, alias upload)."
      "Copie para o cofre de credenciais junto com o .jks e APAGUE este arquivo."
      ""
      $senha
    ) | Set-Content (Join-Path $Pasta "ware-iot-upload-SENHA.txt") -Encoding utf8
  }
}
$senha = $null

Write-Host ""
Write-Host "Chave criada: $jks" -ForegroundColor Green
if ($sha) { Write-Host "Impressão digital ($($sha.Line.Trim()))" }
if ($Ensaio) {
  Write-Host "Ensaio: key.properties NÃO foi escrito. Apague a chave descartável." -ForegroundColor Yellow
} else {
  Write-Host "android/key.properties escrito (fora do git)."
  Write-Host ""
  Write-Host "Agora: guarde o arquivo .jks e a senha no cofre, e uma cópia do .jks fora deste computador." -ForegroundColor Cyan
}
