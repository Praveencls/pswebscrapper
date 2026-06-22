param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Sitemap,

    [string] $OutputPath,

    [ValidateSet('Csv', 'Json')]
    [string] $Format = 'Csv',

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

function Invoke-RetryingWebRequest {
    param([Parameter(Mandatory)][string] $Uri)

    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (compatible; SitemapMetadata/1.0)'
        'Accept'     = 'application/xml,text/xml;q=0.9,text/html;q=0.8,*/*;q=0.7'
    }

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            # Shopify/Cloudflare occasionally resets reused TLS connections.
            # A fresh connection plus a browser-like user agent is more reliable.
            return Invoke-WebRequest `
                -Uri $Uri `
                -MaximumRedirection 10 `
                -UseBasicParsing `
                -DisableKeepAlive `
                -Headers $headers
        }
        catch {
            $statusCode = if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                [int] $_.Exception.Response.StatusCode
            }
            $isTransient = $null -eq $statusCode -or
                $statusCode -eq 408 -or
                $statusCode -eq 429 -or
                $statusCode -ge 500

            if ($attempt -ge $RetryCount -or -not $isTransient) { throw }

            $wait = [Math]::Min(
                $RetryDelayMilliseconds * [Math]::Pow(2, $attempt),
                60000
            )
            Write-Warning "Request to '$Uri' failed (attempt $($attempt + 1) of $($RetryCount + 1)): $($_.Exception.Message). Retrying in $([int]$wait) ms."
            Start-Sleep -Milliseconds ([int] $wait)
        }
    }
}

try {
    if ($Sitemap -match '^https?://') {
        $xmlContent = (Invoke-RetryingWebRequest -Uri $Sitemap).Content
    }
    else {
        $sitemapPath = (Resolve-Path -LiteralPath $Sitemap).Path
        $xmlContent = Get-Content -LiteralPath $sitemapPath -Raw
    }

    $xmlDocument = [System.Xml.XmlDocument]::new()
    $xmlDocument.XmlResolver = $null
    $xmlDocument.LoadXml($xmlContent)
}
catch {
    throw "Unable to read sitemap '$Sitemap': $($_.Exception.Message)"
}

# Only select the page <loc> directly beneath each <url> record. This excludes
# nested image:loc and video:loc entries commonly found in Shopify sitemaps.
# local-name() works with both namespaced and non-namespaced sitemap files.
$urls = @(
    $xmlDocument.SelectNodes(
        "/*[local-name()='urlset']/*[local-name()='url']/*[local-name()='loc']"
    ) |
        ForEach-Object { $_.InnerText.Trim() } |
        Where-Object { $_ -match '^https?://' } |
        Select-Object -Unique
)

if ($urls.Count -eq 0) {
    throw "No valid page <url><loc> entries were found in '$Sitemap'."
}

$results = [System.Collections.Generic.List[object]]::new()

for ($index = 0; $index -lt $urls.Count; $index++) {
    $url = $urls[$index]
    $number = $index + 1

    Write-Progress `
        -Activity 'Reading sitemap metadata' `
        -Status "$number of $($urls.Count): $url" `
        -PercentComplete (($number / $urls.Count) * 100)

    try {
        $metadata = & $metadataScript -Url $url
        $results.Add($metadata)
    }
    catch {
        Write-Warning "Failed to scrape '$url': $($_.Exception.Message)"
        $results.Add([pscustomobject][ordered]@{
            Title                    = 'Not specified'
            Description              = 'Not specified'
            URL                      = $url
            'Canonical URL'          = 'Not specified'
            'Open Graph Title'       = 'Not specified'
            'Open Graph Description' = 'Not specified'
            'Open Graph Image'       = 'Not specified'
            'Twitter Title'          = 'Not specified'
            'Twitter Description'    = 'Not specified'
            'Twitter Image'          = 'Not specified'
            'Meta Keywords'          = 'Not specified'
            'Robots Meta'            = 'Not specified'
            'X-Robots-Tag'           = 'Not specified'
            Languages                = 'Not specified'
            'Word Count'             = 0
            'Character Count'        = 0
            Error                    = $_.Exception.Message
        })
    }

    if ($DelayMilliseconds -gt 0 -and $number -lt $urls.Count) {
        Start-Sleep -Milliseconds $DelayMilliseconds
    }
}

Write-Progress -Activity 'Reading sitemap metadata' -Completed

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $results
    return
}

$parentDirectory = Split-Path -Parent $OutputPath
if ($parentDirectory -and -not (Test-Path -LiteralPath $parentDirectory)) {
    New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
}

switch ($Format) {
    'Json' {
        $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    }
    'Csv' {
        $results | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
    }
}

Write-Host "Processed $($urls.Count) URL(s). Results saved to: $OutputPath"
