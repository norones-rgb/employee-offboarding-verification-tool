#Requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-NonEmpty {
    param([AllowNull()][object]$Value, [string]$Field)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Required field '$Field' is missing or empty."
    }
    return ([string]$Value).Trim()
}

function ConvertTo-UtcInstant {
    param([AllowNull()][object]$Value, [string]$Field)
    $raw = Assert-NonEmpty -Value $Value -Field $Field
    if ($raw -notmatch '(?:Z|[+-][0-9]{2}:[0-9]{2})$') {
        throw "Field '$Field' must contain an explicit UTC/offset timezone: '$raw'."
    }
    [datetimeoffset]$parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        throw "Invalid timestamp in '$Field': '$raw'."
    }
    return $parsed.ToUniversalTime()
}

function ConvertTo-StrictBoolean {
    param([AllowNull()][object]$Value, [string]$Field)
    $raw = Assert-NonEmpty -Value $Value -Field $Field
    [bool]$parsed = $false
    if (-not [bool]::TryParse($raw, [ref]$parsed)) { throw "Field '$Field' must be True or False." }
    return $parsed
}

function Import-RequiredCsv {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$RequiredColumns)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "CSV file not found: '$Path'." }
    $firstLine = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($firstLine)) { throw "CSV file has no header: '$Path'." }
    # Headers are intentionally simple, unquoted identifiers in the published schema.
    $headers = @($firstLine -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim([char]0xFEFF) })
    foreach ($column in $RequiredColumns) {
        if ($column -notin $headers) { throw "CSV '$Path' missing required column '$column'." }
    }
    return @(Import-Csv -LiteralPath $Path -Encoding utf8)
}

function Read-OffboardingConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Config not found: '$Path'." }
    $config = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    $fields = @('schemaVersion','gracePeriodHours','maxEvidenceAgeHours','baselineGroups','privilegedGroups','requiredApplications','activeStates','inactiveStates')
    foreach ($field in $fields) {
        if ($null -eq $config.PSObject.Properties[$field]) { throw "Config missing '$field'." }
    }
    if ([int]$config.schemaVersion -ne 1) { throw 'Unsupported configuration schemaVersion. Expected 1.' }
    foreach ($field in @('gracePeriodHours','maxEvidenceAgeHours')) {
        [int]$number = 0
        if (-not [int]::TryParse([string]$config.$field, [ref]$number) -or $number -lt 0 -or $number -gt 8760) {
            throw "Config '$field' must be an integer between 0 and 8760."
        }
    }
    if ([int]$config.maxEvidenceAgeHours -eq 0) { throw 'maxEvidenceAgeHours must be at least 1.' }
    foreach ($field in @('baselineGroups','privilegedGroups','requiredApplications','activeStates','inactiveStates')) {
        if ($config.$field -isnot [array]) { throw "Config '$field' must be an array." }
    }
    if (@($config.activeStates).Count -eq 0 -or @($config.inactiveStates).Count -eq 0) { throw 'State arrays must be nonempty.' }
    foreach ($state in @($config.activeStates)) {
        if ($state -in @($config.inactiveStates)) { throw "State '$state' cannot be both active and inactive." }
    }
    return $config
}

function Read-OffboardingInputs {
    param(
        [Parameter(Mandatory)][string]$TerminationsPath,
        [Parameter(Mandatory)][string]$AdUsersPath,
        [Parameter(Mandatory)][string]$AdGroupsPath,
        [Parameter(Mandatory)][string]$AppEntitlementsPath
    )
    $people = @(Import-RequiredCsv $TerminationsPath @('EmployeeId','SamAccountName','Status','TerminatedAtUtc'))
    $directory = @(Import-RequiredCsv $AdUsersPath @('EmployeeId','SamAccountName','Found','Enabled','CollectedAtUtc','GroupEvidenceComplete','GroupCollectedAtUtc'))
    $groups = @(Import-RequiredCsv $AdGroupsPath @('SamAccountName','GroupName'))
    $apps = @(Import-RequiredCsv $AppEntitlementsPath @('EmployeeId','Application','Entitlement','State','IsPrivileged','CollectedAtUtc','EvidenceSource'))
    return [pscustomobject]@{ People=$people; Directory=$directory; Groups=$groups; Apps=$apps }
}


function Select-EligibleTerminations {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$People,
          [Parameter(Mandatory)][object]$Config,
          [Parameter(Mandatory)][string]$AsOfUtc)
    $asOf = ConvertTo-UtcInstant $AsOfUtc 'AsOfUtc'
    Assert-UniqueKeys $People @('EmployeeId') 'Terminations'
    Assert-UniqueKeys $People @('SamAccountName') 'Terminations'
    $cutoff=$asOf.AddHours(-[int]$Config.gracePeriodHours)
    $eligible=[System.Collections.Generic.List[object]]::new()
    foreach ($employee in $People) {
        $status=Assert-NonEmpty $employee.Status 'Terminations.Status'
        if ($status -notin @('Terminated','Scheduled')) { throw "Unsupported HR status '$status'." }
        $effective=ConvertTo-UtcInstant $employee.TerminatedAtUtc 'Terminations.TerminatedAtUtc'
        if ($status -eq 'Terminated' -and $effective -le $cutoff) { $eligible.Add($employee) }
    }
    return $eligible.ToArray()
}

function Get-AdDirectoryEvidence {
    <#
    .SYNOPSIS
      Read-only AD snapshot for identities listed in the supplied HR feed.
    .NOTES
      ActiveDirectory RSAT is required on a domain-authorized Windows workstation.
      Uses Get-ADUser and Get-ADPrincipalGroupMembership only; does not modify AD.
      Group membership evidence is the group set returned by AD for each account,
      and must not be interpreted as complete cross-forest or application access.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$People, [string]$DomainController)
    if (-not $IsWindows) { throw 'ActiveDirectory mode requires Windows with the RSAT ActiveDirectory module.' }
    Import-Module ActiveDirectory -ErrorAction Stop
    $users = [System.Collections.Generic.List[object]]::new()
    $groups = [System.Collections.Generic.List[object]]::new()
    $uniqueSam = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $collected = [datetimeoffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    foreach ($person in $People) {
        $sam = Assert-NonEmpty $person.SamAccountName 'SamAccountName'
        if ($sam -notmatch '^[a-zA-Z0-9._@\-$]{1,64}$') { throw "Invalid SamAccountName format: '$sam'." }
        if (-not $uniqueSam.Add($sam)) { continue }
        $query = @{ Identity=$sam; Properties=@('EmployeeID','Enabled'); ErrorAction='Stop' }
        if (-not [string]::IsNullOrWhiteSpace($DomainController)) { $query.Server = $DomainController }
        $adUser = $null
        try {
            $adUser = Get-ADUser @query
        } catch {
            if ($_.Exception.GetType().FullName -like '*ADIdentityNotFoundException') {
                $users.Add([pscustomobject]@{
                    EmployeeId=''; SamAccountName=$sam; Found='False'; Enabled=''; CollectedAtUtc=$collected
                    GroupEvidenceComplete='False'; GroupCollectedAtUtc=''
                })
                continue
            }
            throw "AD lookup failed for '$sam'; scan aborted to avoid misreporting access: $($_.Exception.Message)"
        }
        $membershipComplete = 'True'
        $groupCollected = $collected
        $groupQuery = @{ Identity=$adUser; ErrorAction='Stop' }
        if (-not [string]::IsNullOrWhiteSpace($DomainController)) { $groupQuery.Server = $DomainController }
        try {
            foreach ($group in @(Get-ADPrincipalGroupMembership @groupQuery)) {
                $groups.Add([pscustomobject]@{ SamAccountName=$sam; GroupName=[string]$group.Name })
            }
        } catch {
            $membershipComplete = 'False'
            $groupCollected = ''
            Write-Warning "Could not collect AD groups for '$sam'; report will flag an evidence gap."
        }
        $users.Add([pscustomobject]@{
            EmployeeId=[string]$adUser.EmployeeID; SamAccountName=$sam; Found='True'; Enabled=([string][bool]$adUser.Enabled)
            CollectedAtUtc=$collected; GroupEvidenceComplete=$membershipComplete; GroupCollectedAtUtc=$groupCollected
        })
    }
    return [pscustomobject]@{ Directory=$users.ToArray(); Groups=$groups.ToArray() }
}

function New-OffboardingFinding {
    param([object]$Employee, [string]$RuleId, [ValidateSet('Critical','High','Medium')][string]$Severity,
          [string]$Description, [string]$Evidence, [string]$RecommendedAction,
          [string]$Application='', [string]$Entitlement='')
    return [pscustomobject][ordered]@{
        EmployeeId=[string]$Employee.EmployeeId
        SamAccountName=[string]$Employee.SamAccountName
        RuleId=$RuleId
        Severity=$Severity
        Application=$Application
        Entitlement=$Entitlement
        Description=$Description
        Evidence=$Evidence
        RecommendedAction=$RecommendedAction
    }
}

function Assert-UniqueKeys {
    param([object[]]$Records, [string[]]$Fields, [string]$Source)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $Records) {
        $values = @($Fields | ForEach-Object { Assert-NonEmpty $record.PSObject.Properties[$_].Value "$Source.$_" })
        $key = $values -join '|'
        if (-not $seen.Add($key)) { throw "Duplicate key in ${Source}: '$key'." }
    }
}

function Test-EvidenceAge {
    param([object]$Employee, [string]$Timestamp, [string]$Label, [datetimeoffset]$AsOf,
          [int]$MaxAge, [string]$Application='', [string]$Entitlement='')
    $when = ConvertTo-UtcInstant $Timestamp "$Label.CollectedAtUtc"
    $age = ($AsOf - $when).TotalHours
    if ($age -lt -0.0833334) {
        return (New-OffboardingFinding $Employee 'EVIDENCE-FUTURE' 'Medium' 'Evidence snapshot occurs after the audit cutoff.' "${Label}: $Timestamp" 'Confirm the audit cutoff and timestamp.' $Application $Entitlement)
    }
    if ($age -gt $MaxAge) {
        return (New-OffboardingFinding $Employee 'EVIDENCE-STALE' 'Medium' 'Evidence is older than the configured freshness limit.' "${Label}: $Timestamp ($([math]::Floor($age)) hours old)" 'Refresh this source before certifying offboarding.' $Application $Entitlement)
    }
    return $null
}

function Invoke-OffboardingAnalysis {
    param(
        [Parameter(Mandatory)][object[]]$People,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Directory,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Apps,
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$AsOfUtc,
        [ValidateSet('Csv','ActiveDirectory')][string]$SourceMode='Csv'
    )
    $asOf = ConvertTo-UtcInstant $AsOfUtc 'AsOfUtc'
    Assert-UniqueKeys $People @('EmployeeId') 'Terminations'
    Assert-UniqueKeys $People @('SamAccountName') 'Terminations'
    Assert-UniqueKeys $Directory @('SamAccountName') 'AD users'
    Assert-UniqueKeys $Groups @('SamAccountName','GroupName') 'AD groups'
    Assert-UniqueKeys $Apps @('EmployeeId','Application','Entitlement') 'Application entitlements'

    $dirMap=@{}; $groupMap=@{}; $appMap=@{}
    foreach ($record in $Directory) { $dirMap[[string]$record.SamAccountName]=$record }
    foreach ($record in $Groups) {
        $sam = [string]$record.SamAccountName
        if (-not $groupMap.ContainsKey($sam)) { $groupMap[$sam]=[System.Collections.Generic.List[object]]::new() }
        $groupMap[$sam].Add($record)
    }
    foreach ($record in $Apps) {
        $emp=[string]$record.EmployeeId
        if (-not $appMap.ContainsKey($emp)) { $appMap[$emp]=[System.Collections.Generic.List[object]]::new() }
        $appMap[$emp].Add($record)
    }
    $findings=[System.Collections.Generic.List[object]]::new()
    $matrix=[System.Collections.Generic.List[object]]::new()
    $grace=[int]$Config.gracePeriodHours
    $maxAge=[int]$Config.maxEvidenceAgeHours
    $cutoff=$asOf.AddHours(-$grace)
    $eligible=0
    foreach ($employee in $People) {
        $empId=Assert-NonEmpty $employee.EmployeeId 'Terminations.EmployeeId'
        $sam=Assert-NonEmpty $employee.SamAccountName 'Terminations.SamAccountName'
        $status=Assert-NonEmpty $employee.Status 'Terminations.Status'
        if ($status -notin @('Terminated','Scheduled')) { throw "Unsupported HR status '$status' for '$empId'." }
        $terminated=ConvertTo-UtcInstant $employee.TerminatedAtUtc 'Terminations.TerminatedAtUtc'
        if ($status -ne 'Terminated' -or $terminated -gt $cutoff) { continue }
        $eligible++
        $before=$findings.Count
        if (-not $dirMap.ContainsKey($sam)) {
            $findings.Add((New-OffboardingFinding $employee 'AD-EVIDENCE-MISSING' 'Medium' 'No AD lookup result was supplied.' 'No matching AD evidence row.' 'Collect a fresh AD snapshot and verify account disposition.'))
        } else {
            $user=$dirMap[$sam]
            $found=ConvertTo-StrictBoolean $user.Found 'AD users.Found'
            $fresh=Test-EvidenceAge $employee $user.CollectedAtUtc 'Active Directory' $asOf $maxAge
            if ($null -ne $fresh) { $findings.Add($fresh) }
            if (-not $found) {
                $findings.Add((New-OffboardingFinding $employee 'AD-NOT-FOUND' 'Medium' 'The AD account was not found in the queried directory.' 'Get-ADUser returned no account (or the CSV snapshot recorded Found=False).' 'Confirm correct domain, identity linkage, and account disposition; absence alone is not revocation proof.'))
            } else {
                if ([string]::IsNullOrWhiteSpace([string]$user.EmployeeId) -or [string]$user.EmployeeId -ne $empId) {
                    $findings.Add((New-OffboardingFinding $employee 'AD-IDENTITY-MISMATCH' 'High' 'HR and AD employee identifiers are not aligned.' "HR EmployeeId=$empId; AD EmployeeId=$($user.EmployeeId)" 'Verify identity correlation before relying on this evidence.'))
                }
                if (ConvertTo-StrictBoolean $user.Enabled 'AD users.Enabled') {
                    $findings.Add((New-OffboardingFinding $employee 'AD-ENABLED' 'Critical' 'Terminated employee has an enabled AD account.' 'AD Enabled=True.' 'Escalate to authorized IAM owners for disablement approval and verification.'))
                }
                $groupComplete=ConvertTo-StrictBoolean $user.GroupEvidenceComplete 'AD users.GroupEvidenceComplete'
                if (-not $groupComplete) {
                    $findings.Add((New-OffboardingFinding $employee 'AD-GROUP-EVIDENCE-MISSING' 'Medium' 'AD group collection is incomplete.' 'GroupEvidenceComplete=False.' 'Refresh the directory group snapshot and record collection scope.'))
                } else {
                    $freshGroup=Test-EvidenceAge $employee $user.GroupCollectedAtUtc 'AD groups' $asOf $maxAge
                    if ($null -ne $freshGroup) { $findings.Add($freshGroup) }
                    if ($groupMap.ContainsKey($sam)) {
                        foreach ($group in $groupMap[$sam]) {
                            $name=Assert-NonEmpty $group.GroupName 'AD groups.GroupName'
                            if ($name -in @($Config.privilegedGroups)) {
                                $findings.Add((New-OffboardingFinding $employee 'AD-PRIVILEGED-GROUP' 'Critical' 'Terminated user retains an identified privileged group membership.' "Group: $name" 'Review and remove unauthorized group membership through approved change control.'))
                            } elseif ($name -notin @($Config.baselineGroups)) {
                                $findings.Add((New-OffboardingFinding $employee 'AD-RESIDUAL-GROUP' 'High' 'Terminated user retains a nonbaseline group membership.' "Group: $name" 'Review group owner, business exception, and removal evidence.'))
                            }
                        }
                    }
                }
            }
        }
        $empApps=@(); if ($appMap.ContainsKey($empId)) { $empApps=@($appMap[$empId].ToArray()) }
        foreach ($required in @($Config.requiredApplications)) {
            if (@($empApps | Where-Object { $_.Application -eq $required }).Count -eq 0) {
                $findings.Add((New-OffboardingFinding $employee 'APP-EVIDENCE-MISSING' 'Medium' 'Required application evidence is absent from supplied export.' "Application: $required" 'Verify whether an account existed and obtain application-owner evidence.' ([string]$required)))
            }
        }
        foreach ($app in $empApps) {
            $application=Assert-NonEmpty $app.Application 'Application entitlements.Application'
            $entitlement=Assert-NonEmpty $app.Entitlement 'Application entitlements.Entitlement'
            $state=Assert-NonEmpty $app.State 'Application entitlements.State'
            $isPrivileged=ConvertTo-StrictBoolean $app.IsPrivileged 'Application entitlements.IsPrivileged'
            $appFresh=Test-EvidenceAge $employee $app.CollectedAtUtc ("Application '$application' / '$entitlement'") $asOf $maxAge $application $entitlement
            if ($null -ne $appFresh) { $findings.Add($appFresh) }
            if ($state -in @($Config.activeStates)) {
                if ($isPrivileged) {
                    $findings.Add((New-OffboardingFinding $employee 'APP-PRIVILEGED-ACTIVE' 'Critical' 'Privileged application entitlement remains active after termination.' "State=$state; EvidenceSource=$($app.EvidenceSource)" 'Escalate to application owner for approved revocation and evidence.' $application $entitlement))
                } else {
                    $findings.Add((New-OffboardingFinding $employee 'APP-ACTIVE' 'High' 'Application entitlement remains active after termination.' "State=$state; EvidenceSource=$($app.EvidenceSource)" 'Request application-owner revocation and independently verify completion.' $application $entitlement))
                }
            } elseif ($state -notin @($Config.inactiveStates)) {
                $findings.Add((New-OffboardingFinding $employee 'APP-STATE-UNKNOWN' 'Medium' 'Application entitlement state is not recognized as revoked or disabled.' "State=$state; EvidenceSource=$($app.EvidenceSource)" 'Obtain authoritative state mapping and confirm entitlement removal.' $application $entitlement))
            }
        }
        $count=$findings.Count-$before
        $matrix.Add([pscustomobject][ordered]@{
            EmployeeId=$empId; SamAccountName=$sam; TerminatedAtUtc=$terminated.ToString('yyyy-MM-ddTHH:mm:ssZ')
            FindingsCount=$count; ReviewStatus=$(if($count -gt 0){'Needs review'}else{'No observed exceptions'})
        })
    }
    $ordered=@($findings.ToArray() | Sort-Object -Property @{Expression={switch ($_.Severity) {'Critical' {0} 'High' {1} default {2}}}}, EmployeeId, RuleId, Application, Entitlement)
    $critical=@($ordered | Where-Object Severity -eq 'Critical').Count
    $high=@($ordered | Where-Object Severity -eq 'High').Count
    $medium=@($ordered | Where-Object Severity -eq 'Medium').Count
    $summary=[pscustomobject][ordered]@{
        SchemaVersion=1; SourceMode=$SourceMode; AsOfUtc=$asOf.ToString('yyyy-MM-ddTHH:mm:ssZ')
        GracePeriodHours=$grace; MaxEvidenceAgeHours=$maxAge
        TotalHrRecords=$People.Count; EligibleTerminations=$eligible
        SkippedOrNotDue=($People.Count-$eligible); AccountsWithFindings=@($matrix.ToArray() | Where-Object { $_.FindingsCount -gt 0 }).Count
        TotalFindings=$ordered.Count; Critical=$critical; High=$high; Medium=$medium
        Disclaimer='Evidence-based exception screen; absence of findings is not certification of complete offboarding or app coverage.'
    }
    return [pscustomobject]@{Summary=$summary; Findings=$ordered; Matrix=$matrix.ToArray()}
}

function Protect-SpreadsheetValue {
    param([AllowNull()][object]$Value)
    $value=[string]$Value
    if ($value -match '^[\s]*[=+@\-]') { return "'$value" }
    return $value
}

function ConvertTo-EncodedHtml {
    param([AllowNull()][object]$Value)
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Export-OffboardingReports {
    param([Parameter(Mandatory)][object]$Result, [Parameter(Mandatory)][string]$OutputDirectory)
    $null=New-Item -ItemType Directory -Path $OutputDirectory -Force
    $stem=($Result.Summary.AsOfUtc -replace '[^0-9]', '')
    $folder=Join-Path $OutputDirectory ("offboarding-$stem-$([guid]::NewGuid().ToString('N').Substring(0,8))")
    $null=New-Item -ItemType Directory -Path $folder -Force
    $findingsCsv=Join-Path $folder 'findings.csv'
    $matrixCsv=Join-Path $folder 'review-matrix.csv'
    $jsonPath=Join-Path $folder 'audit.json'
    $htmlPath=Join-Path $folder 'index.html'
    $findingCols=@('EmployeeId','SamAccountName','RuleId','Severity','Application','Entitlement','Description','Evidence','RecommendedAction')
    $matrixCols=@('EmployeeId','SamAccountName','TerminatedAtUtc','FindingsCount','ReviewStatus')
    $safeFindings=@($Result.Findings | Select-Object -Property $findingCols | ForEach-Object {
        $row=[ordered]@{}; foreach ($column in $findingCols) { $row[$column]=Protect-SpreadsheetValue $_.$column }
        [pscustomobject]$row
    })
    $safeMatrix=@($Result.Matrix | Select-Object -Property $matrixCols | ForEach-Object {
        $row=[ordered]@{}; foreach ($column in $matrixCols) { $row[$column]=Protect-SpreadsheetValue $_.$column }
        [pscustomobject]$row
    })
    if ($safeFindings.Count -eq 0) {
        ($findingCols -join ',') | Set-Content -LiteralPath $findingsCsv -Encoding utf8
    } else { $safeFindings | Export-Csv -LiteralPath $findingsCsv -NoTypeInformation -Encoding utf8 }
    if ($safeMatrix.Count -eq 0) {
        ($matrixCols -join ',') | Set-Content -LiteralPath $matrixCsv -Encoding utf8
    } else { $safeMatrix | Export-Csv -LiteralPath $matrixCsv -NoTypeInformation -Encoding utf8 }
    $Result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding utf8
    $s=$Result.Summary
    $rows=[System.Collections.Generic.List[string]]::new()
    foreach($finding in $Result.Findings) {
        $class=([string]$finding.Severity).ToLowerInvariant()
        $cols=@($finding.EmployeeId,$finding.SamAccountName,$finding.RuleId,$finding.Severity,$finding.Application,$finding.Entitlement,$finding.Description,$finding.Evidence,$finding.RecommendedAction)
        $cells=($cols | ForEach-Object { '<td>'+(ConvertTo-EncodedHtml $_)+'</td>' }) -join ''
        $rows.Add("<tr class='$class'>$cells</tr>")
    }
    $bodyRows=if($rows.Count -gt 0){$rows -join "`n"}else{'<tr><td colspan="9">No observed exceptions in the supplied evidence. This does not certify complete offboarding.</td></tr>'}
    $asOf=ConvertTo-EncodedHtml $s.AsOfUtc
    $mode=ConvertTo-EncodedHtml $s.SourceMode
    $html=@"
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>Employee Offboarding Verification | Synthetic/Local Report</title>
<style>
:root{color-scheme:light;--ink:#17212c;--muted:#526170;--line:#dce4eb;--bg:#f5f7fa}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 system-ui,-apple-system,Segoe UI,sans-serif}
main{max-width:1320px;margin:40px auto;padding:0 20px}h1{font-size:29px;margin:0}p{color:var(--muted)}.tag{font-size:12px;text-transform:uppercase;letter-spacing:.12em;font-weight:700;color:#48617e}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin:22px 0}.stat,.panel{background:white;border:1px solid var(--line);border-radius:13px;padding:18px}.stat strong{font-size:28px;display:block}.stat span{font-size:13px;color:var(--muted)}
.notice{border-left:4px solid #9b6416;background:#fffaf0;padding:13px 17px;color:#5b411d;margin:18px 0;border-radius:5px}
.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse;background:white;font-size:12px;min-width:1140px}th,td{text-align:left;padding:11px;border-bottom:1px solid var(--line);vertical-align:top;max-width:250px;overflow-wrap:anywhere}th{background:#edf2f6;position:sticky;top:0}.critical td:nth-child(4){color:#a31923;font-weight:700}.high td:nth-child(4){color:#9b5012;font-weight:700}.medium td:nth-child(4){color:#445d86;font-weight:700}
footer{margin:24px 0;color:var(--muted);font-size:12px}
</style></head><body><main>
<div class="tag">Read-only IAM / Offboarding evidence</div><h1>Employee Offboarding Verification</h1>
<p>Audit cutoff: $asOf | Directory source: $mode</p>
<div class="stats"><div class="stat"><strong>$($s.EligibleTerminations)</strong><span>Eligible terminations</span></div>
<div class="stat"><strong>$($s.AccountsWithFindings)</strong><span>Accounts needing review</span></div>
<div class="stat"><strong>$($s.Critical)</strong><span>Critical findings</span></div>
<div class="stat"><strong>$($s.High)</strong><span>High findings</span></div>
<div class="stat"><strong>$($s.Medium)</strong><span>Medium findings</span></div></div>
<div class="notice">Evidence-limited screening only. No finding does not mean all downstream identities or entitlements have been verified. Check source completeness, scope, freshness, and owner approvals.</div>
<div class="panel"><h2>Exception findings ($($s.TotalFindings))</h2><div class="table-wrap"><table><thead><tr><th>Employee ID</th><th>AD account</th><th>Rule</th><th>Severity</th><th>Application</th><th>Entitlement</th><th>Finding</th><th>Evidence</th><th>Recommended action</th></tr></thead><tbody>
$bodyRows
</tbody></table></div></div>
<footer>Generated locally. No external scripts, fonts, or network assets. Reports can contain sensitive identities: store outside public repositories.</footer>
</main></body></html>
"@
    $html | Set-Content -LiteralPath $htmlPath -Encoding utf8
    return [pscustomobject]@{ Directory=$folder; FindingsCsv=$findingsCsv; ReviewMatrixCsv=$matrixCsv; Json=$jsonPath; Html=$htmlPath }
}

Export-ModuleMember -Function Read-OffboardingConfig,Read-OffboardingInputs,Select-EligibleTerminations,Get-AdDirectoryEvidence,Invoke-OffboardingAnalysis,Export-OffboardingReports
