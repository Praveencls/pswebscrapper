param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https?://')]
    [string] $Url,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $DivId,

    [string] $HtmlAgilityPackPath,

    [string] $ImageOutputDirectory = (Join-Path $PSScriptRoot 'Images\thumbnails')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-StatusMessage {
    param([Parameter(Mandatory)][string] $Message)

    [Console]::Error.WriteLine("[Get-AllHomes] $Message")
}

function Test-HtmlClass {
    param($Node, [Parameter(Mandatory)][string] $ClassName)

    $classes = $Node.GetAttributeValue('class', '') -split '\s+' | Where-Object { $_ }
    return @($classes) -icontains $ClassName
}

function Get-HtmlNodeAttribute {
    param($Node, [Parameter(Mandatory)][string] $Name)

    $attribute = $Node.Attributes[$Name]
    if ($attribute) { return $attribute.Value }
    return $null
}

function Get-NormalizedText {
    param([AllowEmptyString()][string] $Value)

    $decoded = [System.Net.WebUtility]::HtmlDecode($Value)
    return (($decoded -split '\s+' | Where-Object { $_ }) -join ' ')
}

function Find-ByClass {
    param($Root, [Parameter(Mandatory)][string] $ClassName)

    return $Root.DescendantsAndSelf() |
        Where-Object { Test-HtmlClass $_ $ClassName } |
        Select-Object -First 1
}

function Get-ImageFileName {
    param([Parameter(Mandatory)][uri] $ImageUri)

    $leaf = [System.IO.Path]::GetFileName($ImageUri.AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'image' }

    $extension = [System.IO.Path]::GetExtension($leaf)
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.jpg' }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    $invalidChars = [regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars()))
    $baseName = ($baseName -replace "[$invalidChars]", '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($baseName)) { $baseName = 'image' }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($ImageUri.AbsoluteUri)
        $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }

    return "$baseName-$hash$extension"
}

function Get-SafePathPart {
    param([AllowEmptyString()][string] $Value)

    $safeValue = $Value
    if ([string]::IsNullOrWhiteSpace($safeValue)) { $safeValue = 'unknown' }

    $invalidChars = [regex]::Escape((-join [System.IO.Path]::GetInvalidFileNameChars()))
    $safeValue = ($safeValue -replace "[$invalidChars]", '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeValue)) { return 'unknown' }

    return $safeValue
}

function Save-ImageIfMissing {
    param(
        [AllowEmptyString()][string] $ImageUrl,
        [Parameter(Mandatory)][uri] $BaseUrl,
        [Parameter(Mandatory)][string] $OutputDirectory
    )

    if ([string]::IsNullOrWhiteSpace($ImageUrl)) { return $null }

    try {
        $decodedUrl = [System.Net.WebUtility]::HtmlDecode($ImageUrl).Trim()
        $imageUri = [uri]::new($BaseUrl, $decodedUrl)
        if ($imageUri.Scheme -notin @('http', 'https')) { return $null }

        if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        }

        $filePath = Join-Path $OutputDirectory (Get-ImageFileName $imageUri)
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            Invoke-WebRequest `
                -Uri $imageUri.AbsoluteUri `
                -OutFile $filePath `
                -MaximumRedirection 10 `
                -UseBasicParsing `
                -Headers @{
                    'User-Agent' = 'Mozilla/5.0 (compatible; WebScrapper/1.0)'
                    'Accept' = 'image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8'
                }
        }

        return $filePath
    }
    catch {
        Write-Warning "Failed to download image '$ImageUrl': $($_.Exception.Message)"
        return $null
    }
}

try {
    Write-StatusMessage "In progress: scraping homes from '$Url'."

    if ([string]::IsNullOrWhiteSpace($HtmlAgilityPackPath)) {
        $HtmlAgilityPackPath = Join-Path `
            $env:WEB_SCRAPPER_APP_BASE_DIRECTORY `
            'HtmlAgilityPack.PowerShell.dll'
    }

    if (-not (Test-Path -LiteralPath $HtmlAgilityPackPath -PathType Leaf)) {
        throw "HtmlAgilityPack was not found: $HtmlAgilityPackPath"
    }

    Add-Type -Path $HtmlAgilityPackPath | Out-Null

    $response = Invoke-WebRequest `
        -Uri $Url `
        -MaximumRedirection 10 `
        -UseBasicParsing `
        -Headers @{
            'User-Agent' = 'Mozilla/5.0 (compatible; WebScrapper/1.0)'
            'Accept' = 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8'
        }

    $contentType = [string] $response.Headers['Content-Type']
    if ($contentType -and $contentType -notmatch '(?i)(text/html|application/xhtml\+xml)') {
        throw "Unsupported content type '$contentType'. Expected an HTML page."
    }

    $document = [HtmlAgilityPack.HtmlDocument]::new()
    $document.LoadHtml([string] $response.Content)
    $container = $document.GetElementbyId($DivId)

    if ($null -eq $container -or $container.Name -ine 'div') {
        'null'
        return
    }

    $pageUrl = [uri] $Url
    $homeNodes = @(
        $container.ChildNodes |
            Where-Object { $_.NodeType -eq [HtmlAgilityPack.HtmlNodeType]::Element } |
            ForEach-Object { $_ }
    )

    $results = @(
        for ($index = 0; $index -lt $homeNodes.Count; $index++) {
                $number = $index + 1
                $homeNode = $homeNodes[$index]
                $homeId = [System.Net.WebUtility]::HtmlDecode(
                    (Get-HtmlNodeAttribute $homeNode 'homeid'))

                Write-StatusMessage "In progress: processing card $number of $($homeNodes.Count) (homeId: $homeId)."

                $homeLink = [System.Net.WebUtility]::HtmlDecode(
                    (Get-HtmlNodeAttribute $homeNode 'homelink'))

                if ($homeLink) {
                    try { $homeLink = ([uri]::new($pageUrl, $homeLink.Trim())).AbsoluteUri }
                    catch { $homeLink = $homeLink.Trim() }
                }

                $imageNode = Find-ByClass $homeNode 'imageContainer'
                $thumbnailImage = if ($imageNode) {
                    Get-HtmlNodeAttribute $imageNode 'data-img'
                }
                if (-not $thumbnailImage -and $imageNode) {
                    $image = $imageNode.Descendants('img') | Select-Object -First 1
                    if ($image) { $thumbnailImage = Get-HtmlNodeAttribute $image 'src' }
                }

                $badgeNode = Find-ByClass $homeNode 'featured'
                if (-not $badgeNode) {
                    $bannerNode = Find-ByClass $homeNode 'banner'
                    if ($bannerNode) { $badgeNode = Find-ByClass $bannerNode 'nameDirect' }
                }

                $homeNameNode = Find-ByClass $homeNode 'homeName'
                $builderNameNode = Find-ByClass $homeNode 'builderName'
                $homeAddressNode = Find-ByClass $homeNode 'homeAddress'

                $thumbnailImage = if ($thumbnailImage) {
                    [System.Net.WebUtility]::HtmlDecode($thumbnailImage).Trim()
                } else { $null }

                if ($thumbnailImage -and $homeLink) {
                    try {
                        $homeUri = [uri] $homeLink
                        $homeOrigin = [uri] ($homeUri.GetLeftPart(
                            [System.UriPartial]::Authority) + '/')
                        $thumbnailImage = ([uri]::new(
                            $homeOrigin,
                            $thumbnailImage)).AbsoluteUri
                    }
                    catch {
                        # Keep the extracted value when either URL is malformed.
                    }
                }

                $thumbnailDirectory = Join-Path $ImageOutputDirectory (Get-SafePathPart $homeId)

                $localThumbnailPath = Save-ImageIfMissing `
                    -ImageUrl $thumbnailImage `
                    -BaseUrl $pageUrl `
                    -OutputDirectory $thumbnailDirectory

                [pscustomobject][ordered]@{
                    homeId        = $homeId
                    homeLink      = $homeLink
                    thumbnailImage = $thumbnailImage
                    localImagePath = $localThumbnailPath
                    homeName      = if ($homeNameNode) {
                        Get-NormalizedText $homeNameNode.InnerText
                    } else { $null }
                    builderName   = if ($builderNameNode) {
                        Get-NormalizedText $builderNameNode.InnerText
                    } else { $null }
                    homeAddress   = if ($homeAddressNode) {
                        Get-NormalizedText $homeAddressNode.InnerText
                    } else { $null }
                    badge         = if ($badgeNode) {
                        Get-NormalizedText $badgeNode.InnerText
                    } else { $null }
                }
        }
    )

    Write-StatusMessage "Complete: scraped $($results.Count) home card(s)."
    $json = ConvertTo-Json -InputObject $results -Depth 5 -Compress
    $json -replace '\\u0026', '&'
}
catch {
    Write-StatusMessage "Failed: $($_.Exception.Message)"
    throw "Unable to retrieve homes from '$Url': $($_.Exception.Message)"
}
