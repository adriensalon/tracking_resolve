$ErrorActionPreference = 'Stop'

$effectsDirectory = Join-Path $env:APPDATA 'Blackmagic Design\DaVinci Resolve\Support\Fusion\Templates\Edit\Effects'
$trackingDirectory = Join-Path $env:LOCALAPPDATA 'TrackingResolve'
$files = [ordered]@{
    'PointTracking.lua' = Join-Path $trackingDirectory 'PointTracking.lua'
    'TrackPoint.lua' = Join-Path $trackingDirectory 'TrackPoint.lua'
    'TrackingPoint.setting' = Join-Path $effectsDirectory 'Tracking Point.setting'
}

foreach ($name in $files.Keys) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) {
        throw "$name must be next to this installer."
    }
}

New-Item -ItemType Directory -Path $effectsDirectory, $trackingDirectory -Force | Out-Null
foreach ($name in $files.Keys) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $files[$name] -Force
}

Write-Host 'Installed Tracking Point. Restart Resolve to refresh the Effects Library.'
