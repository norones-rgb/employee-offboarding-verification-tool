# Field mapping for pilot data

Only supply data you're authorized to process. Export to a folder **outside** the public repository, e.g. `C:\IAM-Private\offboarding-inputs\`.

## HR export

- `EmployeeId`: unique, stable, non-recycled HR identifier.
- `SamAccountName`: AD account identifier, must represent the actual account under review. A person with multiple accounts needs multiple rows/mapping work not supplied in this MVP.
- `Status`: `Terminated` or `Scheduled`.
- `TerminatedAtUtc`: authoritative effective time with timezone, e.g. `2026-11-05T12:00:00Z`.

## AD user export

- `EmployeeId`: the AD user object's employeeID attribute; mismatch with HR is flagged.
- `Found`: True/False (not found is different from lookup error).
- `Enabled`: True/False; leave blank only when `Found=False`.
- `CollectedAtUtc`: actual time this AD lookup completed.
- `GroupEvidenceComplete`: True only if group collection succeeded for the account in queried directory scope.
- `GroupCollectedAtUtc`: actual time group evidence was obtained; blank if collection failed.

## Application export

- `EmployeeId`: map to HR ID **before** running verification.
- `Application`: stable system code, e.g. `VPN`, `M365`.
- `Entitlement`: distinct membership/license/role within application; same application may have multiple rows.
- `State`: source status, mapped via config to active or inactive; everything else is unverified.
- `IsPrivileged`: Boolean determined by app owner or entitlement classification.
- `CollectedAtUtc`: collection time, not just file creation time.
- `EvidenceSource`: short export/system/ticket provenance; avoid credentials/secrets.

## Practical caveats

- If an app exports **zero rows** for a user, you cannot assume the account never existed. Configure `requiredApplications` only when a per-user disposition record is expected for that app.
- `Enabled=False` does not prove that all AD tokens, application sessions, cloud identities, or app entitlements were revoked.
- If HR feed has multiple employees using the same `SamAccountName` or shared identities, stop and introduce an approved correlation mapping before relying on this tool.
