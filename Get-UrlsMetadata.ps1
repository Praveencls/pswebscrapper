param(
    [Parameter(Mandatory, Position = 0)]
    [string] $UrlsPath,

    [string] $OutputPath = (Join-Path (Get-Location) 'sitemap-metadata.json'),

    [string] $FailureLogPath = (Join-Path (Get-Location) 'sitemap-metadata-failures.json'),

    [ValidateRange(1, 10000)]
    [int] $CheckpointSize = 50,

    [ValidateRange(0, 60000)]
    [int] $DelayMilliseconds = 0,

    [ValidateRange(0, 10)]
    [int] $RetryCount = 4,

    [ValidateRange(100, 60000)]
    [int] $RetryDelayMilliseconds = 1000
)

$ErrorActionPreference = 'Stop'
$metadataScript = Join-Path $PSScriptRoot 'Get-WebMetadata.ps1'

if (-not (Test-Path -LiteralPath $metadataScript -PathType Leaf)) {
    throw "Metadata script was not found: $metadataScript"
}

try {
    $resolvedUrlsPath = (Resolve-Path -LiteralPath $UrlsPath).Path
    $inputRecords = @(Get-Content -LiteralPath $resolvedUrlsPath -Raw | ConvertFrom-Json)
}
catch {
    throw "Unable to read URL JSON '$UrlsPath': $($_.Exception.Message)"
}

$urls = @(
    $inputRecords |
        ForEach-Object {
            foreach ($loc in @($_.loc)) {
                [string] $loc
            }
        } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^https?://' } |
        Select-Object -Unique
)

if ($urls.Count -eq 0) {
    throw "No valid 'loc' URLs were found in '$UrlsPath'."
}

foreach ($path in @($OutputPath, $FailureLogPath)) {
    $parentDirectory = Split-Path -Parent $path
    if ($parentDirectory -and -not (Test-Path -LiteralPath $parentDirectory)) {
        New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
    }
}

$results = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[object]]::new()

function Save-OutputCheckpoint {
    # -InputObject keeps the output as a JSON array for zero or one record too.
    ConvertTo-Json -InputObject $results.ToArray() -Depth 5 |
        Set-Content -LiteralPath $OutputPath -Encoding UTF8

    ConvertTo-Json -InputObject $failures.ToArray() -Depth 3 |
        Set-Content -LiteralPath $FailureLogPath -Encoding UTF8
}

for ($index = 0; $index -lt $urls.Count; $index++) {
    $url = $urls[$index]
    $number = $index + 1

    Write-Progress `
        -Activity 'Fetching URL metadata' `
        -Status "$number of $($urls.Count): $url" `
        -PercentComplete (($number / $urls.Count) * 100)

    try {
        $metadata = & $metadataScript `
            -Url $url `
            -RetryCount $RetryCount `
            -RetryDelayMilliseconds $RetryDelayMilliseconds

        $results.Add($metadata)
    }
    catch {
        $reason = $_.Exception.Message
        Write-Warning "Failed to fetch '$url': $reason"

        $failures.Add([pscustomobject][ordered]@{
            requestUrl = $url
            reason     = $reason
            failedAt   = [DateTimeOffset]::Now.ToString('o')
        })
    }

    if ($DelayMilliseconds -gt 0 -and $number -lt $urls.Count) {
        Start-Sleep -Milliseconds $DelayMilliseconds
    }

    if ($number % $CheckpointSize -eq 0) {
        Save-OutputCheckpoint
        Write-Host "Checkpoint saved after $number URL(s)."
    }
}

Write-Progress -Activity 'Fetching URL metadata' -Completed

# Save the final partial batch, or refresh the last exact-size checkpoint.
Save-OutputCheckpoint

Write-Host "Processed $($urls.Count) URL(s): $($results.Count) succeeded, $($failures.Count) failed."
Write-Host "Metadata saved to: $OutputPath"
Write-Host "Failure log saved to: $FailureLogPath"
