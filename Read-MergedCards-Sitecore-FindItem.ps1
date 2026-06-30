[CmdletBinding()]
param(
    [string] $JsonPath = (Join-Path $PSScriptRoot 'MergedCards.json'),
    [string] $IndexName = 'sitecore_master_index',
    [string] $SitecoreItemIdField = 'itemid',
    [string] $Language = 'en',
    [scriptblock] $ProcessRecord
)

$ErrorActionPreference = 'Stop'

function Find-SitecoreItemByItemId {
    param([Parameter(Mandatory)][string] $ItemId)

    $criteria = @(
        @{ Filter = 'Equals'; Field = $SitecoreItemIdField; Value = $ItemId }
        @{ Filter = 'Equals'; Field = '_language'; Value = $Language }
    )

    # These commands are provided by Sitecore PowerShell Extensions.
    $matches = @(
        Find-Item -Index $IndexName -Criteria $criteria -First 10 |
            Initialize-Item |
            Where-Object {
                [string] $_[$SitecoreItemIdField] -ceq $ItemId
            }
    )

    if ($matches.Count -gt 1) {
        throw "More than one Sitecore item has $SitecoreItemIdField '$ItemId'."
    }

    if ($matches.Count -eq 1) { return $matches[0] }
    return $null
}

if (-not (Get-Command -Name Find-Item -ErrorAction SilentlyContinue)) {
    throw 'Find-Item is unavailable. Run this script in Sitecore PowerShell Extensions (SPE).'
}

if (-not (Get-Command -Name Initialize-Item -ErrorAction SilentlyContinue)) {
    throw 'Initialize-Item is unavailable. Run this script in Sitecore PowerShell Extensions (SPE).'
}

if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) {
    throw "Merged cards JSON was not found at '$JsonPath'."
}

$parsed = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
$records = @(foreach ($record in $parsed) { $record })

Write-Verbose "Reading $($records.Count) merged record(s) from '$JsonPath'."

foreach ($record in $records) {
    $itemId = [string] $record.itemid
    if ([string]::IsNullOrWhiteSpace($itemId)) {
        Write-Warning 'Skipping a JSON record without itemid.'
        continue
    }

    $sitecoreItem = Find-SitecoreItemByItemId -ItemId $itemId
    if ($null -eq $sitecoreItem) {
        Write-Warning "No Sitecore item found with $SitecoreItemIdField '$itemId'."
        continue
    }

    if ($ProcessRecord) {
        & $ProcessRecord $record $sitecoreItem
    }
    else {
        $sitecoreItem
    }
}
