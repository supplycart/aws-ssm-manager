# Unit tests for install.ps1's version handling, the counterpart of
# test/install_test.sh. Dot-sourcing install.ps1 defines Get-SsmAssetUrl and
# stops before it installs anything, so this runs anywhere pwsh does --
# including the Linux CI runner.
#
# Run: pwsh -File test/install_ps_test.ps1

$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here '../install.ps1')

$script:Passed = 0
$script:Failed = 0

function Assert-Eq {
    param($Expected, $Actual, [string]$What)
    if ($Expected -ceq $Actual) { $script:Passed++ }
    else { $script:Failed++; [Console]::Error.WriteLine("  FAIL: ${What}: expected '$Expected', got '$Actual'") }
}

function Assert-True {
    param($Condition, [string]$What)
    if ($Condition) { $script:Passed++ }
    else { $script:Failed++; [Console]::Error.WriteLine("  FAIL: $What") }
}

Write-Host 'dot-sourcing install.ps1'

Assert-True (Get-Command Get-SsmAssetUrl -ErrorAction SilentlyContinue) 'the helper is defined'
# The guard sits above $ErrorActionPreference precisely so this stays Continue:
# a dot-sourced script sets preference variables in the caller's scope.
Assert-Eq 'Continue' $ErrorActionPreference 'sourcing stops before the Stop preference'
Assert-Eq $null (Get-Command Write-Fail -ErrorAction SilentlyContinue) 'sourcing stops before the install helpers'

Write-Host 'Get-SsmAssetUrl'

$cdn = 'https://cdn.supplycart.my/shells/aws-ssm-manager'
Assert-Eq "$cdn/ssm.ps1" (Get-SsmAssetUrl 'latest' 'ssm.ps1') 'latest is the unversioned copy'
Assert-Eq "$cdn/v1.2.3/ssm.ps1" (Get-SsmAssetUrl 'v1.2.3' 'ssm.ps1') 'a release tag'
Assert-Eq "$cdn/v1.10.0/ssm.ps1" (Get-SsmAssetUrl 'v1.10.0' 'ssm.ps1') 'parts are numbers, not digits'
Assert-Eq "$cdn/v0.0.1/ssm.ps1" (Get-SsmAssetUrl 'v0.0.1' 'ssm.ps1') 'zero parts'

# The same rejections test/install_test.sh:51-55 pins for the bash side.
$bad = @('', '1.2.3', 'v1.2', 'v1.2.3.4', 'v1.2.3-rc1', 'v01.2.3', 'V1.2.3', 'LATEST',
    'v1.2.3;rm -rf ~', 'v1.2.3/../x', '../v1.2.3', ' v1.2.3')
foreach ($v in $bad) {
    $out = Get-SsmAssetUrl $v 'ssm.ps1' 2>$null
    Assert-Eq $null $out "'$v' is refused and prints no URL"
}

# The file name ends up in a URL too, so it is an allow-list, not a parameter.
foreach ($f in @('ssm.sh', 'install.ps1', '../ssm.ps1', 'ssm.ps1 ')) {
    $out = Get-SsmAssetUrl 'latest' $f 2>$null
    Assert-Eq $null $out "file name '$f' is refused"
}

Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host "ok — $($script:Passed) assertions passed"
} else {
    [Console]::Error.WriteLine("$($script:Failed) of $($script:Passed + $script:Failed) assertions failed")
    exit 1
}
