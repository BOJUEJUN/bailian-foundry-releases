<#
.SYNOPSIS
  Invoke-WindowsQa.ps1 — bounded Windows acceptance runner for 百炼机关.
  Runs ONLY on Windows (CI runner or test PC). Everything lives under a
  disposable -WorkRoot plus the app's own per-user install dir. Never touches
  unrelated paths/processes. No secrets. Prints PASS/FAIL lines and exits 0/1.

.PARAMETER SetupExe    Path/URL to BailianFoundry-Setup-*.exe (NSIS /S)
.PARAMETER UpdateZip   Optional path/URL to update zip (validated vs manifest)
.PARAMETER ManifestUrl Optional path/URL of update.json (paired with UpdateZip)
.PARAMETER HelperExe   Optional path/URL to BailianUpdateHelper.exe for the
                       apply/no-mutation test on a disposable fixture install.
.PARAMETER WorkRoot    Disposable root (default: $env:TEMP\blqa-<rand>)
.PARAMETER BootTimeoutSec  Max seconds waiting for game window/log (default 45)
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SetupExe,
  [string]$UpdateZip = "",
  [string]$ManifestUrl = "",
  [string]$HelperExe = "",
  [string]$WorkRoot = (Join-Path $env:TEMP ("blqa-" + [guid]::NewGuid().ToString("N").Substring(0,8))),
  [int]$BootTimeoutSec = 45
)

$ErrorActionPreference = 'Continue'
$script:pass = 0; $script:fail = 0; $script:results = @()
function Rec([string]$name, [bool]$ok, [string]$note = "") {
  if ($ok) { $script:pass++ } else { $script:fail++ }
  $script:results += [pscustomobject]@{ name=$name; ok=$ok; note=$note }
  Write-Host ("[{0}] {1}{2}" -f ($(if($ok){'PASS'}else{'FAIL'})), $name, $(if($note){" — $note"}))
}
function Get-Local([string]$p) {
  if ($p -match '^https?://') {
    $dst = Join-Path $WorkRoot ([IO.Path]::GetFileName($p))
    Invoke-WebRequest -Uri $p -OutFile $dst -TimeoutSec 300 -UseBasicParsing
    return $dst
  }
  return $p
}

New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
$logDir = Join-Path $WorkRoot 'logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Write-Host "WorkRoot=$WorkRoot"
$rootDir  = Join-Path $env:LOCALAPPDATA 'BailianFoundry'        # updater root + uninstaller home
$appExe   = Join-Path $rootDir 'app\BailianFoundry.exe'
$appDir   = Split-Path $appExe
$uninstExe= Join-Path $rootDir 'Uninstall.exe'                  # NSI writes it beside app\
$playerLog= Join-Path $env:USERPROFILE 'AppData\LocalLow\Bailian\百炼机关\Player.log'
$proc = $null

try {
  # ---------- 1. silent per-user install -------------------------------------
  $setup = Get-Local $SetupExe
  Rec 'setup-exists' (Test-Path $setup) $setup
  $instLog = Join-Path $logDir 'install.out.log'
  $instErr = Join-Path $logDir 'install.err.log'
  $ip = Start-Process -FilePath $setup -ArgumentList '/S' -PassThru -Wait `
        -RedirectStandardOutput $instLog -RedirectStandardError $instErr
  Rec 'installer-exit-0' ($ip.ExitCode -eq 0) "exit=$($ip.ExitCode)"

  Rec 'exe-installed' (Test-Path $appExe) $appExe
  Rec 'unity-data-present' (Test-Path (Join-Path $appDir 'BailianFoundry_Data')) 'BailianFoundry_Data/'
  Rec 'unityplayer-dll' (Test-Path (Join-Path $appDir 'UnityPlayer.dll')) ''
  Rec 'helper-shipped' (Test-Path (Join-Path $appDir 'BailianUpdateHelper.exe')) 'required for apply step'
  $fileInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($appExe)
  Rec 'exe-version-info' ($fileInfo.ProductName -ne '') "ProductName=$($fileInfo.ProductName) FileVer=$($fileInfo.FileVersion)"
  Rec 'uninstaller-present' (Test-Path $uninstExe) $uninstExe
  Rec 'no-admin-needed' ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') 'not SYSTEM'

  # ---------- 2. native boot evidence ----------------------------------------
  if (Test-Path $playerLog) { Remove-Item $playerLog -Force }
  $proc = Start-Process -FilePath $appExe -PassThru
  $booted = $false; $t = 0
  while ($t -lt $BootTimeoutSec -and -not $booted) {
    Start-Sleep 2; $t += 2
    $proc.Refresh()
    if (-not $proc.HasExited -and $proc.MainWindowTitle -match '百炼') { $booted = $true }
    elseif (Test-Path $playerLog -and (Get-Content $playerLog -Raw -ErrorAction SilentlyContinue) -match 'phase=Menu') { $booted = $true }
  }
  Rec 'game-boots-window' $booted "title='$($proc.MainWindowTitle)' after ${t}s"
  Rec 'process-alive' (-not $proc.HasExited) "pid=$($proc.Id)"
  if (Test-Path $playerLog) {
    $log = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
    Rec 'playerlog-phase-lines' ($log -match 'phase=') 'instrumented phases present'
    Rec 'playerlog-no-errors' ($log -notmatch 'Exception|MissingReference|shader.*(error|not found)') ''
  } else { Rec 'playerlog-phase-lines' $false 'Player.log missing'; Rec 'playerlog-no-errors' $false 'Player.log missing' }

  # ---------- 3. graceful close ----------------------------------------------
  if ($proc -and -not $proc.HasExited) {
    $null = $proc.CloseMainWindow()
    $gone = $proc.WaitForExit(8000)
    if (-not $gone) { $proc.Kill(); $proc.WaitForExit(5000) }
    Rec 'game-close-clean' $gone ($(if($gone){"exit=$($proc.ExitCode)"}else{'had to Kill'}))
  }

  # ---------- 4. uninstall preserves updater root/user data -------------------
  $marker = Join-Path $rootDir 'qa-preserve-marker.txt'
  'keepme' | Set-Content $marker
  if (Test-Path $uninstExe) {
    $up = Start-Process -FilePath $uninstExe -ArgumentList '/S' -PassThru -Wait
    Rec 'uninstall-exit-0' ($up.ExitCode -eq 0) "exit=$($up.ExitCode)"
    Start-Sleep 2
    Rec 'app-removed' (-not (Test-Path $appExe)) ''
    Rec 'user-data-preserved' (Test-Path $marker) 'updater-root marker survived uninstall'
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
  } else { Rec 'uninstall-exit-0' $false 'uninstaller missing — skipped'; Rec 'app-removed' $false 'skipped'; Rec 'user-data-preserved' $false 'skipped' }

  # ---------- 5. unicode + spaced install path --------------------------------
  # NSIS /D must be the LAST argument and is taken literally (spaces ok).
  $uDir = Join-Path $WorkRoot '百炼 游戏 dir'   # CJK + spaces, under WorkRoot
  $uip = Start-Process -FilePath $setup -ArgumentList ('/S /D=' + $uDir) -PassThru -Wait
  Start-Sleep 2
  $uExe = Join-Path $uDir 'BailianFoundry.exe'
  Rec 'unicode-path-install' ($uip.ExitCode -eq 0 -and (Test-Path $uExe)) "dir='$uDir' exit=$($uip.ExitCode)"
  if (Test-Path $uExe) {
    $uproc = Start-Process -FilePath $uExe -PassThru
    $uboot = $uproc.WaitForInputIdle(20000)
    Start-Sleep 3; $uproc.Refresh()
    Rec 'unicode-path-boots' (-not $uproc.HasExited) "pid=$($uproc.Id)"
    if (-not $uproc.HasExited) { $null = $uproc.CloseMainWindow(); if (-not $uproc.WaitForExit(8000)) { $uproc.Kill() } }
    # registry now points at unicode dir; shared Uninstall.exe removes it
    if (Test-Path $uninstExe) {
      $uup = Start-Process -FilePath $uninstExe -ArgumentList '/S' -PassThru -Wait
      Start-Sleep 2
      Rec 'unicode-path-uninstall' (-not (Test-Path $uExe)) "exit=$($uup.ExitCode)"
    }
  }

  # ---------- 6. shipped update artifacts (manifest + zip graph) --------------
  if ($UpdateZip -ne '' -and $ManifestUrl -ne '') {
    $uz = Get-Local $UpdateZip
    $mf = Get-Local $ManifestUrl
    Rec 'update-artifacts-fetched' ((Test-Path $uz) -and (Test-Path $mf)) "$uz | $mf"

    $man = $null
    try { $man = Get-Content $mf -Raw | ConvertFrom-Json } catch {}
    Rec 'manifest-parses' ($null -ne $man) ''
    if ($man) {
      Rec 'manifest-schema-1' ($man.schemaVersion -eq 1) "schemaVersion=$($man.schemaVersion)"
      Rec 'manifest-semver' ($man.version -match '^v?\d+\.\d+(\.\d+)?(-[0-9A-Za-z.\-]+)?(\+[0-9A-Za-z.\-]+)?$') "version=$($man.version)"
      $e = $man.platforms.'windows-x64'
      Rec 'manifest-platform-entry' ($null -ne $e) ''
      if ($e) {
        Rec 'manifest-https-url' ($e.url -match '^https://[^/]+') "url=$($e.url)"
        Rec 'manifest-sha256-format' ($e.sha256 -match '^[0-9a-f]{64}$') ''
        Rec 'manifest-format-zip' ($e.format -eq 'zip') "format=$($e.format)"
        $zlen = (Get-Item $uz).Length
        Rec 'manifest-size-matches-zip' ([long]$e.size -eq $zlen) "declared=$($e.size) actual=$zlen"
        $zsha = (Get-FileHash $uz -Algorithm SHA256).Hash.ToLowerInvariant()
        Rec 'manifest-sha256-matches-zip' ($zsha -eq $e.sha256) "declared=$($e.sha256.Substring(0,12))… actual=$($zsha.Substring(0,12))…"
      }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
      $zip = [IO.Compression.ZipFile]::OpenRead($uz)
      $bad = $zip.Entries | Where-Object {
        $n = $_.FullName
        $bs = $n -replace '/', '\'
        $n.StartsWith('/') -or $bs.StartsWith('\') -or $n -match '^[a-zA-Z]:' `
          -or ($n -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0 `
          -or $n -match '[<>"|?*]' -or ($n -split '[\\/]' | Where-Object { $_ -match '^(CON|NUL|AUX|PRN|COM[1-9]|LPT[1-9])$' }).Count -gt 0 }
      Rec 'update-zip-flat-safe' ($bad.Count -eq 0) ("suspect entries: " + (($bad | ForEach-Object FullName) -join ','))
      $exeAtRoot = $zip.Entries | Where-Object { $_.FullName -eq 'BailianFoundry.exe' }
      Rec 'update-zip-exe-at-root' ($null -ne $exeAtRoot) ''
      $zip.Dispose()
    } catch { Rec 'update-zip-flat-safe' $false "unreadable zip: $_"; Rec 'update-zip-exe-at-root' $false 'skipped' }
  }

  # ---------- 7. update helper on a DISPOSABLE fixture install ----------------
  # Mimics the UpdatePaths layout under WorkRoot only:
  #   <fx>\app\BailianFoundry.exe + _Data\   (pretend installed game, not running)
  #   <fx>\staging\9.9.9\                    (pretend validated payload)
  #   <fx>\backup\, <fx>\updater\helper.log
  if ($HelperExe -ne '') {
    $hx = Get-Local $HelperExe
    Rec 'helper-fetched' (Test-Path $hx) $hx
    $fx = Join-Path $WorkRoot 'fixture-install'
    $fxApp = Join-Path $fx 'app'; $fxStage = Join-Path $fx 'staging\9.9.9'; $fxBak = Join-Path $fx 'backup'
    New-Item -ItemType Directory -Force -Path $fxApp,$fxStage,$fxBak | Out-Null
    'old-exe'  | Set-Content (Join-Path $fxApp 'BailianFoundry.exe')
    'old-data' | Set-Content (Join-Path $fxApp 'BailianFoundry_Data.marker')
    'new-exe'  | Set-Content (Join-Path $fxStage 'BailianFoundry.exe')
    'new-data' | Set-Content (Join-Path $fxStage 'BailianFoundry_Data.marker')
    $hlog = Join-Path $fx 'updater\helper.log'
    New-Item -ItemType Directory -Force -Path (Split-Path $hlog) | Out-Null

    $hp = Start-Process -FilePath $hx -PassThru -Wait -ArgumentList @(
      '--install-dir', "`"$fxApp`"", '--staging-dir', "`"$fxStage`"",
      '--backup-dir', "`"$fxBak`"", '--exe-name', '"BailianFoundry.exe"',
      '--log', "`"$hlog`"", '--keep-backups', '1')
    Rec 'helper-exit' ($hp.ExitCode -eq 0) "exit=$($hp.ExitCode)"
    $swapped = (Get-Content (Join-Path $fxApp 'BailianFoundry.exe') -Raw -ErrorAction SilentlyContinue) -match 'new-exe'
    Rec 'helper-swapped-payload' $swapped ''
    $bakHasOld = (Get-ChildItem $fxBak -Recurse -Filter 'BailianFoundry.exe' -ErrorAction SilentlyContinue |
                  Where-Object { (Get-Content $_.FullName -Raw) -match 'old-exe' }).Count -ge 1
    Rec 'helper-backup-kept' $bakHasOld ''
    Rec 'helper-log-written' (Test-Path $hlog) $hlog

    # no-mutation case: missing staging dir must fail WITHOUT touching app\
    $hp2 = Start-Process -FilePath $hx -PassThru -Wait -ArgumentList @(
      '--install-dir', "`"$fxApp`"", '--staging-dir', "`"$fx\staging\absent`"",
      '--backup-dir', "`"$fxBak`"", '--exe-name', '"BailianFoundry.exe"',
      '--log', "`"$hlog`"", '--keep-backups', '1')
    $stillNew = (Get-Content (Join-Path $fxApp 'BailianFoundry.exe') -Raw) -match 'new-exe'
    Rec 'helper-bad-input-no-mutation' ($hp2.ExitCode -ne 0 -and $stillNew) "exit=$($hp2.ExitCode) app intact=$stillNew"
  }
}
finally {
  if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
  $out = Join-Path $WorkRoot 'qa-results.json'
  [pscustomobject]@{ when=(Get-Date -Format o); workRoot=$WorkRoot;
    results=$script:results } | ConvertTo-Json -Depth 4 | Set-Content $out
  Write-Host "`n==== $($script:pass)/$(($script:pass + $script:fail)) checks passed; results: $out"
  if ($script:fail -gt 0) { exit 1 }
}
