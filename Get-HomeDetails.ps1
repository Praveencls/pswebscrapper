param(
    [Parameter(Mandatory, ParameterSetName = 'FromFile')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $HomesPath,

    [Parameter(Mandatory, ParameterSetName = 'FromPage')]
    [ValidatePattern('^https?://')]
    [string] $PageUrl,

    [Parameter(Mandatory, ParameterSetName = 'FromPage')]
    [ValidateNotNullOrEmpty()]
    [string] $DivId,

    [string] $ApiBaseUrl = 'http://localhost:5132',

    [string] $OutputPath = '.\detailpages.json'
)

$ErrorActionPreference = 'Stop'

try {
    if ($PSCmdlet.ParameterSetName -eq 'FromPage') {
        $encodedPageUrl = [uri]::EscapeDataString($PageUrl)
        $encodedDivId = [uri]::EscapeDataString($DivId)
        $allHomesEndpoint = "$($ApiBaseUrl.TrimEnd('/'))/api/allHomes?url=$encodedPageUrl&divId=$encodedDivId"

        Write-Host "Reading homes from '$PageUrl'..."
        $homes = Invoke-RestMethod -Method Get -Uri $allHomesEndpoint
    }
    else {
        $homes = Get-Content -LiteralPath $HomesPath -Raw | ConvertFrom-Json
    }

    $homeArray = @($homes)

    if ($homeArray.Count -eq 0) {
        throw 'No homes were found.'
    }

    $requestBody = ConvertTo-Json -InputObject $homeArray -Depth 20
    $detailsEndpoint = "$($ApiBaseUrl.TrimEnd('/'))/api/homeDetails"
    $details = Invoke-RestMethod `
        -Method Post `
        -Uri $detailsEndpoint `
        -ContentType 'application/json' `
        -Body $requestBody

    $detailsJson = ConvertTo-Json -InputObject @($details) -Depth 20
    $detailsJson | Set-Content -LiteralPath $OutputPath -Encoding utf8

    Write-Host "Saved $(@($details).Count) detail page result(s) to '$OutputPath'."
    return $details
}
catch {
    throw "Unable to retrieve home details: $($_.Exception.Message)"
}
