[CmdletBinding()]
param(
  [string]$FlutterPath,
  [string]$IsccPath,
  [string]$VcRuntimeDirectory,
  [string]$LandingPagePath = (Join-Path $PSScriptRoot '..\..\Smart-Reserve-Landing-Page')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$appRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$landingRoot = (Resolve-Path -LiteralPath $LandingPagePath).Path
$siteConfig = Join-Path $landingRoot 'src\config\site.ts'
if (-not (Test-Path -LiteralPath $siteConfig)) {
  throw 'LandingPagePath must point to the SmartReserve landing page checkout.'
}

if (-not $FlutterPath) {
  $flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
  if ($flutterCommand) {
    $FlutterPath = $flutterCommand.Source
  } else {
    $settingsPath = Join-Path $appRoot '.vscode\settings.json'
    if (Test-Path -LiteralPath $settingsPath) {
      $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
      if ($settings.PSObject.Properties['dart.flutterSdkPath']) {
        $FlutterPath = Join-Path $settings.'dart.flutterSdkPath' 'bin\flutter.bat'
      }
    }
  }
}
if (-not $FlutterPath -or -not (Test-Path -LiteralPath $FlutterPath)) {
  throw 'Flutter was not found. Supply -FlutterPath with the path to flutter.bat.'
}

if (-not $IsccPath) {
  $isccCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($isccCommand) { $IsccPath = $isccCommand.Source }
  foreach ($candidate in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe')
  )) {
    if (-not $IsccPath -and (Test-Path -LiteralPath $candidate)) { $IsccPath = $candidate }
  }
}
if (-not $IsccPath -or -not (Test-Path -LiteralPath $IsccPath)) {
  throw 'Install Inno Setup 6.7 or later from https://jrsoftware.org/isdl.php, or supply -IsccPath.'
}

if (-not $VcRuntimeDirectory) {
  $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
  if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Visual Studio was not found. Supply -VcRuntimeDirectory with the x64 Microsoft.VC*.CRT folder.'
  }
  $visualStudioPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if ($LASTEXITCODE -ne 0 -or -not $visualStudioPath) { throw 'Visual Studio C++ build tools were not found.' }
  $redistRoot = Join-Path $visualStudioPath 'VC\Redist\MSVC'
  $redistVersions = @(Get-ChildItem -LiteralPath $redistRoot -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending)
  foreach ($redistVersion in $redistVersions) {
    $crt = Get-ChildItem -LiteralPath (Join-Path $redistVersion.FullName 'x64') -Directory |
      Where-Object { $_.Name -match '^Microsoft\.VC\d+\.CRT$' } | Select-Object -First 1
    if ($crt) { $VcRuntimeDirectory = $crt.FullName; break }
  }
}
foreach ($runtimeFile in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
  if (-not $VcRuntimeDirectory -or -not (Test-Path -LiteralPath (Join-Path $VcRuntimeDirectory $runtimeFile))) {
    throw "The x64 redistributable runtime is incomplete: missing $runtimeFile."
  }
}

$pubspec = Get-Content -LiteralPath (Join-Path $appRoot 'pubspec.yaml') -Raw
$versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$')
if (-not $versionMatch.Success) { throw 'Expected version: major.minor.patch+build in pubspec.yaml.' }
$appVersion = $versionMatch.Groups[1].Value
$buildNumber = if ($versionMatch.Groups[2].Success) { $versionMatch.Groups[2].Value } else { '0' }
$siteVersionMatch = [regex]::Match((Get-Content -LiteralPath $siteConfig -Raw), "version:\s*'([^']+)'")
if (-not $siteVersionMatch.Success -or $siteVersionMatch.Groups[1].Value -ne $appVersion) {
  throw "Update the landing page's site.version to $appVersion before packaging this release."
}

Push-Location $appRoot
try {
  # The Windows x64 host builds x64 by default. Flutter has no --target-platform flag here.
  & $FlutterPath build windows --release
  if ($LASTEXITCODE -ne 0) { throw "Flutter build failed with exit code $LASTEXITCODE." }

  $releaseDirectory = Join-Path $appRoot 'build\windows\x64\runner\Release'
  foreach ($releaseFile in @('smartreserve.exe', 'flutter_windows.dll', 'data\app.so', 'data\flutter_assets')) {
    if (-not (Test-Path -LiteralPath (Join-Path $releaseDirectory $releaseFile))) {
      throw "Windows x64 release is incomplete: missing $releaseFile."
    }
  }

  $packagingRoot = [IO.Path]::GetFullPath((Join-Path $appRoot 'build\windows-installer'))
  $bundleDirectory = [IO.Path]::GetFullPath((Join-Path $packagingRoot 'bundle'))
  # Only reset this checkout's dedicated staging directory, never the release or destination.
  if ($bundleDirectory -ne (Join-Path $packagingRoot 'bundle') -or
      -not $packagingRoot.StartsWith($appRoot + '\build\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Unsafe packaging directory.'
  }
  if (Test-Path -LiteralPath $bundleDirectory) { Remove-Item -LiteralPath $bundleDirectory -Recurse -Force }
  New-Item -ItemType Directory -Path $bundleDirectory -Force | Out-Null
  Get-ChildItem -LiteralPath $releaseDirectory | Copy-Item -Destination $bundleDirectory -Recurse
  Get-ChildItem -LiteralPath $VcRuntimeDirectory -Filter '*.dll' | Copy-Item -Destination $bundleDirectory -Force
  # Linker outputs and debug symbols are not needed to run the installed app.
  Get-ChildItem -LiteralPath $bundleDirectory -Recurse -File |
    Where-Object { $_.Extension -in @('.lib', '.exp', '.pdb', '.ilk') } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
  $unexpectedFiles = @(Get-ChildItem -LiteralPath $bundleDirectory -Recurse -File |
    Where-Object { $_.Name -match '(^\.env|firebase-adminsdk|service-account)' })
  if ($unexpectedFiles.Count) { throw 'Release bundle contains credentials; inspect it before packaging.' }

  $outputDirectory = Join-Path $packagingRoot 'output'
  New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
  & $IsccPath "/DAppVersion=$appVersion" "/DAppFileVersion=$appVersion.$buildNumber" "/DBundleDir=$bundleDirectory" "/DOutputDir=$outputDirectory" "/DAppIcon=$(Join-Path $appRoot 'windows\runner\resources\app_icon.ico')" (Join-Path $appRoot 'windows\installer\smartreserve.iss')
  if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed with exit code $LASTEXITCODE." }

  $installerPath = Join-Path $outputDirectory 'SmartReserve-Setup.exe'
  $installer = Get-Item -LiteralPath $installerPath
  if ($installer.Length -ge 100000000) {
    throw 'Installer exceeds the 100 MB website upload budget. Do not publish or switch hosting without resolving this.'
  }
  Push-Location $landingRoot
  try {
    $sourceFiles = @(& git ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect landing page files for the deployment size check.' }
    $sourceBytes = 0L
    foreach ($sourceFile in $sourceFiles) {
      if ($sourceFile -eq 'public/downloads/SmartReserve-Setup.exe') { continue }
      $sourcePath = Join-Path $landingRoot $sourceFile
      if (Test-Path -LiteralPath $sourcePath -PathType Leaf) { $sourceBytes += (Get-Item -LiteralPath $sourcePath).Length }
    }
    if ($sourceBytes + $installer.Length -ge 100000000) {
      throw 'Website source plus installer exceeds the 100 MB Hobby CLI upload budget. Publication must wait.'
    }
  } finally { Pop-Location }

  $downloadsDirectory = Join-Path $landingRoot 'public\downloads'
  New-Item -ItemType Directory -Path $downloadsDirectory -Force | Out-Null
  $destination = Join-Path $downloadsDirectory 'SmartReserve-Setup.exe'
  Copy-Item -LiteralPath $installerPath -Destination $destination -Force
  $checksum = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
  Write-Output "Created SmartReserve $appVersion (build $buildNumber): $destination"
  Write-Output "Size: $($installer.Length) bytes; SHA256: $checksum"
} finally { Pop-Location }
