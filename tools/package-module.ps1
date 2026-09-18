param(
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
if (-not $SkipBuild) {
    & (Join-Path $project 'gradlew.bat') ':app:assembleDebug'
    if ($LASTEXITCODE -ne 0) { throw 'Gradle debug build failed' }
}

$apk = Join-Path $project 'app\build\outputs\apk\debug\app-debug.apk'
if (-not (Test-Path -LiteralPath $apk)) { throw "Debug APK not found: $apk" }

$outputDir = Join-Path $project 'dist'
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('usbmanager-module-' + [guid]::NewGuid().ToString('N'))
$expandedApk = Join-Path ([System.IO.Path]::GetTempPath()) ('usbmanager-apk-' + [guid]::NewGuid().ToString('N'))
$output = Join-Path $outputDir 'USBManager-Root-v6.2.1-lite.zip'

try {
    New-Item -ItemType Directory -Path $staging, $expandedApk, $outputDir -Force | Out-Null
    Copy-Item -Path (Join-Path $project 'rootmodule\*') -Destination $staging -Recurse -Force
    Copy-Item -LiteralPath $apk -Destination (Join-Path $staging 'usbmanager.apk')
    Copy-Item -LiteralPath (Join-Path $project 'LICENSE') -Destination (Join-Path $staging 'LICENSE')
    Copy-Item -LiteralPath (Join-Path $project 'app\src\main\assets\usb_auth_root.sh') -Destination (Join-Path $staging 'usb_auth_root.sh')

    $apkZip = Join-Path $expandedApk 'payload.zip'
    Copy-Item -LiteralPath $apk -Destination $apkZip
    Expand-Archive -LiteralPath $apkZip -DestinationPath (Join-Path $expandedApk 'payload') -Force
    $expandedPayload = Join-Path $expandedApk 'payload'
    $apkLib = Join-Path $expandedPayload 'lib'
    if (-not (Test-Path -LiteralPath $apkLib)) { throw 'Native libraries are missing from the APK' }
    Copy-Item -LiteralPath $apkLib -Destination (Join-Path $staging 'lib') -Recurse -Force

    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [System.IO.File]::Open($output, [System.IO.FileMode]::CreateNew)
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        try {
            Get-ChildItem -LiteralPath $staging -File -Recurse | ForEach-Object {
                $relative = $_.FullName.Substring($staging.Length).TrimStart('\', '/').Replace('\', '/')
                $entry = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive,
                    $_.FullName,
                    $relative,
                    [System.IO.Compression.CompressionLevel]::Optimal
                )
                $isExecutable = $_.Extension -eq '.sh' -or $_.Name -eq 'update-binary'
                $mode = if ($isExecutable) { [Convert]::ToInt32('100755', 8) } else { [Convert]::ToInt32('100644', 8) }
                $entry.ExternalAttributes = $mode -shl 16
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
    Write-Host "Created $output"
}
finally {
    $safeTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    foreach ($taskTemp in @($staging, $expandedApk)) {
        $resolvedTemp = [IO.Path]::GetFullPath($taskTemp)
        if (-not $resolvedTemp.StartsWith($safeTempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $resolvedTemp) -notmatch '^usbmanager-(module|apk)-[0-9a-f]{32}$') {
            throw "Refusing cleanup of unexpected path: $resolvedTemp"
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
