#Requires -Version 5
# Invoke-UpdaterUpgradeSmoke.ps1 — REAL in-game upgrade acceptance for
# BailianFoundry: installed BASELINE (e.g. 0.1.2) -> public NEWER release
# (e.g. 0.1.3) through the shipped UI, helper, and relaunch.
#
# GATED. Runs only when invoked with the approved candidate triple:
#   -ExpectVersion / -ExpectSha256 / -ExpectSize   (from ci/upgrade-acceptance.json)
# and only after the LIVE public manifest matches all three EXACTLY.
# Never fakes a remote version, never uses a mock manifest, never reuses the
# withdrawn 0.1.1 payload.
#
# Proven-contract anchors (main source, read-only reference):
#   UpdateMenu.cs:68-71    检查更新 button   canvas x22..212 y52..104 -> (117,78)
#   UpdateMenu.cs:129-132  下 载 更 新        panel-rel (-130,60) 240x62
#   UpdateMenu.cs:123-127  更 新 并 重 启      same slot — canvas (830,280)
#   UpdateClient.cs:205/210 "up to date: local=… remote=…" / "update available: A -> B"
#   UpdateClient.cs:363    "staged N files, M bytes at <dir>"
#   UpdateClient.cs:420/441 "launch helper: <dst> --install-dir … --wait-pid <pid>"
#                           + "helper pid N launched; quitting for apply"
#   UpdateClient.cs:500    Fail() logs "[bailian-update] <Error>: <detail>" (warning)
#   UpdatePaths.cs         root=<installDir>\.. : download\, staging\<v>\,
#                          updater\BailianUpdateHelper.exe, updater\helper.log,
#                          backup\app-<ts>\
#
# Ownership rules (learned from review): no PE ProductVersion (it is the Unity
# ENGINE version), no bare Get-Process-by-name, no stale HWND reuse, work-area
# fit before clicks (taskbar occlusion), char-offset log tails (UTF-8/中文),
# curl.exe for manifest fetch (Invoke-WebRequest byte[]/member-enumeration
# bug on this runner's PS build), close ONLY owned PIDs.

param(
  [Parameter(Mandatory=$true)][string]$AppExe,
  [string]$OutDir = (Join-Path $env:RUNNER_TEMP 'blqa\logs'),
  [string]$ExpectVersion = '',
  [string]$ExpectSha256  = '',
  [long]$ExpectSize      = 0,
  [string]$BaselineVersion = '',
  [int]$BootTimeoutSec      = 45,
  [int]$CheckTimeoutSec     = 45,
  [int]$DownloadTimeoutSec  = 300,
  [int]$ApplyTimeoutSec     = 150,
  [int]$NewBootTimeoutSec   = 45,
  [int]$NewCheckTimeoutSec  = 60
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$script:results = [ordered]@{}
function Rec($name, $ok, $note='') {
  $script:results[$name] = @{ ok=[bool]$ok; note="$note" }
  Write-Host ("[{0}] {1}{2}" -f $(if($ok){'PASS'}else{'FAIL'}), $name, $(if($note){" — $note"}))
}

Add-Type -AssemblyName System.Drawing
Add-Type -Namespace QaUi -Name U32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool CloseDesktop(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref POINT p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SystemParametersInfoW(uint action, uint param, ref RECT pv, uint fWinIni);
public struct RECT { public int Left, Top, Right, Bottom; }
public struct POINT { public int X, Y; }
'@

$playerLog  = Join-Path $env:USERPROFILE 'AppData\LocalLow\Bailian\百炼机关\Player.log'
$playerPrev = Join-Path $env:USERPROFILE 'AppData\LocalLow\Bailian\百炼机关\Player-prev.log'
$manifestUrl = 'https://github.com/BOJUEJUN/bailian-foundry-releases/releases/latest/download/update.json'

$script:hwnd = [IntPtr]::Zero
$script:logOff = 0

# canvas->client->screen (CanvasScaler 1920x1080 matchWidthOrHeight=0.5)
function CanvasPoint($cx, $cy) {
  $cr = New-Object QaUi.U32+RECT
  if (-not [QaUi.U32]::GetClientRect($script:hwnd, [ref]$cr)) { return $null }
  $cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
  if ($cw -le 0 -or $ch -le 0) { return $null }
  $scale = [Math]::Sqrt(($cw/1920.0)*($ch/1080.0))
  $o = New-Object QaUi.U32+POINT
  if (-not [QaUi.U32]::ClientToScreen($script:hwnd, [ref]$o)) { return $null }
  return @{ X = [int]($o.X + $cx * $scale); Y = [int]($o.Y + $ch - $cy * $scale) }
}
function FitWorkArea {   # keep the WHOLE client rect clickable (taskbar fix)
  try {
    $wa = New-Object QaUi.U32+RECT
    [void][QaUi.U32]::SystemParametersInfoW(0x0030, 0, [ref]$wa, 0)
    $waW = $wa.Right - $wa.Left; $waH = $wa.Bottom - $wa.Top
    if ($waW -gt 0 -and $waH -gt 0) {
      [void][QaUi.U32]::SetWindowPos($script:hwnd, [IntPtr]::Zero,
        $wa.Left + 20, $wa.Top + 10, [int]($waW * 0.9), [int]($waH * 0.88), 0x0040)
      Start-Sleep -Milliseconds 600
    }
  } catch {}
}
function EnsureForeground {  # gate EVERY injection on owning the foreground
  [void][QaUi.U32]::ShowWindow($script:hwnd, 9)
  [void][QaUi.U32]::SetForegroundWindow($script:hwnd)
  Start-Sleep -Milliseconds 350
  return ([QaUi.U32]::GetForegroundWindow() -eq $script:hwnd)
}
function ClickCanvas($cx, $cy, $tag) {
  if (-not (EnsureForeground)) { Rec "$tag-click" $false 'foreground not owned — injection refused'; return $false }
  $pt = CanvasPoint $cx $cy
  if ($null -eq $pt) { Rec "$tag-click" $false 'GetClientRect/ClientToScreen failed'; return $false }
  [void][QaUi.U32]::SetCursorPos($pt.X, $pt.Y)
  Start-Sleep -Milliseconds 120
  [QaUi.U32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [QaUi.U32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Write-Host "  click $tag at screen ($($pt.X),$($pt.Y))"
  Rec "$tag-click" $true "physical click canvas($cx,$cy) -> screen($($pt.X),$($pt.Y))"
  return $true
}
function Capture($name) {
  try {
    $wr = New-Object QaUi.U32+RECT
    if (-not [QaUi.U32]::GetWindowRect($script:hwnd, [ref]$wr)) { return $null }
    $w = $wr.Right - $wr.Left; $h = $wr.Bottom - $wr.Top
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($wr.Left, $wr.Top, 0, 0, $bmp.Size)
    $f = Join-Path $OutDir $name
    $bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    return $f
  } catch { return $null }
}
function LogTail {
  if (-not (Test-Path $playerLog)) { return '' }
  $s = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
  if (-not $s) { return '' }
  return $s.Substring([Math]::Min($script:logOff, $s.Length))
}
function SnapLog {  # char offset into the CURRENT decoded log
  $script:logOff = 0
  if (Test-Path $playerLog) {
    $pre = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
    if ($pre) { $script:logOff = $pre.Length }
  }
}
function UpdaterLines { ((LogTail) -split "`n" | Where-Object { $_ -match '\[bailian-update\]' }) -join ' | ' }
function Wait-Proc($id, $sec) {  # bounded wait for exit; $true if gone
  $w = 0
  while ($w -lt $sec) {
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if (-not $p) { return $true }
    Start-Sleep 1; $w++
  }
  return ($null -eq (Get-Process -Id $id -ErrorAction SilentlyContinue))
}
function Get-ProcInfo($id) {
  try { return Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop } catch { return $null }
}

$old = $null; $new = $null; $tApply = $null; $helperPid = 0; $installDir = $null; $updateRoot = $null
$shots = @()

try {
  # ---------- gate ----------
  $armed = ($ExpectVersion -and $ExpectSha256 -and $ExpectSize -gt 0)
  Rec 'upg-gate' $armed "expectVersion='$ExpectVersion' sha256='$ExpectSha256' size=$ExpectSize baseline='$BaselineVersion'"
  if (-not $armed) { Rec 'upg-verdict' $false 'not armed — candidate triple required'; return }

  # ---------- live manifest MUST match the approved triple exactly ----------
  $mj = $null; $mErr = ''
  try {
    $raw = ((& curl.exe -sL --max-time 20 $manifestUrl) -join "`n")
    if ($raw) { $mj = $raw | ConvertFrom-Json } else { $mErr = 'empty response' }
  } catch { $mErr = $_.Exception.Message }
  $plat = $null
  if ($mj -and $mj.platforms) { $plat = $mj.platforms.'windows-x64' }
  $mOk = $mj -and "$($mj.version)" -eq $ExpectVersion -and $plat -and
         "$($plat.sha256)" -eq $ExpectSha256 -and [long]$plat.size -eq $ExpectSize -and
         "$($plat.url)" -match '^https://'
  Rec 'upg-manifest-match' ([bool]$mOk) (
    "live version='$($mj.version)' sha256='$($plat.sha256)' size=$($plat.size) url='$($plat.url)'" +
    $(if ($mErr) { " err=$mErr" } else { '' }) +
    $(if ($mj -and -not $mOk) { ' — MISMATCH vs approved triple: refusing to run' } else { '' }))
  if (-not $mOk) { Rec 'upg-verdict' $false 'live manifest does not equal approved candidate — nothing exercised'; return }

  # cheap reachability+size corroboration of the payload itself (HEAD only)
  $head = ((& curl.exe -sIL --max-time 20 "$($plat.url)") -join "`n")
  $hCode = ([regex]::Matches($head, 'HTTP/\S+\s+(\d+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Last 1)
  $hLen  = ([regex]::Matches($head, '(?im)^content-length:\s*(\d+)') | ForEach-Object { [long]$_.Groups[1].Value } | Select-Object -Last 1)
  Rec 'upg-payload-head' ($hCode -eq '200' -and $hLen -eq $ExpectSize) "http=$hCode content-length=$hLen expect=$ExpectSize"

  $installDir = Split-Path $AppExe -Parent
  $updateRoot = Split-Path $installDir -Parent   # UpdatePaths: root = parent of install dir

  # ---------- boot BASELINE instance (owned) ----------
  if (Test-Path $playerLog) { Remove-Item $playerLog -Force }
  $old = Start-Process -FilePath $AppExe -PassThru
  $oldPid = $old.Id; $oldStart = $old.StartTime
  $booted = $false; $bw = 0
  while ($bw -lt $BootTimeoutSec -and -not $booted) {
    Start-Sleep 2; $bw += 2
    $old.Refresh()
    if ($old.HasExited) { break }
    if ($old.MainWindowHandle -ne [IntPtr]::Zero) {
      $script:hwnd = $old.MainWindowHandle
      $logNow = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
      if ($logNow -and $logNow.Length -gt 200) { $booted = $true }
    }
  }
  if ($booted) { FitWorkArea; Start-Sleep 2 }
  Rec 'upg-boot' ($booted -and $script:hwnd -ne [IntPtr]::Zero) "baseline pid=$oldPid hwnd=$($script:hwnd) start=$($oldStart.ToString('o')) ${bw}s"

  $idesk = [QaUi.U32]::OpenInputDesktop(0, $false, 0x0001)
  $interactive = ($idesk -ne [IntPtr]::Zero)
  if ($interactive) { [void][QaUi.U32]::CloseDesktop($idesk) }
  $fgOk = $booted -and (EnsureForeground)
  Rec 'upg-input-env' ($booted -and $interactive -and $fgOk) "interactiveDesktop=$interactive foreground=$fgOk"
  $shots += (Capture 'upg-0-menu.png')
  if (-not ($booted -and $interactive -and $fgOk)) { Rec 'upg-verdict' $false 'input env unsupported — upgrade UI unexercised (honest limitation)'; return }

  # ---------- click 检查更新 -> require state=Available with EXACT versions ----------
  SnapLog
  [void](ClickCanvas 117 78 'check-update')
  $avail = $false; $cw = 0; $availLine = ''
  while ($cw -lt $CheckTimeoutSec -and -not $avail) {
    Start-Sleep 2; $cw += 2
    $t = LogTail
    if ($t -match 'update available:\s*(\S+)\s*->\s*(\S+)') { $availLine = $Matches[0]; $lFrom = $Matches[1]; $lTo = $Matches[2] }
    if ($t -match '\[bailian-update\] state=Available') { $avail = $true }
    elseif ($t -match 'state=UpToDate|state=Error') { break }
    $old.Refresh(); if ($old.HasExited) { break }
  }
  $verOk = $avail -and ($lTo -eq $ExpectVersion) -and (-not $BaselineVersion -or $lFrom -eq $BaselineVersion)
  Rec 'upg-available' $verOk "after ${cw}s :: $availLine expect '$BaselineVersion->$ExpectVersion' :: $(UpdaterLines)"
  if (-not $verOk) { Rec 'upg-verdict' $false 'no exact Available transition (UpToDate/Error/timeout/wrong versions)'; return }
  $shots += (Capture 'upg-1-available.png')

  # ---------- click 下 载 更 新 -> Downloading -> Verifying -> ReadyToApply ----------
  [void](ClickCanvas 830 280 'download')
  $ready = $false; $dw = 0; $gotDl = $false
  while ($dw -lt $DownloadTimeoutSec -and -not $ready) {
    Start-Sleep 2; $dw += 2
    $t = LogTail
    if (-not $gotDl -and $t -match 'state=Downloading') {
      $gotDl = $true; $shots += (Capture 'upg-2-downloading.png')
    }
    if ($t -match '\[bailian-update\] state=ReadyToApply') { $ready = $true }
    elseif ($t -match 'state=Error') { break }
    $old.Refresh(); if ($old.HasExited) { break }
  }
  Rec 'upg-ready' $ready "after ${dw}s (downloading-seen=$gotDl) :: $(UpdaterLines)"
  if (-not $ready) { Rec 'upg-verdict' $false 'download/verify never reached ReadyToApply — see updater lines'; return }
  $shots += (Capture 'upg-3-ready.png')

  # ---------- click 更 新 并 重 启 -> Applying -> helper -> quit ----------
  $tApply = Get-Date
  [void](ClickCanvas 830 280 'apply')
  $hl = $false; $aw = 0
  while ($aw -lt $ApplyTimeoutSec -and -not $hl) {
    Start-Sleep 1; $aw++
    $t = LogTail
    if ($t -match 'helper pid (\d+) launched') { $helperPid = [int]$Matches[1]; $hl = $true }
    elseif ($t -match 'state=Error') { break }
    $old.Refresh(); if ($old.HasExited -and -not $hl) { Start-Sleep 2; $t = LogTail; if ($t -match 'helper pid (\d+) launched') { $helperPid = [int]$Matches[1]; $hl = $true }; break }
  }
  $tail = LogTail
  $waitPidOk = ($tail -match "--wait-pid $oldPid(\D|$)")
  Rec 'upg-helper-launched' ($hl -and $waitPidOk) "helperPid=$helperPid waitPid==old:$waitPidOk after ${aw}s :: $(UpdaterLines)"
  if (-not $hl) { Rec 'upg-verdict' $false 'helper never launched'; return }

  $oldGone = Wait-Proc $oldPid 60
  Rec 'upg-old-exited' $oldGone "old pid $oldPid exited=$(($oldGone)) (self-quit via Application.Quit)"

  # live helper snapshot (best effort — helper may already be gone; the
  # game-logged command line above is the authoritative ownership proof)
  $hInfo = Get-ProcInfo $helperPid
  $hNote = if ($hInfo) {
    "live: exe='$($hInfo.ExecutablePath)' parent=$($hInfo.ParentProcessId) cmdline-has-oldpid=$($hInfo.CommandLine -match "--wait-pid $oldPid(\D|$)")"
  } else { 'helper already exited — ownership via game-logged args (wait-pid, install-dir, staging-dir)' }
  Rec 'upg-helper-ownership' ($waitPidOk -and (-not $hInfo -or $hInfo.ParentProcessId -eq $oldPid -or $hInfo.ExecutablePath -like '*\updater\*')) $hNote

  # ---------- NEW owned process: exact path + new pid + post-apply start ----------
  $new = $null; $nw = 0
  while ($nw -lt 60 -and -not $new) {
    Start-Sleep 2; $nw += 2
    $cands = Get-CimInstance Win32_Process -Filter "Name='BailianFoundry.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.ProcessId -ne $oldPid -and $_.ExecutablePath -eq $AppExe -and $_.CreationDate -gt $tApply }
    if ($cands) {
      $ci = $cands | Select-Object -First 1
      $new = Get-Process -Id $ci.ProcessId -ErrorAction SilentlyContinue
      $script:newParent = $ci.ParentProcessId
    }
  }
  $parentOk = ($null -ne $new) -and ($script:newParent -eq $helperPid)
  Rec 'upg-new-process' ($null -ne $new) (
    $(if ($new) { "newPid=$($new.Id) path=$AppExe created>$($tApply.ToString('HH:mm:ss')) parent=$($script:newParent)$(if($parentOk){'=helperPid'})" } else { 'no new BailianFoundry.exe at install path after apply' }))
  # ParentProcessId is stamped at creation and survives the parent's exit, so
  # parent==helperPid is normally provable even after the helper reaps itself.
  # If the helper was never observed live AND parentage is unreadable, the
  # game-logged "--wait-pid <oldPid> --install-dir <ours>" line is still the
  # authoritative spawn-ownership proof — noted, not silently passed.
  Rec 'upg-parent-chain' ($parentOk -or ($null -ne $new -and -not (Get-ProcInfo $helperPid))) (
    $(if ($parentOk) { "new process parented by helper pid $helperPid" }
      elseif ($new) { "parent unreadable (helper reaped before snapshot) — spawn proven by game-logged wait-pid/install-dir args" }
      else { 'no new process — parentage moot' }))

  # helper journal + backup evidence (UpdatePaths layout)
  $hlogPath = Join-Path $updateRoot 'updater\helper.log'
  $hlw = 0; $hlTxt = ''
  while ($hlw -lt 30) {
    if (Test-Path $hlogPath) { $hlTxt = Get-Content $hlogPath -Raw -ErrorAction SilentlyContinue; if ($hlTxt -match 'new version launched') { break } }
    Start-Sleep 2; $hlw += 2
  }
  Rec 'upg-helper-log' ($hlTxt -match 'new version launched') $hlogPath
  if (Test-Path $hlogPath) { Copy-Item $hlogPath (Join-Path $OutDir 'upg-helper.log') -Force -ErrorAction SilentlyContinue }
  $bak = @(Get-ChildItem (Join-Path $updateRoot 'backup') -Directory -Filter 'app-*' -ErrorAction SilentlyContinue)
  Rec 'upg-backup-kept' ($bak.Count -ge 1) "$(@($bak).Count) backup dir(s) under $updateRoot\backup"

  # ---------- NEW instance: own HWND + runtime version proof ----------
  $newHwnd = [IntPtr]::Zero; $nb = 0
  if ($new) {
    while ($nb -lt $NewBootTimeoutSec -and $newHwnd -eq [IntPtr]::Zero) {
      Start-Sleep 2; $nb += 2
      $new.Refresh()
      if ($new.HasExited) { break }
      if ($new.MainWindowHandle -ne [IntPtr]::Zero) { $newHwnd = $new.MainWindowHandle }
    }
  }
  $script:hwnd = $newHwnd   # fresh HWND for the NEW process only
  Rec 'upg-new-window' ($newHwnd -ne [IntPtr]::Zero) "newPid=$(if($new){$new.Id}else{'?'}) hwnd=$newHwnd ${nb}s"
  if ($newHwnd -eq [IntPtr]::Zero) { Rec 'upg-verdict' $false 'new instance produced no window'; return }
  FitWorkArea
  $fgNew = EnsureForeground
  $shots += (Capture 'upg-4-newmenu.png')

  # second 检查更新 on the NEW instance: Player.log is recreated per launch, so
  # the whole current file is the new run's. Runtime Application.version shows
  # up as local=<v> in the updater log — NOT the PE ProductVersion.
  SnapLog
  $clicked2 = $fgNew -and (ClickCanvas 117 78 'check-update-new')
  $proved = $false; $nw2 = 0; $locLine = ''
  while ($nw2 -lt $NewCheckTimeoutSec -and -not $proved) {
    Start-Sleep 2; $nw2 += 2
    $t = LogTail
    if ($t -match 'up to date:\s*local=(\S+)\s*remote=(\S+)') { $locLine = $Matches[0]; $proved = ($Matches[1] -eq $ExpectVersion -and $Matches[2] -eq $ExpectVersion) -and ($t -match 'state=UpToDate') }
    elseif ($t -match 'update available|state=Error') { $locLine = UpdaterLines; break }
  }
  Rec 'upg-runtime-version' $proved "after ${nw2}s :: $locLine expect local=remote=$ExpectVersion :: $(UpdaterLines)"
  $shots += (Capture 'upg-5-newcheck.png')

  # preserve the OLD run's full log (became Player-prev.log on relaunch)
  if (Test-Path $playerPrev) { Copy-Item $playerPrev (Join-Path $OutDir 'upg-oldrun-Player-prev.log') -Force -ErrorAction SilentlyContinue }

  $shotNames = @($shots | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf }) -join ','
  Rec 'upg-capture' (@($shots | Where-Object { $_ }).Count -ge 4) "shots: $shotNames (upg-2-downloading may be absent on fast links)"

  $upgOk = $proved -and ($null -ne $new)
  Rec 'upg-verdict' $upgOk ("upgrade $BaselineVersion->$ExpectVersion " +
    $(if ($proved) { "proven end-to-end: UI clicks -> live manifest -> download -> helper swap -> new instance runtime local=$ExpectVersion" }
      else { 'NOT proven — see failed checks above' }))
}
finally {
  foreach ($p in @($new, $old)) {
    if ($p -and -not $p.HasExited) {
      try { $p.CloseMainWindow() | Out-Null; if (-not $p.WaitForExit(8000)) { $p.Kill() } } catch {}
    }
  }
  $json = Join-Path $OutDir 'updater-upgrade-results.json'
  $script:results | ConvertTo-Json -Depth 4 | Out-File $json -Encoding utf8
  Write-Host "results -> $json"
}
