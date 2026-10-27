<#
.SYNOPSIS
  diskhound - sniff out what's eating your disk, then clear it one item at a time.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\diskhound.ps1
  powershell -ExecutionPolicy Bypass -File .\diskhound.ps1 -DryRun -Top 30
#>
[CmdletBinding()]
param(
  [string]$Path = $env:USERPROFILE,
  [int]$Top = 20,
  [int]$MinMB = 100,
  [switch]$DryRun
)

$ErrorActionPreference = 'SilentlyContinue'
$Root = $Path.TrimEnd('\')
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
  Write-Host "Not a directory: $Path" -ForegroundColor Red
  exit 1
}

# ---------- helpers ----------
function Format-Size([long]$b) {
  if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
  if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
  return ('{0:N0} KB' -f ($b / 1KB))
}

function Get-Size([string]$p) {
  $item = Get-Item -LiteralPath $p -Force
  if (-not $item) { return 0 }
  if (-not $item.PSIsContainer) { return [long]$item.Length }
  $sum = (Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue |
          Measure-Object Length -Sum).Sum
  if ($sum) { return [long]$sum } else { return 0 }
}

# Walks the tree without descending into matches (so nested node_modules are skipped)
function Find-Dirs([string]$start, [string]$name) {
  $stack = New-Object 'System.Collections.Generic.Stack[string]'
  $stack.Push($start)
  while ($stack.Count -gt 0) {
    $d = $stack.Pop()
    try { $subs = [System.IO.Directory]::GetDirectories($d) } catch { continue }
    foreach ($s in $subs) {
      $attr = [System.IO.File]::GetAttributes($s)
      if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { continue }
      if ((Split-Path $s -Leaf) -eq $name) { $s } else { $stack.Push($s) }
    }
  }
}

function Test-Safe([string]$p) {
  return $p.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase)
}

$cands = New-Object System.Collections.ArrayList
function Add-Cand([string]$p, [string]$label, [bool]$contents = $false) {
  if (-not (Test-Path -LiteralPath $p)) { return }
  $b = Get-Size $p
  if ($b -ge 10MB) {
    [void]$cands.Add([pscustomobject]@{
      Path     = (Resolve-Path -LiteralPath $p).ProviderPath
      Bytes    = [long]$b
      Label    = $label
      Contents = $contents
    })
  }
}

function Ask-Run([string]$desc, [scriptblock]$action) {
  Write-Host ""
  Write-Host "   $desc"
  Write-Host "   > $action" -ForegroundColor DarkGray
  $yn = Read-Host "   Run it? [y/N]"
  if ($yn -match '^[yY]') {
    if ($DryRun) { Write-Host "   (dry run) skipped" -ForegroundColor Yellow }
    else { & $action }
  }
}

# ---------- banner ----------
Write-Host ""
Write-Host "  diskhound  -  find what's eating your disk" -ForegroundColor Cyan
$mode = if ($DryRun) { 'dry-run' } else { 'live' }
Write-Host "  scanning: $Root   mode: $mode" -ForegroundColor DarkGray

# ---------- 1. disk overview ----------
Write-Host ""
Write-Host "1. Disk overview" -ForegroundColor White
$drive = (Get-Item -LiteralPath $Root).PSDrive
if ($drive -and $null -ne $drive.Used) {
  $total = $drive.Used + $drive.Free
  Write-Host ("   Total {0}   Used {1}   Free {2}" -f (Format-Size $total), (Format-Size $drive.Used), (Format-Size $drive.Free))
}

# ---------- 2. where the space lives ----------
Write-Host ""
Write-Host "2. Biggest folders in $Root (this can take a few minutes)" -ForegroundColor White
$rows = Get-ChildItem -LiteralPath $Root -Force |
  Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
  ForEach-Object { [pscustomobject]@{ Name = $_.Name; Bytes = (Get-Size $_.FullName) } } |
  Sort-Object Bytes -Descending | Select-Object -First 10
$max = ($rows | Select-Object -First 1).Bytes
foreach ($r in $rows) {
  $n = if ($max -gt 0) { [int](24 * $r.Bytes / $max) } else { 0 }
  $nm = if ($r.Name.Length -gt 28) { $r.Name.Substring(0, 28) } else { $r.Name }
  Write-Host ("   {0,-28} {1,9}  {2}" -f $nm, (Format-Size $r.Bytes), ('#' * $n))
}

# ---------- 3. hunt for the top offenders ----------
Write-Host ""
Write-Host "3. Hunting for the top $Top space hogs..." -ForegroundColor White

if ($Root -ieq $env:USERPROFILE.TrimEnd('\')) {
  Add-Cand "$env:LOCALAPPDATA\npm-cache"                              'npm cache'
  Add-Cand "$env:LOCALAPPDATA\Temp"                                   'Temp files' $true
  Add-Cand "$env:LOCALAPPDATA\pip\Cache"                              'pip cache'
  Add-Cand "$env:LOCALAPPDATA\Yarn\Cache"                             'Yarn cache'
  Add-Cand "$env:LOCALAPPDATA\CrashDumps"                             'Crash dumps'
  Add-Cand "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"            'Internet cache'
  Add-Cand "$env:USERPROFILE\.gradle\caches"                          'Gradle cache'
  Add-Cand "$env:USERPROFILE\.m2\repository"                          'Maven repository'
  Add-Cand "$env:USERPROFILE\.android\cache"                          'Android cache'
  Get-ChildItem "$env:USERPROFILE\.android\avd\*\snapshots" -Directory -Force |
    ForEach-Object { Add-Cand $_.FullName 'Android emulator snapshots' }
}

Find-Dirs $Root 'node_modules' | ForEach-Object { Add-Cand $_ 'node_modules' }

$minBytes = [long]$MinMB * 1MB
Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Length -gt $minBytes -and $_.FullName -notmatch '\\node_modules\\' } |
  ForEach-Object {
    [void]$cands.Add([pscustomobject]@{
      Path = $_.FullName; Bytes = [long]$_.Length; Label = 'large file'; Contents = $false
    })
  }

$topList = @($cands | Sort-Object Bytes -Descending |
  Group-Object Path | ForEach-Object { $_.Group[0] } |
  Sort-Object Bytes -Descending | Select-Object -First $Top)

if ($topList.Count -eq 0) {
  Write-Host "   Nothing big found. Your disk is looking healthy."
  exit 0
}

Write-Host ""
Write-Host "   Top space hogs" -ForegroundColor White
$i = 0; $sum = 0L
foreach ($t in $topList) {
  $i++; $sum += $t.Bytes
  $shown = $t.Path.Replace($env:USERPROFILE, '~')
  Write-Host ("   {0,2}. {1,9}  {2,-26} {3}" -f $i, (Format-Size $t.Bytes), $t.Label, $shown)
}
Write-Host ""
Write-Host "   Potentially reclaimable: $(Format-Size $sum)"

# ---------- 4. clear them one by one ----------
Write-Host ""
Write-Host "4. Clean up one by one (nothing is deleted without your confirmation)" -ForegroundColor White
$freed = 0L
$quit = $false
$idx = 0
foreach ($t in $topList) {
  $idx++
  $p = $t.Path
  if (-not (Test-Path -LiteralPath $p)) { continue }
  Write-Host ""
  Write-Host "[$idx/$($topList.Count)] $p" -ForegroundColor White
  Write-Host ("   {0}  ({1})" -f (Format-Size $t.Bytes), $t.Label) -ForegroundColor DarkGray
  if ($p -match '\.(vhdx|vmdk|vdi|qcow2)$') {
    Write-Host "   Warning: looks like a virtual machine or WSL disk. Deleting it destroys that VM/distro." -ForegroundColor Yellow
  }
  while ($true) {
    $ans = (Read-Host "   [d]elete  [o]pen location  [s]kip  [q]uit").Trim().ToLower()
    if ($ans -eq 'd') {
      if (-not (Test-Safe $p)) {
        Write-Host "   Refused: path is outside the scan root." -ForegroundColor Red
        continue
      }
      $yn = Read-Host "   Permanently delete this? [y/N]"
      if ($yn -match '^[yY]') {
        if ($DryRun) {
          Write-Host "   (dry run) would delete, freeing $(Format-Size $t.Bytes)" -ForegroundColor Yellow
        } else {
          try {
            if ($t.Contents) {
              Get-ChildItem -LiteralPath $p -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            } else {
              Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            }
          } catch {
            Write-Host "   Could not fully delete (permissions or in use)." -ForegroundColor Red
          }
          $after = if (Test-Path -LiteralPath $p) { Get-Size $p } else { 0 }
          $got = [Math]::Max(0, $t.Bytes - $after)
          $freed += $got
          Write-Host "   Freed $(Format-Size $got)." -ForegroundColor Green
        }
        break
      } else {
        Write-Host "   Kept."
      }
    }
    elseif ($ans -eq 'o') { explorer.exe "/select,`"$p`"" }
    elseif ($ans -eq 's' -or $ans -eq '') { Write-Host "   Skipped."; break }
    elseif ($ans -eq 'q') { $quit = $true; break }
    else { Write-Host "   Pick d, o, s or q." }
  }
  if ($quit) { break }
}

# ---------- 5. optional system-level cleanups ----------
Write-Host ""
Write-Host "5. Optional package and system cleanups" -ForegroundColor White
if (Get-Command docker -ErrorAction SilentlyContinue) {
  docker system df
  Ask-Run 'Remove unused Docker images, containers and build cache' { docker system prune -a }
}
if (Get-Command npm -ErrorAction SilentlyContinue) {
  Ask-Run 'Clear the npm cache' { npm cache clean --force }
}
Ask-Run 'Open Windows Disk Cleanup (system files, old updates)' { cleanmgr.exe }

Write-Host ""
Write-Host "Done. Freed about $(Format-Size $freed) in this run." -ForegroundColor Green
