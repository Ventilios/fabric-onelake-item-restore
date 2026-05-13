<#
.SYNOPSIS
    Step 1 of OneLake file restore: authenticate to OneLake and inventory
    soft-deleted tables/files in a Fabric workspace + lakehouse.

.DESCRIPTION
    OneLake retains soft-deleted files for 7 days before permanent removal.
    This script:
      1. Ensures the Az.Storage PowerShell module is available.
      2. Signs in to Azure and lets you interactively review/switch the
         account, tenant, or subscription before proceeding.
      3. Creates a OneLake storage context against the fabric.microsoft.com
         endpoint using the connected Az PowerShell credential.
      4. Lists soft-deleted blobs under the specified lakehouse path
         (Files/ and/or Tables/). Because OneLake uses a hierarchical
         namespace, a deleted folder (e.g. a Delta table) is reported as a
         single deleted item; its descendants are restored together in Step 2.
      5. Exports the inventory to CSV so Step 2 can consume it for restore.

    References:
      - https://learn.microsoft.com/en-us/fabric/onelake/onelake-powershell
      - https://learn.microsoft.com/en-us/fabric/onelake/soft-delete
      - https://learn.microsoft.com/en-us/fabric/onelake/onelake-disaster-recovery

.PARAMETER WorkspaceName
    Fabric workspace name, which OneLake exposes as the storage "container" /
    ADLS Gen2 filesystem. If the workspace name contains characters that
    violate Azure Storage naming rules, pass the workspace GUID instead.

.PARAMETER LakehouseName
    Lakehouse item name without the ".Lakehouse" suffix. The script appends
    ".Lakehouse" automatically (e.g. "sales" -> "sales.Lakehouse").

.PARAMETER Scope
    Which sub-path under the lakehouse to scan. One of: Files, Tables, Both.
    Default: Both.

.PARAMETER SubPath
    Optional additional sub-path filter (e.g. "raw/2026") appended after
    Files/ or Tables/.

.PARAMETER OutputCsv
    Path to write the soft-deleted inventory CSV. Default:
    .\onelake-deleted-inventory.csv

.PARAMETER TenantId
    Optional Entra tenant ID for Connect-AzAccount.

.EXAMPLE
    .\Step1-Connect-And-List-DeletedItems.ps1 `
        -WorkspaceName 'myworkspace' `
        -LakehouseName 'sales' `
        -Scope Both
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [Parameter(Mandatory = $true)]
    [string]$LakehouseName,

    [ValidateSet('Files', 'Tables', 'Both')]
    [string]$Scope = 'Both',

    [string]$SubPath,

    [string]$OutputCsv = (Join-Path $PSScriptRoot 'onelake-deleted-inventory.csv'),

    [string]$TenantId
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1. Ensure Az.Storage module is available
# ---------------------------------------------------------------------------
Write-Host 'Checking Az.Storage module...' -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
    Write-Host '  Az.Storage not found. Installing for current user...' -ForegroundColor Yellow
    Install-Module Az.Storage -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.Storage -ErrorAction Stop

# ---------------------------------------------------------------------------
# 2. Sign in to Azure (interactive context review)
# ---------------------------------------------------------------------------
Write-Host 'Verifying Azure sign-in...' -ForegroundColor Cyan

# Disable WAM (Web Account Manager) sign-in. When WAM is enabled on recent
# Az versions, New-AzStorageContext -UseConnectedAccount against the OneLake
# endpoint can fail with "SharedTokenCacheCredential authentication
# unavailable. No accounts were found in the cache." Turning WAM off forces
# Az.Storage to use the Az PowerShell session credential, which works.
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

# If TenantId was passed explicitly and doesn't match, force reconnect.
if ($ctxAz -and $TenantId -and $ctxAz.Tenant.Id -ne $TenantId) {
    Write-Host ("  Current tenant ({0}) does not match -TenantId. Reconnecting..." -f $ctxAz.Tenant.Id) -ForegroundColor Yellow
    Connect-AzAccount -TenantId $TenantId | Out-Null
    $ctxAz = Get-AzContext
}

# No context at all -> must sign in.
if (-not $ctxAz) {
    if ($TenantId) { Connect-AzAccount -TenantId $TenantId | Out-Null }
    else           { Connect-AzAccount | Out-Null }
    $ctxAz = Get-AzContext
}

# Interactive review loop.
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
# 3. Build OneLake storage context
# ---------------------------------------------------------------------------
# OneLake is exposed as a storage account named "onelake" on the
# fabric.microsoft.com endpoint. -UseConnectedAccount passes the current Az
# PowerShell sign-in through to the data-plane calls below.
Write-Host 'Creating OneLake storage context...' -ForegroundColor Cyan
$ctx = New-AzStorageContext `
    -StorageAccountName 'onelake' `
    -UseConnectedAccount `
    -Endpoint 'fabric.microsoft.com'

# ---------------------------------------------------------------------------
# 4. Compose paths and enumerate soft-deleted blobs
# ---------------------------------------------------------------------------
# In OneLake, the lakehouse item is addressed as "<name>.Lakehouse" and lives
# directly under the workspace (filesystem) root. User data sits under
# Files/ (unstructured) and Tables/ (Delta tables).
$itemRoot = "$LakehouseName.Lakehouse"

$scanPaths = @()
switch ($Scope) {
    'Files'  { $scanPaths += "$itemRoot/Files/" }
    'Tables' { $scanPaths += "$itemRoot/Tables/" }
    'Both'   {
        $scanPaths += "$itemRoot/Files/"
        $scanPaths += "$itemRoot/Tables/"
    }
}

if ($SubPath) {
    $scanPaths = $scanPaths | ForEach-Object { ($_ + $SubPath.TrimStart('/')).TrimEnd('/') + '/' }
}

$inventory = New-Object System.Collections.Generic.List[object]

foreach ($prefix in $scanPaths) {
    Write-Host ("Scanning soft-deleted items under: {0}/{1}" -f $WorkspaceName, $prefix) -ForegroundColor Cyan

    # -IncludeDeleted returns both active and soft-deleted blobs; we filter
    # to just the deleted ones via IsDeleted. On HNS-enabled OneLake, a
    # deleted folder appears as a single entry (the folder itself); its
    # descendants are recovered together when the folder is restored.
    try {
        $blobs = Get-AzStorageBlob `
            -Container $WorkspaceName `
            -Context $ctx `
            -Prefix $prefix `
            -IncludeDeleted `
            -ErrorAction Stop |
            Where-Object { $_.IsDeleted }
    }
    catch {
        Write-Warning ("  Failed to list under '{0}': {1}" -f $prefix, $_.Exception.Message)
        continue
    }

    foreach ($b in $blobs) {
        $inventory.Add([pscustomobject]@{
            Workspace                     = $WorkspaceName
            Lakehouse                     = $LakehouseName
            Scope                         = if ($prefix -match '/Tables/') { 'Tables' } else { 'Files' }
            BlobName                      = $b.Name
            DeletedTime                   = $b.DeletedTime
            RemainingDaysBeforePermDelete = $b.RemainingDaysBeforePermanentDelete
            LengthBytes                   = $b.Length
            SnapshotTime                  = $b.SnapshotTime
            VersionId                     = $b.VersionId
        })
    }

    Write-Host ("  Found {0} soft-deleted blob(s)." -f $blobs.Count) -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 5. Summary + export
# ---------------------------------------------------------------------------
if ($inventory.Count -eq 0) {
    Write-Host 'No soft-deleted items found in the requested scope.' -ForegroundColor Yellow
    return
}

Write-Host ''
Write-Host ("Total soft-deleted items: {0}" -f $inventory.Count) -ForegroundColor Green
$inventory |
    Sort-Object DeletedTime -Descending |
    Select-Object Scope, BlobName, DeletedTime, RemainingDaysBeforePermDelete, LengthBytes |
    Format-Table -AutoSize

$inventory | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
Write-Host ("Inventory exported to: {0}" -f $OutputCsv) -ForegroundColor Green
Write-Host 'Review the CSV, then run Step 2 to restore selected items.' -ForegroundColor Cyan
