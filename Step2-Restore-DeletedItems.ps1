<#
.SYNOPSIS
    Step 2 of OneLake file restore: restore soft-deleted files/tables in a
    Fabric lakehouse using the ADLS Gen2 (HNS) cmdlets.

.DESCRIPTION
    OneLake is hierarchical-namespace (HNS) enabled, so a deleted directory
    (e.g. a Delta table folder) is represented as a single deleted item.
    Calling Restore-AzDataLakeGen2DeletedItem on that folder restores it
    together with all of its descendants (parquet data files, _delta_log,
    etc.) in one operation.

    This script:
      1. Ensures the Az.Storage module is available.
      2. Signs in to Azure and lets you review/switch the active context.
      3. Resolves workspace/lakehouse display names to GUIDs via the Fabric
         REST API when they contain characters that the storage data-plane
         does not accept (spaces, uppercase, etc.).
      4. Creates a OneLake storage context against fabric.microsoft.com.
      5. Sources the list of items to restore from either:
           - the inventory CSV produced by Step 1, or
           - a fresh scan with Get-AzDataLakeGen2DeletedItem.
      6. Optionally filters items by name pattern (-NameLike).
      7. Previews the items, asks for confirmation (unless -Force), then
         restores each one via Restore-AzDataLakeGen2DeletedItem.

    References:
      - https://learn.microsoft.com/en-us/fabric/onelake/soft-delete
      - https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-manage

.PARAMETER WorkspaceName
    Fabric workspace display name or GUID. Auto-resolved to a GUID via the
    Fabric REST API when the display name does not meet Azure Storage
    container naming rules.

.PARAMETER LakehouseName
    Lakehouse display name (without the ".Lakehouse" suffix) or GUID.
    Auto-resolved when the workspace is resolved.

.PARAMETER InventoryCsv
    Path to the CSV produced by Step 1. If omitted, the script will re-scan.

.PARAMETER Path
    When re-scanning (no InventoryCsv), the path under the lakehouse to scan,
    e.g. "Tables" or "Files/raw". Defaults to "" (whole lakehouse).

.PARAMETER NameLike
    Optional wildcard filter applied to the blob/path name (e.g. "*orders*").

.PARAMETER Force
    Skip the confirmation prompt and restore immediately.

.PARAMETER TenantId
    Optional Entra tenant ID for Connect-AzAccount.

.EXAMPLE
    # Restore from the inventory created by Step 1, with confirmation.
    .\Step2-Restore-DeletedItems.ps1 `
        -WorkspaceName 'myworkspace' `
        -LakehouseName 'sales' `
        -InventoryCsv .\onelake-deleted-inventory.csv

.EXAMPLE
    # Re-scan Tables/ and restore everything matching *orders* without prompt.
    .\Step2-Restore-DeletedItems.ps1 `
        -WorkspaceName 'myworkspace' `
        -LakehouseName 'sales' `
        -Path 'Tables' -NameLike '*orders*' -Force
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [string]$LakehouseName,

    [string]$InventoryCsv,

    [string]$Path = '',

    [string]$NameLike,

    [switch]$Force,

    [string]$TenantId
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Module + sign-in
# ---------------------------------------------------------------------------
Write-Host 'Checking Az.Storage module...' -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
    Install-Module Az.Storage -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.Storage -ErrorAction Stop

Write-Host 'Verifying Azure sign-in...' -ForegroundColor Cyan
# Disable WAM sign-in. With WAM enabled on recent Az versions,
# New-AzStorageContext -UseConnectedAccount against the OneLake endpoint can
# fail with "SharedTokenCacheCredential authentication unavailable. No
# accounts were found in the cache." Turning WAM off forces Az.Storage to
# use the Az PowerShell session credential.
try { Update-AzConfig -EnableLoginByWam $false -Scope CurrentUser | Out-Null } catch { }

function Show-AzContextSummary {
    param($Ctx)
    if (-not $Ctx) {
        Write-Host '  (no active Azure context)' -ForegroundColor Yellow
        return
    }
    Write-Host ''
    Write-Host '  Current Azure context:' -ForegroundColor Green
    Write-Host ("    Account      : {0}" -f $Ctx.Account.Id)
    Write-Host ("    Tenant       : {0}" -f $Ctx.Tenant.Id)
    Write-Host ("    Subscription : {0} ({1})" -f $Ctx.Subscription.Name, $Ctx.Subscription.Id)
    Write-Host ("    Environment  : {0}" -f $Ctx.Environment.Name)
    Write-Host ''
}

$ctxAz = Get-AzContext -ErrorAction SilentlyContinue

if ($ctxAz -and $TenantId -and $ctxAz.Tenant.Id -ne $TenantId) {
    Write-Host ("  Current tenant ({0}) does not match -TenantId. Reconnecting..." -f $ctxAz.Tenant.Id) -ForegroundColor Yellow
    Connect-AzAccount -TenantId $TenantId | Out-Null
    $ctxAz = Get-AzContext
}

if (-not $ctxAz) {
    if ($TenantId) { Connect-AzAccount -TenantId $TenantId | Out-Null }
    else           { Connect-AzAccount | Out-Null }
    $ctxAz = Get-AzContext
}

while ($true) {
    Show-AzContextSummary -Ctx $ctxAz

    Write-Host '  Choose an action:' -ForegroundColor Cyan
    Write-Host '    [P] Proceed with this context'
    Write-Host '    [A] Sign in as a different Account'
    Write-Host '    [T] Switch Tenant (re-prompt for tenant)'
    Write-Host '    [S] Switch Subscription (within current tenant)'
    Write-Host '    [Q] Quit'
    $choice = Read-Host 'Selection (default P)'
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = 'P' }

    switch ($choice.ToUpper()) {
        'P' { break }
        'A' {
            Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null
            Clear-AzContext -Force -ErrorAction SilentlyContinue
            Connect-AzAccount | Out-Null
            $ctxAz = Get-AzContext
        }
        'T' {
            $newTenant = Read-Host 'Enter tenant ID (or domain)'
            if ($newTenant) {
                Connect-AzAccount -TenantId $newTenant | Out-Null
                $ctxAz = Get-AzContext
            }
        }
        'S' {
            $subs = Get-AzSubscription -TenantId $ctxAz.Tenant.Id -ErrorAction SilentlyContinue
            if (-not $subs) {
                Write-Host '  No subscriptions visible in this tenant.' -ForegroundColor Yellow
                continue
            }
            for ($i = 0; $i -lt $subs.Count; $i++) {
                Write-Host ("    [{0}] {1} ({2})" -f $i, $subs[$i].Name, $subs[$i].Id)
            }
            $idx = Read-Host 'Pick subscription index'
            if ($idx -match '^\d+$' -and [int]$idx -lt $subs.Count) {
                Set-AzContext -SubscriptionId $subs[[int]$idx].Id | Out-Null
                $ctxAz = Get-AzContext
            }
        }
        'Q' { throw 'Aborted by user before sign-in confirmation.' }
        default { Write-Host '  Invalid choice.' -ForegroundColor Yellow }
    }
    if ($choice.ToUpper() -eq 'P') { break }
}

Write-Host ("  Using: {0} | tenant {1}" -f $ctxAz.Account.Id, $ctxAz.Tenant.Id) -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Resolve workspace name -> GUID if needed
# ---------------------------------------------------------------------------
# OneLake uses the workspace name as the storage container / ADLS Gen2
# filesystem. Azure Storage container names must be all lower case, 3-63
# chars, no spaces. Fabric workspace display names allow spaces and mixed
# case, so when the display name doesn't satisfy those rules we resolve it
# to the workspace GUID via the Fabric REST API.
function Test-IsGuid {
    param([string]$Value)
    return [Guid]::TryParse($Value, [ref]([Guid]::Empty))
}

function Test-IsValidContainerName {
    param([string]$Value)
    return $Value -cmatch '^[a-z0-9](?:[a-z0-9]|-(?!-)){1,61}[a-z0-9]$'
}

function Get-FabricAccessToken {
    $tokenObj = Get-AzAccessToken -ResourceUrl 'https://api.fabric.microsoft.com' -ErrorAction Stop
    if ($tokenObj.Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $tokenObj.Token).Password
    }
    return $tokenObj.Token
}

function Resolve-FabricWorkspaceId {
    param([string]$DisplayName, [string]$AccessToken)
    $headers = @{ Authorization = "Bearer $AccessToken" }
    $uri = 'https://api.fabric.microsoft.com/v1/workspaces'
    $found = @()
    while ($uri) {
        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
        $found += @($resp.value | Where-Object { $_.displayName -eq $DisplayName })
        $uri = $resp.continuationUri
    }
    if ($found.Count -eq 0) {
        throw "Fabric workspace '$DisplayName' was not found for the current user."
    }
    if ($found.Count -gt 1) {
        throw "Multiple Fabric workspaces named '$DisplayName' were found. Pass the workspace GUID directly via -WorkspaceName."
    }
    return $found[0].id
}

function Resolve-FabricLakehouseId {
    param([string]$WorkspaceId, [string]$DisplayName, [string]$AccessToken)
    $headers = @{ Authorization = "Bearer $AccessToken" }
    $uri = "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/lakehouses"
    $found = @()
    while ($uri) {
        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
        $found += @($resp.value | Where-Object { $_.displayName -eq $DisplayName })
        $uri = $resp.continuationUri
    }
    if ($found.Count -eq 0) {
        throw "Lakehouse '$DisplayName' was not found in workspace $WorkspaceId."
    }
    if ($found.Count -gt 1) {
        throw "Multiple lakehouses named '$DisplayName' were found. Pass the lakehouse GUID directly via -LakehouseName."
    }
    return $found[0].id
}

$WorkspaceId = $WorkspaceName
$LakehouseId = $LakehouseName
$useGuids    = $false
if (-not (Test-IsGuid $WorkspaceName) -and -not (Test-IsValidContainerName $WorkspaceName)) {
    Write-Host ("Resolving workspace '{0}' to its GUID via the Fabric API..." -f $WorkspaceName) -ForegroundColor Cyan
    $token = Get-FabricAccessToken
    $WorkspaceId = Resolve-FabricWorkspaceId -DisplayName $WorkspaceName -AccessToken $token
    Write-Host ("  Workspace ID: {0}" -f $WorkspaceId) -ForegroundColor Green

    if (-not (Test-IsGuid $LakehouseName)) {
        Write-Host ("Resolving lakehouse '{0}' to its GUID..." -f $LakehouseName) -ForegroundColor Cyan
        $LakehouseId = Resolve-FabricLakehouseId -WorkspaceId $WorkspaceId -DisplayName $LakehouseName -AccessToken $token
        Write-Host ("  Lakehouse ID: {0}" -f $LakehouseId) -ForegroundColor Green
    }
    $useGuids = $true
}

# ---------------------------------------------------------------------------
# 3. OneLake context
# ---------------------------------------------------------------------------
# OneLake is addressed as the storage account "onelake" on the
# fabric.microsoft.com endpoint. The current Az PowerShell sign-in is used
# for authentication via -UseConnectedAccount.
Write-Host 'Creating OneLake storage context...' -ForegroundColor Cyan
$ctx = New-AzStorageContext `
    -StorageAccountName 'onelake' `
    -UseConnectedAccount `
    -Endpoint 'fabric.microsoft.com'

# Lakehouse items in OneLake are addressed as "<name>.Lakehouse" with
# friendly names, or just "<itemGuid>" with GUIDs.
$itemRoot = if ($useGuids) { $LakehouseId } else { "$LakehouseName.Lakehouse" }

# ---------------------------------------------------------------------------
# 4. Source the list of items to restore
# ---------------------------------------------------------------------------
$targets = New-Object System.Collections.Generic.List[object]

if ($InventoryCsv) {
    if (-not (Test-Path $InventoryCsv)) {
        throw "Inventory CSV not found: $InventoryCsv"
    }
    Write-Host ("Reading inventory: {0}" -f $InventoryCsv) -ForegroundColor Cyan
    $rows = Import-Csv -Path $InventoryCsv
    foreach ($r in $rows) {
        # Step 1 writes BlobName as the path relative to the workspace
        # (filesystem) root, e.g. "<lakehouse>.Lakehouse/Tables/<table_name>".
        # That is exactly the shape Get-/Restore-AzDataLakeGen2DeletedItem
        # expects for -Path, so we keep it as-is.
        $targets.Add([pscustomobject]@{
            Path        = $r.BlobName
            Scope       = $r.Scope
            DeletedTime = $r.DeletedTime
            DaysLeft    = $r.RemainingDaysBeforePermDelete
        })
    }
} else {
    $scanPath = if ($Path) { "$itemRoot/$($Path.Trim('/'))" } else { $itemRoot }
    Write-Host ("Re-scanning for deleted items under: {0}/{1}" -f $WorkspaceId, $scanPath) -ForegroundColor Cyan

    $deleted = Get-AzDataLakeGen2DeletedItem `
        -Context $ctx `
        -FileSystem $WorkspaceId `
        -Path $scanPath

    foreach ($d in $deleted) {
        $targets.Add([pscustomobject]@{
            Path        = $d.Path
            Scope       = if ($d.Path -match '/Tables/') { 'Tables' } else { 'Files' }
            DeletedTime = $d.DeletedOn
            DaysLeft    = $d.RemainingRetentionDays
        })
    }
}

if ($NameLike) {
    $targets = @($targets | Where-Object { $_.Path -like $NameLike })
}

if ($targets.Count -eq 0) {
    Write-Host 'No items to restore.' -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# 5. Preview + confirm
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ("Items to restore ({0}):" -f $targets.Count) -ForegroundColor Yellow
$targets | Format-Table Scope, Path, DeletedTime, DaysLeft -AutoSize

if (-not $Force) {
    $answer = Read-Host 'Proceed with restore? (y/N)'
    if ($answer -notmatch '^(y|yes)$') {
        Write-Host 'Aborted by user.' -ForegroundColor Yellow
        return
    }
}

# ---------------------------------------------------------------------------
# 6. Restore
# ---------------------------------------------------------------------------
$results = New-Object System.Collections.Generic.List[object]

foreach ($t in $targets) {
    if (-not $PSCmdlet.ShouldProcess($t.Path, 'Restore-AzDataLakeGen2DeletedItem')) { continue }

    Write-Host ("Restoring: {0}" -f $t.Path) -ForegroundColor Cyan
    try {
        # Look up the live deleted-item object for this path and pipe it into
        # Restore-AzDataLakeGen2DeletedItem. The object carries the internal
        # deletion identifier that the cmdlet needs; we do not pass it
        # explicitly. If nothing comes back, the item has already been
        # restored or the 7-day retention has expired.
        $deletedItem = Get-AzDataLakeGen2DeletedItem `
            -Context $ctx `
            -FileSystem $WorkspaceId `
            -Path $t.Path `
            -ErrorAction Stop | Select-Object -First 1

        if (-not $deletedItem) {
            throw "Deleted item not found at path '$($t.Path)'. It may already be restored or expired."
        }

        $restored = $deletedItem | Restore-AzDataLakeGen2DeletedItem -ErrorAction Stop

        $results.Add([pscustomobject]@{
            Path    = $t.Path
            Status  = 'Restored'
            Details = $restored.Path
        })
        Write-Host '  OK' -ForegroundColor Green
    }
    catch {
        $results.Add([pscustomobject]@{
            Path    = $t.Path
            Status  = 'Failed'
            Details = $_.Exception.Message
        })
        Write-Warning ("  FAILED: {0}" -f $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'Restore summary:' -ForegroundColor Cyan
$results | Format-Table -AutoSize

$ok   = ($results | Where-Object Status -eq 'Restored').Count
$fail = ($results | Where-Object Status -eq 'Failed').Count
Write-Host ("Restored: {0}   Failed: {1}" -f $ok, $fail) -ForegroundColor Green
