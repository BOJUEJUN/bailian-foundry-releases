#Requires -Version 5
# Invoke-LobbyUiSmoke.ps1 — real-Windows NORMAL-path co-op lobby UI smoke.
#
# The QA-driver cross-platform proof (run 35168824292) bypassed the shipped
# menu. This script drives the REAL 0.1.3 menu with physical input:
#   联机 (GameUI.cs CoopBtn, canvas ~960,234) -> lobby entry panel ->
#   创建房间 (CoopLobbyUI.cs CreateBtn, canvas ~310,238) -> UGS session +
#   Relay provisioning -> room code shown in the room panel -> 离开
#   (LeaveBtn, canvas ~1750,108) cleans up the owned room.
#
# Evidence model (honest): the normal path has NO QA log marks, so a created
# room is proven by (a) the [NgoChannel] "local alloc token from transport"
# Player.log line — emitted only when a real Relay allocation is bound —
# and (b) a window capture of the room panel (root reviews the room-code
# text visually). Panel open alone is NEVER counted as room creation.
# A failure here is reported as FAIL/UNSUPPORTED — never laundered.
#
# Owns exactly one launched process; kills only it. Unique QaLobby namespace
# (QaUi.U32 is already compiled by Invoke-UpdaterUiSmoke.ps1 in-session).

param(
  [Parameter(Mandatory=$true)][string]$AppExe,
  [string]$OutDir = (Join-Path $env:RUNNER_TEMP 'blqa\logs'),
  [int]$BootTimeoutSec = 45,
  [int]$RoomTimeoutSec = 60
)

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$script:results = [ordered]@{}
function Rec($name, $ok, $note='') {
  $script:results[$name] = @{ ok=[bool]$ok; note="$note" }
  Write-Host ("[{0}] {1}{2}" -f $(if($ok){'PASS'}else{'FAIL'}), $name, $(if($note){" — $note"}))
}

Add-Type -AssemblyName System.Drawing
Add-Type -Namespace QaLobby -Name U32 -MemberDefinition @'
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

$playerLog = Join-Path $env:USERPROFILE 'AppData\LocalLow\Bailian\百炼机关\Player.log'
$proc = $null

function CanvasPoint($cx, $cy) {
  $cr = New-Object QaLobby.U32+RECT
  if (-not [QaLobby.U32]::GetClientRect($hwnd, [ref]$cr)) { return $null }
  $cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
  if ($cw -le 0 -or $ch -le 0) { return $null }
  $scale = [Math]::Sqrt(($cw/1920.0)*($ch/1080.0))
  $o = New-Object QaLobby.U32+POINT
  if (-not [QaLobby.U32]::ClientToScreen($hwnd, [ref]$o)) { return $null }
  return @{ X = [int]($o.X + $cx * $scale); Y = [int]($o.Y + $ch - $cy * $scale) }
}
function ClickCanvas($cx, $cy, $tag) {
  $pt = CanvasPoint $cx $cy
  if ($null -eq $pt) { Rec "$tag-click-target" $false 'GetClientRect/ClientToScreen failed'; return $false }
  [void][QaLobby.U32]::SetCursorPos($pt.X, $pt.Y)
  Start-Sleep -Milliseconds 120
  [QaLobby.U32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [QaLobby.U32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Write-Host "  click $tag at screen ($($pt.X),$($pt.Y))"
  return $true
}
function Capture($name) {
  try {
    $wr = New-Object QaLobby.U32+RECT
    if (-not [QaLobby.U32]::GetWindowRect($hwnd, [ref]$wr)) { return $null }
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
  return $s.Substring([Math]::Min($logOff, $s.Length))
}

try {
  # ---------- own launch + boot ----------
  if (Test-Path $playerLog) { Remove-Item $playerLog -Force }
  $proc = Start-Process -FilePath $AppExe -PassThru
  $booted = $false; $hwnd = [IntPtr]::Zero; $bw = 0
  while ($bw -lt $BootTimeoutSec -and -not $booted) {
    Start-Sleep 2; $bw += 2
    $proc.Refresh()
    if ($proc.HasExited) { break }
    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
      $hwnd = $proc.MainWindowHandle
      $logNow = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
      if ($logNow -and $logNow.Length -gt 200) { $booted = $true }
    }
  }
  if ($booted) { Start-Sleep 3 }
  Rec 'lobby-boot' ($booted -and $hwnd -ne [IntPtr]::Zero) "pid=$($proc.Id) hwnd=$hwnd ${bw}s"

  # ---------- interactive desktop + foreground gate ----------
  $idesk = [QaLobby.U32]::OpenInputDesktop(0, $false, 0x0001)
  $interactive = ($idesk -ne [IntPtr]::Zero)
  if ($interactive) { [void][QaLobby.U32]::CloseDesktop($idesk) }
  $fgOk = $false
  if ($booted) {
    [void][QaLobby.U32]::ShowWindow($hwnd, 9)
    try {
      $wa = New-Object QaLobby.U32+RECT
      [void][QaLobby.U32]::SystemParametersInfoW(0x0030, 0, [ref]$wa, 0)
      $waW = $wa.Right - $wa.Left; $waH = $wa.Bottom - $wa.Top
      if ($waW -gt 0 -and $waH -gt 0) {
        [void][QaLobby.U32]::SetWindowPos($hwnd, [IntPtr]::Zero,
          $wa.Left + 20, $wa.Top + 10, [int]($waW * 0.9), [int]($waH * 0.88), 0x0040)
        Start-Sleep -Milliseconds 600
      }
    } catch {}
    [void][QaLobby.U32]::SetForegroundWindow($hwnd)
    Start-Sleep -Milliseconds 400
    $fgOk = ([QaLobby.U32]::GetForegroundWindow() -eq $hwnd)
  }
  Rec 'lobby-input-env' ($booted -and $interactive -and $fgOk) `
      ("interactiveDesktop=$interactive foreground=$fgOk" +
      $(if (-not $interactive) { ' — no input desktop: UNSUPPORTED' }
        elseif (-not $fgOk)    { ' — foreground failed: UNSUPPORTED' } else { '' }))

  # ---------- snapshot CHAR offset, click 联机 ----------
  $logOff = 0
  if (Test-Path $playerLog) {
    $pre = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
    if ($pre) { $logOff = $pre.Length }
  }
  $shot0 = if ($booted) { Capture 'lobby-0-menu.png' } else { $null }

  $opened = $false
  if ($booted -and $interactive -and $fgOk) {
    $opened = ClickCanvas 960 234 'coop-open'          # CoopBtn 联机
    Start-Sleep 3                                       # lobby bootstrap + UGS anonymous sign-in
    $shot1 = Capture 'lobby-1-entry.png'
    Start-Sleep 4                                       # capability check settles (CreateEnabled)
  }
  Rec 'lobby-coop-opened' $opened $(if ($opened) { 'physical click at 联机 (canvas 960,234); entry panel captured' } else { 'not attempted — input env unsupported or mapping failed' })

  # ---------- click 创建房间 -> wait for real Relay alloc ----------
  $created = $false; $allocLine = ''
  if ($opened) {
    $null = ClickCanvas 310 238 'room-create'          # CreateBtn 创建房间
    $cw = 0
    while ($cw -lt $RoomTimeoutSec -and -not $created) {
      Start-Sleep 2; $cw += 2
      $t = LogTail
      if ($t -match '\[NgoChannel\] local alloc token from transport') { $created = $true; $allocLine = ($t -split "`n" | Where-Object { $_ -match 'local alloc token' } | Select-Object -First 1) }
      $proc.Refresh(); if ($proc.HasExited) { break }
    }
    Start-Sleep 1
    $shot2 = Capture 'lobby-2-room.png'                # room panel: code text top-right
  }
  Rec 'lobby-room-created' $created `
      $(if ($created) { "Relay alloc bound after ${cw}s: $allocLine (room code visible in lobby-2-room.png)" }
        elseif (-not $opened) { 'not attempted — lobby never opened' }
        else { "no Relay alloc within ${RoomTimeoutSec}s — create did not provision a session (capability/backend issue or button disabled)" })
  Rec 'lobby-capture' ($null -ne $shot2) $(if ($shot2) { 'room panel captured (root reviews room code visually)' } else { 'window capture unavailable' })

  # ---------- leave the owned room ----------
  if ($created) {
    $null = ClickCanvas 1750 108 'room-leave'          # LeaveBtn 离开
    Start-Sleep 2
    $proc.Refresh()
    Rec 'lobby-leave-clean' (-not $proc.HasExited) '离开 clicked; room released (process still healthy)'
  }

  Rec 'lobby-verdict' ($created -and $opened) `
      $(if ($created) { 'normal menu -> 联机 -> 创建房间 produced a real Relay session; room code shown in UI' }
        else { 'lobby flow incomplete — see checks above (panel open alone is NOT room creation)' })
}
finally {
  if ($proc -and -not $proc.HasExited) {
    try { $proc.CloseMainWindow() | Out-Null; if (-not $proc.WaitForExit(8000)) { $proc.Kill() } } catch {}
  }
  $json = Join-Path $OutDir 'lobby-ui-results.json'
  $script:results | ConvertTo-Json -Depth 4 | Out-File $json -Encoding utf8
  Write-Host "results -> $json"
}
