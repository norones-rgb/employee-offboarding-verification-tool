#Requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Csv','ActiveDirectory')][string]$Mode='Csv',
    [string]$TerminationsPath=(Join-Path $PSScriptRoot 'sample-data/terminations.csv'),
    [string]$AdUsersPath=(Join-Path $PSScriptRoot 'sample-data/ad-users.csv'),
    [string]$AdGroupsPath=(Join-Path $PSScriptRoot 'sample-data/ad-groups.csv'),
    [string]$AppEntitlementsPath=(Join-Path $PSScriptRoot 'sample-data/app-entitlements.csv'),
    [string]$ConfigPath=(Join-Path $PSScriptRoot 'config/default.json'),
    [string]$OutputDirectory=(Join-Path $PSScriptRoot 'output'),
    [string]$AsOfUtc=([datetimeoffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')),
    [string]$DomainController
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'src/OffboardingVerifier.psm1') -Force

$config=Read-OffboardingConfig -Path $ConfigPath
if ($Mode -eq 'Csv') {
    $data=Read-OffboardingInputs -TerminationsPath $TerminationsPath -AdUsersPath $AdUsersPath -AdGroupsPath $AdGroupsPath -AppEntitlementsPath $AppEntitlementsPath
} else {
    # HR and downstream application snapshots remain externally supplied; no write calls are issued.
    $people=Import-Csv -LiteralPath $TerminationsPath -Encoding utf8 -ErrorAction Stop
    $apps=Import-Csv -LiteralPath $AppEntitlementsPath -Encoding utf8 -ErrorAction Stop
    # Validate CSV schemas before collecting the AD snapshot. Other paths are unused in AD mode.
    $headers=@($people | Select-Object -First 1 | ForEach-Object { $_.PSObject.Properties.Name })
    foreach($key in @('EmployeeId','SamAccountName','Status','TerminatedAtUtc')) {
        if($key -notin $headers){ throw "HR CSV missing required column '$key'." }
    }
    $headers=@($apps | Select-Object -First 1 | ForEach-Object { $_.PSObject.Properties.Name })
    foreach($key in @('EmployeeId','Application','Entitlement','State','IsPrivileged','CollectedAtUtc','EvidenceSource')) {
        if($key -notin $headers){ throw "Application CSV missing required column '$key'." }
    }
    # Minimize directory reads: query only effective terminations past the grace period.
    $eligible=Select-EligibleTerminations -People @($people) -Config $config -AsOfUtc $AsOfUtc
    $snapshot=Get-AdDirectoryEvidence -People @($eligible) -DomainController $DomainController
    $data=[pscustomobject]@{People=@($people); Directory=@($snapshot.Directory); Groups=@($snapshot.Groups); Apps=@($apps)}
}
$result=Invoke-OffboardingAnalysis -People @($data.People) -Directory @($data.Directory) -Groups @($data.Groups) -Apps @($data.Apps) -Config $config -AsOfUtc $AsOfUtc -SourceMode $Mode
$reports=Export-OffboardingReports -Result $result -OutputDirectory $OutputDirectory
[pscustomobject]@{ Summary=$result.Summary; Reports=$reports }
