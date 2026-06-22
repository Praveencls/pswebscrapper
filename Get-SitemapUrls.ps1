param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Sitemap,

    [Parameter(Position = 1)]
    [string] $OutputPath = (Join-Path (Get-Location) 'sitemap-urls.json')
)

$ErrorActionPreference = 'Stop'

try {
    if ($Sitemap -match '^https?://') {
        $response = Invoke-WebRequest `
            -Uri $Sitemap `
            -MaximumRedirection 10 `
            -UseBasicParsing `
            -Headers @{ 'User-Agent' = 'Mozilla/5.0 (compatible; SitemapUrlReader/1.0)' }

        $xmlContent = $response.Content
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

# Select only <loc> elements that are direct children of a <url> record.
# This excludes image:loc, video:loc, and other media locations.
$records = @(
    $xmlDocument.SelectNodes(
        "/*[local-name()='urlset']/*[local-name()='url']/*[local-name()='loc']"
    ) |
        ForEach-Object { $_.InnerText.Trim() } |
        Where-Object { $_ -match '^https?://' } |
        Select-Object -Unique |
        ForEach-Object {
            [pscustomobject][ordered]@{ loc = $_ }
        }
)

if ($records.Count -eq 0) {
    throw "No valid <url><loc> records were found in '$Sitemap'."
}

$parentDirectory = Split-Path -Parent $OutputPath
if ($parentDirectory -and -not (Test-Path -LiteralPath $parentDirectory)) {
    New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
}

# -InputObject preserves JSON array shape even when the sitemap has one URL.
ConvertTo-Json -InputObject $records -Depth 2 |
    Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Host "Saved $($records.Count) URL(s) to: $OutputPath"
