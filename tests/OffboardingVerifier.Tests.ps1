#Requires -Version 7.2
BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:root 'src/OffboardingVerifier.psm1') -Force
    $script:cfg = Read-OffboardingConfig (Join-Path $script:root 'config/default.json')
    $script:data = Read-OffboardingInputs `
        -TerminationsPath (Join-Path $script:root 'sample-data/terminations.csv') `
        -AdUsersPath (Join-Path $script:root 'sample-data/ad-users.csv') `
        -AdGroupsPath (Join-Path $script:root 'sample-data/ad-groups.csv') `
        -AppEntitlementsPath (Join-Path $script:root 'sample-data/app-entitlements.csv')
    $script:asOf = '2026-11-05T12:00:00Z'
    $script:result = Invoke-OffboardingAnalysis -People $script:data.People -Directory $script:data.Directory `
        -Groups $script:data.Groups -Apps $script:data.Apps -Config $script:cfg -AsOfUtc $script:asOf
}

Describe 'Read-only offboarding risk detections' {
    It 'evaluates only completed terminations past the configured grace period' {
        $result.Summary.TotalHrRecords | Should -Be 11
        $result.Summary.EligibleTerminations | Should -Be 9
        $result.Summary.SkippedOrNotDue | Should -Be 2
        @($result.Matrix | Where-Object EmployeeId -eq 'EMP007').Count | Should -Be 0
        @($result.Matrix | Where-Object EmployeeId -eq 'EMP008').Count | Should -Be 0
    }
    It 'does not report an exception on a complete clean fixture' {
        @($result.Findings | Where-Object EmployeeId -eq 'EMP001').Count | Should -Be 0
        @($result.Findings | Where-Object EmployeeId -eq 'EMP010').Count | Should -Be 0
    }
    It 'flags enabled AD access without modifying the account' {
        @($result.Findings | Where-Object { $_.EmployeeId -eq 'EMP002' -and $_.RuleId -eq 'AD-ENABLED' }).Count | Should -Be 1
    }
    It 'flags a retained privileged AD group' {
        @($result.Findings | Where-Object { $_.EmployeeId -eq 'EMP003' -and $_.RuleId -eq 'AD-PRIVILEGED-GROUP' }).Count | Should -Be 1
    }
    It 'flags retained nonbaseline AD groups' {
        @($result.Findings | Where-Object { $_.EmployeeId -eq 'EMP004' -and $_.RuleId -eq 'AD-RESIDUAL-GROUP' }).Count | Should -Be 1
    }
    It 'reports directory absence as unverified rather than cleared' {
        @($result.Findings | Where-Object { $_.EmployeeId -eq 'EMP005' -and $_.RuleId -eq 'AD-NOT-FOUND' }).Count | Should -Be 1
    }
    It 'reports stale evidence and incomplete group evidence' {
        @($result.Findings | Where-Object { $_.EmployeeId -eq 'EMP006' -and $_.RuleId -eq 'EVIDENCE-STALE' }).Count | Should -BeGreaterThan 0
        @($result.Findings | Where-Object { $_.EmployeeId -eq 'EMP006' -and $_.RuleId -eq 'AD-GROUP-EVIDENCE-MISSING' }).Count | Should -Be 1
    }
    It 'flags HR / directory employee ID mismatches' {
        @($result.Findings | Where-Object { $_.EmployeeId -eq 'EMP009' -and $_.RuleId -eq 'AD-IDENTITY-MISMATCH' }).Count | Should -Be 1
    }
    It 'flags active privileged application access separately' {
        @($result.Findings | Where-Object { $_.EmployeeId -eq 'EMP003' -and $_.RuleId -eq 'APP-PRIVILEGED-ACTIVE' }).Count | Should -Be 1
    }
    It 'flags incomplete application evidence and unknown states' {
        @($result.Findings | Where-Object { $_.EmployeeId -eq 'EMP005' -and $_.RuleId -eq 'APP-EVIDENCE-MISSING' }).Count | Should -Be 1
        @($result.Findings | Where-Object { $_.EmployeeId -eq 'EMP011' -and $_.RuleId -eq 'APP-STATE-UNKNOWN' }).Count | Should -Be 1
    }
    It 'reports exact synthetic rule totals' {
        $result.Summary.TotalFindings | Should -Be 15
        $result.Summary.Critical | Should -Be 3
        $result.Summary.High | Should -Be 5
        $result.Summary.Medium | Should -Be 7
    }
}

Describe 'Input integrity and report safety' {
    It 'limits live AD collection to eligible terminations only' {
        $subset=@(Select-EligibleTerminations -People $data.People -Config $cfg -AsOfUtc $asOf)
        $subset.Count | Should -Be 9
        @($subset | Where-Object EmployeeId -eq 'EMP008').Count | Should -Be 0
    }
    It 'flags missing AD snapshot rows instead of treating them as clean' {
        $without=@($data.Directory | Where-Object SamAccountName -ne 'kofi.adams')
        $check=Invoke-OffboardingAnalysis -People $data.People -Directory $without -Groups $data.Groups -Apps $data.Apps -Config $cfg -AsOfUtc $asOf
        @($check.Findings | Where-Object { $_.EmployeeId -eq 'EMP010' -and $_.RuleId -eq 'AD-EVIDENCE-MISSING' }).Count | Should -Be 1
    }
    It 'generates missing-application evidence rather than assuming a missing export row means revoked' {
        $without=@($data.Apps | Where-Object { $_.EmployeeId -ne 'EMP010' -or $_.Application -ne 'VPN' })
        $check=Invoke-OffboardingAnalysis -People $data.People -Directory $data.Directory -Groups $data.Groups -Apps $without -Config $cfg -AsOfUtc $asOf
        @($check.Findings | Where-Object { $_.EmployeeId -eq 'EMP010' -and $_.RuleId -eq 'APP-EVIDENCE-MISSING' }).Count | Should -Be 1
    }
    It 'rejects inconsistent HR identity keys' {
        $bad=@($data.People) + @($data.People[0])
        { Invoke-OffboardingAnalysis -People $bad -Directory $data.Directory -Groups $data.Groups -Apps $data.Apps -Config $cfg -AsOfUtc $asOf } | Should -Throw '*Duplicate key*'
    }
    It 'rejects missing timezone offsets on audit cutoff' {
        { Invoke-OffboardingAnalysis -People $data.People -Directory $data.Directory -Groups $data.Groups -Apps $data.Apps -Config $cfg -AsOfUtc '2026-11-05T12:00:00' } | Should -Throw '*timezone*'
    }
    It 'rejects invalid directory boolean values' {
        $badDirectory=@($data.Directory | ForEach-Object { $_.PSObject.Copy() })
        ($badDirectory | Where-Object SamAccountName -eq 'marcus.wright').Enabled='sometimes'
        { Invoke-OffboardingAnalysis -People $data.People -Directory $badDirectory -Groups $data.Groups -Apps $data.Apps -Config $cfg -AsOfUtc $asOf } | Should -Throw '*True or False*'
    }
    It 'writes all report formats with synthetic input' {
        $temp=Join-Path ([IO.Path]::GetTempPath()) ('offboarding-test-'+[guid]::NewGuid().ToString('N'))
        try {
            $reports=Export-OffboardingReports -Result $result -OutputDirectory $temp
            $reports.Directory | Should -Exist
            $reports.FindingsCsv | Should -Exist
            $reports.ReviewMatrixCsv | Should -Exist
            $reports.Json | Should -Exist
            $reports.Html | Should -Exist
            (Get-Content -LiteralPath $reports.Json -Raw | ConvertFrom-Json).Summary.TotalFindings | Should -Be 15
        } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'escapes injected HTML in the offline dashboard and CSV formulas in findings' {
        $badEmployee=[pscustomobject]@{EmployeeId='EMP-X';SamAccountName='=HYPERLINK("https://evil.example")'}
        $f=[pscustomobject][ordered]@{
            EmployeeId=$badEmployee.EmployeeId;SamAccountName=$badEmployee.SamAccountName;RuleId='TEST';Severity='High'
            Application='';Entitlement='';Description='<script>alert(1)</script>'
            Evidence='malicious <img src=x onerror=alert(1)>';RecommendedAction='Review'
        }
        $fake=[pscustomobject]@{
            Summary=[pscustomobject]@{AsOfUtc=$asOf;SourceMode='Csv';EligibleTerminations=1;AccountsWithFindings=1;TotalFindings=1;Critical=0;High=1;Medium=0}
            Findings=@($f);Matrix=@([pscustomobject]@{EmployeeId='EMP-X';SamAccountName=$f.SamAccountName;TerminatedAtUtc=$asOf;FindingsCount=1;ReviewStatus='Needs review'})
        }
        $temp=Join-Path ([IO.Path]::GetTempPath()) ('offboarding-test-'+[guid]::NewGuid().ToString('N'))
        try {
            $reports=Export-OffboardingReports -Result $fake -OutputDirectory $temp
            $html=Get-Content -LiteralPath $reports.Html -Raw
            $csv=Get-Content -LiteralPath $reports.FindingsCsv -Raw
            $html | Should -Not -Match '<script>alert\(1\)</script>'
            $html | Should -Match '&lt;script&gt;'
            $csv | Should -Match "'=HYPERLINK"
        } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'generates no unsafe account mutation commands in the entry point' {
        $text=Get-Content -LiteralPath (Join-Path $root 'src/OffboardingVerifier.psm1') -Raw
        $text | Should -Not -Match '(?im)\b(?:Disable-ADAccount|Remove-ADGroupMember|Set-ADUser|Remove-ADUser|Set-ADAccountPassword)\s'
    }
    It 'runs the bundled entry point in CSV mode end to end' {
        $temp=Join-Path ([IO.Path]::GetTempPath()) ('offboarding-test-'+[guid]::NewGuid().ToString('N'))
        try {
            $run=& (Join-Path $root 'Invoke-OffboardingVerification.ps1') -Mode Csv -AsOfUtc $asOf -OutputDirectory $temp
            $run.Summary.EligibleTerminations | Should -Be 9
            $run.Reports.Html | Should -Exist
        } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
