#Requires -Version 5
# Invoke-CoopQa.ps1 — real Windows-hosted co-op QA for 百炼机关.
#
# Drives ONE owned native Windows QA-player process (BAILIAN_QA build only —
# the driver compiles out of production builds) against a REAL live room:
#   join role — joins a Mac-hosted room by code (Windows<->Mac interop proof)
#   host role — hosts a room here; code surfaced via room file for a peer.
#
# Contract (frozen, CoopQaDriver.cs — read-only reference):
#   args   -bailianQa=host|join  -bailianQaName=<n>  -bailianQaCode=<code>
#          -bailianQaJoin=<code> -bailianQaRoomFile=<p>  -bailianQaLog=<p>
#          -bailianQaPlayers=<n> (def 2)  -bailianQaTimeout=<s> (def 300)
#   marks  "QA <t>s <msg>" appended to the marker log + Debug.Log:
#          boot role=… | room code=… / joined code=… | members=N | ready: …
#          allready n=N | match start host=… | phase=Combat wave=… players=…
#          peerinput slot=N moved path=… | remote edges slot=N n=…
#          remote skill cast slot=N … | snap heroes=N enemies=N (client)
#          shop mirror gold=… | buy sent/acked/unacked idx=… | downed|revived
#          localpause open/closed/noreplay/resume/LEAK/REPLAY | peerinputzero
#          peerinputback | peerlive | peerdrop | leaving | done PASS|FAIL <why>
#   exit   0 = PASS, 2 = FAIL/timeout (driver self-quits; hard-exit backstop)
#
# Evidence discipline: process launch / local menu / "room listed" are NEVER
# co-op proof — only the driver's real wire marks + exit 0 count. UGS/Relay/
# UDP transport failures surface as coop-net-diagnostic FAIL evidence, not
# passes. We kill ONLY our owned PID. Player.log is shared per-product; the
# marker log is ours via -bailianQaLog.

param(
  [Parameter(Mandatory=$true)][string]$QaZip,
  [Parameter(Mandatory=$true)][string]$ExpectSha256,
  [Parameter(Mandatory=$true)][long]$ExpectSize,
  [string]$ExpectVersion = '',
  [ValidateSet('join','host')][string]$Role = 'join',
  [string]$RoomCode = '',
  [string]$RoomFile = '',
  [string]$QaName = 'QA-Win-CI',
  [int]$Players = 2,
  [int]$DriverTimeoutSec = 420,
  [int]$OuterGraceSec = 60,
  [string]$WorkRoot = (Join-Path $env:RUNNER_TEMP 'blcoop'),
  [string]$OutDir   = (Join-Path $env:RUNNER_TEMP 'blcoop\logs')
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
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
public struct RECT { public int Left, Top, Right, Bottom; }
'@

$markLog  = Join-Path $OutDir "coop-qa-$Role.log"   # driver writes marks here (+ .pause.png)
$playerLog = Join-Path $env:USERPROFILE 'AppData\LocalLow\Bailian\百炼机关\Player.log'
$appDir   = Join-Path $WorkRoot 'coopqa-app'
$proc = $null

function Marks {  # decoded marker-log content (may not exist yet)
  if (-not (Test-Path $markLog)) { return '' }
  return (Get-Content $markLog -Raw -ErrorAction SilentlyContinue)
}
function MarkLines($pat) {
  $m = Marks; if (-not $m) { return @() }
  return @($m -split "`n" | Where-Object { $_ -match $pat })
}
function Shot($name) {
  try {
    if (-not $proc -or $proc.HasExited) { return $null }
    $proc.Refresh()
    $hw = $proc.MainWindowHandle
    if ($hw -eq [IntPtr]::Zero) { return $null }
    $wr = New-Object QaUi.U32+RECT
    if (-not [QaUi.U32]::GetWindowRect($hw, [ref]$wr)) { return $null }
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

try {
  # ---------- gate + exact artifact verification ----------
  $joinArmed = ($Role -eq 'host') -or ($RoomCode -or $RoomFile)
  Rec 'coop-armed' ($joinArmed -and (Test-Path $QaZip)) (
    "role=$Role roomCode=$(if($RoomCode){'<set>'}else{'<none>'}) roomFile='$RoomFile' " +
    "zip='$(Split-Path $QaZip -Leaf)' expectVer='$ExpectVersion' sha=$ExpectSha256 size=$ExpectSize")
  if (-not $joinArmed) { Rec 'coop-verdict' $false 'join role needs -RoomCode or -RoomFile — refusing to run without a real live room'; return }

  $fi = Get-Item $QaZip
  $hash = (Get-FileHash $QaZip -Algorithm SHA256).Hash.ToLowerInvariant()
  Rec 'coop-artifact-hash' ($fi.Length -eq $ExpectSize -and $hash -eq $ExpectSha256) (
    "size=$($fi.Length)/$ExpectSize sha256=$hash")
  if ($fi.Length -ne $ExpectSize -or $hash -ne $ExpectSha256) {
    Rec 'coop-verdict' $false 'QA artifact bytes differ from approved handoff — refusing to run'; return
  }

  # ---------- extract (flat QA zip) + locate exe ----------
  if (Test-Path $appDir) { Remove-Item $appDir -Recurse -Force }
  New-Item -ItemType Directory -Force $appDir | Out-Null
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($QaZip, $appDir)
  } catch { Rec 'coop-extract' $false "unzip failed: $_"; Rec 'coop-verdict' $false 'no runnable QA payload'; return }
  $exe = Get-ChildItem $appDir -Filter 'BailianFoundry.exe' -Recurse | Select-Object -First 1
  Rec 'coop-extract' ($null -ne $exe) $(if ($exe) { $exe.FullName } else { 'BailianFoundry.exe not found in QA zip' })
  if (-not $exe) { Rec 'coop-verdict' $false 'no runnable QA payload'; return }

  # ---------- launch ONE owned QA process ----------
  if (Test-Path $markLog) { Remove-Item $markLog -Force }
  $qaArgs = @(
    "-bailianQa=$Role",
    "-bailianQaName=$QaName",
    "-bailianQaLog=$markLog",
    "-bailianQaPlayers=$Players",
    "-bailianQaTimeout=$DriverTimeoutSec"
  )
  if ($Role -eq 'join') {
    if ($RoomCode) { $qaArgs += "-bailianQaCode=$RoomCode" }
    elseif ($RoomFile) { $qaArgs += "-bailianQaRoomFile=$RoomFile" }
  } else {
    $rf = if ($RoomFile) { $RoomFile } else { Join-Path $OutDir 'coop-roomcode.txt' }
    $qaArgs += "-bailianQaRoomFile=$rf"
  }
  $proc = Start-Process -FilePath $exe.FullName -ArgumentList $qaArgs -PassThru `
          -WorkingDirectory $WorkRoot   # own cwd — never inside appDir (locks)
  Rec 'coop-process-owned' $true "pid=$($proc.Id) start=$($proc.StartTime.ToString('o')) exe=$($exe.FullName) args=[$($qaArgs -join ' ')]"

  # ---------- bounded wait: driver self-exits 0/2 ----------
  $bound = $DriverTimeoutSec + $OuterGraceSec
  $w = 0; $combatShot = $false
  while ($w -lt $bound -and -not $proc.HasExited) {
    Start-Sleep 3; $w += 3
    $proc.Refresh()
    if (-not $combatShot -and (Marks) -match 'phase=Combat') {
      $combatShot = [bool](Shot 'coop-0-combat.png')
    }
  }
  $code = if ($proc.HasExited) { $proc.ExitCode } else { $null }
  $m = Marks

  # ---------- evidence parsing (driver's own marks are the proof) ----------
  $bootMark   = (MarkLines 'boot role=') -join ' | '
  $joinMark   = (MarkLines 'joined code=') -join ' | '
  $hostMark   = (MarkLines 'room code=') -join ' | '
  $matchMark  = (MarkLines 'match start') -join ' | '
  $snapMark   = (MarkLines 'snap heroes=') -join ' | '
  $combatMark = (MarkLines 'phase=Combat') -join ' | '
  $peerMarks  = (MarkLines 'peerinput slot|remote edges|remote skill cast') -join ' | '
  $buyMark    = (MarkLines 'buy acked') -join ' | '
  $downMark   = (MarkLines 'downed|revived') -join ' | '
  $pauseMark  = (MarkLines 'localpause') -join ' | '
  $leaveMark  = (MarkLines 'leaving|peerdrop|done ') -join ' | '
  $failMark   = (MarkLines 'done FAIL|capability=|lobby err=') -join ' | '

  Rec 'coop-boot'        ($bootMark -match "role=$Role") $bootMark
  if ($Role -eq 'join') {
    $codeOk = $joinMark -and ($RoomCode -eq '' -or $joinMark -match [regex]::Escape($RoomCode))
    Rec 'coop-joined'   ([bool]$codeOk) "$joinMark (UGS session join over real Relay; expected code='$RoomCode')"
    Rec 'coop-snapshots'($snapMark -match 'heroes=\d+') $snapMark
    Rec 'coop-shop-buy' ($buyMark -ne '') $buyMark
  } else {
    Rec 'coop-room-code' ($hostMark -ne '') "$hostMark (room file: $rf)"
    Rec 'coop-peer-input' ($peerMarks -ne '') "$peerMarks (remote client drove its hero over the wire)"
  }
  Rec 'coop-members'      ($m -match 'members=\d+') ((MarkLines 'members=|allready|ready:') -join ' | ')
  Rec 'coop-match-start'  ($matchMark -ne '') $matchMark
  Rec 'coop-combat'       ($combatMark -ne '') $combatMark
  Rec 'coop-down-revive'  ($downMark -match 'downed' -and $downMark -match 'revived') $downMark
  Rec 'coop-pause'        ($pauseMark -match 'localpause open' -and $pauseMark -match 'closed') $pauseMark
  Rec 'coop-clean-leave'  ($leaveMark -match 'done PASS|leaving|peerdrop') $leaveMark
  Rec 'coop-exit-0'       ($code -eq 0) "exitCode=$code bound=${bound}s elapsed=${w}s"

  # transport/diagnostic honesty: capability/lobby/timeout failures are real
  # runner-network findings (UDP/Relay reachability), never silent passes.
  $netDiag = ''
  if ($m -match 'capability=(\S+)') { $netDiag = "UGS capability=$($Matches[1]) (service/Relay reachability failed at driver level)" }
  elseif ($m -match 'lobby err=(\S+ \S+)') { $netDiag = "lobby error: $($Matches[1])" }
  elseif ($m -match 'done FAIL timeout') { $netDiag = 'driver timeout — see marks for last reached step' }
  Rec 'coop-net-diagnostic' ($netDiag -eq '') $(if ($netDiag) { $netDiag } else { 'no transport-level failure observed' })

  # driver pause-screenshot artifact (driver writes <logpath>.pause.png itself)
  $drvShot = "$markLog.pause.png"
  if (Test-Path $drvShot) { Write-Host "driver pause screenshot: $drvShot" }

  $verdictOk = ($code -eq 0) -and ($m -match 'done PASS')
  Rec 'coop-verdict' $verdictOk (
    $(if ($verdictOk) { "driver PASS: $Role role completed full co-op flow over real Relay" }
      else { "NOT PASS — exit=$code; marks: $leaveMark $failMark" }))
}
finally {
  if ($proc -and -not $proc.HasExited) {
    try { $proc.Kill() } catch {}   # owned PID only — never name-based kills
  }
  if (Test-Path $playerLog) {
    Copy-Item $playerLog (Join-Path $OutDir 'coop-Player.log') -Force -ErrorAction SilentlyContinue
  }
  $json = Join-Path $OutDir 'coop-qa-results.json'
  $script:results | ConvertTo-Json -Depth 4 | Out-File $json -Encoding utf8
  Write-Host "results -> $json"
  if (-not $script:results.Contains('coop-verdict') -or -not $script:results['coop-verdict'].ok) { exit 2 }
}
