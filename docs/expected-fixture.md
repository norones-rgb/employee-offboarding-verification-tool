# Synthetic fixture expectations

Run the synthetic example at `2026-11-05T12:00:00Z`, using `config/default.json`.

| Metric | Expected |
|---|---:|
| HR records | 11 |
| Eligible terminations past 24-hour grace period | 9 |
| Pending / not-yet-due records | 2 |
| Accounts with one or more findings | 7 |
| Total findings | 15 |
| Critical / High / Medium | 3 / 5 / 7 |

| Employee | Synthetic scenario | Rules expected |
|---|---|---|
| EMP001 | Disabled AD, baseline groups, deprovisioned apps | None |
| EMP002 | Enabled AD, VPN and M365 active | `AD-ENABLED`, 2 × `APP-ACTIVE` |
| EMP003 | Retained privileged AD group and app entitlement | `AD-PRIVILEGED-GROUP`, `APP-PRIVILEGED-ACTIVE` |
| EMP004 | Retained nonbaseline AD group | `AD-RESIDUAL-GROUP` |
| EMP005 | AD account not found; VPN missing; unknown M365 state | `AD-NOT-FOUND`, `APP-EVIDENCE-MISSING`, `APP-STATE-UNKNOWN` |
| EMP006 | Stale AD/app evidence, group evidence incomplete, VPN active | 2 × `EVIDENCE-STALE`, `AD-GROUP-EVIDENCE-MISSING`, `APP-ACTIVE` |
| EMP007 | Scheduled future termination | Skipped |
| EMP008 | Effective timestamp after selected audit cutoff | Skipped |
| EMP009 | HR ↔ AD employee ID mismatch | `AD-IDENTITY-MISMATCH` |
| EMP010 | Disabled AD, baseline groups, revoked apps | None |
| EMP011 | Unknown VPN status | `APP-STATE-UNKNOWN` |

These are static expectations, not a claim that the PowerShell runtime passed. Run Pester and GitHub Actions in the newly published repository to validate the implementation.
