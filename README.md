# Fabric OneLake — Soft-Delete File & Table Restore

Two PowerShell scripts that let you **inventory** and **restore** soft-deleted
files and Delta tables in a Microsoft Fabric lakehouse, using Azure PowerShell
against the OneLake endpoint (`fabric.microsoft.com`).

OneLake retains soft-deleted items for **7 days**. After that they are
permanently removed and cannot be recovered.

## Scripts

| File | Purpose |
| --- | --- |
| `Step1-Connect-And-List-DeletedItems.ps1` | Sign in, review/switch Azure context, list soft-deleted items under `Files/` and/or `Tables/`, export an inventory CSV. |
| `Step2-Restore-DeletedItems.ps1` | Read the inventory CSV (or re-scan), preview, confirm, and restore items via the ADLS Gen2 (HNS) cmdlets. Restoring a deleted folder restores all its descendants. |

## Prerequisites

- Windows PowerShell 7+ (`pwsh`) — Windows PowerShell 5.1 also works.
- Azure PowerShell modules: `Az.Accounts` and `Az.Storage`. Step 1 installs
  `Az.Storage` for the current user if it is missing.
- A user (or service principal) signed in with **write access** to the target
  Fabric workspace / lakehouse.

## Step 1 — Inventory soft-deleted items

```powershell
.\Step1-Connect-And-List-DeletedItems.ps1 `
    -WorkspaceName 'myworkspace' `
    -LakehouseName 'sales' `
    -Scope Both
```

Parameters:

| Name | Required | Description |
| --- | --- | --- |
| `-WorkspaceName` | yes | Fabric workspace display name **or** GUID. If the display name contains characters that violate Azure Storage container naming rules (spaces, uppercase, etc.), the script resolves it to the workspace GUID via the Fabric REST API. |
| `-LakehouseName` | yes | Lakehouse display name **or** GUID. When the workspace is resolved to a GUID, the lakehouse is resolved as well (the data-plane API does not allow mixing friendly names and GUIDs). Omit the `.Lakehouse` suffix. |
| `-Scope` | no | `Files`, `Tables`, or `Both` (default). |
| `-SubPath` | no | Extra sub-path under `Files/`/`Tables/`, e.g. `raw/2026`. |
| `-OutputCsv` | no | Output CSV path. Default: `.\onelake-deleted-inventory.csv`. |
| `-TenantId` | no | Entra tenant ID to sign in to. |

The script will:

1. Install/import `Az.Storage` if needed.
2. Disable WAM sign-in (workaround for `SharedTokenCacheCredential` failures).
3. Sign in to Azure and show an interactive prompt to:
   - **[P]** Proceed with the current context
   - **[A]** Sign in as a different Account
   - **[T]** Switch Tenant
   - **[S]** Switch Subscription
   - **[Q]** Quit
4. Create a OneLake storage context.
5. Enumerate soft-deleted blobs under `<lakehouse>.Lakehouse/Files/` and/or
   `Tables/`. Because OneLake is hierarchical-namespace (HNS) enabled, a
   deleted folder (e.g. a Delta table) is reported as a single entry.
6. Print a summary and write the inventory CSV.

## Step 2 — Restore items

```powershell
.\Step2-Restore-DeletedItems.ps1 `
    -WorkspaceName 'myworkspace' `
    -LakehouseName 'sales' `
    -InventoryCsv .\onelake-deleted-inventory.csv
```

Or, without an inventory file, re-scan and filter on the fly:

```powershell
.\Step2-Restore-DeletedItems.ps1 `
    -WorkspaceName 'myworkspace' `
    -LakehouseName 'sales' `
    -Path 'Tables' -NameLike '*orders*' -Force
```

Parameters:

| Name | Required | Description |
| --- | --- | --- |
| `-WorkspaceName` | yes | Fabric workspace display name or GUID (auto-resolved if needed). |
| `-LakehouseName` | yes | Lakehouse display name or GUID (auto-resolved when workspace is). |
| `-InventoryCsv` | no | CSV produced by Step 1. If omitted, the script re-scans. |
| `-Path` | no | Sub-path to re-scan when no `-InventoryCsv` is provided (e.g. `Tables`). |
| `-NameLike` | no | Wildcard filter on the blob path (e.g. `*orders*`). |
| `-Force` | no | Skip the initial confirmation prompt. |
| `-TenantId` | no | Entra tenant ID. |

The script will:

1. Repeat the sign-in / context review flow from Step 1.
2. Load the inventory (or re-scan with `Get-AzDataLakeGen2DeletedItem`).
3. Preview the items and ask `Proceed with restore? (y/N)` unless `-Force`
   is set. Because the script uses `ShouldProcess`, you will then see a
   second confirmation per item (`[Y] Yes  [A] Yes to All  [N] No ...`) —
   press `A` to restore everything.
4. Restore each item via `Restore-AzDataLakeGen2DeletedItem`. For a deleted
   folder this brings back the entire subtree (Parquet files, `_delta_log`,
   etc.) in one call.
5. Print a restore summary.

## Verifying a restore

```powershell
$ctx = New-AzStorageContext -StorageAccountName 'onelake' `
    -UseConnectedAccount -Endpoint 'fabric.microsoft.com'

Get-AzDataLakeGen2ChildItem `
    -Context $ctx `
    -FileSystem 'myworkspace' `
    -Path 'sales.Lakehouse/Tables/orders' -Recurse |
    Select-Object Path, Length, IsDirectory |
    Format-Table -AutoSize
```

In Fabric you may need to refresh the lakehouse explorer for a restored
table to reappear in the Tables list.

## Troubleshooting

- **`Container name '...' is invalid.` / `FriendlyNameSupportDisabled`**
  Triggered when a workspace or lakehouse display name contains characters
  the OneLake storage endpoint rejects (spaces, uppercase, etc.). Both
  scripts detect this and resolve the names to GUIDs via the Fabric REST
  API automatically. If resolution fails (e.g. the name is ambiguous), pass
  the GUIDs directly via `-WorkspaceName` and `-LakehouseName`.

- **`SharedTokenCacheCredential authentication unavailable. No accounts were
  found in the cache.`**
  Caused by WAM sign-in on recent Az versions. Both scripts disable WAM at
  startup with `Update-AzConfig -EnableLoginByWam $false`. If you previously
  signed in with WAM, run the scripts once — they will reconnect cleanly.

- **No soft-deleted items found, but I just deleted something.**
  Wait a few seconds and re-run. Also confirm the `-WorkspaceName` and
  `-LakehouseName` are correct (try the workspace GUID if the name has
  special characters).

- **`Deleted item not found at path ...`**
  The item was already restored or the 7-day retention window has expired.

- **Permission errors during restore.**
  You need write access on the lakehouse to restore items.

## References

- [Manage OneLake with PowerShell](https://learn.microsoft.com/en-us/fabric/onelake/onelake-powershell)
- [Recover deleted files in OneLake (soft delete)](https://learn.microsoft.com/en-us/fabric/onelake/soft-delete)
- [Disaster recovery and data protection for OneLake](https://learn.microsoft.com/en-us/fabric/onelake/onelake-disaster-recovery)
- [Restore soft-deleted blobs and directories with PowerShell](https://learn.microsoft.com/en-us/azure/storage/blobs/soft-delete-blob-manage)
