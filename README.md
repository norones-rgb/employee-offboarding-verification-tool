# Employee Offboarding Verification Tool

> **IAM Automation Toolkit · Project 2/5** | Read-only PowerShell evaluation MVP · Synthetic-first design
>
> [**Portfolio directory**](https://github.com/norones-rgb/ad-ldap-exception-risk-analyzer/blob/main/IAM-AUTOMATION-PORTFOLIO.md) · [**Run the demo**](DEMO.md) · [**Sample HTML preview**](docs/fixture-preview.html) · [**Windows/Linux CI**](https://github.com/norones-rgb/employee-offboarding-verification-tool/actions/workflows/ci.yml)
>
> [![Pester CI](https://github.com/norones-rgb/employee-offboarding-verification-tool/actions/workflows/ci.yml/badge.svg)](https://github.com/norones-rgb/employee-offboarding-verification-tool/actions/workflows/ci.yml) · PowerShell 7.2+ · CSV / JSON / offline HTML output


**Read-only PowerShell IAM control validation | MVP v0.1**

Reconcile an authoritative HR termination feed with an Active Directory snapshot, direct group membership evidence, and application entitlement exports. Produce **exception findings and a review matrix** in CSV, JSON, and an offline HTML dashboard. All committed sample identities are **synthetic**.

> This tool identifies observable risks and audit evidence gaps. It does **not** certify that all access has been removed, replace owner sign-off, discover every app or tenant, or perform access remediation.

## Quick start (no AD connection required)

Requirements: PowerShell **7.2+** on Windows, Linux, or macOS. No additional modules for CSV mode.

```powershell
# From the repository directory:
./Invoke-OffboardingVerification.ps1 -Mode Csv -AsOfUtc '2026-11-05T12:00:00Z'
```

The command uses only the synthetic files in `sample-data/` and writes a new timestamped folder under `output/` (ignored by Git). Open its `index.html` locally to view the report. For custom input use:

```powershell
./Invoke-OffboardingVerification.ps1 -Mode Csv `
  -TerminationsPath './private/terminations.csv' `
  -AdUsersPath './private/ad-users.csv' `
  -AdGroupsPath './private/ad-groups.csv' `
  -AppEntitlementsPath './private/app-entitlements.csv' `
  -ConfigPath './config/default.json' `
  -OutputDirectory './private-reports'
```

## What gets checked

- **AD state:** enabled terminated account; missing account (verification gap); HR/AD EmployeeId mismatch; stale AD evidence.
- **AD groups:** retained privileged group memberships; retained nonbaseline group memberships; incomplete or stale group evidence.
- **Applications:** active entitlements; active privileged entitlements; unknown states; stale or missing expected app evidence.
- **Control context:** effective termination cutoff, configurable grace period, and explicitly declared evidence freshness SLA.

See [rule catalog](docs/rules.md) for rule identifiers, severities, and caveats. Findings are *triage suggestions*, not proof of compromise or automatic tickets.

## Data contracts

All timestamps require explicit UTC `Z` or offset, e.g. `2026-11-05T12:00:00Z`. Use the exact CSV header names shown below. Keys are case-insensitive for matching. `SamAccountName` is used to link the HR feed with AD; `EmployeeId` is used for application exports. The AD EmployeeId is an **additional correlation check**.

| Input | Required columns | Notes |
|---|---|---|
| HR terminations | `EmployeeId,SamAccountName,Status,TerminatedAtUtc` | Status `Terminated` or `Scheduled`; only effective terminations beyond grace are evaluated. |
| AD users | `EmployeeId,SamAccountName,Found,Enabled,CollectedAtUtc,GroupEvidenceComplete,GroupCollectedAtUtc` | `Found=True/False`, `Enabled=True/False` for found records. `GroupEvidenceComplete` must reflect actual collection scope. |
| AD groups | `SamAccountName,GroupName` | Direct memberships returned by collector; baseline and privileged group names are configurable. |
| App entitlements | `EmployeeId,Application,Entitlement,State,IsPrivileged,CollectedAtUtc,EvidenceSource` | One row per entitlement. App mappings and statuses must be validated with each app owner. |

**Important:** Missing records are **not** interpreted as removal proof. Only the configured `requiredApplications` generate missing-source findings; other unlisted applications remain outside audit coverage. A group marked complete refers only to the queried AD account and directory scope.

## Optional AD mode (authorized environments only)

On a Windows workstation with RSAT ActiveDirectory module, domain connectivity, and authorized read permissions:

```powershell
./Invoke-OffboardingVerification.ps1 -Mode ActiveDirectory `
  -TerminationsPath './private/terminations.csv' `
  -AppEntitlementsPath './private/app-entitlements.csv' `
  -DomainController 'dc01.example.internal' `
  -OutputDirectory './private-reports'
```

This invokes **`Get-ADUser`** and **`Get-ADPrincipalGroupMembership`** for HR-listed identities only. It does not discover application access. App data must be supplied from authoritative exports and mapped to the `EmployeeId` field. Do not place HR lists, snapshots, results, credentials, tickets, or real account data in GitHub.

If AD lookup fails due to permissions/connectivity, the scan fails rather than treating inaccessible objects as removed. If a group lookup fails for a found user, the results flag incomplete group evidence. Use scoped service identities and review AD/forest coverage with directory owners.

## Config

Edit [`config/default.json`](config/default.json):

- `gracePeriodHours` (default **24**): evaluate only after that interval from HR effective termination timestamp.
- `maxEvidenceAgeHours` (**168**): flag older snapshots as stale.
- `baselineGroups`: group memberships deliberately excluded from residual-group alerts.
- `privilegedGroups`: known privileged group names in this environment (names alone may not be globally unique).
- `requiredApplications`: systems for which you expect a source record for every evaluated employee. **Customize this** before a pilot to avoid false missing-source findings.
- `activeStates` / `inactiveStates`: exact application-export mappings. Unknown values generate findings; treat these as an app-specific policy decision.

Rule configuration is illustrative, not an industry-standard default. No automatic remediation or access approvals are performed.

## Generated artifacts

For each run, `output/offboarding-<UTC>-<id>/` contains:

- `findings.csv`: prioritized, formula-neutralized findings for review.
- `review-matrix.csv`: one row per eligible terminated employee, with finding counts.
- `audit.json`: full findings, summary, and review matrix for downstream ingestion.
- `index.html`: standalone HTML report; all user-controlled text is HTML-encoded and no external assets are loaded.

CSV formula-like values receive an apostrophe prefix. JSON retains raw evidence, so treat **all** generated files as sensitive and protect them with appropriate access controls.

## Tests

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser
Invoke-Pester -Path ./tests -Output Detailed
```

GitHub Actions tests CSV mode on Windows and Linux. AD mode needs an **authorized lab domain** for integration testing; the public CI environment never accesses production AD.

## Repository layout

```text
Invoke-OffboardingVerification.ps1
src/OffboardingVerifier.psm1
config/default.json
sample-data/{terminations,ad-users,ad-groups,app-entitlements}.csv
tests/OffboardingVerifier.Tests.ps1
docs/{architecture,rules,field-mapping,pilot-checklist,security-and-privacy}.md
.github/workflows/ci.yml
```

## Safety and commercial use

This is a public **portfolio demonstration**. All code is read-only with respect to AD. Real HR/personnel records are confidential, and the default public repository must contain **only synthetic data**. Review [security and privacy](docs/security-and-privacy.md) before pilots and [NOTICE](NOTICE) for reuse terms. No open-source license is granted by this repository.