# ============================================================
#  move-day-photos.ps1
#  Move one teacher's photos from one day folder to another,
#  renumbering into the target day's next free numbers and
#  fixing the db records so quotas/grids stay correct.
#
#  Usage:
#     .\move-day-photos.ps1 -First henry -From day4 -To day3
#     .\move-day-photos.ps1 -First henry -From day4 -To day3 -Token "ya29..."
#
#  Token: upload.html -> sign in -> F12 console -> type  accessToken
# ============================================================

param(
    [Parameter(Mandatory=$true)][string]$First,           # teacher file prefix, e.g. henry
    [Parameter(Mandatory=$true)][ValidateSet("day1","day2","day3","day4","day5")][string]$From,
    [Parameter(Mandatory=$true)][ValidateSet("day1","day2","day3","day4","day5")][string]$To,
    [string]$Root  = "1EXAxxpZ0QQ_6GShM9pTruQYzCQP5bVLU",
    [string]$Token = ""
)

$ErrorActionPreference = "Stop"
if ($From -eq $To) { Write-Warning "From and To are the same"; exit 1 }
if (-not $Token) { $Token = Read-Host "Paste OAuth access token" }
$H = @{ Authorization = "Bearer $Token" }

function DriveList([string]$q) {
    $u = "https://www.googleapis.com/drive/v3/files?q=" + [uri]::EscapeDataString($q) +
         "&fields=" + [uri]::EscapeDataString("files(id,name)") + "&pageSize=1000"
    (Invoke-RestMethod -Uri $u -Headers $H).files
}
function FolderId([string]$name) {
    $f = DriveList "'$Root' in parents and name='$name' and mimeType='application/vnd.google-apps.folder' and trashed=false"
    if (-not $f) { throw "folder '$name' not found" }
    $f[0].id
}

$fromId = FolderId $From
$toId   = FolderId $To
$dbId   = FolderId "db"

# ── next free number in target day (across webp + jpg) ──
$toFiles = @(DriveList "'$toId' in parents and trashed=false")
$maxN = 0
$toFiles | Where-Object { $_.name -match "^$First-(\d+)\." } | ForEach-Object {
    $n = [int][regex]::Match($_.name, "^$First-(\d+)\.").Groups[1].Value
    if ($n -gt $maxN) { $maxN = $n }
}
Write-Host ("target {0}: next number starts at {1}" -f $To, ($maxN + 1))

# ── collect source files grouped by number ──
$fromFiles = @(DriveList "'$fromId' in parents and trashed=false") |
    Where-Object { $_.name -match "^$First-(\d+)\.(webp|jpe?g|png)$" }
if (-not $fromFiles) { Write-Warning "no '$First-N.*' files in $From"; exit 0 }

$groups = $fromFiles | Group-Object {
    [int][regex]::Match($_.name, "^$First-(\d+)\.").Groups[1].Value
} | Sort-Object { [int]$_.Name }

Write-Host ("moving {0} photo group(s) ({1} file(s)) {2} -> {3}" -f `
    $groups.Count, $fromFiles.Count, $From, $To)

$idMap = @{}   # fileId -> @{ name = newName }
foreach ($g in $groups) {
    $maxN++
    foreach ($f in $g.Group) {
        $ext = [regex]::Match($f.name, "\.([^.]+)$").Groups[1].Value
        $newName = "$First-$maxN.$ext"
        $u = "https://www.googleapis.com/drive/v3/files/$($f.id)" +
             "?addParents=$toId&removeParents=$fromId&fields=id"
        Invoke-RestMethod -Method Patch -Uri $u -Headers $H `
            -ContentType "application/json" `
            -Body ('{"name":"' + $newName + '"}') | Out-Null
        $idMap[$f.id] = $newName
        Write-Host ("  {0}  ->  {1}/{2}" -f $f.name, $To, $newName) -ForegroundColor Green
    }
}

# ── fix db records (folder / name / origName) ──
$dbFile = DriveList "'$dbId' in parents and name='hctp-2026-db.json' and trashed=false"
if ($dbFile) {
    $dbf = $dbFile[0].id
    $dbj = Invoke-RestMethod -Uri "https://www.googleapis.com/drive/v3/files/$dbf`?alt=media" -Headers $H
    $fixed = 0
    foreach ($u in $dbj.uploads) {
        if ($idMap.ContainsKey($u.fileId)) {
            $u.folder = $To
            $u.name   = $idMap[$u.fileId]
            $fixed++
        }
        if ($u.origId -and $idMap.ContainsKey($u.origId)) {
            $u.origName = $idMap[$u.origId]
        }
    }
    $body = $dbj | ConvertTo-Json -Depth 6 -Compress
    Invoke-RestMethod -Method Patch `
        -Uri "https://www.googleapis.com/upload/drive/v3/files/$dbf`?uploadType=media" `
        -Headers $H -ContentType "application/json" -Body $body | Out-Null
    Write-Host ("db updated: {0} record(s) re-pointed to {1}" -f $fixed, $To) -ForegroundColor Cyan
} else {
    Write-Warning "hctp-2026-db.json not found - files moved, but counts may self-heal on next upload.html load"
}

Write-Host ""
Write-Host "Done. Viewer shows the change on next refresh (no publish needed)." -ForegroundColor Green
