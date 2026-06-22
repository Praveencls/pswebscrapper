param(
    [Parameter(Mandatory, Position = 0)]
    [ValidatePattern('^https?://')]
    [string] $Url,

    [switch] $AsJson,

    [ValidateRange(0, 10)]
    [int] $RetryCount = 4,

    [ValidateRange(100, 60000)]
    [int] $RetryDelayMilliseconds = 1000
)

$ErrorActionPreference = 'Stop'

function ConvertFrom-HtmlText {
    param([AllowEmptyString()][string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    return [System.Net.WebUtility]::HtmlDecode($Value).Trim()
}

function Get-HtmlAttribute {
    param(
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][string] $Name
    )

    $escapedName = [regex]::Escape($Name)
    $match = [regex]::Match(
        $Tag,
        "(?is)\b$escapedName\s*=\s*(?:`"(?<value>[^`"]*)`"|'(?<value>[^']*)'|(?<value>[^\s>]+))"
    )

    if ($match.Success) { return ConvertFrom-HtmlText $match.Groups['value'].Value }
    return $null
}

function Get-MetaContent {
    param(
        [Parameter(Mandatory)][string] $Html,
        [Parameter(Mandatory)][string[]] $Names
    )

    foreach ($tagMatch in [regex]::Matches($Html, '(?is)<meta\b[^>]*>')) {
        $tag = $tagMatch.Value
        $key = Get-HtmlAttribute $tag 'name'
        if (-not $key) { $key = Get-HtmlAttribute $tag 'property' }

        if ($key -and $Names -icontains $key) {
            return Get-HtmlAttribute $tag 'content'
        }
    }

    return $null
}

function Get-LinkHref {
    param(
        [Parameter(Mandatory)][string] $Html,
        [Parameter(Mandatory)][string] $Rel
    )

    foreach ($tagMatch in [regex]::Matches($Html, '(?is)<link\b[^>]*>')) {
        $tag = $tagMatch.Value
        $relationship = Get-HtmlAttribute $tag 'rel'
        if ($relationship -and ($relationship -split '\s+') -icontains $Rel) {
            return Get-HtmlAttribute $tag 'href'
        }
    }

    return $null
}

function Resolve-WebUrl {
    param([string] $Value, [uri] $BaseUrl)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try { return ([uri]::new($BaseUrl, $Value)).AbsoluteUri } catch { return $Value }
}

function Show-OrNotSpecified {
    param([AllowNull()][string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Not specified' }
    return $Value
}

function Invoke-RetryingWebRequest {
    param([Parameter(Mandatory)][string] $Uri)

    $headers = @{
        'User-Agent' = 'Mozilla/5.0 (compatible; SitemapMetadata/1.0)'
        'Accept'     = 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8'
    }

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
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
    $response = Invoke-RetryingWebRequest -Uri $Url
    $contentType = [string] $response.Headers['Content-Type']
    if ($contentType -and $contentType -notmatch '(?i)(text/html|application/xhtml\+xml)') {
        throw "Unsupported content type '$contentType'. Expected an HTML page."
    }

    $html = $response.Content
    if ($html -isnot [string]) {
        throw "The response does not contain HTML text."
    }
    $finalUrl = if ($response.BaseResponse.RequestMessage -and $response.BaseResponse.RequestMessage.RequestUri) {
        $response.BaseResponse.RequestMessage.RequestUri
    } elseif ($response.BaseResponse.ResponseUri) {
        $response.BaseResponse.ResponseUri
    } else {
        [uri] $Url
    }

    $titleMatch = [regex]::Match($html, '(?is)<title\b[^>]*>(?<value>.*?)</title>')
    $title = if ($titleMatch.Success) { ConvertFrom-HtmlText $titleMatch.Groups['value'].Value }
    $description = Get-MetaContent $html @('description')
    $openGraphTitle = Get-MetaContent $html @('og:title')
    $openGraphDescription = Get-MetaContent $html @('og:description')
    $openGraphImage = Get-MetaContent $html @('og:image')
    $twitterTitle = Get-MetaContent $html @('twitter:title')
    $twitterDescription = Get-MetaContent $html @('twitter:description')
    $twitterImage = Get-MetaContent $html @('twitter:image', 'twitter:image:src')

    $htmlTag = [regex]::Match($html, '(?is)<html\b[^>]*>').Value
    $language = if ($htmlTag) { Get-HtmlAttribute $htmlTag 'lang' }

    $xRobotsTag = $response.Headers['X-Robots-Tag']
    if ($xRobotsTag -is [array]) { $xRobotsTag = $xRobotsTag -join ', ' }

    $result = [pscustomobject][ordered]@{
        Title                    = Show-OrNotSpecified $title
        Description              = Show-OrNotSpecified $description
        URL                      = $finalUrl.AbsoluteUri
        'Canonical URL'          = Show-OrNotSpecified (Resolve-WebUrl (Get-LinkHref $html 'canonical') $finalUrl)
        'Open Graph Title'       = Show-OrNotSpecified $openGraphTitle
        'Open Graph Description' = Show-OrNotSpecified $openGraphDescription
        'Open Graph Image'       = Show-OrNotSpecified (Resolve-WebUrl $openGraphImage $finalUrl)
        'Twitter Title'          = Show-OrNotSpecified $(if ($twitterTitle) { $twitterTitle } elseif ($openGraphTitle) { $openGraphTitle } else { $title })
        'Twitter Description'    = Show-OrNotSpecified $(if ($twitterDescription) { $twitterDescription } elseif ($openGraphDescription) { $openGraphDescription } else { $description })
        'Twitter Image'          = Show-OrNotSpecified (Resolve-WebUrl $twitterImage $finalUrl)
        'Meta Keywords'          = Show-OrNotSpecified (Get-MetaContent $html @('keywords'))
        'Robots Meta'            = Show-OrNotSpecified (Get-MetaContent $html @('robots'))
        'X-Robots-Tag'           = Show-OrNotSpecified $xRobotsTag
        Languages                = Show-OrNotSpecified $language
    }

    if ($AsJson) { $result | ConvertTo-Json -Depth 3 } else { $result }
}
catch {
    throw "Unable to scrape '$Url': $($_.Exception.Message)"
}
