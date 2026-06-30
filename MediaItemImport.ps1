function UploadFile-ToMediaLibrary {
    param (
        [Parameter(Mandatory = $true)]
        [string]$IntegrationId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceUri,

        [Parameter(Mandatory = $true)]
        [string]$MediaLibraryRoot,

        [string]$AltText
    )

    try {

        # Folder for this Home
        $mediaLibraryPath = "$MediaLibraryRoot/$IntegrationId"

        # File information
        $fileName = [System.IO.Path]::GetFileName(([System.Uri]$ResourceUri).AbsolutePath)
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)

        # Sitecore media item name
        $itemName = $baseName

        # Check before downloading so existing media does not cause network or file work.
        $existingItem = Get-Item "master:$mediaLibraryPath/$itemName" -ErrorAction SilentlyContinue

        if($existingItem)
        {
            Write-Host "Media item already exists: $($existingItem.Paths.Path)"

            return $existingItem
        }

        CreateParentNodes $mediaLibraryPath

        $extension = [System.IO.Path]::GetExtension($fileName)
        $temporaryName = '{0}{1}' -f ([guid]::NewGuid()), $extension
        $downloadFilePath = Join-Path $SitecoreDataFolder $temporaryName

        try {
            Invoke-WebRequest -Uri $ResourceUri -OutFile $downloadFilePath

            return New-MediaItem `
                -filePath $downloadFilePath `
                -mediaPath $mediaLibraryPath `
                -itemId ([guid]::NewGuid()) `
                -itemName $itemName `
                -altText $AltText
        }
        finally {
            if (Test-Path -LiteralPath $downloadFilePath) {
                Remove-Item -LiteralPath $downloadFilePath -Force
            }
        }
    }
    catch {

        Write-Warning "Media upload failed for '$ResourceUri': $($_.Exception.Message)"
        return $null
    }
}

function New-MediaItem {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$filePath,

        [Parameter(Position = 1, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$mediaPath,
        
        [Parameter(Position = 2, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$itemId,
        
        [Parameter(Position = 3, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$itemName,

        [Parameter(Position = 4, Mandatory = $false)]
        [string]$altText
    )

    $fileExtension = [System.IO.Path]::GetExtension($filePath)
    $mediaItemFullPath = "$mediaPath/$itemName"

    $mco = New-Object Sitecore.Resources.Media.MediaCreatorOptions
    $mco.Database = [Sitecore.Configuration.Factory]::GetDatabase("master")
    $mco.Language = [Sitecore.Globalization.Language]::Parse("en")
    $mco.Versioned = [Sitecore.Configuration.Settings+Media]::UploadAsVersionableByDefault
    $mco.Destination = $mediaItemFullPath
    $mco.FileBased = $false

    $mc = New-Object Sitecore.Resources.Media.MediaCreator
    $template = [Sitecore.Resources.Media.MediaManager]::Config.GetTemplate(
        $fileExtension,
        $mco.Versioned)
    $templateItem = $mco.Database.Templates[$template]

    try {
        $newItem = New-Item `
            -Path "master:$mediaPath" `
            -Name $itemName `
            -ItemType $templateItem.ID.ToString() `
            -ForceId $itemId
        $mediaItem = New-Object Sitecore.Data.Items.MediaItem $newItem

        if ($null -eq $mediaItem) {
            throw "Failed to create media item '$mediaItemFullPath'."
        }

        $fileStream = $null
        try {
            $fileStream = New-Object System.IO.FileStream -ArgumentList `
                $filePath,
                ([System.IO.FileMode]::Open),
                ([System.IO.FileAccess]::Read),
                ([System.IO.FileShare]::Read)
            $updatedItem = $mc.AttachStreamToMediaItem(
                $fileStream,
                $mediaItem.InnerItem.Paths.Path,
                $filePath,
                $mco)
        }
        finally {
            if ($null -ne $fileStream) {
                $fileStream.Dispose()
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($altText)) {
            New-UsingBlock (New-Object Sitecore.Data.BulkUpdateContext) {
                $updatedItem.Editing.BeginEdit()
                try {
                    $updatedItem.Fields["Alt"].Value = $altText
                    $updatedItem.Editing.EndEdit() | Out-Null
                }
                catch {
                    $updatedItem.Editing.CancelEdit()
                    throw
                }
            }
        }

        Write-Host "Item created successfully with ID: $($newItem.ID)"
        return $updatedItem
    }
    catch {
        throw "Failed to create media item '$mediaItemFullPath': $($_.Exception.Message)"
    }
}

# Function to create parent nodes if they don't exist
function CreateParentNodes($path) {

    # RootMediaFolder
    $rootMediaFolder = "/sitecore/media library"
   
    # Split the path into individual segments
    $pathSegments = $path.Replace($rootMediaFolder, "").TrimStart("/") -split "/"

    # Initialize a variable to keep track of the current parent item
    $currentParentItem = Get-Item -Path "master:$rootMediaFolder"

    # Loop through each segment of the path
    foreach ($segment in $pathSegments) {
        # Construct the full path of the current item
        $currentItemPath = Join-Path -Path $currentParentItem.Paths.Path -ChildPath $segment

        # Check if the current item already exists
        $existingItem = Get-Item -Path "master:$currentItemPath" -ErrorAction SilentlyContinue

        if ($existingItem -eq $null) {
            # Create the missing item if it doesn't exist
            $newItem = New-Item `
                -Path "master:$($currentParentItem.Paths.Path)" `
                -Name $segment `
                -ItemType "/sitecore/templates/System/Media/Media folder"

            $currentParentItem = $newItem
        }
        else {
            $currentParentItem = $existingItem
        }

    }

    Write-Host "All nodes of the path '$path' are ensured to exist."
}

function Set-SitecoreImageField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Sitecore.Data.Items.Item]$Item,

        [Parameter(Mandatory = $true)]
        [string]$FieldName,

        [Parameter(Mandatory = $true)]
        [Sitecore.Data.Items.Item]$MediaItem
    )

    if ($null -eq $Item) {
        throw "Item cannot be null."
    }

    if ($null -eq $MediaItem) {
        throw "Media item cannot be null."
    }

    New-UsingBlock (New-Object Sitecore.Data.BulkUpdateContext) {

        $Item.Editing.BeginEdit()

        try {

            [Sitecore.Data.Fields.ImageField]$imageField = $Item.Fields[$FieldName]

            if ($imageField -eq $null) {
                throw "Image field '$FieldName' does not exist on item '$($Item.Paths.FullPath)'."
            }

            $imageField.MediaID = $MediaItem.ID

            $Item.Editing.EndEdit() | Out-Null

            Write-Host "Updated image field '$FieldName' on '$($Item.Paths.FullPath)'."
        }
        catch {

            $Item.Editing.CancelEdit()

            throw
        }
    }
}

$MergedCardsJson = @'
[
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-portfolio-celeste/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/lbqkhznb/rah-celeste-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134243720406500000",
        "homeName":  "Portfolio - Celeste",
        "builderName":  "Richmond American Homes",
        "itemid":  "360032",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/lbqkhznb/rah-celeste-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Celeste Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/sp2nhdvy/rah-celeste-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Celeste Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/gzohxryi/rah-celeste-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Celeste Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/dc2eseeo/rah-celeste-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Celeste Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/r01ndqki/celestep243_print_05_22_26.jpg",
                               "alt":  "Celestep243 Print 05 22 26"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-portfolio-cassandra/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/sqeiavj2/rah-cassandra-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134243721012130000",
        "homeName":  "Portfolio - Cassandra",
        "builderName":  "Richmond American Homes",
        "itemid":  "360035",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/sqeiavj2/rah-cassandra-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Cassandra Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/y31fztjb/rah-cassandra-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Cassandra Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/5vyddfgj/rah-cassandra-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Cassandra Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/fernop0m/rah-cassandra-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Cassandra Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/tuynl413/cassandrap642_print_05_22_26.jpg",
                               "alt":  "Cassandrap642 Print 05 22 26"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-portfolio-raleigh/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/seqkdnfe/rah-raleigh-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134243720203300000",
        "homeName":  "Portfolio - Raleigh",
        "builderName":  "Richmond American Homes",
        "itemid":  "360036",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/seqkdnfe/rah-raleigh-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Raleigh Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ecofydq0/rah-raleigh-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Raleigh Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/dfpdh52k/rah-raleigh-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Raleigh Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/4vyn4xao/rah-raleigh-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Portfolio Raleigh Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/mzgdgz53/raleighp741_print_05_22_26.jpg",
                               "alt":  "Raleighp741 Print 05 22 26"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/taylor-morrison-london/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/0nel5e4e/london-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134268606908470000",
        "homeName":  "Landmark - London",
        "builderName":  "Taylor Morrison",
        "itemid":  "362565",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/0nel5e4e/london-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark London Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/lrobzsw1/london-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark London Elevation C - Craftsman"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/0yslzgvs/london-elevation-e.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark London Elevation E - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/bbtpjekn/005-alamar-landmark-4521-london-main.jpg",
                               "alt":  "005 Alamar Landmark 4521 London Main"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/2sipn2up/005-alamar-landmark-4521-london-exterior-options.jpg",
                               "alt":  "005 Alamar Landmark 4521 London Exterior Options"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/5b2jlx40/005-alamar-landmark-4521-london-interior-options.jpg",
                               "alt":  "005 Alamar Landmark 4521 London Interior Options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/taylor-morrison-madrid/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/yngpstos/madrid-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134268606140100000",
        "homeName":  "Landmark - Madrid",
        "builderName":  "Taylor Morrison",
        "itemid":  "362566",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/yngpstos/madrid-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark Madrid Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/etic4xhv/madrid-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark Madrid Elevation C - Craftsman"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/0bpjr0dr/madrid-elevation-e.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark Madrid Elevation E - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/fftomqwk/005-alamar-landmark-4519-madrid-main.jpg",
                               "alt":  "005 Alamar Landmark 4519 Madrid Main"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/szolbylw/005-alamar-landmark-4519-madrid-exterior-options.jpg",
                               "alt":  "005 Alamar Landmark 4519 Madrid Exterior Options"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/vdkjzdks/005-alamar-landmark-4519-madrid-interior-options.jpg",
                               "alt":  "005 Alamar Landmark 4519 Madrid Interior Options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/taylor-morrison-paris/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/srbdjd0o/paris-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134268607617030000",
        "homeName":  "Landmark - Paris",
        "builderName":  "Taylor Morrison",
        "itemid":  "362567",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/srbdjd0o/paris-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark Paris Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/nq1ax2vm/paris-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark Paris Elevation C - Craftsman"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/wzuem4n5/paris-elevation-e.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark Paris Elevation E - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/h5pcnxjm/005-alamar-landmark-4523-paris-main.jpg",
                               "alt":  "005 Alamar Landmark 4523 Paris Main"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/so4n2m1f/005-alamar-landmark-4523-paris-exterior-options.jpg",
                               "alt":  "005 Alamar Landmark 4523 Paris Exterior Options"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/02jggftm/005-alamar-landmark-4523-paris-interior-options.jpg",
                               "alt":  "005 Alamar Landmark 4523 Paris Interior Options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/taylor-morrison-york/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/qwvjbdia/york-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134268609219570000",
        "homeName":  "Landmark - York",
        "builderName":  "Taylor Morrison",
        "itemid":  "362569",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/qwvjbdia/york-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark York Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/akjbpgz5/york-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark York Elevation C - Craftsman"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/zwvogo4n/york-elevation-e.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Landmark York Elevation E - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/r4oehbfp/005-alamar-landmark-4524-york-main.jpg",
                               "alt":  "005 Alamar Landmark 4524 York Main"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/ap5bcsxn/005-alamar-landmark-4524-york-exterior-options.jpg",
                               "alt":  "005 Alamar Landmark 4524 York Exterior Options"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/1ibp2clx/005-alamar-landmark-4524-york-interior-options.jpg",
                               "alt":  "005 Alamar Landmark 4524 York Interior Options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/taylor-morrison-crossing/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/2hihabwk/crossing-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134268644968800000",
        "homeName":  "Journey - Crossing",
        "builderName":  "Taylor Morrison",
        "itemid":  "362645",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/2hihabwk/crossing-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Crossing Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/uvwfo1gg/crossing-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Crossing Elevation C - Craftsman"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/5fsorbtp/crossing-elevation-e.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Crossing Elevation E - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/30ahq2gz/005-alamar-journey-5524rv-crossing-main.jpg",
                               "alt":  "005 Alamar Journey 5524RV Crossing Main"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/veqll2jj/005-alamar-journey-5524rv-crossing-exterior-options.jpg",
                               "alt":  "005 Alamar Journey 5524RV Crossing Exterior Options"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/3jam2qum/005-alamar-journey-5524rv-crossing-interior-options.jpg",
                               "alt":  "005 Alamar Journey 5524RV Crossing Interior Options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/taylor-morrison-embark/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/zajbgs0e/embark-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134268643777600000",
        "homeName":  "Journey - Embark",
        "builderName":  "Taylor Morrison",
        "itemid":  "362646",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/zajbgs0e/embark-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Embark Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/psjcb0oy/embark-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Embark Elevation C - Craftsman"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/o2gbrtfv/embark-elevation-e.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Embark Elevation E - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/c3xowlm0/005-alamar-journey-5522rv-embark-main.jpg",
                               "alt":  "005 Alamar Journey 5522RV Embark Main"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/cdmphszn/005-alamar-journey-5522rv-embark-exterior-options.jpg",
                               "alt":  "005 Alamar Journey 5522RV Embark Exterior Options"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/odah0ntm/005-alamar-journey-5522rv-embark-interior-options.jpg",
                               "alt":  "005 Alamar Journey 5522RV Embark Interior Options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/taylor-morrison-overland/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/4x4elf5i/overland-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134268646154770000",
        "homeName":  "Journey - Overland",
        "builderName":  "Taylor Morrison",
        "itemid":  "362647",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/4x4elf5i/overland-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Overland Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/eueossx3/overland-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Overland Elevation C - Craftsman"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/rkkokvf5/overland-elevation-e.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Overland Elevation E - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/eb1jsfp4/005-alamar-journey-5528rv-overland-main.jpg",
                               "alt":  "005 Alamar Journey 5528RV Overland Main"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/gkjoybpd/005-alamar-journey-5528rv-overland-exterior-options.jpg",
                               "alt":  "005 Alamar Journey 5528RV Overland Exterior Options"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/oakfnsj5/005-alamar-journey-5528rv-overland-interior-options.jpg",
                               "alt":  "005 Alamar Journey 5528RV Overland Interior Options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/taylor-morrison-cardinal/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/a1sn2wz4/cardinal-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134268646721900000",
        "homeName":  "Journey - Cardinal",
        "builderName":  "Taylor Morrison",
        "itemid":  "362649",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/a1sn2wz4/cardinal-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Cardinal Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/je1ddj4t/cardinal-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Cardinal Elevation C - Craftsman"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/tmbpymmc/cardinal-elevation-e.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Cardinal Elevation E - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/uw5ir32i/005-alamar-journey-5528tg-cardinal-main.jpg",
                               "alt":  "005 Alamar Journey 5528TG Cardinal Main"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/p4aohygt/005-alamar-journey-5528tg-cardinal-exterior-options.jpg",
                               "alt":  "005 Alamar Journey 5528TG Cardinal Exterior Options"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/5zaiojw0/005-alamar-journey-5528tg-cardinal-interior-options.jpg",
                               "alt":  "005 Alamar Journey 5528TG Cardinal Interior Options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/taylor-morrison-compass/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/bi1bk0vl/compass-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134268644393430000",
        "homeName":  "Journey - Compass",
        "builderName":  "Taylor Morrison",
        "itemid":  "362651",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/bi1bk0vl/compass-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Compass Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/hcapipu2/compass-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Compass Elevation C - Craftsman"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/fqoja3lk/compass-elevation-e.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Compass Elevation E - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/aorfumoh/005-alamar-journey-5522tg-compass-main.jpg",
                               "alt":  "005 Alamar Journey 5522TG Compass Main"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/pytabfkw/005-alamar-journey-5522tg-compass-exterior-options.jpg",
                               "alt":  "005 Alamar Journey 5522TG Compass Exterior Options"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/hzamityg/005-alamar-journey-5522tg-compass-interior-options.jpg",
                               "alt":  "005 Alamar Journey 5522TG Compass Interior Options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/taylor-morrison-beacon/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/xdndqk1c/beacon-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134268645584970000",
        "homeName":  "Journey - Beacon",
        "builderName":  "Taylor Morrison",
        "itemid":  "362652",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/xdndqk1c/beacon-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Beacon Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/gcclkhwi/beacon-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Beacon Elevation C - Craftsman"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/pknglgw3/beacon-elevation-e.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Taylor Morrison Alamar Journey Beacon Elevation E - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/jcxmdtlo/005-alamar-journey-5524tg-beacon-main.jpg",
                               "alt":  "005 Alamar Journey 5524TG Beacon Main"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/mweeq0tu/005-alamar-journey-5524tg-beacon-exterior-options.jpg",
                               "alt":  "005 Alamar Journey 5524TG Beacon Exterior Options"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/imyase5a/005-alamar-journey-5524tg-beacon-interior-options.jpg",
                               "alt":  "005 Alamar Journey 5524TG Beacon Interior Options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-sage-indigo/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/cjqe2ucl/indigo-a.jpg?mode=min&quality=80&width=720&rnd=134250548467130000",
        "homeName":  "Highland Sage - Indigo",
        "builderName":  "Brookfield Residential",
        "itemid":  "288724",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/cjqe2ucl/indigo-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Indigo Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/rhjpnh13/indigo-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Indigo Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/bxrnxpnm/indigo-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Indigo Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/vutniq21/highland_sage_indigo.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/xxtb2zm0/highland_sage_indigo_opt.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-77-12563-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/cjqe2ucl/indigo-a.jpg?mode=min&quality=80&width=720&rnd=134250548467130000",
        "homeName":  "Highland Sage - Indigo",
        "builderName":  "Brookfield Residential",
        "itemid":  "351887",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/cjqe2ucl/indigo-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Indigo Elevation A - Spanish Colonial"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/vutniq21/highland_sage_indigo.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/xxtb2zm0/highland_sage_indigo_opt.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-sage-azure/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/gpghh5kx/azure-a.jpg?mode=min&quality=80&width=720&rnd=134250551493430000",
        "homeName":  "Highland Sage - Azure",
        "builderName":  "Brookfield Residential",
        "itemid":  "288725",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/gpghh5kx/azure-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Azure Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/d3xd124a/azure-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Azure Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/5n2fbdch/azure-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Azure Elevation C - Traditional Southwest"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710900/brookfield-residential-sage-azure-model.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Azure model front exterior by Brookfield Residential at Alamar community in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710906/brookfield-residential-alamar-avondale-az-sage-azure-model-great-room.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Azure model great room dining kitchen by Brookfield Residential at Alamar community in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710907/brookfield-residential-alamar-avondale-az-sage-azure-model-family-room.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Azure model family room by Brookfield Residential at Alamar community in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710909/brookfield-residential-alamar-avondale-az-sage-azure-model-dining-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Azure model kitchen by Brookfield Residential at Alamar community in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710908/brookfield-residential-alamar-avondale-az-sage-azure-model-dining.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Azure model dining by Brookfield Residential at Alamar community in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710904/brookfield-residential-alamar-avondale-az-sage-azure-model-primary-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Azure model Primary Bedroom by Brookfield Residential at Alamar community in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710905/brookfield-residential-alamar-avondale-az-sage-azure-model-primary-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Azure model bathroom by Brookfield Residential at Alamar community in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710901/brookfield-residential-alamar-avondale-az-sage-azure-model-secondary-bedroom.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Azure model secondary bedroom by Brookfield Residential at Alamar community in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710902/brookfield-residential-alamar-avondale-az-sage-azure-model-secondary-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Azure model secondary bedroom by Brookfield Residential at Alamar community in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710903/brookfield-residential-alamar-avondale-az-sage-azure-model-rear-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Azure model rear exterior by Brookfield Residential at Alamar community in Avondale, AZ"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/32efnkps/highland_sage_azure.jpg",
                               "alt":  "Sage Azure floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/1gtnm4az/highland_sage_azure_opt.jpg",
                               "alt":  "Sage Azure floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-16-12570-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/rhjpnh13/indigo-b.jpg?mode=min&quality=80&width=720&rnd=134250548635900000",
        "homeName":  "Sage - Indigo",
        "builderName":  "Brookfield Residential",
        "itemid":  "342768",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/rhjpnh13/indigo-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Indigo Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/vutniq21/highland_sage_indigo.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/xxtb2zm0/highland_sage_indigo_opt.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-22-12518-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/rhjpnh13/indigo-b.jpg?mode=min&quality=80&width=720&rnd=134250548635900000",
        "homeName":  "Highland Sage - Indigo",
        "builderName":  "Brookfield Residential",
        "itemid":  "358217",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/rhjpnh13/indigo-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Indigo Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/vutniq21/highland_sage_indigo.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/xxtb2zm0/highland_sage_indigo_opt.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-25-12506-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/rhjpnh13/indigo-b.jpg?mode=min&quality=80&width=720&rnd=134250548635900000",
        "homeName":  "Highland Sage - Indigo",
        "builderName":  "Brookfield Residential",
        "itemid":  "360889",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/rhjpnh13/indigo-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Indigo Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/vutniq21/highland_sage_indigo.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/xxtb2zm0/highland_sage_indigo_opt.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-71-12511-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/bxrnxpnm/indigo-c.jpg?mode=min&quality=80&width=720&rnd=134250548787330000",
        "homeName":  "Highland Sage - Indigo",
        "builderName":  "Brookfield Residential",
        "itemid":  "360168",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/bxrnxpnm/indigo-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Indigo Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/vutniq21/highland_sage_indigo.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/xxtb2zm0/highland_sage_indigo_opt.jpg",
                               "alt":  "Sage Indigo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/pulte-bergamot/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/sa4jyzwn/bergamot-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159710637270000",
        "homeName":  "Meadow - Bergamot",
        "builderName":  "Pulte Homes",
        "itemid":  "351306",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/sa4jyzwn/bergamot-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Bergamot - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/cttbhh1i/bergamot-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Bergamot - Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/zyzhwthx/bergamot-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Bergamot - Elevation C"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/hkgph2db/3514-2-bergamot-1-cm.jpg",
                               "alt":  "Bergamot floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-sage-clover/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/mx2d40cs/clover-a.jpg?mode=min&quality=80&width=720&rnd=134250547889730000",
        "homeName":  "Highland Sage - Clover",
        "builderName":  "Brookfield Residential",
        "itemid":  "288726",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/mx2d40cs/clover-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Clover Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/5neann25/clover-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Clover Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/25jogbfu/clover-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Clover Elevation C - Traditional Southwest"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713742/clover-exterior-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Clover Exterior by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713743/clover-kitchen-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Clover Kitchen by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713744/clover-kitchen-backyard-view-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Clover Kitchen by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713745/clover-kitchen-pantry-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Clover Kitchen Pantry by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713746/clover-great-room-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Clover Great Room by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713747/clover-primary-bath-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Clover Primary Bath by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713748/clover-primary-bed-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Clover Primary Bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713750/clover-bath-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Clover Bath by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713751/clover-laundry-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Clover Laundry Room by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713752/clover-garage-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Clover Garage by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713753/clover-backyard-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Clover Backyard by Brookfield Residential at Alamar in Avondale, AZ"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/3jbnivh4/highland_sage_clover.jpg",
                               "alt":  "Sage Clover floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/rtuho1mx/highland_sage_clover_opt.jpg",
                               "alt":  "Sage Clover floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-ridge-lantana/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/jkujg32g/lantana-a.jpg?mode=min&quality=80&width=720&rnd=134250480153400000",
        "homeName":  "Highland Ridge - Lantana",
        "builderName":  "Brookfield Residential",
        "itemid":  "288750",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/jkujg32g/lantana-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Lantana Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/vu2jsglz/lantana-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Lantana Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/l4qciswa/lantana-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Lantana Elevation C - Traditional Southwest"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713754/highland-ridge-lantana-exterior-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Lantana Exterior by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713755/highland-ridge-lantana-kitchen-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Lantana Kitchen by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713756/highland-ridge-lantana-bedroom-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Lantana Bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713757/highland-ridge-lantana-backyard-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Lantana Bathroom by Brookfield Residential at Alamar in Avondale, AZ"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/q0apapeh/highland_ridge_lantana.jpg",
                               "alt":  "Ridge Lantana floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/robdssck/highland_ridge_lantana_opt.jpg",
                               "alt":  "Ridge Lantana floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/pulte-hummingbird/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/a0xm3vpz/hummingbird-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159710855400000",
        "homeName":  "Meadow - Hummingbird",
        "builderName":  "Pulte Homes",
        "itemid":  "351371",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/a0xm3vpz/hummingbird-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Hummingbird - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/uljhueb5/hummingbird-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Hummingbird - Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/bewlkvx5/hummingbird-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Hummingbird - Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/tnqf1kks/alamar-hummingbird-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Exterior"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/a20j4isa/alamar-hummingbird-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/wccf4mmj/alamar-hummingbird-kitchen-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Kitchen 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/y0lfvgnr/alamar-hummingbird-kitchen-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Kitchen 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/4qom4qz5/alamar-hummingbird-kitchen-4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Kitchen 4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/4zvc4chc/alamar-hummingbird-dining.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Dining"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ad0ne3af/alamar-hummingbird-living.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Living"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/hc2gi1pq/alamar-hummingbird-living-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Living 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/jl1jsafc/alamar-hummingbird-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Bed"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/w3dpmo3c/alamar-hummingbird-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/0lpfdgqf/alamar-hummingbird-bath-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Bath 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/o5bn5gy1/alamar-hummingbird-closet.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Closet"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/hrrjxa3b/alamar-hummingbird-bed-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Bed 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/xi2pt05v/alamar-hummingbird-bed-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Bed 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/wj0pxz0p/alamar-hummingbird-bed-4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Bed 4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/fl3bnftg/alamar-hummingbird-bath-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Bath 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/2xmnxkv3/alamar-hummingbird-laundry.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Hummingbird Laundry"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/4egnt2tg/3516-1-hummingbird-1-cm.jpg",
                               "alt":  "Hummingbird floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-mariposa-acacia/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/x5zdwat4/highland-mariposa-acacia-spanish-colonial.jpg?mode=min&quality=80&width=720&rnd=134250466729800000",
        "homeName":  "Highland Mariposa - Acacia",
        "builderName":  "Brookfield Residential",
        "itemid":  "338773",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/x5zdwat4/highland-mariposa-acacia-spanish-colonial.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Acacia Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ok2dsnrm/highland-mariposa-acacia-arizona-ranch.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Acacia Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/li5etli1/highland-mariposa-acacia-traditional-southwest.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Acacia Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/mxvcmh4s/highland_mariposa_acacia.jpg",
                               "alt":  "Mariposa Acacia floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/zkkpy5mw/highland_mariposa_acacia_opt.jpg",
                               "alt":  "Mariposa Acacia floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/pulte-nectar/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/31wdxjvx/nectar-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159711412170000",
        "homeName":  "Meadow - Nectar",
        "builderName":  "Pulte Homes",
        "itemid":  "351372",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/31wdxjvx/nectar-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Nectar - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/r2ejb3ab/nectar-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Nectar - Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/11ojpufq/nectar-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Nectar - Elevation C"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/chrdic0f/3517-2-nectar-1-cm.jpg",
                               "alt":  "Nectar floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-ridge-laredo/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/0axaze5o/laredo-a.jpg?mode=min&quality=80&width=720&rnd=134250481993100000",
        "homeName":  "Highland Ridge - Laredo",
        "builderName":  "Brookfield Residential",
        "itemid":  "288751",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/0axaze5o/laredo-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Laredo Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/wovjz5d3/laredo-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Laredo Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/kmxnyyx4/laredo-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Laredo Elevation C - Traditional Southwest"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713758/laredo-exterior-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo New Home by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713759/laredo-great-room-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo Great Room by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713760/laredo-kitchen-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo Kitchen by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713761/laredo-dining-room-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo Dining Room by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713762/laredo-dining-office-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo Office by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713763/laredo-desk-workspace-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo Office Nook by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713764/laredo-primary-bedroom-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo Primary Bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713765/laredo-primary-bath-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo Primary Bath by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713766/laredo-secondary-bedroom-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo Secondary Bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713767/laredo-secondary-bedroom-2-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo Secondary Bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713768/laredo-backyard-porch-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo Backyard Porch by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713769/laredo-backyard-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Laredo Backyard Porch by Brookfield Residential at Alamar in Avondale, AZ"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/e4mflxhn/highland_ridge_laredo.jpg",
                               "alt":  "Ridge Laredo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/t21m3mwz/highland_ridge_laredo_opt.jpg",
                               "alt":  "Ridge Laredo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-sage-dakota/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/enao1iw2/dakota-a.jpg?mode=min&quality=80&width=720&rnd=134250546406770000",
        "homeName":  "Highland Sage - Dakota",
        "builderName":  "Brookfield Residential",
        "itemid":  "288738",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/enao1iw2/dakota-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Dakota Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/pzriqduu/dakota-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Dakota Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/2v2haool/dakota-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Dakota Elevation C - Traditional Southwest"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710616/brookfield-residential-sage-dakota-front-exterior-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model front exterior by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710617/brookfield-residential-sage-dakota-dining-kitchen-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model Dining and Kitchen by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710614/brookfield-residential-sage-dakota-greatroom-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model Great Room by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710615/brookfield-residential-sage-dakota-great-room-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model Great Room by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710609/brookfield-residential-sage-dakota-primary-bed-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model Primary Bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710610/brookfield-residential-sage-dakota-primary-bath-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model Primary Bathroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710607/brookfield-residential-sage-dakota-bed-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model secondary bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710618/brookfield-residential-sage-dakota-bedroom-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model secondary bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710612/brookfield-residential-sage-dakota-nursery-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model nursery by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710613/brookfield-residential-sage-dakota-loft-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model Loft by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710611/brookfield-residential-sage-dakota-outdoor-room-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model Outdoor Room by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710608/brookfield-residential-sage-dakota-rear-elevation-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Sage Dakota model rear yard by Brookfield Residential at Alamar in Avondale, AZ"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/35ppd4ic/highland_sage_dakota.jpg",
                               "alt":  "Sage Dakota floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/xocfngjt/highland_sage_dakota_opt.jpg",
                               "alt":  "Sage Dakota floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/pulte-potenza-lot-118-12420-w-jones-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/mtipaaoa/potenza-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159728557900000",
        "homeName":  "Cactus - Potenza",
        "builderName":  "Pulte Homes",
        "itemid":  "354331",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/mtipaaoa/potenza-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Potenza - Elevation A"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/sx2nzuga/4017-1-potenza-1-cm.jpg",
                               "alt":  "Potenza floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/lennar-barbaro/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/tqhbcxcc/lennar-barbaro-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134190946331770000",
        "homeName":  "Barbaro",
        "builderName":  "Lennar",
        "itemid":  "288697",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/tqhbcxcc/lennar-barbaro-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Barbaro - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/t3djacel/lennar-barbaro-elevation-h.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Barbaro - Elevation H"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/1bxfwplj/lennar-barabo-elevationm.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Barbaro - Elevation M"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/2ygkjs0u/azh_discovery_westerngarden_fp_3570_barbaro_mkgt.jpg",
                               "alt":  "AZH Discovery Westerngarden FP 3570 Barbaro MKGT"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/lennar-lot-83-12609-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/tqhbcxcc/lennar-barbaro-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134190946331770000",
        "homeName":  "Barbaro",
        "builderName":  "Lennar",
        "itemid":  "359505",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/tqhbcxcc/lennar-barbaro-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Barbaro - Elevation A"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/2ygkjs0u/azh_discovery_westerngarden_fp_3570_barbaro_mkgt.jpg",
                               "alt":  "AZH Discovery Westerngarden FP 3570 Barbaro MKGT"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/pulte-sunbird/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/g3mpy4ti/sunbird-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159711860500000",
        "homeName":  "Meadow - Sunbird",
        "builderName":  "Pulte Homes",
        "itemid":  "351373",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/g3mpy4ti/sunbird-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Sunbird - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/asthmwry/sunbird-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Sunbird - Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/4lfpv42p/sunbird-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Meadow Sunbird - Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/zjaelhls/alamar-sunbird-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Exterior"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/v3hfmr5n/alamar-sunbird-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/eesccvs4/alamar-sunbird-kitchen-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Kitchen 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ahwbe5jp/alamar-sunbird-kitchen-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Kitchen 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/yvlp0xry/alamar-sunbird-living.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Living"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/2ibbexbv/alamar-sunbird-living-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Living 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/vz1jvofz/alamar-sunbird-dining.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Dining"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/2ylbibup/alamar-sunbird-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Bed"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/yycjapae/alamar-sunbird-bed-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Bed 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/pjwjfc4x/alamar-sunbird-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/hjjfk4oy/alamar-sunbird-closet.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Closet"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/0q2blg3m/alamar-sunbird-office.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Office"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/rsbesamc/alamar-sunbird-bed-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Bed 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/w43nkuwt/alamar-sunbird-bed-4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Bed 4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/0tubiygs/alamar-sunbird-bed-5.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Bed 5"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/jqnf1sot/alamar-sunbird-bath-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Sunbird Bath 2"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/3frh4peu/3519-4-sunbird-1-cm.jpg",
                               "alt":  "Sunbird floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-26-12502-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/5n2fbdch/azure-c.jpg?mode=min&quality=80&width=720&rnd=134250551493730000",
        "homeName":  "Highland Sage - Azure",
        "builderName":  "Brookfield Residential",
        "itemid":  "360891",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/5n2fbdch/azure-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Azure Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/32efnkps/highland_sage_azure.jpg",
                               "alt":  "Sage Azure floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/1gtnm4az/highland_sage_azure_opt.jpg",
                               "alt":  "Sage Azure floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-20-12554-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/mx2d40cs/clover-a.jpg?mode=min&quality=80&width=720&rnd=134250547889730000",
        "homeName":  "Highland Sage - Clover",
        "builderName":  "Brookfield Residential",
        "itemid":  "351883",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/mx2d40cs/clover-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Clover Elevation A - Spanish Colonial"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/3jbnivh4/highland_sage_clover.jpg",
                               "alt":  "Sage Clover floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/rtuho1mx/highland_sage_clover_opt.jpg",
                               "alt":  "Sage Clover floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/pulte-potenza/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/mtipaaoa/potenza-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159728557900000",
        "homeName":  "Cactus - Potenza",
        "builderName":  "Pulte Homes",
        "itemid":  "351381",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/mtipaaoa/potenza-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Potenza - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/wgsb5a4d/potenza-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Potenza - Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/2afheimg/potenza-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Potenza - Elevation C"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/sx2nzuga/4017-1-potenza-1-cm.jpg",
                               "alt":  "Potenza floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-75-12555-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/5neann25/clover-b.jpg?mode=min&quality=80&width=720&rnd=134250547889730000",
        "homeName":  "Highland Sage - Clover",
        "builderName":  "Brookfield Residential",
        "itemid":  "351884",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/5neann25/clover-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Clover Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/3jbnivh4/highland_sage_clover.jpg",
                               "alt":  "Sage Clover floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/rtuho1mx/highland_sage_clover_opt.jpg",
                               "alt":  "Sage Clover floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/lennar-lot-12-12606-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/r2yo5bn5/lennar-lewis-elevationa.jpg?mode=min&quality=80&width=720&rnd=134190947399170000",
        "homeName":  "Lewis",
        "builderName":  "Lennar",
        "itemid":  "359506",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/r2yo5bn5/lennar-lewis-elevationa.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Lewis - Elevation A"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/plkfv02t/azh_discovery_westerngarden_fp_3575_lewis_mkgt.jpg",
                               "alt":  "AZH Discovery Westerngarden FP 3575 Lewis MKGT"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-70-12507-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/5neann25/clover-b.jpg?mode=min&quality=80&width=720&rnd=134250547889730000",
        "homeName":  "Highland Sage - Clover",
        "builderName":  "Brookfield Residential",
        "itemid":  "360892",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/5neann25/clover-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Clover Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/3jbnivh4/highland_sage_clover.jpg",
                               "alt":  "Sage Clover floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/rtuho1mx/highland_sage_clover_opt.jpg",
                               "alt":  "Sage Clover floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-23-12514-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/25jogbfu/clover-c.jpg?mode=min&quality=80&width=720&rnd=134250547889900000",
        "homeName":  "Highland Sage - Clover",
        "builderName":  "Brookfield Residential",
        "itemid":  "358218",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/25jogbfu/clover-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Clover Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/3jbnivh4/highland_sage_clover.jpg",
                               "alt":  "Sage Clover floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/rtuho1mx/highland_sage_clover_opt.jpg",
                               "alt":  "Sage Clover floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-sage-rockrose/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/txobxb0h/rockrose-a.jpg?mode=min&quality=80&width=720&rnd=134250548001630000",
        "homeName":  "Highland Sage - Rockrose",
        "builderName":  "Brookfield Residential",
        "itemid":  "288727",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/txobxb0h/rockrose-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Rockrose Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/f4fjv0zl/rockrose-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Rockrose Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/te1bva5z/rockrose-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Rockrose Elevation C - Traditional Southwest"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713774/rockrose-exterior-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Rockrose Exterior by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713775/rockrose-kitchen-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Rockrose Kitchen by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713776/rockrose-primary-bed-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Rockrose Primary Bed by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713777/rockrose-primary-bath-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Rockrose Primary Bath by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713778/rockrose-backyard-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Rockrose Backyard by Brookfield Residential at Alamar in Avondale, AZ"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/04unxxte/highland_sage_rokerose.jpg",
                               "alt":  "Sage Rockrose floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/jjlaatqh/highland_sage_rokerose_opt.jpg",
                               "alt":  "Sage Rockrose floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-mariposa-ironwood/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/wcclw1f1/highland-mariposa-ironwood-spanish-colonial.jpg?mode=min&quality=80&width=720&rnd=134250461626930000",
        "homeName":  "Highland Mariposa - Ironwood",
        "builderName":  "Brookfield Residential",
        "itemid":  "338776",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/wcclw1f1/highland-mariposa-ironwood-spanish-colonial.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Ironwood Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/c1pazgt0/highland-mariposa-ironwood-arizona-ranch.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Ironwood Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/qmhf4lzc/highland-mariposa-ironwood-traditional-southwest.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Ironwood Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/l2vd2uqb/highland_mariposa_ironwood.jpg",
                               "alt":  "Mariposa Ironwood floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/jnaezt20/highland_mariposa_ironwood_opt.jpg",
                               "alt":  "Mariposa Ironwood floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/lennar-ironwood/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/0nkjmlqg/lennar-ironwood-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134190946875230000",
        "homeName":  "Ironwood",
        "builderName":  "Lennar",
        "itemid":  "288704",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/0nkjmlqg/lennar-ironwood-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Ironwood - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/t3yjfqy0/lennar-ironwood-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Ironwood - Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/5bejm1up/lennar-ironwood-elevation-i.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Ironwood - Elevation I"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/s0ue4xsj/alamar-lennar-ironwood-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Exterior"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/mn0bc2ph/alamar-lennar-ironwood-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/3xihk0b1/alamar-lennar-ironwood-kitchen-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Kitchen 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/og0prmdk/alamar-lennar-ironwood-kitchen-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Kitchen 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/fo3lfnla/alamar-lennar-ironwood-kitchen-4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Kitchen 4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/xazjko3h/alamar-lennar-ironwood-kitchen-5.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Kitchen 5"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/b3nl35tt/alamar-lennar-ironwood-kitchen-6.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Kitchen 6"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/f1tpvraw/alamar-lennar-ironwood-dining.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Dining"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/o4nnf42y/alamar-lennar-ironwood-dining-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Dining 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/if4hcfso/alamar-lennar-ironwood-living.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Living"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/rzspjkmf/alamar-lennar-ironwood-living-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Living 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/n2kjzeuo/alamar-lennar-ironwood-living-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Living 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/5qsnozcs/alamar-lennar-ironwood-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Bed"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/flwdli1u/alamar-lennar-ironwood-bed-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Bed 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/quqdf1ls/alamar-lennar-ironwood-closet.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Closet"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/1ycb0vtc/alamar-lennar-ironwood-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/vcroz2ur/alamar-lennar-ironwood-bath-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Bath 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/mqdhcts1/alamar-lennar-ironwood-bed-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Bed 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/wsxhb3ms/alamar-lennar-ironwood-bath-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Bath 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/cjvecg1v/alamar-lennar-ironwood-bed-4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Bed 4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/sdmngtek/alamar-lennar-ironwood-bed-5.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Bed 5"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/jwxjooem/alamar-lennar-ironwood-bath-4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Bath 4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/gk5phxcg/alamar-lennar-ironwood-laundry.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Laundry"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/2rqbzo4p/alamar-lennar-ironwood-backyard.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Ironwood Backyard"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/yozbzbrk/azh_discovery_westerngarden_fp_3518_ironwood_mkgt.jpg",
                               "alt":  "AZH Discovery Westerngarden FP 3518 Ironwood MKGT"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-197-12427-w-atlantis-way/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/vu2jsglz/lantana-b.jpg?mode=min&quality=80&width=720&rnd=134250480153570000",
        "homeName":  "Highland Ridge - Lantana",
        "builderName":  "Brookfield Residential",
        "itemid":  "352423",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/vu2jsglz/lantana-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Lantana Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/q0apapeh/highland_ridge_lantana.jpg",
                               "alt":  "Ridge Lantana floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/robdssck/highland_ridge_lantana_opt.jpg",
                               "alt":  "Ridge Lantana floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-199-12435-w-atlantis-way/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/jkujg32g/lantana-a.jpg?mode=min&quality=80&width=720&rnd=134250480153400000",
        "homeName":  "Highland Ridge - Lantana",
        "builderName":  "Brookfield Residential",
        "itemid":  "352425",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/jkujg32g/lantana-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Lantana Elevation A - Spanish Colonial"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/q0apapeh/highland_ridge_lantana.jpg",
                               "alt":  "Ridge Lantana floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/robdssck/highland_ridge_lantana_opt.jpg",
                               "alt":  "Ridge Lantana floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-178-12436-w-atlantis-way/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/vu2jsglz/lantana-b.jpg?mode=min&quality=80&width=720&rnd=134250480153570000",
        "homeName":  "Highland Ridge - Lantana",
        "builderName":  "Brookfield Residential",
        "itemid":  "352426",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/vu2jsglz/lantana-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Lantana Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/q0apapeh/highland_ridge_lantana.jpg",
                               "alt":  "Ridge Lantana floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/robdssck/highland_ridge_lantana_opt.jpg",
                               "alt":  "Ridge Lantana floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/lennar-lewis/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/r2yo5bn5/lennar-lewis-elevationa.jpg?mode=min&quality=80&width=720&rnd=134190947399170000",
        "homeName":  "Lewis",
        "builderName":  "Lennar",
        "itemid":  "288709",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/r2yo5bn5/lennar-lewis-elevationa.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Lewis - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/bxgbzfw5/lennar-lewis-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Lewis - Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/k44kk4gm/lennar-lewis-elevation-h.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Lewis - Elevation H"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/plkfv02t/azh_discovery_westerngarden_fp_3575_lewis_mkgt.jpg",
                               "alt":  "AZH Discovery Westerngarden FP 3575 Lewis MKGT"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-alexandrite/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9718281/richmond-american-alamar-alexandritep921-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134061442269130000",
        "homeName":  "Fire Sky - Alexandrite",
        "builderName":  "Richmond American Homes",
        "itemid":  "296652",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9718281/richmond-american-alamar-alexandritep921-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Alexandrite Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9718279/richmond-american-alamar-alexandritep921-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Alexandrite Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9718280/richmond-american-alamar-alexandritep921-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Alexandrite Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9718290/richmond-american-alamar-alexandritep921-floor-plan.jpg",
                               "alt":  "Richmond American Alamar AlexandriteP921 Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/pulte-acerra-lot-121-12408-w-jones-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/kvoltj04/acerra-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159729412070000",
        "homeName":  "Cactus - Acerra",
        "builderName":  "Pulte Homes",
        "itemid":  "354332",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/kvoltj04/acerra-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Acerra - Elevation A"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/lb1dlr5r/4020-1-acerra-1-cm.jpg",
                               "alt":  "Acerra floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-mariposa-agave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/csfjp0xm/highland-mariposa-agave-spanish-colonial.jpg?mode=min&quality=80&width=720&rnd=134250464935670000",
        "homeName":  "Highland Mariposa - Agave",
        "builderName":  "Brookfield Residential",
        "itemid":  "338778",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/csfjp0xm/highland-mariposa-agave-spanish-colonial.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Agave Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/jwilzukd/highland-mariposa-agave-arizona-ranch.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Agave Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/txtp4x0k/highland-mariposa-agave-traditional-southwest.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Agave Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/425pfkco/highland_mariposa_agave.jpg",
                               "alt":  "Mariposa Agave floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/n4xfofsw/highland_mariposa_agave_opt.jpg",
                               "alt":  "Mariposa Agave floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/pulte-acerra-lot-117-12424-w-jones-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/zfkhlmwx/acerra-elevation-b.jpg?mode=min&quality=80&width=720&rnd=134159729263400000",
        "homeName":  "Cactus - Acerra",
        "builderName":  "Pulte Homes",
        "itemid":  "362008",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/zfkhlmwx/acerra-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Acerra - Elevation B"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/lb1dlr5r/4020-1-acerra-1-cm.jpg",
                               "alt":  "Acerra floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-alden/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9717005/richmond-american-alamar-aldenp844-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134061446307170000",
        "homeName":  "Bridle Park - Alden",
        "builderName":  "Richmond American Homes",
        "itemid":  "296646",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9717005/richmond-american-alamar-aldenp844-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Alden Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9717003/richmond-american-alamar-aldenp844-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Alden Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9717004/richmond-american-alamar-aldenp844-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Alden Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9715914/richmond-american-alamar-aldenp844-floor-plan.jpg",
                               "alt":  "richmond american alamar AldenP844 floor plan"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/9715915/richmond-american-alamar-aldenp844-floor-plan-options.jpg",
                               "alt":  "richmond american alamar AldenP844 floor plan options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/pulte-acerra/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/kvoltj04/acerra-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159729412070000",
        "homeName":  "Cactus - Acerra",
        "builderName":  "Pulte Homes",
        "itemid":  "351383",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/kvoltj04/acerra-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Acerra - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/zfkhlmwx/acerra-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Acerra - Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/tnobwfuq/acerra-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Acerra - Elevation C"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/lb1dlr5r/4020-1-acerra-1-cm.jpg",
                               "alt":  "Acerra floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-179-12432-w-atlantis-way/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/0axaze5o/laredo-a.jpg?mode=min&quality=80&width=720&rnd=134250481993100000",
        "homeName":  "Highland Ridge - Laredo",
        "builderName":  "Brookfield Residential",
        "itemid":  "352420",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/0axaze5o/laredo-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Laredo Elevation A - Spanish Colonial"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/e4mflxhn/highland_ridge_laredo.jpg",
                               "alt":  "Ridge Laredo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/t21m3mwz/highland_ridge_laredo_opt.jpg",
                               "alt":  "Ridge Laredo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/pulte-barletta-lot-136-12407-w-jones-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/t11lhrlu/barletta-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159730036230000",
        "homeName":  "Cactus - Barletta",
        "builderName":  "Pulte Homes",
        "itemid":  "354333",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/t11lhrlu/barletta-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Barletta - Elevation A"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/nlxa3aj4/4021-1-barletta-1-cm.jpg",
                               "alt":  "Barletta floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/pulte-barletta-lot-119-12416-w-jones-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/yqgahjne/barletta-elevation-c.jpg?mode=min&quality=80&width=720&rnd=134159729730070000",
        "homeName":  "Cactus - Barletta",
        "builderName":  "Pulte Homes",
        "itemid":  "357806",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/yqgahjne/barletta-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Barletta - Elevation C"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/nlxa3aj4/4021-1-barletta-1-cm.jpg",
                               "alt":  "Barletta floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/pulte-barletta/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/t11lhrlu/barletta-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159730036230000",
        "homeName":  "Cactus - Barletta",
        "builderName":  "Pulte Homes",
        "itemid":  "351385",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/t11lhrlu/barletta-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Barletta - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/qslpu0t2/barletta-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Barletta - Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/yqgahjne/barletta-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Barletta - Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/k2hel1uy/barletta-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Exterior"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/k3qe5kux/barletta-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/pvzflea4/barletta-kitchen2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Kitchen2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/qdomjmw0/barletta-kitchen3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Kitchen3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/glsnxhn5/barletta-kitchen4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Kitchen4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/qltlkoxq/barletta-living.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Living"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/52bdusuz/barletta-living2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Living2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/rifjd1y5/barletta-master.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Master"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/n0pa5gkc/barletta-master-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Master Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/wnyje5rv/barletta-office.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Office"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/5yeiz5xn/barletta-office2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Office2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/gbrpkw1k/barletta-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Bed"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/wldjo1rh/barletta-bed2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Bed2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/n2lnkpmc/barletta-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Barletta Bath"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/nlxa3aj4/4021-1-barletta-1-cm.jpg",
                               "alt":  "Barletta floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/lennar-lot-11-12610-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/ibnbqxd3/lennar-latitude-elevationa.jpg?mode=min&quality=80&width=720&rnd=134190947888300000",
        "homeName":  "Latitude",
        "builderName":  "Lennar",
        "itemid":  "359504",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/ibnbqxd3/lennar-latitude-elevationa.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Latitude - Elevation A"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/04yjgj0t/azh_discovery_westerngarden_fp_3580_latitude_mkgt.jpg",
                               "alt":  "AZH Discovery Westerngarden FP 3580 Latitude MKGT"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-245-12513-w-southgate-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/ok2dsnrm/highland-mariposa-acacia-arizona-ranch.jpg?mode=min&quality=80&width=720&rnd=134250466932000000",
        "homeName":  "Highland Mariposa - Acacia",
        "builderName":  "Brookfield Residential",
        "itemid":  "357808",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/ok2dsnrm/highland-mariposa-acacia-arizona-ranch.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Acacia Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/mxvcmh4s/highland_mariposa_acacia.jpg",
                               "alt":  "Mariposa Acacia floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/zkkpy5mw/highland_mariposa_acacia_opt.jpg",
                               "alt":  "Mariposa Acacia floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-72-12515-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/pzriqduu/dakota-b.jpg?mode=min&quality=80&width=720&rnd=134250546406770000",
        "homeName":  "Highland Sage - Dakota",
        "builderName":  "Brookfield Residential",
        "itemid":  "358220",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/pzriqduu/dakota-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Sage Dakota Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/35ppd4ic/highland_sage_dakota.jpg",
                               "alt":  "Sage Dakota floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/xocfngjt/highland_sage_dakota_opt.jpg",
                               "alt":  "Sage Dakota floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-agate/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9718278/richmond-american-alamar-agatep922-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134061441900530000",
        "homeName":  "Fire Sky - Agate",
        "builderName":  "Richmond American Homes",
        "itemid":  "296649",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9718278/richmond-american-alamar-agatep922-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Agate Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9718276/richmond-american-alamar-agatep922-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Agate Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9718277/richmond-american-alamar-agatep922-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Agate Elevation D"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/plyojmdt/richmond-american-alamar-agatep922-front-street-view.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar Agatep922 Front Street View"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ooygegnc/richmond-american-alamar-agatep922-living-room.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar Agatep922 Living Room"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/n0zo0vgz/richmond-american-alamar-agatep922-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar Agatep922 Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/egklt2qz/richmond-american-alamar-agatep922-office.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar Agatep922 Office"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/hylp2nzh/richmond-american-alamar-agatep922-bedroom.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar Agatep922 Bedroom"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/dguhys10/richmond-american-alamar-agatep922-back-patio.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar Agatep922 Back Patio"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/fnqpc50w/richmond-american-alamar-agatep922-backyard.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar Agatep922 Backyard"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9718289/richmond-american-alamar-agatep922-floor-plan.jpg",
                               "alt":  "Richmond American Alamar AgateP922 Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/pulte-cantania-lot-120-12412-w-jones-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/vdhapmq5/cantania-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159730609300000",
        "homeName":  "Cactus - Cantania",
        "builderName":  "Pulte Homes",
        "itemid":  "357807",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/vdhapmq5/cantania-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Cantania - Elevation A"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/gjdpnpig/4023-1-cantania-1-cm.jpg",
                               "alt":  "Cantania floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/lennar-latitude/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/ibnbqxd3/lennar-latitude-elevationa.jpg?mode=min&quality=80&width=720&rnd=134190947888300000",
        "homeName":  "Latitude",
        "builderName":  "Lennar",
        "itemid":  "288710",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/ibnbqxd3/lennar-latitude-elevationa.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Latitude - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/mxpcqi02/lennar-latitude-elevationl.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Latitude - Elevation I"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/k1ydgsg2/lennar-latitude-elevation-m.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Latitude - Elevation M"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/cshhlvwd/alamar-lennar-latitude-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Exterior"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ybynqxuc/alamar-lennar-latitude-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/izvha31z/alamar-lennar-latitude-kitchen-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Kitchen 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/omjghnoh/alamar-lennar-latitude-kitchen-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Kitchen 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/a5shmic4/alamar-lennar-latitude-living.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Living"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/besfvx4r/alamar-lennar-latitude-living-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Living 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/q3zfqt3s/alamar-lennar-latitude-dining.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Dining"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/wvdhevin/alamar-lennar-latitude-dining-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Dining 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/oznnaey4/alamar-lennar-latitude-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Bed"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/lz3jkj2y/alamar-lennar-latitude-bed-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Bed 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/qn4nvbp5/alamar-lennar-latitude-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ymzhktce/alamar-lennar-latitude-bath-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Bath 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/mtjjkich/alamar-lennar-latitude-closet.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Closet"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/uv4oq04e/alamar-lennar-latitude-bed-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Bed 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/acjdigdq/alamar-lennar-latitude-bed-4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Bed 4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/eu2avb2b/alamar-lennar-latitude-bath-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Bath 3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/tcvhvnqi/alamar-lennar-latitude-laundry.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Laundry"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/zfebhvpj/alamar-lennar-latitude-ng-living.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude NG Living"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/qmgj1dqt/alamar-lennar-latitude-ng-living-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude NG Living 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/akodkvir/alamar-lennar-latitude-ng-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude NG Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/gmxlao50/alamar-lennar-latitude-ng-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude NG Bed"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/kqtjzoyj/alamar-lennar-latitude-ng-bed-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude NG Bed 2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ot3knoxp/alamar-lennar-latitude-ng-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude NG Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/l3wfpxfq/alamar-lennar-latitude-ng-closet.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude NG Closet"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/lidn01ix/alamar-lennar-latitude-backyard.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Alamar Lennar Latitude Backyard"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/04yjgj0t/azh_discovery_westerngarden_fp_3580_latitude_mkgt.jpg",
                               "alt":  "AZH Discovery Westerngarden FP 3580 Latitude MKGT"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/lennar-lot-8-12622-w-odeum-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/k1ydgsg2/lennar-latitude-elevation-m.jpg?mode=min&quality=80&width=720&rnd=134190947996270000",
        "homeName":  "Latitude",
        "builderName":  "Lennar",
        "itemid":  "362813",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/k1ydgsg2/lennar-latitude-elevation-m.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Lennar Latitude - Elevation M"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/04yjgj0t/azh_discovery_westerngarden_fp_3580_latitude_mkgt.jpg",
                               "alt":  "AZH Discovery Westerngarden FP 3580 Latitude MKGT"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-mariposa-lily/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/3fdpxtdo/highland-mariposa-lily-spanish-colonial.jpg?mode=min&quality=80&width=720&rnd=134250459628200000",
        "homeName":  "Highland Mariposa - Lily",
        "builderName":  "Brookfield Residential",
        "itemid":  "338780",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/3fdpxtdo/highland-mariposa-lily-spanish-colonial.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Lily Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/yvldfyqg/highland-mariposa-lily-arizona-ranch.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Lily Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/hqafcno0/highland-mariposa-lily-traditional-southwest.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Lily Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/wpvfno4t/highland_mariposa_lily.jpg",
                               "alt":  "Mariposa Lily floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/eb5k3fkm/highland_mariposa_lily_opt.jpg",
                               "alt":  "Mariposa Lily floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-slate/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9718288/richmond-american-alamar-slatep927-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134061441691870000",
        "homeName":  "Fire Sky - Slate",
        "builderName":  "Richmond American Homes",
        "itemid":  "296650",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9718288/richmond-american-alamar-slatep927-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Slate Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9718286/richmond-american-alamar-slatep927-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Slate Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9718287/richmond-american-alamar-slatep927-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Slate Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9718292/richmond-american-alamar-slatep927-floor-plan.jpg",
                               "alt":  "Richmond American Alamar SlateP927 Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-ridge-ponderosa/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/emjffqio/ponderosa-a.jpg?mode=min&quality=80&width=720&rnd=134250484201700000",
        "homeName":  "Highland Ridge - Ponderosa",
        "builderName":  "Brookfield Residential",
        "itemid":  "288753",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/emjffqio/ponderosa-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Ponderosa Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ffobk5wa/ponderosa-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Ponderosa Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/astfxqhs/ponderosa-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Ponderosa Elevation C - Traditional Southwest"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710648/brookfield-residential-ridge-ponderosa-alamar-avondale-az-front-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model front exterior by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710645/brookfield-residential-ridge-ponderosa-alamar-avondale-az-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model Kitchen by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710646/brookfield-residential-ridge-ponderosa-alamar-avondale-az-kitchen-dining.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model Dining and Kitchen by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710650/brookfield-residential-ridge-ponderosa-alamar-avondale-az-dining-to-family-room.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model Dining and Family Room by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710641/brookfield-residential-ridge-ponderosa-alamar-avondale-az-primary-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model Primary Bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710642/brookfield-residential-ridge-ponderosa-alamar-avondale-az-primary-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model Primary Bath by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710644/brookfield-residential-ridge-ponderosa-alamar-avondale-az-loft.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model Loft by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710647/brookfield-residential-ridge-ponderosa-alamar-avondale-az-gen-x-suite.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model Gen Suite by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710637/brookfield-residential-ridge-ponderosa-alamar-avondale-az-seondary-bedroom.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model secondary bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710639/brookfield-residential-ridge-ponderosa-alamar-avondale-az-secondary-bed-2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710638/brookfield-residential-ridge-ponderosa-alamar-avondale-az-secondary-bed-3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model secondary bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710643/brookfield-residential-ridge-ponderosa-alamar-avondale-az-outdoor-room.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model Outdoor Room by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710640/brookfield-residential-ridge-ponderosa-alamar-avondale-az-rear-elevation.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model rear exterior by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9710649/brookfield-residential-ridge-ponderosa-alamar-avondale-az-family-room.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Ridge Ponderosa model Family Room by Brookfield Residential at Alamar in Avondale, AZ"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/oqfjnciw/highland_ridge_ponderosa.jpg",
                               "alt":  "Ridge Ponderosa floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/oo1obqi3/highland_ridge_ponderosa_opt.jpg",
                               "alt":  "Ridge Ponderosa floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-181-12424-w-atlantis-way/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/wovjz5d3/laredo-b.jpg?mode=min&quality=80&width=720&rnd=134250481993730000",
        "homeName":  "Highland Ridge - Laredo",
        "builderName":  "Brookfield Residential",
        "itemid":  "352421",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/wovjz5d3/laredo-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Laredo Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/e4mflxhn/highland_ridge_laredo.jpg",
                               "alt":  "Ridge Laredo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/t21m3mwz/highland_ridge_laredo_opt.jpg",
                               "alt":  "Ridge Laredo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-198-12431-w-atlantis-way/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/kmxnyyx4/laredo-c.jpg?mode=min&quality=80&width=720&rnd=134250481994030000",
        "homeName":  "Highland Ridge - Laredo",
        "builderName":  "Brookfield Residential",
        "itemid":  "352422",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/kmxnyyx4/laredo-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Laredo Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/e4mflxhn/highland_ridge_laredo.jpg",
                               "alt":  "Ridge Laredo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/t21m3mwz/highland_ridge_laredo_opt.jpg",
                               "alt":  "Ridge Laredo floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/richmond-american-lot-114-12377-w-luxton-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9718281/richmond-american-alamar-alexandritep921-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134061442269130000",
        "homeName":  "Fire Sky - Alexandrite",
        "builderName":  "Richmond American Homes",
        "itemid":  "362820",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9718281/richmond-american-alamar-alexandritep921-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Alexandrite Elevation A"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9718290/richmond-american-alamar-alexandritep921-floor-plan.jpg",
                               "alt":  "Richmond American Alamar AlexandriteP921 Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-raleigh/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/nm5ntygg/raleigh-exterior.jpg?mode=min&quality=80&width=720&rnd=134061457825700000",
        "homeName":  "Bridle Park - Raleigh",
        "builderName":  "Richmond American Homes",
        "itemid":  "296648",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/nm5ntygg/raleigh-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Bridle Park Raleigh Model Home"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9717011/richmond-american-alamar-raleighp741-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Raleigh Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9717009/richmond-american-alamar-raleighp741-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Raleigh Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9717010/richmond-american-alamar-raleighp741-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Raleigh Elevation D"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/bfndnrft/raleigh-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/xa0c4lry/raleigh-kitchen2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Kitchen2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ymykdx15/raleigh-family.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Family"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/1gpjuwse/raleigh-family2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Family2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/5htltpum/raleigh-office.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Office"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ufobcl0a/raleigh-master.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Master"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/lfvn2ufj/raleigh-master2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Master2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/rtncr3b0/raleigh-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/yiilaudu/raleigh-bath2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Bath2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/gdibjukh/raleigh-bath3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Bath3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/5fxnj43n/raleigh-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Bed"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/iw1p0ybf/raleigh-bed2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Bed2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/2kcl4tk2/raleigh-bed3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Bed3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/vlnfmssy/raleigh-laundry.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Laundry"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/bsjd25h0/raleigh-patio.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Patio"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ur1hobxd/raleigh-backyard.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Raleigh Backyard"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9715907/richmond-american-alamar-raleighp741-floor-plan.jpg",
                               "alt":  "richmond american alamar RaleighP741 floor plan"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/9715908/richmond-american-alamar-raleighp741-floor-plan-options.jpg",
                               "alt":  "richmond american alamar RaleighP741 floor plan options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-celeste/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9717008/richmond-american-alamar-celestep243-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134061445747600000",
        "homeName":  "Bridle Park - Celeste",
        "builderName":  "Richmond American Homes",
        "itemid":  "296644",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9717008/richmond-american-alamar-celestep243-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Celeste Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9717006/richmond-american-alamar-celestep243-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Celeste Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9717007/richmond-american-alamar-celestep243-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Celeste Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9715913/richmond-american-alamar-celestep243-floor-plan.jpg",
                               "alt":  "richmond american alamar CelesteP243 floor plan"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/9715912/richmond-american-alamar-celestep243-floor-plan-options.jpg",
                               "alt":  "richmond american alamar CelesteP243 floor plan options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-townsend/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9717014/richmond-american-alamar-townsendp843-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134061443742670000",
        "homeName":  "Bridle Park - Townsend",
        "builderName":  "Richmond American Homes",
        "itemid":  "296647",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9717014/richmond-american-alamar-townsendp843-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Townsend Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9717012/richmond-american-alamar-townsendp843-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Townsend Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9717013/richmond-american-alamar-townsendp843-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Townsend Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9715919/richmond-american-alamar-townsendt843-floor-plan.jpg",
                               "alt":  "richmond american alamar TownsendT843 floor plan"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/9715920/richmond-american-alamar-townsendt843-floor-plan-options.jpg",
                               "alt":  "richmond american alamar TownsendT843 floor plan options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-ridge-heritage/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/wfgddaof/heritage-a.jpg?mode=min&quality=80&width=720&rnd=134250485799200000",
        "homeName":  "Highland Ridge - Heritage",
        "builderName":  "Brookfield Residential",
        "itemid":  "288752",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/wfgddaof/heritage-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Heritage Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ynedsrof/heritage-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Heritage Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/x2df5vie/heritage-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Blossom Rock Highland Ridge Heritage Elevation C - Traditional Southwest"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713770/heritage-exterior-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Heritage Exterior by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713771/heritage-kitchen-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Heritage Kitchen by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713772/heritage-primary-bedroom-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Heritage Primary Bedroom by Brookfield Residential at Alamar in Avondale, AZ"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9713773/heritage-backyard-brookfield-residential-alamar-avondale-az.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Heritage Backyard by Brookfield Residential at Alamar in Avondale, AZ"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/d4aagavg/highland_ridge_heritage.jpg",
                               "alt":  "Ridge Heritage floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/y0ifirwg/highland_ridge_heritage_opt.jpg",
                               "alt":  "Ridge Heritage floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/pulte-cantania/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/vdhapmq5/cantania-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159730609300000",
        "homeName":  "Cactus - Cantania",
        "builderName":  "Pulte Homes",
        "itemid":  "351387",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/vdhapmq5/cantania-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Cantania - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/br2pdiig/cantania-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Cantania - Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/3v0jftos/cantania-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Cantania - Elevation C"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/gjdpnpig/4023-1-cantania-1-cm.jpg",
                               "alt":  "Cantania floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/richmond-american-lot-128-12362-w-luxton-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9718276/richmond-american-alamar-agatep922-elevation-b.jpg?mode=min&quality=80&width=720&rnd=134061442019400000",
        "homeName":  "Fire Sky - Agate",
        "builderName":  "Richmond American Homes",
        "itemid":  "362823",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9718276/richmond-american-alamar-agatep922-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Agate Elevation B"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9718289/richmond-american-alamar-agatep922-floor-plan.jpg",
                               "alt":  "Richmond American Alamar AgateP922 Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/richmond-american-lot-36-12012-w-parkway-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/tikmt4c4/richmond-american-alamar-12012-w-parkway-ln-exterior.jpg?mode=min&quality=80&width=720&rnd=133953269792400000",
        "homeName":  "Bridle Park - Townsend",
        "builderName":  "Richmond American Homes",
        "itemid":  "305661",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/tikmt4c4/richmond-american-alamar-12012-w-parkway-ln-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Exterior"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/hu1fqrlp/richmond-american-alamar-12012-w-parkway-ln-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/xamcwllk/richmond-american-alamar-12012-w-parkway-ln-dining.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Dining"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ug2n22zs/richmond-american-alamar-12012-w-parkway-ln-dining2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Dining2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/livkwudv/richmond-american-alamar-12012-w-parkway-ln-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Bed"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/gyef034w/richmond-american-alamar-12012-w-parkway-ln-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/opnkacbt/richmond-american-alamar-12012-w-parkway-ln-bath2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Bath2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/tvyjxqa0/richmond-american-alamar-12012-w-parkway-ln-closet.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Closet"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/t41f0j5l/richmond-american-alamar-12012-w-parkway-ln-bed2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Bed2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/mcap3r5r/richmond-american-alamar-12012-w-parkway-ln-bath3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Bath3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/20jp01fg/richmond-american-alamar-12012-w-parkway-ln-garage.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Garage"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/gxff3kma/richmond-american-alamar-12012-w-parkway-ln-exterior-rear.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Exterior Rear"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/k3xj4ydi/richmond-american-alamar-12012-w-parkway-ln-exterior-rear2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Exterior Rear2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/xuxj3okx/richmond-american-alamar-12012-w-parkway-ln-exterior-rear3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Alamar 12012 W Parkway Ln Exterior Rear3"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/dpomm0mx/richmond-american-alamar-12012-w-parkway-ln-floorplan.jpg",
                               "alt":  "Richmond American Alamar 12012 W Parkway Ln Floorplan"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/brookfield-residential-mariposa-solstice/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/itflvzbs/highland-mariposa-solstice-spanish-colonial.jpg?mode=min&quality=80&width=720&rnd=134250456877570000",
        "homeName":  "Highland Mariposa - Solstice",
        "builderName":  "Brookfield Residential",
        "itemid":  "338782",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/itflvzbs/highland-mariposa-solstice-spanish-colonial.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Solstice Elevation A - Spanish Colonial"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/gy0g5yek/highland-mariposa-solstice-arizona-ranch.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Solstice Elevation B - Arizona Ranch"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/v0klsm5w/highland-mariposa-solstice-traditional-southwest.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Solstice Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/sx1dazhc/highland_mariposa_solstice.jpg",
                               "alt":  "Mariposa Solstice floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/gexofc1f/highland_mariposa_solstice_opt.jpg",
                               "alt":  "Mariposa Solstice floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-246-12517-w-southgate-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/qmhf4lzc/highland-mariposa-ironwood-traditional-southwest.jpg?mode=min&quality=80&width=720&rnd=134250462019330000",
        "homeName":  "Highland Mariposa - Ironwood",
        "builderName":  "Brookfield Residential",
        "itemid":  "358222",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/qmhf4lzc/highland-mariposa-ironwood-traditional-southwest.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Ironwood Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/l2vd2uqb/highland_mariposa_ironwood.jpg",
                               "alt":  "Mariposa Ironwood floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/jnaezt20/highland_mariposa_ironwood_opt.jpg",
                               "alt":  "Mariposa Ironwood floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-249-12561-w-southgate-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/c1pazgt0/highland-mariposa-ironwood-arizona-ranch.jpg?mode=min&quality=80&width=720&rnd=134250461820230000",
        "homeName":  "Highland Mariposa - Ironwood",
        "builderName":  "Brookfield Residential",
        "itemid":  "358223",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/c1pazgt0/highland-mariposa-ironwood-arizona-ranch.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Ironwood Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/l2vd2uqb/highland_mariposa_ironwood.jpg",
                               "alt":  "Mariposa Ironwood floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/jnaezt20/highland_mariposa_ironwood_opt.jpg",
                               "alt":  "Mariposa Ironwood floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/pulte-cantania-lot-122-12404-w-jones-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/3v0jftos/cantania-elevation-c.jpg?mode=min&quality=80&width=720&rnd=134159730307230000",
        "homeName":  "Cactus - Cantania",
        "builderName":  "Pulte Homes",
        "itemid":  "354334",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/3v0jftos/cantania-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Cantania - Elevation C"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/gjdpnpig/4023-1-cantania-1-cm.jpg",
                               "alt":  "Cantania floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/richmond-american-lot-90-12365-w-parkway-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/xrwcos3u/12365-w-parkway-ln-exterior.jpg?mode=min&quality=80&width=720&rnd=134193462249970000",
        "homeName":  "Fire Sky - Elderberry",
        "builderName":  "Richmond American Homes",
        "itemid":  "337451",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/xrwcos3u/12365-w-parkway-ln-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Exterior"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/1uxp5fuj/12365-w-parkway-ln-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/3myboerh/12365-w-parkway-ln-kitchen2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Kitchen2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/pp2bmzo5/12365-w-parkway-ln-pantry.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Pantry"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ytwpfvl1/12365-w-parkway-ln-pantry2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Pantry2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/qdfm4t5n/12365-w-parkway-ln-living.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Living"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/nkbhinpu/12365-w-parkway-ln-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Bed"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ng1lwz1b/12365-w-parkway-ln-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ocsbci4t/12365-w-parkway-ln-bed2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Bed2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/cclf2kvt/12365-w-parkway-ln-bath2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Bath2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/d4bhs4xp/12365-w-parkway-ln-bath3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Bath3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/1codzgko/12365-w-parkway-ln-bed3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Bed3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/vhdbnpfa/12365-w-parkway-ln-bath4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Bath4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/cmphsaeb/12365-w-parkway-ln-laundry.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Laundry"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/uukbnzvz/12365-w-parkway-ln-patio.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Patio"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/obghapt4/12365-w-parkway-ln-backyard.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Backyard"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/p22pzovc/12365-w-parkway-ln-backyard2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Backyard2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/wxcapwje/12365-w-parkway-ln-backyard3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "12365 W Parkway Ln Backyard3"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/imkfwkr2/12365-w-parkway-ln-floorplan.jpg",
                               "alt":  "12365 W Parkway Ln Floorplan"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/d1gde5wj/12365-w-parkway-ln-floorplan-upstairs.jpg",
                               "alt":  "12365 W Parkway Ln Floorplan Upstairs"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-elderberry/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9718283/richmond-american-alamar-elderberryp966-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134061442635370000",
        "homeName":  "Fire Sky - Elderberry",
        "builderName":  "Richmond American Homes",
        "itemid":  "296651",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9718283/richmond-american-alamar-elderberryp966-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Elderberry Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9718284/richmond-american-alamar-elderberryp966-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Elderberry Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/9718285/richmond-american-alamar-elderberryp966-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Elderberry Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9718291/richmond-american-alamar-elderberryp966-floor-plan.jpg",
                               "alt":  "Richmond American Alamar ElderberryP966 Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/pulte-starling/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/r5sbzch0/starling-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159731159800000",
        "homeName":  "Cactus - Starling",
        "builderName":  "Pulte Homes",
        "itemid":  "351389",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/r5sbzch0/starling-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Starling - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/tqjbzi4z/starling-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Starling - Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/4hjp5xwm/starling-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Starling - Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/lm3hvbpq/starling-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Exterior"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/gm4nezku/starling-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/t1rd34jq/starling-kitchen2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Kitchen2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/yrsgj3ok/starling-living.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Living"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/z3jjbvca/starling-living2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Living2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/xpchcwwp/starling-living3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Living3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/b2iihd22/starling-living4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Living4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/mvjlr41v/starling-dining.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Dining"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/4zhjvmbu/starling-master.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Master"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/4xip4m0c/starling-master-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Master Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/rawlwzpg/starling-upstairs.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Upstairs"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/uhgp5pod/starling-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/2a2cqos2/starling-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Bed"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/kbvjiihi/starling-bed2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Bed2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/uzhjiibi/starling-bed3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Bed3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/j4waiq3x/starling-bed4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Bed4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/aobfm4jf/starling-bath2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Bath2"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/ka3bqveg/4025-1-starling-1-cm.jpg",
                               "alt":  "Starling main floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/gjwjvon4/4025-1-starling-2-cm.jpg",
                               "alt":  "Starling upstairs floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-250-12565-w-southgate-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/txtp4x0k/highland-mariposa-agave-traditional-southwest.jpg?mode=min&quality=80&width=720&rnd=134250465409930000",
        "homeName":  "Highland Mariposa - Agave",
        "builderName":  "Brookfield Residential",
        "itemid":  "358221",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/txtp4x0k/highland-mariposa-agave-traditional-southwest.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Agave Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/425pfkco/highland_mariposa_agave.jpg",
                               "alt":  "Mariposa Agave floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/n4xfofsw/highland_mariposa_agave_opt.jpg",
                               "alt":  "Mariposa Agave floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/pulte-starling-lot-138-12415-w-jones-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/lm3hvbpq/starling-exterior.jpg?mode=min&quality=80&width=720&rnd=134199535824330000",
        "homeName":  "Cactus - Starling",
        "builderName":  "Pulte Homes",
        "itemid":  "362009",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/lm3hvbpq/starling-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Starling Exterior"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/ka3bqveg/4025-1-starling-1-cm.jpg",
                               "alt":  "Starling main floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/gjwjvon4/4025-1-starling-2-cm.jpg",
                               "alt":  "Starling upstairs floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-244-12509-w-southgate-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/txtp4x0k/highland-mariposa-agave-traditional-southwest.jpg?mode=min&quality=80&width=720&rnd=134268604344800000",
        "homeName":  "Highland Mariposa - Agave",
        "builderName":  "Brookfield Residential",
        "itemid":  "362817",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/txtp4x0k/highland-mariposa-agave-traditional-southwest.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Agave Elevation C - Traditional Southwest"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/425pfkco/highland_mariposa_agave.jpg",
                               "alt":  "Mariposa Agave floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/n4xfofsw/highland_mariposa_agave_opt.jpg",
                               "alt":  "Mariposa Agave floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/pulte-starling-lot-137-12411-w-jones-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/tqjbzi4z/starling-elevation-b.jpg?mode=min&quality=80&width=720&rnd=134159731016030000",
        "homeName":  "Cactus - Starling",
        "builderName":  "Pulte Homes",
        "itemid":  "354335",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/tqjbzi4z/starling-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Starling - Elevation B"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/ka3bqveg/4025-1-starling-1-cm.jpg",
                               "alt":  "Starling main floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/gjwjvon4/4025-1-starling-2-cm.jpg",
                               "alt":  "Starling upstairs floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/richmond-american-lot-111-12365-w-luxton-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9718285/richmond-american-alamar-elderberryp966-elevation-d.jpg?mode=min&quality=80&width=720&rnd=134061442871130000",
        "homeName":  "Fire Sky - Elderberry",
        "builderName":  "Richmond American Homes",
        "itemid":  "362825",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9718285/richmond-american-alamar-elderberryp966-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Elderberry Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9718291/richmond-american-alamar-elderberryp966-floor-plan.jpg",
                               "alt":  "Richmond American Alamar ElderberryP966 Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/pulte-visionary/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/xspd3l2g/visionary-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159731741730000",
        "homeName":  "Cactus - Visionary",
        "builderName":  "Pulte Homes",
        "itemid":  "351391",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/xspd3l2g/visionary-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Visionary - Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/o2inmx14/visionary-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Visionary - Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/3s4heisq/visionary-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Visionary - Elevation C"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/430fe41j/4028-3-visionary-1-cm.jpg",
                               "alt":  "Visionary main floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/v3ojthrs/4028-3-visionary-2-cm.jpg",
                               "alt":  "Visionary upstairs floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-248-12557-w-southgate-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/yvldfyqg/highland-mariposa-lily-arizona-ranch.jpg?mode=min&quality=80&width=720&rnd=134250459808470000",
        "homeName":  "Highland Mariposa - Lily",
        "builderName":  "Brookfield Residential",
        "itemid":  "352416",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/yvldfyqg/highland-mariposa-lily-arizona-ranch.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Lily Elevation B - Arizona Ranch"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/wpvfno4t/highland_mariposa_lily.jpg",
                               "alt":  "Mariposa Lily floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/eb5k3fkm/highland_mariposa_lily_opt.jpg",
                               "alt":  "Mariposa Lily floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/richmond-american-lot-127-12366-w-luxton-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9718285/richmond-american-alamar-elderberryp966-elevation-d.jpg?mode=min&quality=80&width=720&rnd=134061442871130000",
        "homeName":  "Fire Sky - Elderberry",
        "builderName":  "Richmond American Homes",
        "itemid":  "362824",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9718285/richmond-american-alamar-elderberryp966-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Elderberry Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9718291/richmond-american-alamar-elderberryp966-floor-plan.jpg",
                               "alt":  "Richmond American Alamar ElderberryP966 Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/richmond-american-lot-113-12373-w-luxton-ln/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9718284/richmond-american-alamar-elderberryp966-elevation-b.jpg?mode=min&quality=80&width=720&rnd=134061442754770000",
        "homeName":  "Fire Sky - Elderberry",
        "builderName":  "Richmond American Homes",
        "itemid":  "359786",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9718284/richmond-american-alamar-elderberryp966-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Fire Sky Elderberry Elevation B"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9718291/richmond-american-alamar-elderberryp966-floor-plan.jpg",
                               "alt":  "Richmond American Alamar ElderberryP966 Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-powell/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/zcrhlq4z/powell-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134152780862570000",
        "homeName":  "Estates - Powell",
        "builderName":  "Richmond American Homes",
        "itemid":  "350757",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/zcrhlq4z/powell-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Powell Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/yych1qbu/powell-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Powell Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/noapqcrg/powell-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Powell Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/qmulbirx/powell-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Powell Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/kcyeuc0r/richmond-american-the-powell-floorplan1.jpg",
                               "alt":  "Richmond American Alamar Powell Floor Plan."
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/jznbb2p3/richmond-american-the-powell-floorplan-options.jpg",
                               "alt":  "Richmond American Alamar Powell Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/pulte-visionary-lot-139-12419-w-jones-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/xspd3l2g/visionary-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134159731741730000",
        "homeName":  "Cactus - Visionary",
        "builderName":  "Pulte Homes",
        "itemid":  "362010",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/xspd3l2g/visionary-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Visionary - Elevation A"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/430fe41j/4028-3-visionary-1-cm.jpg",
                               "alt":  "Visionary main floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/v3ojthrs/4028-3-visionary-2-cm.jpg",
                               "alt":  "Visionary upstairs floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/william-ryan-homes-lot-300-12712-w-corona-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/3s2h1jg5/william-ryan-alamar-12712-w-corona-ave-exterior.jpg?mode=min&quality=80&width=720&rnd=133953212294570000",
        "homeName":  "Camelback",
        "builderName":  "William Ryan Homes",
        "itemid":  "330648",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/3s2h1jg5/william-ryan-alamar-12712-w-corona-ave-exterior.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Exterior"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/cihjiaqh/william-ryan-alamar-12712-w-corona-ave-exterior2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Exterior2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/02ckx2xr/william-ryan-alamar-12712-w-corona-ave-exterior3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Exterior3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/h1mpytnk/william-ryan-alamar-12712-w-corona-ave-family.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Family"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/0d2fwk0j/william-ryan-alamar-12712-w-corona-ave-kitchen.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Kitchen"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/qtmjjgfw/william-ryan-alamar-12712-w-corona-ave-living.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Living"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ziaepgel/william-ryan-alamar-12712-w-corona-ave-living2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Living2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/r53ehmvw/william-ryan-alamar-12712-w-corona-ave-living3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Living3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/nykiki3w/william-ryan-alamar-12712-w-corona-ave-living4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Living4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/5icm1yzt/william-ryan-alamar-12712-w-corona-ave-kitchen2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Kitchen2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/45cbb3wu/william-ryan-alamar-12712-w-corona-ave-kitchen3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Kitchen3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/e5tddxfr/william-ryan-alamar-12712-w-corona-ave-kitchen4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Kitchen4"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/bwsbrxn3/william-ryan-alamar-12712-w-corona-ave-kitchen5.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Kitchen5"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ig2c5y0i/william-ryan-alamar-12712-w-corona-ave-kitchen6.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Kitchen6"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/cz1dedwa/william-ryan-alamar-12712-w-corona-ave-master.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Master"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ctvbeiiz/william-ryan-alamar-12712-w-corona-ave-master2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Master2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/r2pf30tk/william-ryan-alamar-12712-w-corona-ave-master3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Master3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/tzrdx5uq/william-ryan-alamar-12712-w-corona-ave-mbath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Mbath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ggtb5r5a/william-ryan-alamar-12712-w-corona-ave-mbath2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Mbath2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/i12di342/william-ryan-alamar-12712-w-corona-ave-bed.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Bed"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/1kslldkw/william-ryan-alamar-12712-w-corona-ave-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/y04bbl4t/william-ryan-alamar-12712-w-corona-ave-bed2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Bed2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/vz4oxb1d/william-ryan-alamar-12712-w-corona-ave-half-bath.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Half Bath"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/uoabjmzr/william-ryan-alamar-12712-w-corona-ave-entry.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Entry"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/2rfdj4sj/william-ryan-alamar-12712-w-corona-ave-laundry.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Laundry"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ystiax31/william-ryan-alamar-12712-w-corona-ave-family2.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Family2"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/my4jd2ke/william-ryan-alamar-12712-w-corona-ave-family3.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Family3"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/inobxe21/william-ryan-alamar-12712-w-corona-ave-family4.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "William Ryan Alamar 12712 W Corona Ave Family4"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9710714/william-ryan-camelback-floorplan-floor-1-alamar-avondale-az.jpeg",
                               "alt":  "Camelback floorplan floor 1 by William Ryan Homes at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/9710715/william-ryan-camelback-floorplan-floor-2-alamar-avondale-az.jpeg",
                               "alt":  "Camelback floorplan floor 2 by William Ryan Homes at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/9710716/william-ryan-camelback-floorplan-floor-covered-patio-options-alamar-avondale-az.jpeg",
                               "alt":  "Camelback floorplan covered patio options by William Ryan Homes at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/brookfield-residential-lot-247-12553-w-southgate-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/itflvzbs/highland-mariposa-solstice-spanish-colonial.jpg?mode=min&quality=80&width=720&rnd=134268604989370000",
        "homeName":  "Highland Mariposa - Solstice",
        "builderName":  "Brookfield Residential",
        "itemid":  "352417",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/itflvzbs/highland-mariposa-solstice-spanish-colonial.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Brookfield Residential Alamar Highland Mariposa Solstice Elevation A - Spanish Colonial"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/sx1dazhc/highland_mariposa_solstice.jpg",
                               "alt":  "Mariposa Solstice floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/gexofc1f/highland_mariposa_solstice_opt.jpg",
                               "alt":  "Mariposa Solstice floorplan by Brookfield Residential at Alamar in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/pulte-visionary-lot-135-12403-w-jones-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/o2inmx14/visionary-elevation-b.jpg?mode=min&quality=80&width=720&rnd=134159731596900000",
        "homeName":  "Cactus - Visionary",
        "builderName":  "Pulte Homes",
        "itemid":  "354336",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/o2inmx14/visionary-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Pulte Homes Alamar Cactus Visionary - Elevation B"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/430fe41j/4028-3-visionary-1-cm.jpg",
                               "alt":  "Visionary main floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/v3ojthrs/4028-3-visionary-2-cm.jpg",
                               "alt":  "Visionary upstairs floorplan by Pulte Homes in Alamar community in Avondale, AZ"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-deacon/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/tptl4v24/deacon-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134152780645700000",
        "homeName":  "Estates - Deacon",
        "builderName":  "Richmond American Homes",
        "itemid":  "350772",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/tptl4v24/deacon-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Deacon Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/mnlfulwz/deacon-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Deacon Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/j1mlldon/deacon-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Deacon Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/msskexed/deacon-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Deacon Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/sxlf4b1g/richmond-american-the-deacon-floorplan.jpg",
                               "alt":  "Richmond American Alamar Deacon Floor Plan."
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/e4fl22j4/richmond-american-the-deacon-floorplan-options.jpg",
                               "alt":  "Richmond American Alamar Deacon Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/model/richmond-american-darius/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/wfdp2tmg/darius-elevation-a.jpg?mode=min&quality=80&width=720&rnd=134152779941230000",
        "homeName":  "Estates - Darius",
        "builderName":  "Richmond American Homes",
        "itemid":  "350767",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/wfdp2tmg/darius-elevation-a.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Darius Elevation A"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/ct1g1al0/darius-elevation-b.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Darius Elevation B"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/m4xhhp0c/darius-elevation-c.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Darius Elevation C"
                       },
                       {
                           "src":  "https://www.liveatalamar.com/media/u1pl54j0/darius-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Estates Darius Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/14qltl0u/richmond-american-the-darius-floorplan.jpg",
                               "alt":  "Richmond American Alamar Darius Floor Plan."
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/5wgn225i/richmond-american-the-darius-floorplan-options.jpg",
                               "alt":  "Richmond American Alamar Darius Floor Plan."
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/richmond-american-celeste-lot-74-4617-s-119th-dr/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9717007/richmond-american-alamar-celestep243-elevation-d.jpg?mode=min&quality=80&width=720&rnd=134061446127470000",
        "homeName":  "Bridle Park - Celeste",
        "builderName":  "Richmond American Homes",
        "itemid":  "359784",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9717007/richmond-american-alamar-celestep243-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Celeste Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9715913/richmond-american-alamar-celestep243-floor-plan.jpg",
                               "alt":  "richmond american alamar CelesteP243 floor plan"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/9715912/richmond-american-alamar-celestep243-floor-plan-options.jpg",
                               "alt":  "richmond american alamar CelesteP243 floor plan options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/richmond-american-raleigh-lot-75-4621-s-119th-dr/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9717010/richmond-american-alamar-raleighp741-elevation-d.jpg?mode=min&quality=80&width=720&rnd=134061457676170000",
        "homeName":  "Bridle Park - Raleigh",
        "builderName":  "Richmond American Homes",
        "itemid":  "360165",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9717010/richmond-american-alamar-raleighp741-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Raleigh Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9715907/richmond-american-alamar-raleighp741-floor-plan.jpg",
                               "alt":  "richmond american alamar RaleighP741 floor plan"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/9715908/richmond-american-alamar-raleighp741-floor-plan-options.jpg",
                               "alt":  "richmond american alamar RaleighP741 floor plan options"
                           }
                       ]
    },
    {
        "homeLink":  "https://www.liveatalamar.com/homefinder/inventory/richmond-american-raleigh-lot-71-11933-w-marguerite-ave/",
        "thumbnailImage":  "https://www.liveatalamar.com/media/9717010/richmond-american-alamar-raleighp741-elevation-d.jpg?mode=min&quality=80&width=720&rnd=134061457676170000",
        "homeName":  "Bridle Park - Raleigh",
        "builderName":  "Richmond American Homes",
        "itemid":  "360166",
        "photos":  [
                       {
                           "src":  "https://www.liveatalamar.com/media/9717010/richmond-american-alamar-raleighp741-elevation-d.jpg?width=900&mode=min&quality=80&format=jpeg",
                           "alt":  "Richmond American Homes Alamar Bridle Park Raleigh Elevation D"
                       }
                   ],
        "floorplans":  [
                           {
                               "src":  "https://www.liveatalamar.com/media/9715907/richmond-american-alamar-raleighp741-floor-plan.jpg",
                               "alt":  "richmond american alamar RaleighP741 floor plan"
                           },
                           {
                               "src":  "https://www.liveatalamar.com/media/9715908/richmond-american-alamar-raleighp741-floor-plan-options.jpg",
                               "alt":  "richmond american alamar RaleighP741 floor plan options"
                           }
                       ]
    }
]

'@ 



$parsed = $MergedCardsJson | ConvertFrom-Json
$records = @(foreach ($record in $parsed) { $record })

$recordsById = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($record in $records) {
    $itemId = ([string] $record.itemid).Trim()
    if ([string]::IsNullOrWhiteSpace($itemId)) {
        Write-Warning 'Skipping a JSON record without itemid.'
        continue
    }

    if ($recordsById.ContainsKey($itemId)) {
        throw "Duplicate itemid '$itemId' exists in the embedded JSON."
    }

    $recordsById.Add($itemId, $record)
}

Write-Host "Loaded $($recordsById.Count) unique Item IDs from JSON."

$rootPath = 'master:/sitecore/content/BR Land/LiveAtAlamar/Home/Home Options/Homes Data'
$root = Get-Item -Path $rootPath -ErrorAction Stop
$sitecoreItemsById = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# Scan the Sitecore subtree once and index items by Integration ID.
$sitecoreItems = @($root) + @(Get-ChildItem -Path $root.ProviderPath -Recurse)
foreach ($sitecoreItem in $sitecoreItems) {
    $integrationId = ([string] $sitecoreItem.Fields['Integration ID'].Value).Trim()
    if ([string]::IsNullOrWhiteSpace($integrationId)) { continue }

    if ($sitecoreItemsById.ContainsKey($integrationId)) {
        throw "Duplicate Integration ID '$integrationId' exists under '$rootPath'."
    }

    $sitecoreItemsById.Add($integrationId, $sitecoreItem)
}

Write-Host "Indexed $($sitecoreItemsById.Count) Sitecore items by Integration ID."

foreach ($entry in $recordsById.GetEnumerator()) {
    $itemId = $entry.Key
    $record = $entry.Value
    $matchedItem = $null

    if (-not $sitecoreItemsById.TryGetValue($itemId, [ref] $matchedItem)) {
        Write-Warning "No Sitecore item found with Integration ID '$itemId'."
        continue
    }

    if ([string]::IsNullOrWhiteSpace([string] $record.thumbnailImage)) {
        Write-Warning "Record '$itemId' has no thumbnailImage."
        continue
    }

    $thumbnailMediaItem = UploadFile-ToMediaLibrary `
        -IntegrationId $itemId `
        -ResourceUri ([string] $record.thumbnailImage) `
        -MediaLibraryRoot '/sitecore/media library/BR Land/Homes' `
        -AltText ([string] $record.homeName)

    if ($null -eq $thumbnailMediaItem) {
        Write-Warning "Thumbnail image was not imported for '$itemId'."
        continue
    }

    Set-SitecoreImageField `
        -Item $matchedItem `
        -FieldName 'Featured Image' `
        -MediaItem $thumbnailMediaItem
}
