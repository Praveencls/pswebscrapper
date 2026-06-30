[CmdletBinding()]
param(
    [string] $CardsPath = (Join-Path $PSScriptRoot 'Cards.json'),

    [Alias('CardsDetailsPath', 'DetailsPath')]
    [string] $CardDetailsPath = (Join-Path $PSScriptRoot 'CardDetails.json'),

    [string] $OutputPath = (Join-Path $PSScriptRoot 'MergedCards.json'),

    [string[]] $ExcludedProperties = @(
        'homeId',
        'localImagePath',
        'homeAddress',
        'badge',
        'description',
        'ContactDetail',
        'localPath'
    )
)

$ErrorActionPreference = 'Stop'

function Read-JsonArray {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description file was not found: $Path"
    }

    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }

    return @(foreach ($item in $parsed) { $item })
}

function Remove-ExcludedJsonProperties {
    param(
        [AllowNull()][object] $Value,
        [Parameter(Mandatory)]
        [System.Collections.Generic.HashSet[string]] $ExcludedNames
    )

    if ($null -eq $Value) { return $null }

    if ($Value -is [System.Array]) {
        $filteredItems = @(
            foreach ($item in $Value) {
                Remove-ExcludedJsonProperties `
                    -Value $item `
                    -ExcludedNames $ExcludedNames
            }
        )

        # The unary comma keeps zero- and one-item JSON arrays as arrays.
        return ,$filteredItems
    }

    if ($Value -is [pscustomobject]) {
        $filteredProperties = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($ExcludedNames.Contains($property.Name)) { continue }

            $filteredProperties[$property.Name] =
                Remove-ExcludedJsonProperties `
                    -Value $property.Value `
                    -ExcludedNames $ExcludedNames
        }

        return [pscustomobject] $filteredProperties
    }

    return $Value
}

try {
    $cards = @(Read-JsonArray -Path $CardsPath -Description 'Cards')
    $details = @(Read-JsonArray `
        -Path $CardDetailsPath `
        -Description 'Card details')

    $detailsById = [System.Collections.Generic.Dictionary[string, object]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($detail in $details) {
        $detailId = [string] $detail.id
        if ([string]::IsNullOrWhiteSpace($detailId)) {
            Write-Warning 'Skipping a card detail record without an id.'
            continue
        }

        if ($detailsById.ContainsKey($detailId)) {
            throw "Duplicate card detail id '$detailId'."
        }

        $detailsById.Add($detailId, $detail)
    }

    $matchedIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    $unmatchedCardCount = 0

    $mergedCards = @(
        foreach ($card in $cards) {
            $properties = [ordered]@{}
            foreach ($property in $card.PSObject.Properties) {
                $properties[$property.Name] = $property.Value
            }

            $homeId = [string] $card.homeId
            $detail = $null
            if (-not [string]::IsNullOrWhiteSpace($homeId) -and
                $detailsById.TryGetValue($homeId, [ref] $detail)) {
                [void] $matchedIds.Add($homeId)

                # Detail values win when the same property exists in both files.
                foreach ($property in $detail.PSObject.Properties) {
                    $outputName = if ($property.Name -ieq 'id') {
                        'itemid'
                    } else {
                        $property.Name
                    }
                    $properties[$outputName] = $property.Value
                }
            }
            else {
                $unmatchedCardCount++
                Write-Warning "No card detail found for homeId '$homeId'."
            }

            [pscustomobject] $properties
        }
    )

    $unmatchedDetailCount = @(
        $detailsById.Keys | Where-Object { -not $matchedIds.Contains($_) }
    ).Count

    if ($unmatchedDetailCount -gt 0) {
        Write-Warning "$unmatchedDetailCount card detail record(s) had no matching card."
    }

    $excludedNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($propertyName in $ExcludedProperties) {
        if (-not [string]::IsNullOrWhiteSpace($propertyName)) {
            [void] $excludedNames.Add($propertyName.Trim())
        }
    }

    $jsonCards = @(
        foreach ($mergedCard in $mergedCards) {
            Remove-ExcludedJsonProperties `
                -Value $mergedCard `
                -ExcludedNames $excludedNames
        }
    )

    $json = ConvertTo-Json -InputObject $jsonCards -Depth 10
    $json = $json -replace '\\u0026', '&'
    $json | Set-Content -LiteralPath $OutputPath -Encoding utf8

    [Console]::Error.WriteLine(
        "[Merge-HomeCards] Complete: merged $($mergedCards.Count) card(s); " +
        "$unmatchedCardCount card(s) and $unmatchedDetailCount detail record(s) unmatched.")

    $json
}
catch {
    [Console]::Error.WriteLine("[Merge-HomeCards] Failed: $($_.Exception.Message)")
    throw
}
