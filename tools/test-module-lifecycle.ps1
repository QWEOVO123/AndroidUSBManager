$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$bash = 'C:\Program Files\Git\bin\bash.exe'
foreach ($name in @('service.sh','customize.sh','uninstall.sh')) {
    & $bash -n (Join-Path $project "rootmodule/$name")
    if ($LASTEXITCODE -ne 0) { throw "Syntax failed: $name" }
}
# Execute the actual uninstall control flow with every external mutation mocked.
# No Android device is contacted and no module/APP/file is removed.
$source = (Get-Content -Raw (Join-Path $project 'rootmodule/uninstall.sh')).Replace("`r", '')
$source = $source.Replace('/system/bin/svc', 'mock_svc').Replace('/system/bin/reboot', 'mock_reboot')
$source = $source.Replace('[ -d /data/adb/usbmanager-auth/session ] && [ -f "$MODULE/usb_auth_root.sh" ]', '[ "$RESTORE_TEST" = 1 ]')
$mocks = @'
id() { echo 0; }
readlink() { if [ "$BAD_PATH" = 1 ]; then echo /wrong/path; else echo "$2"; fi; }
sleep() { :; }
cat() { return 1; }
am() { echo "MOCK am $*"; }
pm() { if [ "$1" = list ]; then echo package:com.tiger.usbmanager; else echo "MOCK pm $*"; [ "$FAIL_PM" != 1 ]; fi; }
settings() { echo "MOCK settings $*"; }
setprop() { echo "MOCK setprop $*"; }
mock_svc() { echo "MOCK svc $*"; }
mock_reboot() { echo 'MOCK reboot'; }
touch() { echo "MOCK touch $*"; }
rm() { echo "MOCK rm $*"; }
sync() { echo 'MOCK sync'; }
nohup() { echo 'MOCK nohup'; }
getprop() { echo arm64-v8a; }
sh() { echo 'MOCK old-profile restore failed'; return 1; }
'@
function Run-Mock([string]$mode, [string]$failPm, [string]$badPath, [string]$restoreTest = '0') {
    $start = [Diagnostics.ProcessStartInfo]::new($bash)
    $start.ArgumentList.Add('-s')
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $process.StandardInput.WriteLine("FAIL_PM=$failPm; BAD_PATH=$badPath; RESTORE_TEST=$restoreTest; set -- $mode")
    $process.StandardInput.WriteLine($mocks)
    $process.StandardInput.WriteLine($source)
    $process.StandardInput.Close()
    $output = $process.StandardOutput.ReadToEnd()
    $errorOutput = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $result = @{ Code=$process.ExitCode; Output=$output; Error=$errorOutput }
    $process.Dispose()
    return $result
}
$ok = Run-Mock '--app' '0' '0'
if ($ok.Code -ne 0 -or $ok.Output -notmatch 'MOCK reboot' -or $ok.Output -notmatch 'MOCK rm -rf /data/adb/modules/usbmanager_root') { throw "App flow failed: $($ok.Output) $($ok.Error)" }
if ($ok.Output.IndexOf('MOCK pm uninstall') -gt $ok.Output.IndexOf('MOCK svc usb setScreenUnlockedFunctions') -or $ok.Output.IndexOf('MOCK rm -rf') -gt $ok.Output.IndexOf('MOCK reboot')) { throw 'Wrong cleanup ordering' }
Write-Host 'PASS in-app uninstall -> reset USB defaults -> remove exact module -> reboot (mocked)'
$manager = Run-Mock '' '0' '0'
if ($manager.Code -ne 0 -or $manager.Output -match 'MOCK reboot|MOCK rm -rf') { throw 'Manager hook must not remove itself or reboot' }
Write-Host 'PASS manager hook does not reboot or self-delete'
$failed = Run-Mock '--app' '1' '0'
if ($failed.Code -ne 3 -or $failed.Output -match 'MOCK reboot|MOCK rm -rf') { throw 'Uninstall failure safety failed' }
Write-Host 'PASS package uninstall failure preserves module and prevents reboot'
$bad = Run-Mock '--app' '0' '1'
if ($bad.Code -ne 2 -or $bad.Output -match 'MOCK pm uninstall|MOCK rm|MOCK reboot') { throw 'Path guard failed' }
Write-Host 'PASS wrong resolved module path rejected before mutations'
$restoreFailed = Run-Mock '--app' '0' '0' '1'
if ($restoreFailed.Code -ne 0 -or $restoreFailed.Output -notmatch 'MOCK old-profile restore failed' -or $restoreFailed.Output -notmatch 'MOCK reboot') { throw 'Old profile restore failure incorrectly blocked removal' }
Write-Host 'PASS failed old USB profile restore does not block charging-reset/removal flow (mocked)'
$authSource = Get-Content -Raw (Join-Path $project 'app/src/main/assets/usb_auth_root.sh')
foreach ($probe in @('generic_probe','nothing_probe')) {
    $body = [regex]::Match($authSource, "(?ms)^$probe\(\) \{(.*?)^\}").Groups[1].Value
    if (-not $body -or $body -match '\b(rm|mount|umount|save_state|generic_prepare|daemon_start|restore|kill|setprop)\s') { throw "Mutating capability probe: $probe" }
}
Write-Host 'PASS detection probes do not mutate USB or recovery-session state (source contract)'
