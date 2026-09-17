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
$script:pass = 0; $script:fail = 0; $script:skip = 0; $script:results = @()
$script:outPath = $null
function Rec([string]$name, [bool]$ok = $false, [string]$note = "", [switch]$Skip) {
  if ($Skip) { $script:skip++; $st = 'SKIP' } elseif ($ok) { $script:pass++; $st = 'PASS' } else { $script:fail++; $st = 'FAIL' }
  $script:results += [pscustomobject]@{ name=$name; ok=$ok; skipped=[bool]$Skip; note=$note }
  Write-Host ("[{0}] {1}{2}" -f $st, $name, $(if($note){" — $note"}))
  # Incremental evidence: if Actions kills this job (timeout/wedge), the
  # finally-block may never run — persist partial results after every check.
  if ($script:outPath) {
    try { [pscustomobject]@{ when=(Get-Date -Format o); workRoot=$WorkRoot; partial=$true;
      results=$script:results } | ConvertTo-Json -Depth 4 | Set-Content $script:outPath } catch {}
  }
}
function Start-Bounded([string]$File, [string]$ArgString = '', [int]$TimeoutMs = 300000,
                       [string]$What = 'process', [string]$OutLog = '', [string]$ErrLog = '') {
  # Hard per-child bound: pwsh -Wait also waits on DESCENDANTS (7.x), so a
  # spawned child that lingers can hold -Wait open until the job is killed.
  # WaitForExit(ms) bounds only the started process; disappearance polls below
  # cover respawn children (NSIS uninstaller) explicitly.
  # ArgString is passed VERBATIM as the command line (single string form) —
  # required so NSIS /D=<path with spaces> stays unquoted per NSIS rules.
  $sp = @{ FilePath=$File; PassThru=$true; ErrorAction='Stop' }
  if ($ArgString -ne '') { $sp.ArgumentList = $ArgString }
  if ($OutLog -ne '') { $sp.RedirectStandardOutput = $OutLog }
  if ($ErrLog -ne '') { $sp.RedirectStandardError = $ErrLog }
  try { $p = Start-Process @sp } catch { return @{ ran=$false; code=$null; timedOut=$false; note="start failed: $_" } }
  if ($p.WaitForExit($TimeoutMs)) { return @{ ran=$true; code=$p.ExitCode; timedOut=$false; note='' } }
  try { $p.Kill() } catch {}
  try { $p.WaitForExit(5000) } catch {}
  return @{ ran=$true; code=$null; timedOut=$true; note="$What exceeded ${TimeoutMs}ms — killed" }
}
function Wait-Gone([string]$Path, [int]$TimeoutSec = 90) {
  $w = 0; while ((Test-Path $Path) -and $w -lt $TimeoutSec) { Start-Sleep 2; $w += 2 }
  return -not (Test-Path $Path)
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
$script:outPath = Join-Path $WorkRoot 'qa-results.json'
Write-Host "WorkRoot=$WorkRoot"
$rootDir  = Join-Path $env:LOCALAPPDATA 'BailianFoundry'        # updater root + uninstaller home
$appExe   = Join-Path $rootDir 'app\BailianFoundry.exe'
$appDir   = Split-Path $appExe
$uninstExe= Join-Path $rootDir 'Uninstall.exe'                  # NSI writes it beside app\
$playerLog= Join-Path $env:USERPROFILE 'AppData\LocalLow\Bailian\百炼机关\Player.log'
$proc = $null

try {
  # ---------- 1. silent per-user install -------------------------------------
  Write-Host '--- section 1: silent install'
  $setup = Get-Local $SetupExe
  Rec 'setup-exists' (Test-Path $setup) $setup
  $instLog = Join-Path $logDir 'install.out.log'
  $instErr = Join-Path $logDir 'install.err.log'
  $ip = Start-Bounded -File $setup -ArgString '/S' -TimeoutMs 300000 -What 'installer' -OutLog $instLog -ErrLog $instErr
  Rec 'installer-exit-0' ($ip.ran -and $ip.code -eq 0) "exit=$($ip.code) $($ip.note)"

  # Forensics: which payload dirs exist post-attempt pinpoints WHERE the NSI
  # aborted — none = pre-extract (.onInit/probe), app.new = extract/swap stage.
  $residue = @()
  foreach ($d in @("$appDir.new", "$appDir.old", $appDir, $rootDir)) {
    if (Test-Path $d) {
      $n = @(Get-ChildItem $d -Recurse -Force -ErrorAction SilentlyContinue).Count
      $residue += "$d ($n items)"
    }
  }
  Rec 'install-residue-diagnostic' $true ("post-install state: " + $(if ($residue) { $residue -join ' | ' } else { "nothing written under $rootDir" }))

  $installed = Test-Path $appExe
  Rec 'exe-installed' $installed $appExe
  Rec 'unity-data-present' (Test-Path (Join-Path $appDir 'BailianFoundry_Data')) 'BailianFoundry_Data/'
  Rec 'unityplayer-dll' (Test-Path (Join-Path $appDir 'UnityPlayer.dll')) ''
  Rec 'helper-shipped' (Test-Path (Join-Path $appDir 'BailianUpdateHelper.exe')) 'required for apply step'
  $fileInfo = $null
  if ($installed) { try { $fileInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($appExe) } catch {} }
  Rec 'exe-version-info' ($null -ne $fileInfo -and $fileInfo.ProductName -ne '') ($(if ($fileInfo) { "ProductName=$($fileInfo.ProductName) FileVer=$($fileInfo.FileVersion)" } else { 'exe absent — no version info' }))
  Rec 'uninstaller-present' (Test-Path $uninstExe) $uninstExe
  Rec 'no-admin-needed' ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') 'not SYSTEM'

  if (-not $installed) {
    foreach ($n in @('game-boots-window','process-alive','playerlog-phase-lines','playerlog-no-errors',
                     'combat-hwnd-found','combat-input-mode','combat-input-posted','combat-phase-entered',
                     'combat-no-new-exceptions','combat-process-survived',
                     'ui-boot-menu','ui-input-env','ui-manifest-corroboration','ui-check-clicked',
                     'ui-state-evidence','ui-capture','ui-verdict',
                     'game-close-clean','uninstall-exit-0','app-removed','user-data-preserved',
                     'unicode-path-install','unicode-path-boots','unicode-path-uninstall')) {
      Rec $n -Skip -note 'install failed — check requires an installed game'
    }
  } else {
  # ---------- 2. native boot evidence ----------------------------------------
  Write-Host '--- section 2: native boot'
  if (Test-Path $playerLog) { Remove-Item $playerLog -Force }
  $proc = Start-Process -FilePath $appExe -PassThru
  $booted = $false; $t = 0
  while ($t -lt $BootTimeoutSec -and -not $booted) {
    Start-Sleep 2; $t += 2
    $proc.Refresh()
    if (-not $proc.HasExited -and $proc.MainWindowTitle -match '百炼') { $booted = $true }
    elseif ((Test-Path $playerLog) -and ((Get-Content $playerLog -Raw -ErrorAction SilentlyContinue) -match 'phase=')) { $booted = $true }
  }
  Rec 'game-boots-window' $booted "title='$($proc.MainWindowTitle)' after ${t}s"
  Rec 'process-alive' (-not $proc.HasExited) "pid=$($proc.Id)"
  if (Test-Path $playerLog) {
    $log = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
    Rec 'playerlog-phase-lines' ($log -match 'phase=') 'instrumented phases present'
    Rec 'playerlog-no-errors' ($log -notmatch 'Exception|MissingReference|shader.*(error|not found)') ''
  } else { Rec 'playerlog-phase-lines' $false 'Player.log missing'; Rec 'playerlog-no-errors' $false 'Player.log missing' }

  # ---------- 2b. combat-entry smoke: real Enter -> phase=Combat -------------
  # Regresses the 0.1.1 GamepadNavigator combat-entry NRE using a REAL key
  # event on the game's own window — not state injection. Enter maps to
  # GameAction.Confirm (BailianInput.cs) -> navigator ContextAdvance ->
  # StartRun() -> phase=Combat logged.
  #
  # Mechanism ladder: PostMessageW(WM_KEYDOWN/UP, VK_RETURN) to
  # $proc.MainWindowHandle — posts into the window thread's queue, works on a
  # service/Session-0 runner. NOTE: PostMessage DELIVERY is not proof Unity
  # consumed the key — only an observed phase=Combat transition proves the
  # input path worked. keybd_event fallback (global input) is used ONLY when
  # an interactive desktop exists AND our own game HWND is foreground at
  # inject time; key-down is always paired with key-up in finally.
  Add-Type -Namespace QaSmoke -Name U32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.UIntPtr w, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool CloseDesktop(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@

  # keybd_event injects into the GLOBAL input stream -> it lands wherever
  # focus is. Gate every send on GetForegroundWindow == our own game HWND
  # (reacquire first); key-up is in finally so a held key can never leak
  # into another window. Returns $false when our window isn't foreground.
  function Send-ReturnKeybd([IntPtr]$targetHwnd) {
    try { $null = [QaSmoke.U32]::SetForegroundWindow($targetHwnd); Start-Sleep -Milliseconds 250 } catch {}
    if ([QaSmoke.U32]::GetForegroundWindow() -ne $targetHwnd) { return $false }
    try {
      [QaSmoke.U32]::keybd_event(0x0D, 0x1C, 0, [UIntPtr]::Zero)   # VK_RETURN down
      Start-Sleep -Milliseconds 120
    } finally {
      try { [QaSmoke.U32]::keybd_event(0x0D, 0x1C, 2, [UIntPtr]::Zero) } catch {}  # KEYUP
    }
    return $true
  }

  $proc.Refresh()
  $hwnd = $proc.MainWindowHandle
  Rec 'combat-hwnd-found' ($hwnd -ne [IntPtr]::Zero) "hwnd=$hwnd pid=$($proc.Id)"

  # foreground is informational only — PostMessage does not require it
  $fgOk = $false
  if ($hwnd -ne [IntPtr]::Zero) {
    try { $null = [QaSmoke.U32]::SetForegroundWindow($hwnd); Start-Sleep -Milliseconds 300 } catch {}
    $fgOk = ([QaSmoke.U32]::GetForegroundWindow() -eq $hwnd)
  }
  $idesk = [QaSmoke.U32]::OpenInputDesktop(0, $false, 0x0001)   # DESKTOP_READOBJECTS
  $interactive = ($idesk -ne [IntPtr]::Zero)
  if ($interactive) { $null = [QaSmoke.U32]::CloseDesktop($idesk) }
  Rec 'combat-input-mode' $true "interactiveDesktop=$interactive foreground=$fgOk (postmessage needs neither)"

  # Snapshot the log position BEFORE the keypress in CHARACTER units of the
  # same decoded string we will later substring — (Get-Item).Length is BYTES
  # and misaligns on UTF-8 Chinese content. If the file is absent at snapshot
  # time, offset 0 keeps the whole log (first phase/error lines never lost).
  $logBeforeChars = 0
  if (Test-Path $playerLog) {
    $pre = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
    if ($pre) { $logBeforeChars = $pre.Length }
  }

  $posted = $false; $mech = 'none'
  if ($hwnd -ne [IntPtr]::Zero) {
    # WM_KEYDOWN/WM_KEYUP VK_RETURN, scan 0x1C: down lParam 0x001C0001,
    # up lParam 0xC01C0001 (bit30 previous-state + bit31 transition).
    $d = [QaSmoke.U32]::PostMessageW($hwnd, 0x0100, [UIntPtr]0x0D, [IntPtr]0x001C0001)
    Start-Sleep -Milliseconds 350            # key held ~20 frames — edge visible
    $u = [QaSmoke.U32]::PostMessageW($hwnd, 0x0101, [UIntPtr]0x0D, [IntPtr][long]0xC01C0001)
    $posted = ($d -and $u); if ($posted) { $mech = 'postmessage' }
  }
  if (-not $posted -and $interactive) {
    if (Send-ReturnKeybd $hwnd) { $posted = $true; $mech = 'keybd_event' }
  }
  $mechNote = "mechanism=$mech" + $(if (-not $posted) { ' — no input path (session-0/no desktop); UNSUPPORTED on this runner' } else { ' (delivered != consumed; only phase=Combat proves it)' })
  Rec 'combat-input-posted' $posted $mechNote

  # bounded wait for the real transition evidence (max 30 s)
  $combatSeen = $false; $cw = 0
  while ($cw -lt 30 -and -not $combatSeen) {
    Start-Sleep 2; $cw += 2
    if (Test-Path $playerLog) {
      $seg = (Get-Content $playerLog -Raw -ErrorAction SilentlyContinue)
      if ($seg -and $seg.Substring([Math]::Min($logBeforeChars, $seg.Length)) -match 'phase=Combat') { $combatSeen = $true }
    }
    $proc.Refresh()
    if ($proc.HasExited) { break }
  }
  # disambiguation: PostMessage delivered but no transition — on an
  # interactive desktop retry once via keybd_event (real injection, still
  # foreground-gated) before calling it a genuine fail. Bounded (<=20 s).
  if (-not $combatSeen -and $interactive -and $mech -eq 'postmessage') {
    if (Send-ReturnKeybd $hwnd) { $mech = 'postmessage+keybd_event-retry' }
    $cw2 = 0
    while ($cw2 -lt 20 -and -not $combatSeen) {
      Start-Sleep 2; $cw2 += 2
      if (Test-Path $playerLog) {
        $seg = (Get-Content $playerLog -Raw -ErrorAction SilentlyContinue)
        if ($seg -and $seg.Substring([Math]::Min($logBeforeChars, $seg.Length)) -match 'phase=Combat') { $combatSeen = $true }
      }
      $proc.Refresh(); if ($proc.HasExited) { break }
    }
    $cw += $cw2
  }
  $combatNote = "phase=Combat after ${cw}s via $mech"
  if (-not $combatSeen -and $posted) { $combatNote += ' — delivered but no transition: cannot distinguish swallowed input from product defect on this runner' }
  Rec 'combat-phase-entered' $combatSeen $combatNote

  # observe 10 s of real combat; judge ONLY post-press log segment for
  # exceptions (the 0.1.1 NRE fired on this exact transition)
  Start-Sleep 10
  $newSeg = ''
  if (Test-Path $playerLog) {
    $seg2 = (Get-Content $playerLog -Raw -ErrorAction SilentlyContinue)
    if ($seg2) { $newSeg = $seg2.Substring([Math]::Min($logBeforeChars, $seg2.Length)) }
  }
  Rec 'combat-no-new-exceptions' ($combatSeen -and $newSeg -notmatch 'NullReferenceException|Unhandled|Exception:|FATAL') `
      "$(($newSeg -split "`n").Count) new log lines scanned"
  Rec 'combat-process-survived' ($combatSeen -and -not $proc.HasExited) "pid=$($proc.Id)"

  # ---------- 3. graceful close ----------------------------------------------
  if ($proc -and -not $proc.HasExited) {
    $null = $proc.CloseMainWindow()
    $gone = $proc.WaitForExit(8000)
    if (-not $gone) { $proc.Kill(); $proc.WaitForExit(5000) }
    Rec 'game-close-clean' $gone ($(if($gone){"exit=$($proc.ExitCode)"}else{'had to Kill'}))
  }

  # ---------- 3b. updater-UI smoke (own fresh instance at Menu) ----------------
  # Runs AFTER the first instance's graceful close and BEFORE uninstall so the
  # installed game is still present. The child script owns its own process and
  # records ui-* checks; results merge into this gate (failures count).
  Write-Host '--- section 3b: updater UI smoke (检查更新 click)'
  $uiScript = Join-Path $PSScriptRoot 'Invoke-UpdaterUiSmoke.ps1'
  if (Test-Path $uiScript) {
    try {
      & $uiScript -AppExe $appExe -OutDir $logDir | ForEach-Object { Write-Host "  $_" }
      $uiJson = Join-Path $logDir 'updater-ui-results.json'
      if (Test-Path $uiJson) {
        $uiRes = Get-Content $uiJson -Raw | ConvertFrom-Json
        foreach ($prop in $uiRes.PSObject.Properties) {
          Rec $prop.Name ([bool]$prop.Value.ok) $prop.Value.note
        }
      } else { Rec 'ui-verdict' $false 'updater-ui-results.json missing — smoke script produced no evidence' }
    } catch { Rec 'ui-verdict' $false "smoke invocation failed: $_" }
  } else { Rec 'ui-verdict' $false "Invoke-UpdaterUiSmoke.ps1 not found at $uiScript" }

  # ---------- 3c. in-game upgrade acceptance (ARMED only) ---------------------
  # Armed exclusively by ci/upgrade-acceptance.json {armed:true + exact
  # approved expectedVersion/expectedSha256/expectedSize}. While disarmed the
  # flow is a recorded SKIP — never a fake pass, never runs against a mock.
  # When armed it drives: baseline UI check -> Available(exact versions) ->
  # download -> ReadyToApply -> Apply -> helper(wait-pid) swap -> NEW owned
  # process+HWND -> runtime version proof via a second in-game check.
  Write-Host '--- section 3c: upgrade acceptance (armed by ci/upgrade-acceptance.json)'
  $armFile = Join-Path $PSScriptRoot 'upgrade-acceptance.json'
  $upgScript = Join-Path $PSScriptRoot 'Invoke-UpdaterUpgradeSmoke.ps1'
  $arm = $null
  if (Test-Path $armFile) { try { $arm = Get-Content $armFile -Raw | ConvertFrom-Json } catch { $arm = $null } }
  if ($arm -and $arm.armed -eq $true -and $arm.expectedVersion -and $arm.expectedSha256 -and $arm.expectedSize -and (Test-Path $upgScript)) {
    try {
      & $upgScript -AppExe $appExe -OutDir $logDir `
          -ExpectVersion "$($arm.expectedVersion)" -ExpectSha256 "$($arm.expectedSha256)" `
          -ExpectSize ([long]$arm.expectedSize) -BaselineVersion "$($arm.baselineVersion)" |
          ForEach-Object { Write-Host "  $_" }
      $upgJson = Join-Path $logDir 'updater-upgrade-results.json'
      if (Test-Path $upgJson) {
        $upgRes = Get-Content $upgJson -Raw | ConvertFrom-Json
        foreach ($prop in $upgRes.PSObject.Properties) {
          Rec $prop.Name ([bool]$prop.Value.ok) $prop.Value.note
        }
      } else { Rec 'upg-verdict' $false 'updater-upgrade-results.json missing — harness produced no evidence' }
    } catch { Rec 'upg-verdict' $false "upgrade harness invocation failed: $_" }
  } else {
    Rec 'upg-armed' $false 'upgrade acceptance NOT armed — needs real approved newer public release + ci/upgrade-acceptance.json triple' -Skip
  }

  # ---------- 4. uninstall preserves updater root/user data -------------------
  Write-Host '--- section 4: uninstall/data preservation'
  $marker = Join-Path $rootDir 'qa-preserve-marker.txt'
  'keepme' | Set-Content $marker
  if (Test-Path $uninstExe) {
    # NSIS uninstallers respawn a copy under %TEMP%; the parent's exit code is
    # what we assert, but payload removal is polled for explicitly (bounded).
    $up = Start-Bounded -File $uninstExe -ArgString '/S' -TimeoutMs 300000 -What 'uninstaller'
    Rec 'uninstall-exit-0' ($up.ran -and $up.code -eq 0) "exit=$($up.code) $($up.note)"
    $gone = Wait-Gone $appExe 90
    Rec 'app-removed' $gone ''
    Rec 'user-data-preserved' (Test-Path $marker) 'updater-root marker survived uninstall'
    Remove-Item $marker -Force -ErrorAction SilentlyContinue
  } else { Rec 'uninstall-exit-0' $false 'uninstaller missing — skipped'; Rec 'app-removed' $false 'skipped'; Rec 'user-data-preserved' $false 'skipped' }

  # ---------- 5. unicode + spaced install path --------------------------------
  Write-Host '--- section 5: unicode/spaced /D= path'
  # NSIS /D must be the LAST argument and is taken literally (spaces ok).
  $uDir = Join-Path $WorkRoot '百炼 游戏 dir'   # CJK + spaces, under WorkRoot
  $uip = Start-Bounded -File $setup -ArgString ('/S /D=' + $uDir) -TimeoutMs 300000 -What 'unicode-install'
  $uExe = Join-Path $uDir 'BailianFoundry.exe'
  Rec 'unicode-path-install' ($uip.ran -and $uip.code -eq 0 -and (Test-Path $uExe)) "dir='$uDir' exit=$($uip.code) $($uip.note)"
  if (Test-Path $uExe) {
    $uproc = Start-Process -FilePath $uExe -PassThru
    $uboot = $uproc.WaitForInputIdle(20000)
    Start-Sleep 3; $uproc.Refresh()
    Rec 'unicode-path-boots' (-not $uproc.HasExited) "pid=$($uproc.Id)"
    if (-not $uproc.HasExited) { $null = $uproc.CloseMainWindow(); if (-not $uproc.WaitForExit(8000)) { $uproc.Kill() } }
    # registry now points at unicode dir; shared Uninstall.exe removes it
    if (Test-Path $uninstExe) {
      $uup = Start-Bounded -File $uninstExe -ArgString '/S' -TimeoutMs 300000 -What 'unicode-uninstall'
      $ugone = Wait-Gone $uExe 90
      Rec 'unicode-path-uninstall' $ugone "exit=$($uup.code) $($uup.note)"
    }
  }
  } # end if installed

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
  Write-Host '--- section 7: update-helper fixture (dry-run swap)'
  # Mimics the UpdatePaths layout under WorkRoot only:
  #   <fx>\app\BailianFoundry.exe + _Data\   (pretend installed game, not running)
  #   <fx>\staging\9.9.9\                    (pretend validated payload)
  #   <fx>\backup\, <fx>\updater\helper.log
  # --dry-run is REQUIRED here: fixture exes are text files that can never
  # launch; without it the helper's launch+liveness step deterministically
  # fails (exit 4) and rolls back, producing false FAILs. The real-PE launch
  # path is covered separately by the real-payload smoke below.
  if ($HelperExe -eq '' -and $UpdateZip -ne '') {
    # The helper ships INSIDE the update zip / install payload — extract the
    # real binary so apply/no-mutation still gets tested without a loose asset.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
      $uzp2 = Get-Local $UpdateZip
      $z2 = [IO.Compression.ZipFile]::OpenRead($uzp2)
      $he = $z2.Entries | Where-Object { $_.FullName -eq 'BailianUpdateHelper.exe' } | Select-Object -First 1
      if ($he) {
        $hxp = Join-Path $WorkRoot 'BailianUpdateHelper.exe'
        [IO.Compression.ZipFileExtensions]::ExtractToFile($he, $hxp, $true)
        $HelperExe = $hxp
        Write-Host "helper extracted from update zip -> $hxp"
      } else { Write-Host 'no BailianUpdateHelper.exe entry in update zip — helper test skipped' }
      $z2.Dispose()
    } catch { Write-Host "helper extraction failed (skipped): $_" }
  }
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

    $hp = Start-Bounded -File $hx -TimeoutMs 180000 -What 'helper dry-run' -ArgString (
      '--install-dir "' + $fxApp + '" --staging-dir "' + $fxStage + '"' +
      ' --backup-dir "' + $fxBak + '" --exe-name "BailianFoundry.exe"' +
      ' --log "' + $hlog + '" --keep-backups 1 --dry-run')
    Rec 'helper-exit' ($hp.ran -and $hp.code -eq 0) "exit=$($hp.code) $($hp.note)"
    $swapped = (Get-Content (Join-Path $fxApp 'BailianFoundry.exe') -Raw -ErrorAction SilentlyContinue) -match 'new-exe'
    Rec 'helper-swapped-payload' $swapped ''
    $bakHasOld = (Get-ChildItem $fxBak -Recurse -Filter 'BailianFoundry.exe' -ErrorAction SilentlyContinue |
                  Where-Object { (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'old-exe' }).Count -ge 1
    Rec 'helper-backup-kept' $bakHasOld ''
    Rec 'helper-log-written' (Test-Path $hlog) $hlog

    # no-mutation case: missing staging dir must fail WITHOUT touching app\
    $hp2 = Start-Bounded -File $hx -TimeoutMs 180000 -What 'helper bad-input' -ArgString (
      '--install-dir "' + $fxApp + '" --staging-dir "' + $fx + '\staging\absent"' +
      ' --backup-dir "' + $fxBak + '" --exe-name "BailianFoundry.exe"' +
      ' --log "' + $hlog + '" --keep-backups 1 --dry-run')
    $stillNew = (Get-Content (Join-Path $fxApp 'BailianFoundry.exe') -Raw -ErrorAction SilentlyContinue) -match 'new-exe'
    Rec 'helper-bad-input-no-mutation' ($hp2.ran -and $hp2.code -ne 0 -and $stillNew) "exit=$($hp2.code) app intact=$stillNew $($hp2.note)"

    # ---------- 7b. REAL-payload apply + real-exe launch smoke -----------------
    # --dry-run proves the swap mechanics only. This uses the SHIPPED update
    # zip itself as the staged payload — real Unity PE, real launch+liveness —
    # under a disposable WorkRoot fixture. Publishes nothing.
    if ($UpdateZip -ne '') {
      Write-Host '--- section 7b: real-payload helper apply+launch'
      try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $uzr = Get-Local $UpdateZip
        $fxr = Join-Path $WorkRoot 'real-apply-fixture'
        $fxrApp = Join-Path $fxr 'app'; $fxrStage = Join-Path $fxr 'staging\payload'; $fxrBak = Join-Path $fxr 'backup'
        New-Item -ItemType Directory -Force -Path $fxrApp,$fxrStage,$fxrBak | Out-Null
        'old-exe'  | Set-Content (Join-Path $fxrApp 'BailianFoundry.exe')
        'sentinel' | Set-Content (Join-Path $fxrApp 'OLD_INSTALL.txt')
        [IO.Compression.ZipFile]::ExtractToDirectory($uzr, $fxrStage)
        Rec 'real-payload-staged' (Test-Path (Join-Path $fxrStage 'BailianFoundry.exe')) $fxrStage
        $hlog2 = Join-Path $fxr 'updater\helper.log'
        New-Item -ItemType Directory -Force -Path (Split-Path $hlog2) | Out-Null
        $hr = Start-Bounded -File $hx -TimeoutMs 240000 -What 'helper real-apply' -ArgString (
          '--install-dir "' + $fxrApp + '" --staging-dir "' + $fxrStage + '"' +
          ' --backup-dir "' + $fxrBak + '" --exe-name "BailianFoundry.exe"' +
          ' --log "' + $hlog2 + '" --keep-backups 1')
        Rec 'helper-real-apply-exit-0' ($hr.ran -and $hr.code -eq 0) "exit=$($hr.code) $($hr.note)"
        $rExe = Join-Path $fxrApp 'BailianFoundry.exe'
        $rLen = (Get-Item $rExe -ErrorAction SilentlyContinue).Length
        $mz = $false
        if (Test-Path $rExe) { try { $fs=[IO.File]::OpenRead($rExe); $b0=$fs.ReadByte(); $b1=$fs.ReadByte(); $fs.Close(); $mz=($b0 -eq 0x4D -and $b1 -eq 0x5A) } catch {} }
        Rec 'helper-real-payload-in-place' ($mz -and $rLen -gt 10KB) "size=$rLen MZ=$mz (real Unity stub ~650KB)"
        $hl = Get-Content $hlog2 -Raw -ErrorAction SilentlyContinue
        Rec 'helper-real-launched' ($hl -match 'new version launched') 'helper.log launch line'
        Rec 'helper-real-backup-kept' (@(Get-ChildItem $fxrBak -Recurse -Filter 'OLD_INSTALL.txt' -ErrorAction SilentlyContinue).Count -ge 1) 'old install moved to backup'
        # the helper leaves the real game running — stop ONLY this fixture's instance
        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like (Join-Path $fxrApp '*') } |
          ForEach-Object { try { $_.Kill() } catch {} }
      } catch { Rec 'helper-real-apply-exit-0' $false "exception: $_" }
    }
  }

  # ---------- 8. co-op acceptance (ARMED only, zero workflow changes) ---------
  # ci/coop-acceptance.json arms this: main/installer publishes the BAILIAN_QA
  # Windows build as an asset on the named release tag (draft OK — fetched via
  # the ambient GH_TOKEN the workflow already exports), supplies the exact
  # sha256/size/version, and a LIVE room code arrives via the same file (join)
  # or a room file is written for peers (host). Disarmed => recorded SKIP.
  # The dedicated windows-coop-qa.yml is staged but the token lacks the
  # `workflow` scope to push it; this in-runner path needs no new permissions.
  Write-Host '--- section 8: co-op acceptance (armed by ci/coop-acceptance.json)'
  $coopArmFile = Join-Path $PSScriptRoot 'coop-acceptance.json'
  $coopScript  = Join-Path $PSScriptRoot 'Invoke-CoopQa.ps1'
  $carm = $null
  if (Test-Path $coopArmFile) { try { $carm = Get-Content $coopArmFile -Raw | ConvertFrom-Json } catch { $carm = $null } }
  if ($carm -and $carm.armed -eq $true -and $carm.qaTag -and $carm.qaAssetName -and $carm.qaSha256 -and $carm.qaSize -and (Test-Path $coopScript)) {
    try {
      # fetch the exact QA asset from the named release (draft-safe API)
      $auth = @{ Authorization = "Bearer $env:GH_TOKEN"; 'X-GitHub-Api-Version' = '2022-11-28' }
      $rels = Invoke-RestMethod "https://api.github.com/repos/$env:GITHUB_REPOSITORY/releases?per_page=50" -Headers $auth
      $rel  = $rels | Where-Object { $_.tag_name -eq "$($carm.qaTag)" } | Select-Object -First 1
      $qaAsset = $null
      if ($rel) { $qaAsset = $rel.assets | Where-Object { $_.name -eq "$($carm.qaAssetName)" } | Select-Object -First 1 }
      if (-not $qaAsset) { throw "QA asset '$($carm.qaAssetName)' not found in release '$($carm.qaTag)'" }
      $qaZip = Join-Path $env:RUNNER_TEMP $qaAsset.name
      Invoke-WebRequest "https://api.github.com/repos/$env:GITHUB_REPOSITORY/releases/assets/$($qaAsset.id)" `
        -Headers ($auth + @{ Accept = 'application/octet-stream' }) -OutFile $qaZip -UseBasicParsing -TimeoutSec 600
      Write-Host "QA asset downloaded: $($qaAsset.name) ($((Get-Item $qaZip).Length) bytes)"

      $coopArgs = @{
        QaZip = $qaZip
        ExeName = "$($carm.exeName)"
        ExpectSha256 = "$($carm.qaSha256)"; ExpectSize = [long]$carm.qaSize
        ExpectVersion = "$($carm.qaVersion)"; Role = "$($carm.role)"
        QaName = 'QA-Win-CI'; Players = [int]$carm.players
        DriverTimeoutSec = [int]$carm.driverTimeoutSec
        WorkRoot = $WorkRoot; OutDir = $logDir
      }
      if ($carm.roomCode) { $coopArgs.RoomCode = "$($carm.roomCode)" }
      & $coopScript @coopArgs | ForEach-Object { Write-Host "  $_" }
      $coopJson = Join-Path $logDir 'coop-qa-results.json'
      if (Test-Path $coopJson) {
        $coopRes = Get-Content $coopJson -Raw | ConvertFrom-Json
        foreach ($prop in $coopRes.PSObject.Properties) {
          Rec $prop.Name ([bool]$prop.Value.ok) $prop.Value.note
        }
      } else { Rec 'coop-verdict' $false 'coop-qa-results.json missing — harness produced no evidence' }
    } catch { Rec 'coop-verdict' $false "co-op section failed: $_" }
  } else {
    Rec 'coop-armed' $false 'co-op acceptance NOT armed — needs real QA build handoff + live room code' -Skip
  }
}
finally {
  if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
  # collect NSIS runtime log if the installer wrote one (diag variant does)
  Get-ChildItem "$env:TEMP\BailianFoundry-Setup*.log" -ErrorAction SilentlyContinue |
    ForEach-Object { Copy-Item $_.FullName $logDir -Force -ErrorAction SilentlyContinue }
  $out = Join-Path $WorkRoot 'qa-results.json'
  [pscustomobject]@{ when=(Get-Date -Format o); workRoot=$WorkRoot;
    results=$script:results } | ConvertTo-Json -Depth 4 | Set-Content $out
  Write-Host "`n==== $($script:pass) pass / $($script:fail) fail / $($script:skip) skip; results: $out"
  if ($script:fail -gt 0) { exit 1 }
}
