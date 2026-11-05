# Detection rules (v0.1)

| Rule ID | Severity | Condition | Typical response |
|---|---|---|---|
| `AD-EVIDENCE-MISSING` | Medium | No AD row for an eligible HR identity | Recollect directory evidence. |
| `AD-NOT-FOUND` | Medium | Query explicitly returned no matching AD account | Verify account correlation/domain and disposition. |
| `AD-IDENTITY-MISMATCH` | High | AD EmployeeId missing or different from HR EmployeeId | Reconcile identifiers before sign-off. |
| `AD-ENABLED` | Critical | AD account still enabled after grace | Escalate to approved disablement workflow. |
| `AD-GROUP-EVIDENCE-MISSING` | Medium | AD membership collection unsuccessful or incomplete | Collect direct memberships and record scope. |
| `AD-PRIVILEGED-GROUP` | Critical | Listed privileged AD group still present | Investigate privileged membership and owner approval. |
| `AD-RESIDUAL-GROUP` | High | Group neither privileged nor baseline | Review for unnecessary retained access. |
| `APP-EVIDENCE-MISSING` | Medium | Required app lacks any entitlement record for employee | Obtain owner evidence; do not assume absence means revoked. |
| `APP-PRIVILEGED-ACTIVE` | Critical | Privileged application entitlement in configured active state | Escalate via application-owner process. |
| `APP-ACTIVE` | High | Regular app entitlement in configured active state | Confirm approved revocation and retention rules. |
| `APP-STATE-UNKNOWN` | Medium | App state not mapped to active or inactive states | Confirm state semantics with app owner. |
| `EVIDENCE-STALE` | Medium | AD, group, or app snapshot older than maximum age | Refresh evidence before decision. |
| `EVIDENCE-FUTURE` | Medium | Snapshot timestamp more than 5 minutes after selected cutoff | Correct time source or audit cutoff. |

Severities are working triage values, not legal, contractual, or regulatory classifications. These rules do not evaluate MFA sessions, application-side effective permissions, service accounts, nested memberships, or exceptions previously approved outside the tool. Duplicate rule IDs can occur for distinct applications, groups, or stale source records; every finding includes context in its evidence field.

## Expected demo scenario

The sample fixture intentionally contains enabled accounts, retained groups, privileged app access, stale data, an AD/HR identity mismatch, an unknown application state, and missing evidence. The `2026-11-05T12:00:00Z` cutoff makes tests deterministic.
