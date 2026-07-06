param(
    [string] $Alias = "jmapi",
    [string] $KeyStorePassword = "",
    [string] $KeyPassword = ""
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command keytool -ErrorAction SilentlyContinue)) {
    throw "keytool was not found. Install JDK 17 or run this script in GitHub Codespaces."
}

function New-RandomSecret {
    -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char] $_ })
}

if ($KeyStorePassword -eq "") {
    $KeyStorePassword = New-RandomSecret
}
if ($KeyPassword -eq "") {
    $KeyPassword = New-RandomSecret
}

keytool `
    -genkeypair `
    -v `
    -keystore signingkey.jks `
    -alias $Alias `
    -keyalg RSA `
    -keysize 2048 `
    -validity 10000 `
    -storepass $KeyStorePassword `
    -keypass $KeyPassword `
    -dname "CN=JM API Extension,O=Personal,C=CN"

$base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("signingkey.jks"))
Set-Content -LiteralPath "signingkey.jks.base64" -Value $base64 -Encoding ASCII

Write-Host ""
Write-Host "Add these GitHub Actions secrets:"
Write-Host "SIGNING_KEYSTORE_BASE64=$base64"
Write-Host "ALIAS=$Alias"
Write-Host "KEY_STORE_PASSWORD=$KeyStorePassword"
Write-Host "KEY_PASSWORD=$KeyPassword"

