param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https?://')]
    [string] $Url,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $DivId,

    [string] $HtmlAgilityPackPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

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

try {
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
    $results = @(
        $container.ChildNodes |
            Where-Object { $_.NodeType -eq [HtmlAgilityPack.HtmlNodeType]::Element } |
            ForEach-Object {
                $homeNode = $_
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

                [pscustomobject][ordered]@{
                    homeId        = [System.Net.WebUtility]::HtmlDecode(
                        (Get-HtmlNodeAttribute $homeNode 'homeid'))
                    homeLink      = $homeLink
                    thumbnailImage = if ($thumbnailImage) {
                        [System.Net.WebUtility]::HtmlDecode($thumbnailImage).Trim()
                    } else { $null }
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

    ConvertTo-Json -InputObject $results -Depth 5 -Compress
}
catch {
    throw "Unable to retrieve homes from '$Url': $($_.Exception.Message)"
}
