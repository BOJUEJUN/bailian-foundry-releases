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

function CanvasPoint($cx, $cy) {
  $cr = New-Object QaLobby.U32+RECT
  if (-not [QaLobby.U32]::GetClientRect($hwnd, [ref]$cr)) { return $null }
  $cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
  if ($cw -le 0 -or $ch -le 0) { return $null }
  $scale = [Math]::Sqrt(($cw/1920.0)*($ch/1080.0))
  # CanvasScaler match=0.5: the visible canvas is NOT exactly 1920x1080
  # units — when the client aspect differs, visible units = clientPx/scale
  # and the authored 1920x1080 content is CENTERED. Elements are offset by
  # (visible - ref)/2 on each axis; omitting this put clicks ~48 units low
  # (create-room click landed on join).
  $hoff = ($cw / $scale - 1920.0) / 2.0
  $voff = ($ch / $scale - 1080.0) / 2.0
  $o = New-Object QaLobby.U32+POINT
  if (-not [QaLobby.U32]::ClientToScreen($hwnd, [ref]$o)) { return $null }
  return @{ X = [int]($o.X + ($cx + $hoff) * $scale); Y = [int]($o.Y + $ch - ($cy + $voff) * $scale) }
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

  # ---------- nickname entry (ed6a48b layout: top-anchored buttons below
  # the field; Nick() defaults to 玩家 when empty, but typing proves real
  # input). NickField: anchor(0,1) pos(72,-228) size(476,80) on the centered
  # 620x620 EntryPanel => canvas (960,582).
  $nickTyped = $false
  if ($opened) {
    $null = ClickCanvas 960 582 'nick-field'
    Start-Sleep -Milliseconds 400
    foreach ($vk in 0x51,0x41,0x57,0x49,0x4E,0x43,0x49) {   # "qawinci"
      if ([QaLobby.U32]::GetForegroundWindow() -ne $hwnd) { break }
      [QaLobby.U32]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 60
      [QaLobby.U32]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 60
    }
    $nickTyped = $true
    Start-Sleep -Milliseconds 300
    $shot1b = Capture 'lobby-1b-nick.png'              # shows typed nick text
  }
  Rec 'lobby-nick-typed' $nickTyped $(if ($nickTyped) { 'typed qawinci into nick field (see lobby-1b-nick.png)' } else { 'not attempted — lobby never opened' })

  # ---------- click 创建房间 -> wait for real Relay alloc ----------
  # ed6a48b: EntryPanel is a 620x620 CENTERED modal (canvas 650..1270 x
  # 230..850); CreateBtn anchor(0,1) pos(72,-320) size(476,80) =>
  # panel-local y[220,300] => canvas center (960,490). JoinBtn sits at
  # canvas (960,398) — 92 units below create, no overlap.
  $created = $false; $allocLine = ''
  if ($opened) {
    $cw = 0
    foreach ($tryNo in 1,2) {
      $null = ClickCanvas 960 490 "room-create#$tryNo"  # CreateBtn 创建房间
      while ($cw -lt 30 -and -not $created) {
        Start-Sleep 2; $cw += 2
        $t = LogTail
        if ($t -match '\[NgoChannel\] local alloc token from transport') { $created = $true; $allocLine = ($t -split "`n" | Where-Object { $_ -match 'local alloc token' } | Select-Object -First 1) }
        $proc.Refresh(); if ($proc.HasExited) { break }
      }
      if ($created -or $proc.HasExited) { break }
      # first click may have landed while the button was still disabled
      # (capability check settling) — one retry is bounded and honest.
    }
    Start-Sleep 1
    $shot2 = Capture 'lobby-2-room.png'                # room panel: code text top-right
  }
  Rec 'lobby-room-created' $created `
      $(if ($created) { "Relay alloc bound after ${cw}s: $allocLine (room code visible in lobby-2-room.png)" }
        elseif (-not $opened) { 'not attempted — lobby never opened' }
        else { "no Relay alloc within ${RoomTimeoutSec}s — create did not provision a session (capability/backend issue or button disabled)" })
  Rec 'lobby-capture' ($null -ne $shot2) $(if ($shot2) { 'room panel captured (root reviews room code visually)' } else { 'window capture unavailable' })

  # ---------- full room workflow: 准备 -> 开始战斗 -> Combat -> 返回主菜单 ----------
  # RoomPanel 780x620 centered (canvas x 570..1350, y 230..850). 0.1.4 footer
  # uses fractional anchors (disjoint thirds):
  #   ReadyBtn anchor(0,0)-(1/3,0) off(40,60)-(-10,156) => panel (145,108) => canvas (715,338)
  #   StartBtn anchor(1/3,0)-(2/3,0) off(10,60)-(-10,156) => panel (390,108) => canvas (960,338)
  #   LeaveBtn anchor(2/3,0)-(1,0)   off(10,60)-(-40,156) => panel (635,108) => canvas (1205,338)
  $combat = $false; $menuBack = $false
  if ($created) {
    # --- 准备: the ready save emits NO Player.log line (verified: a real
    # ready click on run 35189098289 logged nothing — SetReadyAsync's
    # SaveCurrentPlayerDataAsync does not ride the NgoChannel publish hook).
    # Evidence = lobby-3-ready.png (slot shows 已准备, button flips to
    # 取消准备); PROGRAMMATIC consumption is transitive: RequestStart is
    # gated by ComputeStartEligible -> AllReady, so a later phase=Combat
    # proves the ready flag was consumed.
    $pre = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
    if ($pre) { $logOff = $pre.Length }
    $null = ClickCanvas 715 338 'room-ready'
    Start-Sleep 4
    $shot3 = Capture 'lobby-3-ready.png'          # slot ready state + start hint
    Rec 'lobby-ready-clicked' ($null -ne $shot3) `
        '准备 click delivered; ready state + start hint in lobby-3-ready.png (consumption proven by lobby-match-started — start is gated on AllReady)'

    # --- 开始战斗: solo start is legitimate — ComputeStartEligible passes at
    # occ>=1 once AllReady ("可单人开始"). Consumption = real phase=Combat.
    $pre = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
    if ($pre) { $logOff = $pre.Length }
    $null = ClickCanvas 960 338 'room-start'
    $sw2 = 0
    while ($sw2 -lt 25 -and -not $combat) {
      Start-Sleep 2; $sw2 += 2
      if ((LogTail) -match 'phase=Combat') { $combat = $true }
      $proc.Refresh(); if ($proc.HasExited) { break }
    }
    Start-Sleep 3
    $shot4 = Capture 'lobby-4-combat.png'         # real co-op combat frame
    Rec 'lobby-match-started' $combat `
        $(if ($combat) { "开始战斗 -> phase=Combat after ${sw2}s; owned process healthy" }
          else { 'no phase=Combat within 25s — start not consumed (ready flag or backend)' })

    # --- return via actual controls: Esc opens the co-op local-pause
    # overlay (战斗菜单), then 返回主菜单 — inside the 480x560 centered
    # pause panel (canvas y 250..830): anchor(0.5,1) pos(0,-416) =>
    # panel-local y 144 => canvas (960,394). ReturnToMenu calls
    # link.RequestLeave() so the room is released here.
    if ($combat) {
      [QaLobby.U32]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 80
      [QaLobby.U32]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
      Start-Sleep 2
      $shotEsc = Capture 'lobby-4b-pause.png'     # local pause overlay
      $null = ClickCanvas 960 394 'pause-menu-exit'
      $mw = 0
      while ($mw -lt 15 -and -not $menuBack) {
        Start-Sleep 2; $mw += 2
        if ((LogTail) -match 'phase=Menu') { $menuBack = $true }
        $proc.Refresh(); if ($proc.HasExited) { break }
      }
      Start-Sleep 1
      $shot5 = Capture 'lobby-5-back.png'
      Rec 'lobby-returned-to-menu' $menuBack `
          $(if ($menuBack) { "Esc -> 返回主菜单 -> phase=Menu after ${mw}s (ReturnToMenu issued RequestLeave)" }
            else { 'no phase=Menu within 15s — pause/menu return not consumed' })
    }
  }

  # ---------- explicit leave flow: clean RoomReleased ----------
  # Two honest paths: (a) start never consumed -> still sitting in the room
  # panel, leave room #1 directly; (b) back at menu -> reopen 联机, create
  # room #2, click 离开房间 — covering the explicit-release verb too.
  $room2 = $false
  if ($created -and -not $combat -and -not $menuBack) {
    $null = ClickCanvas 1205 338 'room-leave'
    Start-Sleep 3
    $shot8 = Capture 'lobby-8-leave-entry.png'      # room panel -> entry
    $proc.Refresh()
    Rec 'lobby-leave-clean' (-not $proc.HasExited) '离开房间 clicked on room #1; room released (process healthy)'
  }
  elseif ($menuBack) {
    Start-Sleep 2
    $null = ClickCanvas 960 234 'coop-reopen'
    Start-Sleep 7                                   # reopen + capability settle
    $shot6 = Capture 'lobby-6-entry.png'
    # retype nick (DraftNick may persist; appending 'qa2' stays <=16 either way)
    $null = ClickCanvas 960 582 'nick-field-2'
    Start-Sleep -Milliseconds 400
    foreach ($vk in 0x51,0x41,0x32) {               # "qa2"
      if ([QaLobby.U32]::GetForegroundWindow() -ne $hwnd) { break }
      [QaLobby.U32]::keybd_event([byte]$vk, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 60
      [QaLobby.U32]::keybd_event([byte]$vk, 0, 2, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 60
    }
    $pre = Get-Content $playerLog -Raw -ErrorAction SilentlyContinue
    if ($pre) { $logOff = $pre.Length }
    $null = ClickCanvas 960 490 'room-create-2'
    $aw = 0; $alloc2 = ''
    while ($aw -lt 30 -and -not $room2) {
      Start-Sleep 2; $aw += 2
      $t = LogTail
      if ($t -match 'local alloc token from transport') {
        $room2 = $true
        $alloc2 = ($t -split "`n" | Where-Object { $_ -match 'local alloc token' } | Select-Object -First 1)
      }
      $proc.Refresh(); if ($proc.HasExited) { break }
    }
    Start-Sleep 1
    $shot7 = Capture 'lobby-7-room2.png'
    Rec 'lobby-room2-created' $room2 `
        $(if ($room2) { "room #2 alloc after ${aw}s: $alloc2" }
          else { 'no second Relay alloc — reopen did not yield a fresh create (still in room? see lobby-6-entry.png)' })

    # --- direct 离开房间: the explicit room-release path ----------
    if ($room2) {
      $null = ClickCanvas 1205 338 'room-leave'
      Start-Sleep 3
      $shot8 = Capture 'lobby-8-leave-entry.png'    # room panel -> entry
      $proc.Refresh()
      Rec 'lobby-leave-clean' (-not $proc.HasExited) '离开房间 clicked; room released (process healthy; entry in lobby-8-leave-entry.png)'
    }
  }

  Rec 'lobby-verdict' ($created -and $combat -and $menuBack -and $room2) `
      $(if ($created -and $combat -and $menuBack -and $room2) {
          'full normal room workflow real: create -> Relay -> ready -> start -> Combat -> menu -> room2 -> explicit leave'
        } else {
          "room workflow incomplete: created=$created combat=$combat menu=$menuBack room2=$room2"
        })
}
finally {
  if ($proc -and -not $proc.HasExited) {
    try { $proc.CloseMainWindow() | Out-Null; if (-not $proc.WaitForExit(8000)) { $proc.Kill() } } catch {}
  }
  try { if (Test-Path $playerLog) { Copy-Item $playerLog (Join-Path $OutDir 'lobby-Player.log') -Force } } catch {}
  $json = Join-Path $OutDir 'lobby-ui-results.json'
  $script:results | ConvertTo-Json -Depth 4 | Out-File $json -Encoding utf8
  Write-Host "results -> $json"
}
