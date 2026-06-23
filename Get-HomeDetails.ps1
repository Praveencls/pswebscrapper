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

    $results = @(
        foreach ($homeRecord in $homeArray) {
            $homeLink = [string] $homeRecord.homeLink
            if ($homeLink -notmatch '^https?://') {
                throw "A valid absolute HTTP or HTTPS homeLink is required. Received '$homeLink'."
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
            $builderContainer = $document.DocumentNode.DescendantsAndSelf() |
                Where-Object { Test-HtmlClass $_ 'builderName' } |
                Select-Object -First 1

            $builderMeta = if ($builderContainer) {
                $builderContainer.Descendants('meta') |
                    Where-Object { $_.GetAttributeValue('itemprop', '') -ieq 'name' } |
                    Select-Object -First 1
            }
            $builderName = if ($builderMeta) {
                Get-HtmlNodeAttribute $builderMeta 'content'
            }

            [pscustomobject][ordered]@{
                homeId         = $homeRecord.homeId
                homeLink       = $homeLink
                thumbnailImage = $homeRecord.thumbnailImage
                homeName       = $homeRecord.homeName
                builderName    = if ($builderName) {
                    [System.Net.WebUtility]::HtmlDecode($builderName).Trim()
                } else {
                    $homeRecord.builderName
                }
                homeAddress    = $homeRecord.homeAddress
                badge          = $homeRecord.badge
            }
        }
    )

    $json = ConvertTo-Json -InputObject $results -Depth 5
    if ($OutputPath) { $json | Set-Content -LiteralPath $OutputPath -Encoding utf8 }

    $json
}
catch {
    throw "Unable to retrieve home details: $($_.Exception.Message)"
}
