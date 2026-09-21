# Unit tests for the pure helpers in ssm.ps1 -- the counterpart of
# test/args_test.sh, in the same order and with the same section headings, so
# the two can be read side by side. No AWS, no network, no fzf.
#
# Run: pwsh -File test/ssm_test.ps1

$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here '../ssm.ps1')

$script:Passed = 0
$script:Failed = 0

function Assert-Eq {
    param($Expected, $Actual, [string]$What)
    if ([string]$Expected -ceq [string]$Actual) { $script:Passed++ }
    else { $script:Failed++; [Console]::Error.WriteLine("  FAIL: ${What}: expected '$Expected', got '$Actual'") }
}

function Assert-True {
    param($Condition, [string]$What)
    if ($Condition) { $script:Passed++ } else { $script:Failed++; [Console]::Error.WriteLine("  FAIL: $What") }
}

function Assert-False {
    param($Condition, [string]$What)
    if (-not $Condition) { $script:Passed++ } else { $script:Failed++; [Console]::Error.WriteLine("  FAIL: $What") }
}

# .Contains, not -clike: the wildcard operator reads [sc-staging] as a
# character class and throws on it.
function Assert-Contains {
    param([string]$Needle, [string]$Haystack, [string]$What)
    if ($Haystack.Contains($Needle, [StringComparison]::Ordinal)) { $script:Passed++ }
    else { $script:Failed++; [Console]::Error.WriteLine("  FAIL: ${What}: expected '$Needle' in '$Haystack'") }
}

function Assert-NotContains {
    param([string]$Needle, [string]$Haystack, [string]$What)
    if (-not $Haystack.Contains($Needle, [StringComparison]::Ordinal)) { $script:Passed++ }
    else { $script:Failed++; [Console]::Error.WriteLine("  FAIL: ${What}: did not expect '$Needle'") }
}

# Runs a scriptblock with stderr captured, so a refusal's message can be
# asserted on without printing it. Exit-Ssm throws, which is caught here.
function Invoke-Capture {
    param([scriptblock]$Block)
    $stderr = [System.IO.StringWriter]::new()
    $prev = [Console]::Error
    [Console]::SetError($stderr)
    $script:LastExit = 0
    try { $result = & $Block } catch [SsmExitException] { $script:LastExit = $_.Exception.Code }
    finally { [Console]::SetError($prev) }
    $script:LastErr = $stderr.ToString()
    return $result
}

$COMMAND = 'ssh'

Write-Host 'Read-SsmArgs'

Invoke-Capture { Read-SsmArgs '--env --app' '--host' @('--env', 'staging', '--app', 'adam', '--host') } | Out-Null
Assert-Eq 'staging' $ARG_ENV 'a value flag'
Assert-Eq 'adam' $ARG_APP 'a second value flag'
Assert-Eq '1' $ARG_HOST 'a boolean flag'

Invoke-Capture { Read-SsmArgs '--env --app' '--host' @('--env=stg', '--app=x') } | Out-Null
Assert-Eq 'stg' $ARG_ENV 'the --flag=value form'
Assert-Eq '' $ARG_HOST 'a second call clears a boolean flag'

Invoke-Capture { Read-SsmArgs '--env' '' @() } | Out-Null
Assert-Eq '' $ARG_ENV 'a second call clears a value flag'

Invoke-Capture { Read-SsmArgs '--env --namespace --container' '' @('-e', 'stg') } | Out-Null
Assert-Eq 'stg' $ARG_ENV '-e is --env'
Invoke-Capture { Read-SsmArgs '--env' '' @('--account', 'stg') } | Out-Null
Assert-Eq 'stg' $ARG_ENV '--account is --env'
Invoke-Capture { Read-SsmArgs '--namespace' '' @('-n', 'kube-system') } | Out-Null
Assert-Eq 'kube-system' $ARG_NAMESPACE '-n is --namespace'
Invoke-Capture { Read-SsmArgs '--container' '' @('-c', 'php') } | Out-Null
Assert-Eq 'php' $ARG_CONTAINER '-c is --container'

Assert-False (Invoke-Capture { Read-SsmArgs '--env' '' @('--nope') }) 'an unknown flag is refused'
Assert-Contains "Unknown option '--nope'" $script:LastErr 'unknown flag message'
Assert-False (Invoke-Capture { Read-SsmArgs '--env' '' @('--pod', 'x') }) "another command's flag is refused"
Assert-False (Invoke-Capture { Read-SsmArgs '--env' '' @('--env') }) 'a value flag with no value is refused'
Assert-Contains 'requires a value' $script:LastErr 'missing value message'
Assert-False (Invoke-Capture { Read-SsmArgs '--env --app' '' @('--env', '--app', 'x') }) 'a value flag followed by a flag is refused'
Assert-False (Invoke-Capture { Read-SsmArgs '' '--host' @('--host=yes') }) 'a boolean flag given a value is refused'

# PowerShell compares case-insensitively by default; bash's `case` does not.
# These four would all silently pass without the ordinal comparisons.
Assert-False (Invoke-Capture { Read-SsmArgs '--env' '' @('--ENV', 'stg') }) '--ENV is not --env'
Assert-False (Invoke-Capture { Read-SsmArgs '--env' '' @('-E', 'stg') }) '-E is not -e'
# CmdletBinding would silently accept all of these.
Assert-False (Invoke-Capture { Read-SsmArgs '--env' '' @('--verbose') }) '--verbose is not a flag'
Assert-False (Invoke-Capture { Read-SsmArgs '--env' '' @('-ErrorAction', 'Stop') }) '-ErrorAction is not a flag'

# A bare "-" is a real value for --secret-key; anything else starting with a
# dash is a missing value.
Assert-True (Invoke-Capture { Read-SsmArgs '--secret-key' '' @('--secret-key', '-') }) 'a bare dash is a value'
Assert-Eq '-' $ARG_SECRET_KEY 'the bare dash is stored'

Write-Host 'Resolve-SsmSelection'

$rows = [string[]]@("i-0abc`tweb-01", "i-0def`tweb-02")
Assert-Eq "i-0abc`tweb-01" (Invoke-Capture { Resolve-SsmSelection 'i-0abc' 'instance' 'app adam' 'Select:' '1' '' $rows }) 'an exact match on field 1'
Assert-Eq "i-0def`tweb-02" (Invoke-Capture { Resolve-SsmSelection 'web-02' 'instance' 'app adam' 'Select:' '1,2' '' $rows }) 'a match on field 2'
Assert-Eq $null (Invoke-Capture { Resolve-SsmSelection 'web-02' 'instance' 'app adam' 'Select:' '1' '' $rows }) 'field 2 does not match when only field 1 is searched'
Assert-Eq $null (Invoke-Capture { Resolve-SsmSelection 'nope' 'account' 'the config' 'Select:' '1' '' $rows }) 'no match returns nothing'
Assert-Contains "no account 'nope' in the config" $script:LastErr 'no-match message'
Assert-Contains 'Available:' $script:LastErr 'no-match lists the candidates'

$dupes = [string[]]@("t1`tphp-fpm", "t2`tphp-fpm")
Assert-Eq $null (Invoke-Capture { Resolve-SsmSelection 'php-fpm' 'container' 'the tasks' 'Select:' '2' '' $dupes }) 'an ambiguous match returns nothing'
Assert-Contains "ambiguous container 'php-fpm'" $script:LastErr 'ambiguous message'

$one = [string[]]@("i-0abc`tweb-01")
Assert-Eq "i-0abc`tweb-01" (Invoke-Capture { Resolve-SsmSelection '' 'instance' 'app adam' 'Select:' '1' 'auto' $one }) 'a single candidate auto-selects'
Assert-Contains 'Auto-selecting:' $script:LastErr 'auto-select says so'

# The return value is the only thing on the success stream: a status line
# leaking into it would be captured by every caller.
$out = @(Invoke-Capture { Resolve-SsmSelection '' 'instance' 'app adam' 'Select:' '1' 'auto' $one })
Assert-Eq 1 $out.Count 'auto-select returns exactly one value'

Write-Host 'Read-SsmSecretValue'

$env:SSM_AWS_SECRET_KEY = 'from-env'
Assert-Eq 'from-env' (Invoke-Capture { Read-SsmSecretValue '' }) 'the environment variable wins'
Assert-Eq 'from-env' (Invoke-Capture { Read-SsmSecretValue '-' }) 'the environment variable beats stdin'
$env:SSM_AWS_SECRET_KEY = $null
Assert-Eq $null (Invoke-Capture { Read-SsmSecretValue 'AKIAsecret' }) 'a literal value is refused'
Assert-Contains 'shell history' $script:LastErr 'the refusal explains why'

Write-Host 'Write-SsmTunnelBanner'

$C_RESET = ''; $C_BOLD = ''; $C_DIM = ''; $C_GREEN = ''; $C_YELLOW = ''
$banner = Write-SsmTunnelBanner '127.0.0.1' '15432' 'db.abc.rds.amazonaws.com' '5432'
$joined = $banner -join "`n"
Assert-Contains '127.0.0.1' $joined 'the banner shows the tunnel host'
Assert-Contains '15432' $joined 'the banner shows the local port'
Assert-Contains 'db.abc.rds.amazonaws.com' $joined 'the banner shows the real host'
Assert-Contains 'do NOT use' $joined 'the banner warns off the real endpoint'
$widths = @($banner | ForEach-Object { $_.Length } | Sort-Object -Unique)
Assert-Eq 1 $widths.Count 'every plain line is the same width'

# Padding is measured on the label and value alone; measuring the coloured
# string would pull the right border in by the length of the escapes.
$C_BOLD = "`e[1m"; $C_GREEN = "`e[32m"; $C_DIM = "`e[2m"; $C_YELLOW = "`e[33m"; $C_RESET = "`e[0m"
$colored = Write-SsmTunnelBanner '127.0.0.1' '15432' 'db.abc.rds.amazonaws.com' '5432'
$plainWidths = @($colored | ForEach-Object { ($_ -replace "`e\[[0-9;]*m", '').Length } | Sort-Object -Unique)
Assert-Eq 1 $plainWidths.Count 'every coloured line is the same width once escapes are stripped'
$C_RESET = ''; $C_BOLD = ''; $C_DIM = ''; $C_GREEN = ''; $C_YELLOW = ''

$env:COLUMNS = '44'
$narrow = Write-SsmTunnelBanner '127.0.0.1' '15432' 'a-very-long-database-endpoint.rds.amazonaws.com' '5432'
Assert-True (@($narrow | ForEach-Object { $_.Length } | Sort-Object -Unique)[0] -le 44) 'COLUMNS narrows the box'
$env:COLUMNS = $null

Write-Host 'Test-SsmPort'

foreach ($p in @('1', '15432', '65535')) { Assert-True (Invoke-Capture { Test-SsmPort $p }) "$p is a port" }
# '+5' and ' 15432 ' are why this is a regex and not [int]::TryParse.
foreach ($p in @('0', '65536', 'abc', '-5', '154.32', '', '+5', ' 15432 ', '1e4', '0x10')) {
    Assert-False (Invoke-Capture { Test-SsmPort $p }) "'$p' is not a port"
}
Invoke-Capture { Test-SsmPort 'abc' } | Out-Null
Assert-Contains '1-65535' $script:LastErr 'the range is in the message'

Write-Host 'config file helpers'

$fixture = Join-Path ([IO.Path]::GetTempPath()) "ssm-test-$PID.json"
function Reset-Fixture {
    $json = '{"staging":{"profile":"sc-staging","region":"ap-southeast-5","databases":{"adam-db":15432}},' +
    '"production":{"profile":"sc-prod","region":"ap-southeast-1","databases":{}}}'
    [System.IO.File]::WriteAllText($fixture, $json)
    $script:CONFIG_FILE = $fixture
}
Reset-Fixture

Assert-True (Test-SsmAccountExists 'staging') 'an account that exists'
Assert-False (Test-SsmAccountExists 'nope') 'an account that does not'
Assert-False (Test-SsmAccountExists 'STAGING') 'account lookup is case-sensitive'

Assert-Eq 'sc-staging' (Get-SsmConfigValue 'staging' 'profile') 'reading a field'
Assert-Eq '' (Get-SsmConfigValue 'nope' 'profile') 'a missing account reads as empty'
Assert-Eq 'production staging' ((Get-SsmAccountList) -join ' ') 'accounts come back sorted by codepoint'

Reset-Fixture
Assert-True (Invoke-Capture { Rename-SsmAccount 'staging' 'stg' }) 'renaming an account'
Assert-Eq 'sc-staging' (Get-SsmConfigValue 'stg' 'profile') 'the profile follows the rename'
Assert-Eq 'ap-southeast-5' (Get-SsmConfigValue 'stg' 'region') 'the region follows the rename'
Assert-Eq 15432 (Get-SsmMember (Get-SsmMember (Get-SsmConfig) 'stg') 'databases').'adam-db' 'the db ports follow the rename'
Assert-False (Test-SsmAccountExists 'staging') 'the old name is gone'

Reset-Fixture
Assert-False (Invoke-Capture { Rename-SsmAccount 'staging' 'production' }) 'renaming onto an existing account is refused'
Assert-Contains 'already exists' $script:LastErr 'rename clash message'
Assert-Eq 'sc-prod' (Get-SsmConfigValue 'production' 'profile') 'the refused rename left the target alone'

Reset-Fixture
Assert-True (Invoke-Capture { Set-SsmDbPort 'production' 'prod-db' '15500' }) 'setting a port'
$stored = (Get-SsmMember (Get-SsmMember (Get-SsmConfig) 'production') 'databases').'prod-db'
Assert-Eq 15500 $stored 'the port reads back'
# A port stored as a string drops out of the collision scan, silently.
Assert-True ($stored -is [int] -or $stored -is [long]) 'the port is stored as a JSON number, not a string'
Assert-Contains '"prod-db": 15500' ([System.IO.File]::ReadAllText($fixture)) 'the file holds an unquoted number'

Assert-True (Invoke-Capture { Set-SsmDbPort 'production' 'zero-db' '015441' }) 'a leading-zero port'
Assert-Eq 15441 (Get-SsmMember (Get-SsmMember (Get-SsmConfig) 'production') 'databases').'zero-db' 'the leading zero is normalised'

Invoke-Capture { Set-SsmDbPort 'production' 'clash-db' '15432' } | Out-Null
Assert-Contains 'already assigned to staging.adam-db' $script:LastErr 'a clash warns and still writes'

Reset-Fixture
Assert-True (Invoke-Capture { Remove-SsmDbPort 'staging' 'adam-db' }) 'removing a port'
Assert-True (Test-SsmAccountExists 'staging') 'the account survives'
Assert-False (Invoke-Capture { Remove-SsmDbPort 'staging' 'nope' }) 'removing an unknown port is refused'
Assert-Contains 'no port assignment' $script:LastErr 'unknown port message'

# The whole config survives a read-write round trip unchanged: this is what
# catches ConvertTo-Json's default -Depth 2, which turns the databases object
# into the string "System.Management.Automation.PSCustomObject".
Reset-Fixture
$before = [System.IO.File]::ReadAllText($fixture)
Save-SsmConfig (Get-SsmConfig)
$after = Get-SsmConfig
Assert-Eq 'staging production' ((@($after.PSObject.Properties.Name)) -join ' ') 'a round trip keeps the key order'
Assert-Eq 15432 (Get-SsmMember (Get-SsmMember $after 'staging') 'databases').'adam-db' 'a round trip keeps nested ports'
Assert-Contains '15432' ([System.IO.File]::ReadAllText($fixture)) 'a round trip keeps the port in the file'

Write-Host 'Get-SsmConfigNumbers / Get-SsmFreePort'

[System.IO.File]::WriteAllText($fixture, '{"a":{"databases":{"x":15432,"y":"15433"}}}')
$numbers = @(Get-SsmConfigNumbers)
Assert-True ($numbers -contains 15432) 'a JSON number is found'
# jq's [.. | numbers] skips a string, so this must too, or a port written as a
# string would quietly stop protecting anyone from a collision.
Assert-False ($numbers -contains 15433) 'a port stored as a string is not a number'

Reset-Fixture
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$busy = $listener.LocalEndpoint.Port
try {
    Assert-True ((Get-SsmFreePort $busy) -ne $busy) 'a port in use is skipped'
} finally { $listener.Stop() }
Assert-True ((Get-SsmFreePort 15432) -ne 15432) 'a port assigned in the config is skipped'

Remove-Item $fixture -Force -ErrorAction SilentlyContinue

Write-Host 'version'

Assert-Eq 'dev' (Get-SsmScriptVersion (Join-Path $here '../ssm.ps1')) 'the repository copy is dev'
Assert-Eq 'unknown' (Get-SsmScriptVersion (Join-Path $here '../nope.ps1')) 'a missing file is unknown'

$stamped = Join-Path ([IO.Path]::GetTempPath()) "ssm-stamp-$PID.ps1"
[System.IO.File]::WriteAllText($stamped, "#Requires -Version 7.2`n`$SSM_VERSION = 'v9.9.9'`n")
Assert-Eq 'v9.9.9' (Get-SsmScriptVersion $stamped) 'a stamped PowerShell copy'
# Also reads the bash spelling, for anyone whose ~/.ssm once held ssm.sh.
[System.IO.File]::WriteAllText($stamped, "#!/bin/bash`nSSM_VERSION=`"v8.8.8`"`n")
Assert-Eq 'v8.8.8' (Get-SsmScriptVersion $stamped) 'a stamped bash copy'
[System.IO.File]::WriteAllText($stamped, "nothing here`n")
Assert-Eq 'unknown' (Get-SsmScriptVersion $stamped) 'an unstamped copy is unknown'
Remove-Item $stamped -Force -ErrorAction SilentlyContinue

Write-Host 'Invoke-SsmSelfReplace'

$replaceDir = Join-Path ([IO.Path]::GetTempPath()) "ssm-replace-$PID"
New-Item -ItemType Directory -Path $replaceDir -Force | Out-Null
$target = Join-Path $replaceDir 'ssm.ps1'
$staged = Join-Path $replaceDir 'ssm.ps1.new'
[System.IO.File]::WriteAllText($target, "old`n")
[System.IO.File]::WriteAllText($staged, "new`n")
Invoke-SsmSelfReplace $target $staged
Assert-Eq "new`n" ([System.IO.File]::ReadAllText($target)) 'the target is replaced'
Assert-False (Test-Path "$target.old") 'the .old copy is cleaned up'
Assert-False (Test-Path $staged) 'the staged copy is gone'
Remove-Item $replaceDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'Remove-SsmPathEntry'

Assert-Eq 'C:\a;C:\b' (Remove-SsmPathEntry 'C:\a;C:\ssm;C:\b' 'C:\ssm') 'the entry is removed'
Assert-Eq 'C:\a;C:\b' (Remove-SsmPathEntry 'C:\a;C:\ssm\;C:\b' 'C:\ssm') 'a trailing backslash still matches'
Assert-Eq 'C:\a;C:\b' (Remove-SsmPathEntry 'C:\a;C:\b' 'C:\ssm') 'an absent entry changes nothing'
Assert-Eq 'C:\a;C:\b' (Remove-SsmPathEntry 'C:\a;;C:\b' 'C:\ssm') 'empty segments are dropped'
Assert-Eq 'C:\a' (Remove-SsmPathEntry 'C:\a;C:\ssm;C:\ssm' 'C:\ssm') 'a duplicated entry goes entirely'

Write-Host 'Select-SsmPickerView'

$items = [string[]]@('staging', 'production', 'stg-eu')
Assert-Eq 3 (Select-SsmPickerView $items '').Count 'an empty filter keeps everything'
Assert-Eq 'stg-eu' ((Select-SsmPickerView $items 'stg') -join ',') 'a substring filter'
Assert-Eq 'stg-eu' ((Select-SsmPickerView $items 'STG') -join ',') 'the filter ignores case'
Assert-Eq 0 (Select-SsmPickerView $items 'zzz').Count 'no matches is empty, not everything'

Write-Host 'ConvertTo-SsmCanonicalFlag'

Assert-Eq '--env' (ConvertTo-SsmCanonicalFlag '-e') '-e'
Assert-Eq '--env' (ConvertTo-SsmCanonicalFlag '--account') '--account'
Assert-Eq '--namespace' (ConvertTo-SsmCanonicalFlag '-n') '-n'
Assert-Eq '--container' (ConvertTo-SsmCanonicalFlag '-c') '-c'
Assert-Eq '--help' (ConvertTo-SsmCanonicalFlag '-h') '-h'
Assert-Eq '-E' (ConvertTo-SsmCanonicalFlag '-E') 'aliases are case-sensitive'
Assert-Eq '--other' (ConvertTo-SsmCanonicalFlag '--other') 'anything else passes through'

Write-Host 'Remove-SsmAwsProfile'

$awsDir = Join-Path ([IO.Path]::GetTempPath()) "ssm-aws-$PID"
New-Item -ItemType Directory -Path $awsDir -Force | Out-Null
$creds = Join-Path $awsDir 'credentials'
$env:AWS_SHARED_CREDENTIALS_FILE = $creds
$env:AWS_CONFIG_FILE = Join-Path $awsDir 'config'

[System.IO.File]::WriteAllText($creds, @"
# a comment worth keeping
[keep-me]
aws_access_key_id=AKIAKEEP

[sc-staging]
aws_access_key_id=AKIAGONE
aws_secret_access_key=secret

[sso-session my-sso]
sso_region=ap-southeast-1
"@)
Remove-SsmAwsProfile 'sc-staging'
$left = [System.IO.File]::ReadAllText($creds)
Assert-Contains '# a comment worth keeping' $left 'comments survive'
Assert-Contains '[keep-me]' $left 'other profiles survive'
Assert-Contains 'aws_access_key_id=AKIAKEEP' $left 'key spacing is not normalised'
Assert-Contains '[sso-session my-sso]' $left 'an sso-session block is left alone'
Assert-NotContains 'AKIAGONE' $left 'the target profile is gone'
Assert-NotContains '[sc-staging]' $left 'the target section header is gone'
# A BOM here makes botocore miss the first section entirely.
$bytes = [System.IO.File]::ReadAllBytes($creds)
Assert-False ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'the file has no BOM'

[System.IO.File]::WriteAllText($creds, "[other]`nk=v`n")
$mtime = (Get-Item $creds).LastWriteTimeUtc
Start-Sleep -Milliseconds 20
Remove-SsmAwsProfile 'absent-profile'
Assert-Eq $mtime (Get-Item $creds).LastWriteTimeUtc 'a file with no matching section is not rewritten'

$env:AWS_SHARED_CREDENTIALS_FILE = $null
$env:AWS_CONFIG_FILE = $null
Remove-Item $awsDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'uninstall'

$launcherDir = Join-Path ([IO.Path]::GetTempPath()) "ssm-launcher-$PID"
New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
$ours = Join-Path $launcherDir 'ssm.cmd'
Write-SsmLauncher $ours
Assert-True (Test-SsmOwnLauncher $ours) 'the shim we wrote is recognised as ours'
Assert-Contains "`r`n" ([System.IO.File]::ReadAllText($ours)) 'the shim is written CRLF for cmd.exe'
$bytes = [System.IO.File]::ReadAllBytes($ours)
Assert-False ($bytes[0] -eq 0xEF) 'the shim has no BOM'
[System.IO.File]::WriteAllText($ours, "@echo off`r`nsomething else`r`n")
Assert-False (Test-SsmOwnLauncher $ours) 'a shim we did not write is left alone'
Remove-Item $launcherDir -Recurse -Force -ErrorAction SilentlyContinue

# Builds the real rows against a scratch directory. -f binds looser than the
# comma in a method call, so an unparenthesised `.Add("..." -f $a, $b)` passes
# two arguments and throws at runtime -- which nothing else here would catch.
$rowsDir = Join-Path ([IO.Path]::GetTempPath()) "ssm-rows-$PID"
New-Item -ItemType Directory -Path $rowsDir -Force | Out-Null
Set-Content (Join-Path $rowsDir 'config.json') '{}'
$SSM_DIR = $rowsDir
$AWS_CLI_DIR = Join-Path $rowsDir 'awscli'
$SSM_PLUGIN_DIR = Join-Path $rowsDir 'plugin'
New-Item -ItemType Directory -Path $AWS_CLI_DIR -Force | Out-Null
New-Item -ItemType Directory -Path $SSM_PLUGIN_DIR -Force | Out-Null

$built = Get-SsmUninstallRows
Assert-Eq 3 $built.Count 'only the items that are present are offered'
Assert-Eq 'config' (($built[0] -split "`t")[0]) 'the config row comes first, as install order'
Assert-Contains 'config.json, db ports, kubeconfig' ($built -join "`n") 'the config row is formatted'
Assert-Contains 'AWS CLI v2' ($built -join "`n") 'the AWS CLI row is formatted'
Assert-Contains '(admin)' ($built -join "`n") 'the rows needing admin say so'

# A bare install -- nothing in ~/.ssm but the script -- offers nothing.
Remove-Item (Join-Path $rowsDir 'config.json') -Force
Remove-Item $AWS_CLI_DIR, $SSM_PLUGIN_DIR -Recurse -Force
Set-Content (Join-Path $rowsDir 'ssm.ps1') '# script'
Assert-Eq 0 (Get-SsmUninstallRows).Count 'a bare install offers nothing optional'
Remove-Item $rowsDir -Recurse -Force -ErrorAction SilentlyContinue

$ARG_PURGE = ''; $ARG_WITH_DEPS = ''
$rows = [string[]]@("config`t~/.ssm", "junegunn.fzf`tfzf", "Amazon.AWSCLI`tAWS CLI v2")
Assert-Eq '' ((Get-SsmUninstallFlaggedKeys $rows) -join ' ') 'neither flag selects nothing'
$ARG_WITH_DEPS = '1'
Assert-Eq 'junegunn.fzf Amazon.AWSCLI' ((Get-SsmUninstallFlaggedKeys $rows) -join ' ') '--with-deps selects dependencies, not config'
$ARG_WITH_DEPS = ''; $ARG_PURGE = '1'
Assert-Eq 'config' ((Get-SsmUninstallFlaggedKeys $rows) -join ' ') '--purge selects config, not dependencies'
$ARG_WITH_DEPS = '1'
Assert-Eq 'config junegunn.fzf Amazon.AWSCLI' ((Get-SsmUninstallFlaggedKeys $rows) -join ' ') 'both select both'
$ARG_PURGE = ''; $ARG_WITH_DEPS = ''

Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host "ok — $($script:Passed) assertions passed"
} else {
    [Console]::Error.WriteLine("$($script:Failed) of $($script:Passed + $script:Failed) assertions failed")
    exit 1
}
