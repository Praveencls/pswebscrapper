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

    [string] $OutputPath
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

try {
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
        $homeArray
    } else {
        @(
            foreach ($homeRecord in $homeArray) {
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
                Get-NormalizedText $builderTitle.InnerText
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

                        [pscustomobject][ordered]@{
                            src = if ($src) {
                                [System.Net.WebUtility]::HtmlDecode($src).Trim()
                            } else { $null }
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

                        [pscustomobject][ordered]@{
                            src = if ($src) {
                                [System.Net.WebUtility]::HtmlDecode($src).Trim()
                            } else { $null }
                            alt = if ($alt) {
                                [System.Net.WebUtility]::HtmlDecode($alt).Trim()
                            } else { $null }
                        }
                    }
            )

            $homeIdNode = $document.GetElementbyId('homeId')
            $detailHomeId = if ($homeIdNode -and
                $homeIdNode.Name -ieq 'input' -and
                $homeIdNode.GetAttributeValue('type', '') -ieq 'hidden') {
                Get-HtmlNodeAttribute $homeIdNode 'value'
            }

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
                            $contactDetailProperties[$className] =
                                Get-NormalizedText $_.InnerText
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
    if ($OutputPath) { $json | Set-Content -LiteralPath $OutputPath -Encoding utf8 }

    $json
}
catch {
    throw "Unable to retrieve home details: $($_.Exception.Message)"
}
