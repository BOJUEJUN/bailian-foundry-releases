#Requires -Version 5
# Invoke-UpdaterUiSmoke.ps1 — real-Windows updater UI smoke for BailianFoundry.
#
# Drives the SHIPPED 0.1.2 UI only: owns its launched process, foregrounds its
# own HWND, physical mouse click on 检查更新 (UpdateMenu.cs:68-71), which calls
# Open() -> UpdateClient.CheckNow() (UpdateMenu.cs:152-157). Verdict evidence:
# Player.log post-click CHAR segment for "[bailian-update] state=..." lines
# (UpdateClient.cs:503-510) + owned-window PNG captures for visual review.
#
# Physical injection via SetCursorPos + mouse_event requires an interactive
# desktop (proven present on the GH runner by CI 35155499023 keybd_event
# Enter->Combat). Absent desktop / failed foreground / failed capture are
# reported as UNSUPPORTED/FAIL diagnostics — never a fake pass.
#
# -UpgradeExpected gates the future 0.1.2->0.1.3 flow (Download->ReadyToApply
# ->Apply->old exit->helper swap->new player+version). Runs ONLY when the
# public manifest actually advertises a newer version.
#
# Closes ONLY the owned process. Writes updater-ui-results.json + PNGs to
# -OutDir (default rides the existing windows-qa-evidence upload path).

param(
  [Parameter(Mandatory=$true)][string]$AppExe,
  [string]$OutDir = (Join-Path $env:RUNNER_TEMP 'blqa\logs'),
  [int]$BootTimeoutSec = 45,
  [int]$CheckTimeoutSec = 30,
  [int]$DownloadTimeoutSec = 300,
  [int]$ApplyTimeoutSec = 90,
  [switch]$UpgradeExpected
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
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessageW(System.IntPtr h, uint m, System.UIntPtr w, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int cmd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool CloseDesktop(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, System.UIntPtr extra);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetClientRect(System.IntPtr h, out RECT r);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ClientToScreen(System.IntPtr h, ref POINT p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SystemParametersInfoW(uint action, uint param, ref RECT pv, uint fWinIni);
public struct RECT { public int Left, Top, Right, Bottom; }
public struct POINT { public int X, Y; }
'@

$playerLog = Join-Path $env:USERPROFILE 'AppData\LocalLow\Bailian\百炼机关\Player.log'
$proc = $null

# canvas->client mapping: CanvasScaler ScaleWithScreenSize ref 1920x1080,
# matchWidthOrHeight=0.5  =>  scale = sqrt((cw/1920)*(ch/1080))
function CanvasPoint($cx, $cy) {
  $cr = New-Object QaUi.U32+RECT
  if (-not [QaUi.U32]::GetClientRect($hwnd, [ref]$cr)) { return $null }
  $cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
  if ($cw -le 0 -or $ch -le 0) { return $null }
  $scale = [Math]::Sqrt(($cw/1920.0)*($ch/1080.0))
  $o = New-Object QaUi.U32+POINT   # client (0,0) -> screen
  if (-not [QaUi.U32]::ClientToScreen($hwnd, [ref]$o)) { return $null }
  # canvas origin = client bottom-left; screen y grows downward
  return @{ X = [int]($o.X + $cx * $scale); Y = [int]($o.Y + $ch - $cy * $scale) }
}
function ClickCanvas($cx, $cy, $tag) {
  $pt = CanvasPoint $cx $cy
  if ($null -eq $pt) { Rec "$tag-click-target" $false 'GetClientRect/ClientToScreen failed'; return $false }
  [void][QaUi.U32]::SetCursorPos($pt.X, $pt.Y)
  Start-Sleep -Milliseconds 120
  [QaUi.U32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)   # LEFTDOWN
  Start-Sleep -Milliseconds 80
  [QaUi.U32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)   # LEFTUP
  Write-Host "  click $tag at screen ($($pt.X),$($pt.Y))"
  return $true
}
function Capture($name) {
  try {
    $wr = New-Object QaUi.U32+RECT
    if (-not [QaUi.U32]::GetWindowRect($hwnd, [ref]$wr)) { return $null }
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
function LogTail {   # post-click CHAR segment (task requires char offsets)
  if (-not (Test-Path $playerLog)) { return '' }
  $s = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
  if (-not $s) { return '' }
  return $s.Substring([Math]::Min($logOff, $s.Length))
}

try {
  # ---------- own launch + boot ----------
  if (Test-Path $playerLog) { Remove-Item $playerLog -Force }
  $proc = Start-Process -FilePath $AppExe -PassThru
  # Boot proof = our own process has a real window AND Player.log exists with
  # engine-init content. phase=Menu is NEVER logged on 0.1.2 startup (the
  # phase setter only logs on CHANGE) — requiring it would gate on an
  # impossible line. The post-click [bailian-update] state lines are the
  # real evidence the Menu UI flow works.
  $booted = $false; $hwnd = [IntPtr]::Zero; $bw = 0
  while ($bw -lt $BootTimeoutSec -and -not $booted) {
    Start-Sleep 2; $bw += 2
    $proc.Refresh()
    if ($proc.HasExited) { break }
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
      $hwnd = $proc.MainWindowHandle
      $logNow = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
      if ($logNow -and $logNow.Length -gt 200) { $booted = $true }  # engine init lines present
    }
  }
  if ($booted) { Start-Sleep 3 }   # let first frames/UI canvas settle
  Rec 'ui-boot-menu' ($booted -and $hwnd -ne [IntPtr]::Zero) "pid=$($proc.Id) hwnd=$hwnd ${bw}s (window+log; Menu proven by post-click state)"

  # ---------- interactive desktop + foreground gate ----------
  $idesk = [QaUi.U32]::OpenInputDesktop(0, $false, 0x0001)
  $interactive = ($idesk -ne [IntPtr]::Zero)
  if ($interactive) { [void][QaUi.U32]::CloseDesktop($idesk) }
  $fgOk = $false
  if ($booted) {
    [void][QaUi.U32]::ShowWindow($hwnd, 9)                     # SW_RESTORE
    # The shipped window can extend BEHIND the taskbar; the 检查更新 button
    # sits at canvas bottom-left and was occluded (click landed on the
    # taskbar). Fit the owned window inside the work area so the whole
    # client rect is clickable, then re-acquire foreground.
    try {
      $wa = New-Object QaUi.U32+RECT
      [void][QaUi.U32]::SystemParametersInfoW(0x0030, 0, [ref]$wa, 0)   # SPI_GETWORKAREA
      $waW = $wa.Right - $wa.Left; $waH = $wa.Bottom - $wa.Top
      if ($waW -gt 0 -and $waH -gt 0) {
        [void][QaUi.U32]::SetWindowPos($hwnd, [IntPtr]::Zero,
          $wa.Left + 20, $wa.Top + 10, [int]($waW * 0.9), [int]($waH * 0.88), 0x0040)  # SWP_SHOWWINDOW
        Start-Sleep -Milliseconds 600
      }
    } catch {}
    [void][QaUi.U32]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 400
    $fgOk = ([QaUi.U32]::GetForegroundWindow() -eq $hwnd)
  }
  Rec 'ui-input-env' ($booted -and $interactive -and $fgOk) `
      ("interactiveDesktop=$interactive foreground=$fgOk" +
      $(if (-not $interactive) { ' — no input desktop: UNSUPPORTED for physical injection' }
        elseif (-not $fgOk)    { ' — foreground activation failed: UNSUPPORTED' }
        else { '' }))

  # ---------- expected outcome from public manifest (corroboration only) ----------
  $remote = $null; $rawHead = ''
  try {
    $raw = Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 `
        'https://github.com/BOJUEJUN/bailian-foundry-releases/releases/latest/download/update.json' |
        Select-Object -ExpandProperty Content
    $flat = ($raw -replace '\s+',' ')
    $rawHead = $flat.Substring(0, [Math]::Min(80, $flat.Length))
    $mj = $raw | ConvertFrom-Json
    $remote = "$($mj.version)"
  } catch { $remote = "(manifest GET failed: $($_.Exception.Message))" }
  Rec 'ui-manifest-corroboration' $true "public manifest version='$remote' installed=0.1.2 raw='$rawHead'"

  # ---------- CHAR-offset snapshot, then click 检查更新 ----------
  $logOff = 0
  if (Test-Path $playerLog) {
    $pre = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
    if ($pre) { $logOff = $pre.Length }   # CHAR offset of decoded string (UTF-8 log)
  }
  $shot0 = if ($booted) { Capture 'updater-0-menu.png' } else { $null }

  $clicked = $false; $shot1 = $null; $shot3 = $null; $shot4 = $null
  if ($booted -and $interactive -and $fgOk) {
    $clicked = ClickCanvas 117 78 'check-update'   # btn rect x22..212 y52..104
    Start-Sleep 1
    $shot1 = Capture 'updater-1-modal-checking.png'
  }
  Rec 'ui-check-clicked' $clicked $(if ($clicked) { 'physical click at 检查更新 (canvas 117,78)' } elseif (-not ($booted -and $interactive -and $fgOk)) { 'not attempted — input env unsupported (see ui-input-env)' } else { 'click attempted but target mapping failed' })

  # ---------- bounded wait for real updater state evidence ----------
  $state = $null; $cw = 0
  if ($clicked) {
    while ($cw -lt $CheckTimeoutSec -and -not $state) {
      Start-Sleep 2; $cw += 2
      $t = LogTail
      if     ($t -match '\[bailian-update\] state=UpToDate')  { $state = 'UpToDate' }
      elseif ($t -match '\[bailian-update\] state=Available') { $state = 'Available' }
      elseif ($t -match '\[bailian-update\] state=Error')     { $state = 'Error' }
      $proc.Refresh(); if ($proc.HasExited) { break }
    }
  }
  $detail = ((LogTail) -split "`n" | Where-Object { $_ -match '\[bailian-update\]' }) -join ' | '
  Rec 'ui-state-evidence' ($null -ne $state) "state=$state after ${cw}s :: $detail"

  Start-Sleep 1                                          # let status text paint
  $shot2 = if ($state) { Capture 'updater-2-settled.png' } else { $null }
  $shotNames = @($shot0, $shot1, $shot2 | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf }) -join ','
  Rec 'ui-capture' ($null -ne $shot2) $(if ($shot2) { "shots: $shotNames" } else { "window capture unavailable — log evidence only (got: $(if($shotNames){$shotNames}else{'none'}))" })

  # ---------- verdict ----------
  switch ($state) {
    'UpToDate'  { Rec 'ui-verdict' $true "已是最新版本 expected — UI check against live manifest succeeded" }
    'Available' {
      $ok = [bool]$UpgradeExpected
      Rec 'ui-verdict' $ok ("state=Available remote=$remote" + $(if (-not $ok) { ' — unexpected while manifest==installed (0.1.2): investigate' } else { '' }))
    }
    'Error'     {
      $netOk = ($remote -notmatch 'failed')
      Rec 'ui-verdict' $false "Error state; runner manifest GET ok=$netOk — $(if($netOk){'real UI/updater defect'}else{'runner network UNSUPPORTED — environmental limitation, NOT a game pass'})"
    }
    default     {
      Rec 'ui-verdict' $false $(if ($clicked) { 'no updater state after click — button missing/integration gap, or log lost' } else { 'no input path (unsupported env) — updater UI unexercised; honest limitation' })
    }
  }

  # ---------- future upgrade flow: INTENTIONALLY REMOVED / quarantined -------
  # The staged -UpgradeExpected branch was unsound and is NOT run in 0.1.2:
  #  - it read newProcess.MainModule.FileVersionInfo.ProductVersion, which on a
  #    Unity player is the ENGINE version (e.g. 6000.6.x), not the game version
  #  - Get-Process by name + Select-First is not ownership proof of the
  #    relaunched player
  #  - Capture() reused the OLD hwnd of the exited process
  # A real 0.1.3-era test must instead prove the new version via actual runtime
  # evidence (Application.version in the new Player.log / updater helper log),
  # a NEW owned PID with exact exe path + start-time + parent verification,
  # and a freshly acquired HWND. Until then: no fake future-version claims.

  # ---------- close modal politely, then owned process ----------
  if ($booted -and -not $proc.HasExited) {
    [void](ClickCanvas 1100 280 'close-modal')           # 关 闭
    Start-Sleep -Milliseconds 400
  }
}
finally {
  if ($proc -and -not $proc.HasExited) {
    try { $proc.CloseMainWindow() | Out-Null; if (-not $proc.WaitForExit(8000)) { $proc.Kill() } } catch {}
  }
  $json = Join-Path $OutDir 'updater-ui-results.json'
  $script:results | ConvertTo-Json -Depth 4 | Out-File $json -Encoding utf8
  Write-Host "results -> $json"
}
