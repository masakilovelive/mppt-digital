[CmdletBinding()]
param(
  [ValidateRange(0, 255)]
  [int]$ExitCode = 0,
  [ValidateRange(0, 60000)]
  [int]$HangMilliseconds = 0,
  [string]$SummaryPath = ''
)

[Console]::Out.WriteLine('MOCK_NATIVE_STDOUT_SENTINEL')
[Console]::Error.WriteLine('MOCK_NATIVE_STDERR_SENTINEL')
if (-not [string]::IsNullOrWhiteSpace($SummaryPath)) {
  $summary = [ordered]@{
    schema = 'mock-native-child-summary-v1'
    result = if ($ExitCode -eq 0) { 'PASS' } else { 'FAIL' }
    requested_exit_code = $ExitCode
  } | ConvertTo-Json -Compress
  [IO.File]::WriteAllText($SummaryPath, $summary,
    [Text.UTF8Encoding]::new($false))
}
if ($HangMilliseconds -gt 0) {
  Start-Sleep -Milliseconds $HangMilliseconds
}
exit $ExitCode
