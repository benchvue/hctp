# ============================================================
#  convert-day-webp.ps1
#  For a Drive day folder: every basename that has a .jpg but
#  NO matching .webp gets converted and uploaded as .webp.
#
#  Usage:
#     .\convert-day-webp.ps1 -Day day1
#     .\convert-day-webp.ps1 -Day day3 -Token "ya29...."
#
#  Token: open upload.html, sign in, press F12 -> Console,
#         type   accessToken   and copy the printed string.
#         (Valid ~1 hour; rerun sign-in for a fresh one.)
#
#  - existing basename.webp        -> skip
#  - two same-named jpg (resized + original) -> smaller one is used
#  - big jpg is resized to max 1600px during conversion
#  - uploaded webp is made link-public for the viewer
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("day1","day2","day3","day4","day5","group")]
    [string]$Day,

    [string]$Root  = "1EXAxxpZ0QQ_6GShM9pTruQYzCQP5bVLU",   # Drive "2026" folder id
    [string]$Token = "",
    [int]$Quality  = 82,
    [int]$MaxDim   = 1600
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

if (-not $Token) {
    $Token = Read-Host "Paste OAuth access token (upload.html -> F12 console -> type: accessToken)"
}
$H = @{ Authorization = "Bearer $Token" }

function DriveList([string]$q) {
    $u = "https://www.googleapis.com/drive/v3/files?q=" + [uri]::EscapeDataString($q) +
         "&fields=" + [uri]::EscapeDataString("files(id,name,size,mimeType)") + "&pageSize=1000"
    (Invoke-RestMethod -Uri $u -Headers $H).files
}

# ── locate cwebp.exe (download libwebp automatically if missing) ──
$here  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$cwebp = Get-Command cwebp -ErrorAction SilentlyContinue
if ($cwebp) { $cwebp = $cwebp.Source }
else {
    $cwebp = Get-ChildItem -Path $here -Recurse -Filter cwebp.exe -ErrorAction SilentlyContinue |
             Select-Object -First 1 -ExpandProperty FullName
}
if (-not $cwebp) {
    Write-Host "cwebp.exe not found - downloading libwebp ..." -ForegroundColor Yellow
    $zip = Join-Path $here "libwebp.zip"
    Invoke-WebRequest "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0-windows-x64.zip" -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $here -Force
    Remove-Item $zip
    $cwebp = Get-ChildItem -Path $here -Recurse -Filter cwebp.exe | Select-Object -First 1 -ExpandProperty FullName
    if (-not $cwebp) { Write-Warning "could not obtain cwebp.exe"; exit 1 }
}
Write-Host "cwebp : $cwebp"

# ── resolve day folder ──
$folder = DriveList "'$Root' in parents and name='$Day' and mimeType='application/vnd.google-apps.folder' and trashed=false"
if (-not $folder) { Write-Warning "folder '$Day' not found under root $Root"; exit 1 }
$fid = $folder[0].id
Write-Host "folder: $Day  ($fid)"

# ── inventory ──
$files = @(DriveList "'$fid' in parents and trashed=false")
$webpBase = @{}
$files | Where-Object { $_.name -match '\.webp$' } | ForEach-Object {
    $webpBase[($_.name -replace '\.webp$','').ToLower()] = $true
}
$jpgGroups = $files | Where-Object { $_.name -match '\.jpe?g$' } |
    Group-Object { ($_.name -replace '\.jpe?g$','').ToLower() }

$tmp = Join-Path $env:TEMP ("hctp-webp-" + (Get-Random))
New-Item -ItemType Directory -Path $tmp | Out-Null

$made = 0; $skipped = 0; $failed = 0
foreach ($g in $jpgGroups) {
    $base = $g.Name
    if ($webpBase.ContainsKey($base)) {
        Write-Host ("  skip  {0}  (.webp exists)" -f $base) -ForegroundColor DarkGray
        $skipped++
        continue
    }
    # smaller file = the resized upload; original is the big one
    $src = $g.Group | Sort-Object { [long]($_.size) } | Select-Object -First 1
    $jpgPath  = Join-Path $tmp ($base + ".jpg")
    $webpPath = Join-Path $tmp ($base + ".webp")
    try {
        Write-Host ("  conv  {0}  (src {1:N0} KB)" -f $src.name, ([long]$src.size/1KB))
        Invoke-WebRequest -Uri ("https://www.googleapis.com/drive/v3/files/$($src.id)?alt=media") `
            -Headers $H -OutFile $jpgPath

        # resize only when the source is larger than MaxDim
        $img = [System.Drawing.Image]::FromFile($jpgPath)
        $needResize = ($img.Width -gt $MaxDim -or $img.Height -gt $MaxDim)
        $img.Dispose()
        $args = @("-quiet","-q","$Quality")
        if ($needResize) {
            $args += @("-resize", ($(if ($img.Width -ge $img.Height) { "$MaxDim 0" } else { "0 $MaxDim" }) -split ' '))
        }
        & $cwebp @args $jpgPath -o $webpPath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $webpPath)) { throw "cwebp failed" }

        # multipart upload as base.webp
        $name  = $base + ".webp"
        $bound = "hctp" + (Get-Random)
        $meta  = '{"name":"' + $name + '","parents":["' + $fid + '"]}'
        $nl    = "`r`n"
        $head  = "--$bound$nl" + "Content-Type: application/json; charset=UTF-8$nl$nl" + $meta + $nl +
                 "--$bound$nl" + "Content-Type: image/webp$nl$nl"
        $tail  = "$nl--$bound--$nl"
        $enc   = [System.Text.Encoding]::ASCII
        $bytes = New-Object System.IO.MemoryStream
        $b1 = $enc.GetBytes($head); $bytes.Write($b1,0,$b1.Length)
        $b2 = [System.IO.File]::ReadAllBytes($webpPath); $bytes.Write($b2,0,$b2.Length)
        $b3 = $enc.GetBytes($tail); $bytes.Write($b3,0,$b3.Length)

        $up = Invoke-RestMethod -Method Post `
            -Uri "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id" `
            -Headers $H -ContentType "multipart/related; boundary=$bound" `
            -Body $bytes.ToArray()

        # make it link-public so the viewer (API key) can see it
        try {
            Invoke-RestMethod -Method Post `
                -Uri "https://www.googleapis.com/drive/v3/files/$($up.id)/permissions" `
                -Headers $H -ContentType "application/json" `
                -Body '{"role":"reader","type":"anyone"}' | Out-Null
        } catch { }

        Write-Host ("  done  {0}" -f $name) -ForegroundColor Green
        $made++
    }
    catch {
        Write-Warning ("  FAIL  {0} : {1}" -f $base, $_.Exception.Message)
        $failed++
    }
    finally {
        Remove-Item $jpgPath, $webpPath -ErrorAction SilentlyContinue
    }
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host ""
Write-Host ("{0}: converted {1}, skipped {2}, failed {3}" -f $Day, $made, $skipped, $failed) -ForegroundColor Cyan
if ($made -gt 0) { Write-Host "Viewer will show them on next refresh (no publish needed)." }
