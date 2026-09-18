$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$source = Get-Content -Raw (Join-Path $project 'rootmodule/service.sh')
$body = [regex]::Match($source, '(?ms)^run_host_edit_job\(\) \{.*?^\}').Value.Replace("`r", '')
if (-not $body) { throw 'Production edit function missing' }
$harness = @'
native_library() { echo mock-lib; }
sh() { echo UPDATED; }
log_msg() { :; }
write_response() { echo "RESPONSE $*"; }
physical_usb_online() { [ "$ONLINE" = 1 ]; }
apply_usb_config() { echo "APPLY $*"; [ "$APPLY_FAIL" != 1 ]; }
CURRENT_HOST_ID=host-a
ONLINE=1
APPLY_FAIL=0
run_host_edit_job request-a host-a label mtp 1
run_host_edit_job request-b host-b label ptp 0
APPLY_FAIL=1
run_host_edit_job request-c host-a label rndis 0
ONLINE=0
run_host_edit_job request-d host-a label mtp 0
'@
$start = [Diagnostics.ProcessStartInfo]::new('C:\Program Files\Git\bin\bash.exe')
$start.ArgumentList.Add('-s'); $start.UseShellExecute=$false
$start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true
$process = [Diagnostics.Process]::Start($start)
$process.StandardInput.WriteLine($body)
$process.StandardInput.WriteLine($harness)
$process.StandardInput.Close()
$output = $process.StandardOutput.ReadToEnd(); $process.WaitForExit(); $process.Dispose()
foreach ($expected in @('RESPONSE request-a OK|APPLIED','RESPONSE request-b OK|SAVED','RESPONSE request-c SAVED|APPLY_FAILED','RESPONSE request-d OK|SAVED')) {
    if (-not $output.Contains($expected)) { throw "Missing $expected : $output" }
}
if (($output | Select-String -Pattern '(?m)^APPLY ' -AllMatches).Matches.Count -ne 2) { throw "Wrong host applied: $output" }
Write-Host 'PASS current host applies immediately; other/disconnected host saves only; apply failure preserves saved result'
