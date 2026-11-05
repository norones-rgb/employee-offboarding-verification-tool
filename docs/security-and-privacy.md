# Security and privacy

**Do not use production employee exports in the public repository.** HR terminations, account states, entitlement data and report output are sensitive. The sample data is fabricated.

## Read-only access

The AD collector intentionally invokes only `Get-ADUser` and `Get-ADPrincipalGroupMembership`, and the core analyzer evaluates in-memory records. It does not disable users, remove groups, change credentials, call external services, send email, or create workflow tickets. Provide a least-privilege directory read role and use change-controlled workflows for remediation.

## Evidence limitations

A missing AD account can be caused by querying the wrong domain, rename, deletion, connector failure, or incomplete identity correlation. A missing application export row has similar ambiguity. Never treat either as proof of removal. Review freshness and coverage for every source.

## Export defenses

- CSV export neutralizes leading spreadsheet formula characters (`=`, `+`, `-`, `@`) by prefixing an apostrophe. Consumers should keep their own spreadsheet sandboxing controls.
- HTML outputs encode all variable data and set a restrictive Content Security Policy. The HTML has no network assets or scripts.
- JSON retains exact evidence text and should be considered sensitive. There is no built-in encryption; use OS-level disk and folder protections.
- `output/` is Git-ignored, but other private directories are not necessarily ignored. **Use paths outside the clone for real data and reports** and review `git status` before committing.

## Data retention and reporting

Write reports only to a protected location with authorized viewers, defined retention, and approved transfer methods. Avoid dumping HR feeds or reports into issue comments, CI logs, or public repositories. CI only uses synthetic fixtures.

## Incident response

If you accidentally publish real data, revoke access to exposed secrets (if any), notify the data owners/security team under policy, and purge repository history with their guidance. Simply deleting a file in the latest commit does not remove it from Git history.

## License

This public demonstration has **no open-source license**. The repository's `NOTICE` preserves rights while allowing code review through GitHub. Any client production deployment requires separate authorization, review, and licensing.
