param(
  [string]$SupabaseCliVersion = '2.117.0'
)

$ErrorActionPreference = 'Stop'

$rawOutput = & npx --yes "supabase@$SupabaseCliVersion" migration list --agent yes
if ($LASTEXITCODE -ne 0) {
  throw "Supabase migration inspection failed with exit code $LASTEXITCODE."
}

$output = ($rawOutput | Out-String).Trim()
$jsonStart = $output.IndexOf('{')
if ($jsonStart -lt 0) {
  throw 'Supabase migration inspection returned no JSON result.'
}

$result = $output.Substring($jsonStart) | ConvertFrom-Json
$missingRemote = @(
  $result.migrations | Where-Object { $_.local -and -not $_.remote }
)
$missingLocal = @(
  $result.migrations | Where-Object { $_.remote -and -not $_.local }
)

if ($missingRemote.Count -gt 0 -or $missingLocal.Count -gt 0) {
  if ($missingRemote.Count -gt 0) {
    Write-Output (
      'Local migrations missing from the linked project: ' +
      (($missingRemote | ForEach-Object { $_.local }) -join ', ')
    )
  }
  if ($missingLocal.Count -gt 0) {
    Write-Output (
      'Linked-project migrations missing locally: ' +
      (($missingLocal | ForEach-Object { $_.remote }) -join ', ')
    )
  }
  exit 1
}

Write-Output 'Supabase migration histories match.'
