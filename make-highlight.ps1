# ============================================================
#  make-highlight.ps1  -  HCTP highlight video maker (1080p mp4)
#
#  Photos AND video clips -> crossfade slideshow (no motion)
#  with title cards and background music (music auto-ducks
#  while an interview clip plays, its own audio comes through).
#
#  Usage:
#     .\make-highlight.ps1 -Photos .\highlight -Music .\song.mp3
#
#  - items play in FILE NAME order: 01-arrival.jpg, 02-...,
#    14-interview.mp4, 15-... (mp4/mov clips allowed anywhere)
#  - portrait media letterboxed on a blurred backdrop (no crop)
#  - clips play FULL length by default (use -MaxClip N to cap)
#  - Korean subtitles: put  NAME.srt  next to  NAME.mov/mp4
#    (save as UTF-8!) and it is burned into that clip
#  - needs ffmpeg:  winget install Gyan.FFmpeg
# ============================================================

param(
    [Parameter(Mandatory=$true)][string]$Photos,
    [string]$Music  = "",
    [string]$Out    = "hctp-highlight-2026.mp4",
    [double]$Secs   = 4,
    [double]$Fade   = 0.8,
    [double]$MaxClip= 0,      # 0 = no trim: clips play full length
    [string]$Title  = "HCTP Summer Camp 2026",
    [string]$Title2 = "Hanaim Community Tutorial Program",
    [string]$Outro  = "Thank You",
    [string]$Outro2 = "See you next summer!"
)

$ErrorActionPreference = "Stop"
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Warning "ffmpeg not found. Install:  winget install Gyan.FFmpeg  then reopen PowerShell."
    exit 1
}

$files = @(Get-ChildItem -LiteralPath $Photos -File |
    Where-Object { $_.Extension -match '^\.(jpe?g|png|webp|mp4|mov|m4v)$' } |
    Sort-Object Name)
if ($files.Count -lt 2) { Write-Warning "need at least 2 files in $Photos"; exit 1 }

function Probe([string]$path) {
    $j = & ffprobe -v error -show_entries format=duration -show_streams -of json $path | ConvertFrom-Json
    $dur  = [double]$j.format.duration
    $hasA = @($j.streams | Where-Object { $_.codec_type -eq "audio" }).Count -gt 0
    ,@($dur, $hasA)
}

# item: @{ path; kind(img|vid); dur; hasA }
$items = @()
foreach ($f in $files) {
    if ($f.Extension -match '^\.(mp4|mov|m4v)$') {
        $p = Probe $f.FullName
        $d = if ($MaxClip -gt 0) { [math]::Round([math]::Min($p[0], $MaxClip), 3) }
             else { [math]::Round($p[0], 3) }
        $items += @{ path=$f.FullName; kind="vid"; dur=$d; hasA=$p[1] }
        Write-Host ("  clip  {0}  ({1:N1}s{2})" -f $f.Name, $d, $(if($p[1]){", audio"}else{", no audio"}))
    } else {
        $items += @{ path=$f.FullName; kind="img"; dur=$Secs; hasA=$false }
    }
}

$font = @("georgiai.ttf","georgia.ttf","arial.ttf") |
    ForEach-Object { Join-Path "C:\Windows\Fonts" $_ } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
$fontF = ($font -replace '\\','/') -replace ':','\:'

$FPS = 30; $INTRO = 4.5; $OUTRO = 5.0
$durs = @($INTRO) + @($items | ForEach-Object { $_.dur }) + @($OUTRO)
$nSeg = $durs.Count
$total = ($durs | Measure-Object -Sum).Sum - $Fade * ($nSeg - 1)
Write-Host ("{0} items  ->  video length ~{1:N1}s" -f $items.Count, $total)

$G = New-Object System.Collections.Generic.List[string]

$G.Add((("color=c=0x0d0b09:s=1920x1080:r={0}:d={1}," +
    "drawtext=fontfile='{2}':text='{3}':fontsize=84:fontcolor=0xc8ab6e:x=(w-text_w)/2:y=(h-text_h)/2-46," +
    "drawtext=fontfile='{2}':text='{4}':fontsize=30:fontcolor=0x9b8a6a:x=(w-text_w)/2:y=(h)/2+58," +
    "format=yuv420p,setsar=1[vin]") -f $FPS, $INTRO, $fontF, $Title, $Title2))

for ($k = 0; $k -lt $items.Count; $k++) {
    $it = $items[$k]
    if ($it.kind -eq "img") {
        # 정지 화면 (zoompan 없음 -> 계단 현상/떨림 없음, 최고 선명도)
        $G.Add(("[{0}:v]fps={1},split[a{0}][b{0}]" -f $k, $FPS))
        $G.Add(("[a{0}]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,boxblur=24:2[bg{0}]" -f $k))
        $G.Add(("[b{0}]scale=1920:1080:force_original_aspect_ratio=decrease[fg{0}]" -f $k))
        $G.Add((("[bg{0}][fg{0}]overlay=(W-w)/2:(H-h)/2,trim=0:{1},setpts=PTS-STARTPTS," +
            "format=yuv420p,setsar=1[v{0}]") -f $k, $it.dur))
    } else {
        $G.Add(("[{0}:v]trim=0:{1},setpts=PTS-STARTPTS,fps={2},split[a{0}][b{0}]" -f $k, $it.dur, $FPS))
        $G.Add(("[a{0}]scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,boxblur=24:2[bg{0}]" -f $k))
        $G.Add(("[b{0}]scale=1920:1080:force_original_aspect_ratio=decrease[fg{0}]" -f $k))
        $srt = [System.IO.Path]::ChangeExtension($it.path, ".srt")
        if (Test-Path -LiteralPath $srt) {
            $srtF = (($srt -replace '\\','/') -replace ':','\:')
            $G.Add((("[bg{0}][fg{0}]overlay=(W-w)/2:(H-h)/2," +
                "subtitles=filename='{1}':charenc=UTF-8:" +
                "force_style='FontName=Malgun Gothic,FontSize=19,PrimaryColour=&H00FFFFFF," +
                "OutlineColour=&H80000000,Outline=2,Shadow=1,MarginV=46'," +
                "format=yuv420p,setsar=1[v{0}]") -f $k, $srtF))
            Write-Host ("        + subtitles: {0}" -f (Split-Path $srt -Leaf)) -ForegroundColor Cyan
        } else {
            $G.Add(("[bg{0}][fg{0}]overlay=(W-w)/2:(H-h)/2,format=yuv420p,setsar=1[v{0}]" -f $k))
        }
    }
}

$G.Add((("color=c=0x0d0b09:s=1920x1080:r={0}:d={1}," +
    "drawtext=fontfile='{2}':text='{3}':fontsize=96:fontcolor=0xc8ab6e:x=(w-text_w)/2:y=(h-text_h)/2-36," +
    "drawtext=fontfile='{2}':text='{4}':fontsize=34:fontcolor=0x9b8a6a:x=(w-text_w)/2:y=(h)/2+66," +
    "format=yuv420p,setsar=1[vcard1]") -f $FPS, $OUTRO, $fontF, $Outro, $Outro2))

$segs = @("[vin]") + (0..($items.Count-1) | ForEach-Object { "[v$_]" }) + @("[vcard1]")
$offsets = @(); $cur = 0.0
for ($j = 0; $j -lt $nSeg - 1; $j++) { $cur += $durs[$j] - $Fade; $offsets += [math]::Round($cur, 3) }
$prev = $segs[0]
for ($j = 1; $j -lt $segs.Count; $j++) {
    $outLbl = if ($j -lt $segs.Count - 1) { "[x$j]" } else { "[vfinal]" }
    $G.Add((("{0}{1}xfade=transition=fade:duration={2}:offset={3}{4}" -f `
        $prev, $segs[$j], $Fade, $offsets[$j-1], $outLbl)))
    $prev = $outLbl
}

# ── audio: music with ducking under clips, clip audio mixed in ──
$T  = [math]::Round($total, 3)
$Tf = [math]::Round($total - 3, 3)
$mi = $items.Count                       # music input index
$win = @()                                # video windows on the final timeline
for ($k = 0; $k -lt $items.Count; $k++) {
    if ($items[$k].kind -eq "vid") {
        $a = $offsets[$k]                # transition into segment k starts here
        $win += @{ k=$k; a=$a; b=[math]::Round($a + $items[$k].dur, 3); hasA=$items[$k].hasA; d=$items[$k].dur }
    }
}
$haveMusic = $Music -and (Test-Path -LiteralPath $Music)
if ($haveMusic) {
    $duck = if ($win.Count) { (@($win | ForEach-Object { "between(t\,$($_.a)\,$($_.b))" }) -join "+") } else { "0" }
    $G.Add((("[{0}:a]atrim=0:{1},afade=t=in:st=0:d=1.2,afade=t=out:st={2}:d=3," +
        "volume=eval=frame:volume='if({3}\,0.12\,1)'[mus]") -f $mi, $T, $Tf, $duck))
    $mixIn = @("[mus]")
} else {
    Write-Host "no music given - clips' own audio only" -ForegroundColor Yellow
    $G.Add("anullsrc=r=44100:cl=stereo,atrim=0:$T[mus]")
    $mixIn = @("[mus]")
}
foreach ($w in $win) {
    if ($w.hasA) {
        $ms = [int]($w.a * 1000)
        $G.Add((("[{0}:a]atrim=0:{1},afade=t=in:st=0:d=0.3,afade=t=out:st={2}:d=0.4," +
            "adelay={3}|{3},apad=whole_dur={4}[iva{0}]") -f $w.k, $w.d, [math]::Round($w.d-0.4,3), $ms, $T))
        $mixIn += "[iva$($w.k)]"
    }
}
if ($mixIn.Count -gt 1) {
    $G.Add(($mixIn -join "") + "amix=inputs=$($mixIn.Count):normalize=0,atrim=0:$T,asetpts=PTS-STARTPTS[afinal]")
} else {
    $G.Add("[mus]asetpts=PTS-STARTPTS[afinal]")
}

$graph = Join-Path $env:TEMP "hctp-highlight-graph.txt"
($G -join ";`n") | Set-Content -LiteralPath $graph -Encoding ASCII

$ffArgs = @("-y","-stats","-v","error")
foreach ($it in $items) {
    if ($it.kind -eq "img") { $ffArgs += @("-loop","1","-t",[string]$it.dur,"-i",$it.path) }
    else                    { $ffArgs += @("-i", $it.path) }
}
if ($haveMusic) { $ffArgs += @("-i", (Resolve-Path $Music).Path) }
else            { $ffArgs += @("-f","lavfi","-t","1","-i","anullsrc") }   # placeholder to keep index math
$ffArgs += @("-filter_complex_script", $graph,
    "-map","[vfinal]","-map","[afinal]",
    "-c:v","libx264","-preset","medium","-crf","18",
    "-c:a","aac","-b:a","192k","-movflags","+faststart",
    $Out)

Write-Host "rendering... (a few minutes)" -ForegroundColor Cyan
& ffmpeg @ffArgs
if ($LASTEXITCODE -ne 0) { Write-Warning "ffmpeg failed - see messages above"; exit 1 }

$mb = [math]::Round((Get-Item $Out).Length / 1MB, 1)
Write-Host ""
Write-Host ("Done!  {0}  ({1} MB, ~{2:N0}s, 1080p)" -f $Out, $mb, $total) -ForegroundColor Green
