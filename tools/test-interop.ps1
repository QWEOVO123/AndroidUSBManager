$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$classes = Join-Path $project 'build\interop-classes'
New-Item -ItemType Directory -Path $classes -Force | Out-Null
& javac -encoding UTF-8 -d $classes (Join-Path $project 'app\src\main\java\com\tiger\usbmanager\auth\UsbAuthDaemon.java') (Join-Path $PSScriptRoot 'interop\PhoneHarness.java')
if ($LASTEXITCODE -ne 0) { throw 'Java compile failed' }
& java -cp $classes PhoneHarness descriptors
if ($LASTEXITCODE -ne 0) { throw 'Descriptor regression test failed' }
& dotnet run --project (Join-Path $PSScriptRoot 'interop\Interop.csproj') -- $classes
if ($LASTEXITCODE -ne 0) { throw 'Cross-language protocol tests failed' }
