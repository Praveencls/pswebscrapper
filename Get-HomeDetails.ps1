param(
    [Parameter(Mandatory, ParameterSetName = 'FromFile')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $HomesPath,

    [Parameter(Mandatory, ParameterSetName = 'FromPage')]
    [ValidatePattern('^https?://')]
    [Alias('PageUrl')]
    [string] $Url,

    [Parameter(Mandatory, ParameterSetName = 'FromPage')]
    [ValidateNotNullOrEmpty()]
    [string] $DivId,

    [Parameter(Mandatory, ParameterSetName = 'FromStandardInput')]
    [switch] $ReadFromStandardInput,

    [ValidateSet('true', 'false', '1', '0')]
    [string] $ScrapeDetails = 'false',

    [string] $HtmlAgilityPackPath,

    [string] $OutputPath,

    [string] $ImageOutputDirectory = (Join-Path $PSScriptRoot 'Images\details')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-StatusMessage {
    param([Parameter(Mandatory)][string] $Message)

    [Console]::Error.WriteLine("[Get-HomeDetails] $Message")
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

function Resolve-MediaUrl {
    param(
        [AllowEmptyString()][string] $MediaUrl,
        [Parameter(Mandatory)][string] $HomeUrl
    )

    if ([string]::IsNullOrWhiteSpace($MediaUrl)) { return $null }

    $decodedUrl = [System.Net.WebUtility]::HtmlDecode($MediaUrl).Trim()
    try {
        $homeUri = [uri] $HomeUrl
        $homeOrigin = [uri] ($homeUri.GetLeftPart(
            [System.UriPartial]::Authority) + '/')
        return ([uri]::new($homeOrigin, $decodedUrl)).AbsoluteUri
    }
    catch {
        return $decodedUrl
    }
}

function Get-DirectText {
    param($Node)

    if (-not $Node) { return $null }

    $text = @(
        $Node.ChildNodes |
            Where-Object {
                $_.NodeType -eq [HtmlAgilityPack.HtmlNodeType]::Text
            } |
            ForEach-Object { $_.InnerText }
    ) -join ' '

    return Get-NormalizedText $text
}

function Resolve-HtmlAgilityPackPath {
    if (-not [string]::IsNullOrWhiteSpace($HtmlAgilityPackPath)) {
        return $HtmlAgilityPackPath
    }

    if (-not [string]::IsNullOrWhiteSpace(
        $env:WEB_SCRAPPER_APP_BASE_DIRECTORY)) {
        return Join-Path `
            $env:WEB_SCRAPPER_APP_BASE_DIRECTORY `
            'HtmlAgilityPack.PowerShell.dll'
    }

    $binPath = Join-Path $PSScriptRoot 'WebScrapper\bin'
    if (Test-Path -LiteralPath $binPath -PathType Container) {
        $assembly = Get-ChildItem `
            -LiteralPath $binPath `
            -Filter 'HtmlAgilityPack.PowerShell.dll' `
            -File `
            -Recurse |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($assembly) { return $assembly.FullName }
    }

    return Join-Path `
        $env:USERPROFILE `
        '.nuget\packages\htmlagilitypack\1.12.4\lib\Net45\HtmlAgilityPack.dll'
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

function Get-ImageFileName {
    param([Parameter(Mandatory)][uri] $ImageUri)

    $leaf = [System.IO.Path]::GetFileName($ImageUri.AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'image' }

    $extension = [System.IO.Path]::GetExtension($leaf)
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = '.jpg' }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    $baseName = Get-SafePathPart $baseName

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
    Write-StatusMessage "In progress: loading home records."

    $HtmlAgilityPackPath = Resolve-HtmlAgilityPackPath

    if (-not (Test-Path -LiteralPath $HtmlAgilityPackPath -PathType Leaf)) {
        throw "HtmlAgilityPack was not found: $HtmlAgilityPackPath"
    }

    Add-Type -Path $HtmlAgilityPackPath | Out-Null

    switch ($PSCmdlet.ParameterSetName) {
        'FromStandardInput' {
            $homes = [Console]::In.ReadToEnd() | ConvertFrom-Json
        }
        'FromPage' {
            $homes = & (Join-Path $PSScriptRoot 'Get-AllHomes.ps1') `
                -Url $Url `
                -DivId $DivId `
                -HtmlAgilityPackPath $HtmlAgilityPackPath |
                ConvertFrom-Json
        }
        default {
            $homes = Get-Content -LiteralPath $HomesPath -Raw | ConvertFrom-Json
        }
    }

    $homeArray = @($homes)
    if ($homeArray.Count -eq 0) { throw 'No homes were found.' }

    $shouldScrapeDetails = $ScrapeDetails -in @('true', '1')
    $results = if (-not $shouldScrapeDetails) {
        Write-StatusMessage "In progress: detail scraping disabled; returning $($homeArray.Count) home record(s)."
        $homeArray
    } else {
        $detailIndex = 0
        @(
            foreach ($homeRecord in $homeArray) {
                $detailIndex++

                $homeLink = [string] $homeRecord.homeLink
                if ([string]::IsNullOrWhiteSpace($homeLink)) {
                    $homeLink = [string] $homeRecord.ItemLink
                }
                if ([string]::IsNullOrWhiteSpace($homeLink)) {
                    $homeLink = [string] $homeRecord.itemUrl
                }
                if ($homeLink -notmatch '^https?://') {
                    throw 'A valid absolute HTTP or HTTPS homeLink, ItemLink, or itemUrl is required.'
                }

            Write-StatusMessage "In progress: scraping detail $detailIndex of $($homeArray.Count): $homeLink"

            $response = Invoke-WebRequest `
                -Uri $homeLink `
                -MaximumRedirection 10 `
                -UseBasicParsing `
                -Headers @{
                    'User-Agent' = 'Mozilla/5.0 (compatible; WebScrapper/1.0)'
                    'Accept' = 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8'
                }

            $document = [HtmlAgilityPack.HtmlDocument]::new()
            $document.LoadHtml([string] $response.Content)

            $homeIdNode = $document.GetElementbyId('homeId')
            $detailHomeId = if ($homeIdNode -and
                $homeIdNode.Name -ieq 'input' -and
                $homeIdNode.GetAttributeValue('type', '') -ieq 'hidden') {
                Get-HtmlNodeAttribute $homeIdNode 'value'
            }

            $downloadHomeId = if ($detailHomeId) {
                [System.Net.WebUtility]::HtmlDecode($detailHomeId).Trim()
            } elseif ($homeRecord.homeId) {
                [string] $homeRecord.homeId
            } else {
                [System.IO.Path]::GetFileName($homeLink.TrimEnd([char[]] @('/')))
            }

            $homeImageDirectory = Join-Path $ImageOutputDirectory (Get-SafePathPart $downloadHomeId)

            $modelTitle = $document.GetElementbyId('ModelName')
            $builderContainer = if ($modelTitle) {
                $modelTitle.DescendantsAndSelf() |
                    Where-Object {
                        $_.Name -ieq 'div' -and
                        (Test-HtmlClass $_ 'builderName')
                    } |
                    Select-Object -First 1
            }

            $builderTitle = if ($builderContainer) {
                $builderContainer.Descendants('h1') |
                    Where-Object { Test-HtmlClass $_ 'builderName__title' } |
                    Select-Object -First 1
            }
            $builderName = if ($builderTitle) {
                Get-DirectText $builderTitle
            }

            $modelNameTitle = if ($builderTitle) {
                $builderTitle.Descendants('span') |
                    Where-Object { Test-HtmlClass $_ 'modelName__title' } |
                    Select-Object -First 1
            }
            $homeName = if ($modelNameTitle) {
                Get-DirectText $modelNameTitle
            }

            $communityInfo = $document.DocumentNode.DescendantsAndSelf() |
                Where-Object {
                    $_.Name -ieq 'div' -and
                    (Test-HtmlClass $_ 'community-info__info')
                } |
                Select-Object -First 1
            $descriptionNode = if ($communityInfo) {
                $communityInfo.Descendants('p') | Select-Object -First 1
            }
            if (-not $descriptionNode) {
                $descriptionContainer = $document.GetElementbyId('DescriptionDiv')
                if ($descriptionContainer -and
                    $descriptionContainer.GetAttributeValue('itemprop', '') -ieq 'description') {
                    $descriptionNode = $descriptionContainer.Descendants('p') |
                        Select-Object -First 1
                }
            }

            $photos = @(
                $document.DocumentNode.Descendants('img') |
                    Where-Object {
                        $_.GetAttributeValue('itemprop', '') -ieq 'photo'
                    } |
                    ForEach-Object {
                        $src = Get-HtmlNodeAttribute $_ 'src'
                        $alt = Get-HtmlNodeAttribute $_ 'alt'
                        $normalizedSrc = Resolve-MediaUrl `
                            -MediaUrl $src `
                            -HomeUrl $homeLink
                        $photoDirectory = Join-Path $homeImageDirectory 'photos'

                        [pscustomobject][ordered]@{
                            src = $normalizedSrc
                            localPath = Save-ImageIfMissing `
                                -ImageUrl $normalizedSrc `
                                -BaseUrl ([uri] $homeLink) `
                                -OutputDirectory $photoDirectory
                            alt = if ($alt) {
                                [System.Net.WebUtility]::HtmlDecode($alt).Trim()
                            } else { $null }
                        }
                    }
            )

            $floorplans = @(
                $document.DocumentNode.Descendants('img') |
                    Where-Object {
                        $_.GetAttributeValue('itemprop', '') -ieq 'additionalProperty'
                    } |
                    ForEach-Object {
                        $src = Get-HtmlNodeAttribute $_ 'src'
                        $alt = Get-HtmlNodeAttribute $_ 'alt'
                        $normalizedSrc = Resolve-MediaUrl `
                            -MediaUrl $src `
                            -HomeUrl $homeLink
                        $floorplanDirectory = Join-Path $homeImageDirectory 'floorplans'

                        [pscustomobject][ordered]@{
                            src = $normalizedSrc
                            localPath = Save-ImageIfMissing `
                                -ImageUrl $normalizedSrc `
                                -BaseUrl ([uri] $homeLink) `
                                -OutputDirectory $floorplanDirectory
                            alt = if ($alt) {
                                [System.Net.WebUtility]::HtmlDecode($alt).Trim()
                            } else { $null }
                        }
                    }
            )

            $contactDetailProperties = [ordered]@{}
            $contactDetailsNode = $document.GetElementbyId('ContactDetails')
            if ($contactDetailsNode) {
                $contactDetailsNode.ChildNodes |
                    Where-Object {
                        $_.NodeType -eq [HtmlAgilityPack.HtmlNodeType]::Element -and
                        $_.Name -ieq 'div'
                    } |
                    ForEach-Object {
                        $className = ($_.GetAttributeValue('class', '') -split '\s+' |
                            Where-Object { $_ } |
                            Select-Object -First 1)

                        if ($className) {
                            $contactDetailProperties[$className] = if (
                                $className -ieq 'salresRepHours'
                            ) {
                                # Preserve paragraph, strong, span, and br markup
                                # for Sitecore Rich Text Editor fields.
                                $richTextHtml = $_.InnerHtml.Trim()
                                if ($richTextHtml -match '&lt;/?[a-zA-Z][^&]*&gt;') {
                                    $richTextHtml = [System.Net.WebUtility]::HtmlDecode(
                                        $richTextHtml)
                                }
                                $richTextHtml
                            }
                            else {
                                Get-NormalizedText $_.InnerText
                            }
                        }
                    }
            }
            $contactDetail = [pscustomobject] $contactDetailProperties

            [pscustomobject][ordered]@{
                id = if ($detailHomeId) {
                    [System.Net.WebUtility]::HtmlDecode($detailHomeId).Trim()
                } else {
                    $null
                }
                builderName = if ($builderName) {
                    [System.Net.WebUtility]::HtmlDecode($builderName).Trim()
                } else {
                    $homeRecord.builderName
                }
                homeName = if ($homeName) {
                    [System.Net.WebUtility]::HtmlDecode($homeName).Trim()
                } else {
                    $homeRecord.homeName
                }
                description = if ($descriptionNode) {
                    Get-NormalizedText $descriptionNode.InnerText
                } else {
                    $null
                }
                photos = $photos
                floorplans = $floorplans
                ContactDetail = $contactDetail
            }
            }
        )
    }

    $resultArray = @($results)
    $json = ConvertTo-Json -InputObject $resultArray -Depth 5
    $json = $json -replace '\\u0026', '&'
    if ($OutputPath) { $json | Set-Content -LiteralPath $OutputPath -Encoding utf8 }

    Write-StatusMessage "Complete: processed $($resultArray.Count) home detail record(s)."
    $json
}
catch {
    Write-StatusMessage "Failed: $($_.Exception.Message)"
    throw "Unable to retrieve home details: $($_.Exception.Message)"
}
