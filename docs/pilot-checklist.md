# Controlled pilot checklist

## Before running

- [ ] Obtain authorization from IAM/security, HR data owners, and directory/application owners.
- [ ] Restrict scope to a small test group and record the target AD domain/DC and intended application exports.
- [ ] Confirm retention/deletion policy for HR and identity data; avoid public repositories and unencrypted email.
- [ ] Validate HR effective dates and timezone with HR system owner.
- [ ] Map EmployeeId to AD and app identities; resolve known aliases, rehires, and dual accounts outside this MVP.
- [ ] Review baseline groups, privileged groups, app state mappings, grace interval, and evidence freshness SLA.
- [ ] Use an authorized **read-only** credential to access AD (no directory write permissions).
- [ ] Test an isolated lab or fully synthetic scenario first; do not use live tenant credentials in source code.

## During verification

- [ ] Record run cutoff UTC, source filenames, source timestamps, collector scope, and accountable reviewers.
- [ ] Run CSV mode with complete source exports, or AD mode with an approved DC and separate app exports.
- [ ] Review all critical/high findings and every stale/missing/unknown evidence finding.
- [ ] Route remediation only through authorized IAM/app-owner changes; no changes are implemented by this script.

## After verification

- [ ] Reconcile each finding with ticket IDs, ownership, business exceptions, and accepted risks.
- [ ] Re-collect evidence after approved remediation; preserve both versions securely if needed for audit.
- [ ] Confirm no real identities, names, credentials, or reports are staged or committed to public GitHub.
- [ ] Record blind spots: unsupported tenants, cross-forest identities, privileged nested memberships, SaaS sessions, service accounts, contractors, and app integrations.
- [ ] Delete local pilot exports according to the documented retention schedule.
