# Installs ssm and its dependencies on Windows 11.
#
#   irm https://cdn.supplycart.my/shells/aws-ssm-manager/install.ps1 | iex
#   $env:SSM_INSTALL_VERSION = 'v1.1.0'; irm https://cdn.supplycart.my/shells/aws-ssm-manager/install.ps1 | iex
#
# Written to run under Windows PowerShell 5.1 as well as PowerShell 7, because
# "powershell" in the Start Menu is still 5.1 and that is where this gets
# pasted. So: no ternaries, no null-coalescing, no $IsWindows. ssm.ps1 itself
# requires PowerShell 7, which this installs.

param([string]$Version)

# Get-SsmAssetUrl <latest|vX.Y.Z> <ssm.ps1>
# Prints the CDN URL of that file. Every release keeps its own copy under
# shells/aws-ssm-manager/vX.Y.Z/, so any released version can be installed.
# Anything but a plain release tag is refused, since it ends up in a URL -- and
# so is any file name other than the one we publish, for the same reason.
function Get-SsmAssetUrl {
    param([string]$Version, [string]$File)

    $tagRe = '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
    $base = 'https://cdn.supplycart.my/shells/aws-ssm-manager'

    if ($File -cne 'ssm.ps1') {
        [Console]::Error.WriteLine("Error: '$File' is not a release file.")
        return
    }
    if ($Version -ceq 'latest') { return "$base/$File" }
    if ($Version -cmatch $tagRe) { return "$base/$Version/$File" }

    [Console]::Error.WriteLine("Error: '$Version' is not a version. Pass a release tag such as v1.1.0, or nothing for the latest.")
    return
}

# test/install_ps_test.ps1 dot-sources this file for the helper above; stop
# before installing anything. InvocationName is '.' only when dot-sourced.
#
# Everything below this line, including $ErrorActionPreference, is deliberately
# after the guard: a dot-sourced script sets preference variables in the
# caller's scope, so setting it above would leak Stop into the test harness.
if ($MyInvocation.InvocationName -eq '.') { return }

$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$m) Write-Host "==> $m" -ForegroundColor Blue }
function Write-Ok { param([string]$m) Write-Host "[ok] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[!] $m" -ForegroundColor Yellow }
# Not `exit`. The documented way to run this is `irm ... | iex`, and `exit`
# inside Invoke-Expression terminates the whole PowerShell session -- the
# window closes instantly and takes the reason with it, which is how a failed
# install looks exactly like a finished one. A throw stops the install, leaves
# the message on screen, and still exits non-zero under `pwsh -File`.
function Write-Fail {
    param([string]$m)
    # Printed, then thrown terse: PowerShell's error formatter reflows what it
    # is given into the error gutter, which destroys the line breaks in the
    # multi-line messages below and jams URLs mid-sentence. So the readable
    # copy goes out first and the throw only has to stop the install.
    Write-Host "[x] $m" -ForegroundColor Red
    throw 'ssm was not installed.'
}

# ---------------------------------------------------------------------------
# Platform gate. The mirror of install.sh's `uname != Darwin`.
# ---------------------------------------------------------------------------
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Fail 'This script only supports Windows. On macOS use install.sh.'
}
$build = [Environment]::OSVersion.Version.Build
if ($build -lt 19041) {
    Write-Fail "This script needs Windows 10 2004 (build 19041) or newer; this is build $build."
}
if ($build -lt 22000) {
    # Everything used here works on Windows 10 21H2, so warn rather than refuse.
    Write-Warn "Windows 11 is what this is tested on; you are on build $build. Continuing."
}

# ---------------------------------------------------------------------------
# Resolve and validate the version before anything is installed, so a typo
# fails here rather than after the AWS CLI is already on the machine.
# irm | iex cannot pass arguments, hence the environment variable.
# ---------------------------------------------------------------------------
if (-not $Version) { $Version = $env:SSM_INSTALL_VERSION }
if (-not $Version) { $Version = 'latest' }

$ssmUrl = Get-SsmAssetUrl $Version 'ssm.ps1'
if (-not $ssmUrl) { throw 'Nothing was installed.' }

try {
    $response = Invoke-WebRequest -Uri $ssmUrl -Method Head -UseBasicParsing
    $status = [int]$response.StatusCode
} catch {
    $status = 0
    if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
        $status = [int]$_.Exception.Response.StatusCode
    }
}
if ($status -eq 403 -or $status -eq 404) {
    Write-Fail "ssm $Version has no Windows build. Released versions: https://github.com/supplycart/aws-ssm-manager/releases"
} elseif ($status -ne 200) {
    Write-Fail "Could not reach $ssmUrl (HTTP $status). Check your connection and try again."
}

# There is no counterpart to install.sh's "don't pipe me into bash" guard.
# That exists only because of the sudo prompt; nothing here reads a password,
# so `irm | iex` is safe and is the documented way to run this.

# ---------------------------------------------------------------------------
# Dependencies, via winget. Unlike install.sh, which bootstraps Homebrew, this
# does not bootstrap winget: it ships with Windows 11, and installing App
# Installer without the Store is not a road worth going down.
# ---------------------------------------------------------------------------
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Fail @'
winget is required but not available. It ships with Windows 11 as part of
App Installer. Install it from the Microsoft Store:
  https://apps.microsoft.com/detail/9nblggh4nns1
then run this script again.
'@
}

function Install-SsmPackage {
    param([string]$Id, [switch]$UserScope, [switch]$Optional)

    winget list --id $Id --exact --accept-source-agreements 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "$Id already installed"
        return
    }

    Write-Info "Installing $Id ..."
    $common = @('install', '--id', $Id, '--exact', '--silent',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity')

    if ($UserScope) {
        winget @common --scope user 2>&1 | Out-Null
        # 0x8a15010c: no installer for that scope. winget fails rather than
        # falling back, so retry machine-wide.
        if ($LASTEXITCODE -eq -1978335092) { winget @common 2>&1 | Out-Null }
    } else {
        winget @common 2>&1 | Out-Null
    }

    if ($LASTEXITCODE -ne 0) {
        if ($Optional) {
            Write-Warn "Could not install $Id (exit $LASTEXITCODE). ssm works without it."
        } else {
            Write-Fail "Could not install $Id (exit $LASTEXITCODE)."
        }
        return
    }
    Write-Ok "$Id installed"
}

Write-Info 'Windows may ask for permission once per AWS installer.'

# ssm.ps1 needs PowerShell 7; the shim below invokes pwsh by name.
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Install-SsmPackage -Id 'Microsoft.PowerShell'
} else {
    Write-Ok 'PowerShell 7 already installed'
}

Install-SsmPackage -Id 'Amazon.AWSCLI'
Install-SsmPackage -Id 'Amazon.SessionManagerPlugin'
Install-SsmPackage -Id 'Kubernetes.kubectl' -UserScope
# fzf only makes the menus nicer; ssm falls back to a built-in picker.
Install-SsmPackage -Id 'junegunn.fzf' -UserScope -Optional

# No jq. PowerShell parses JSON itself, so Windows has one fewer dependency
# than macOS.

# ---------------------------------------------------------------------------
# The script itself. Same location as macOS -- $HOME\.ssm is %USERPROFILE%\.ssm
# -- so config.json is documented once and is literally portable between them.
# ---------------------------------------------------------------------------
$ssmDir = Join-Path $env:USERPROFILE '.ssm'
$ssmScript = Join-Path $ssmDir 'ssm.ps1'
$ssmLauncher = Join-Path $ssmDir 'ssm.cmd'
$configFile = Join-Path $ssmDir 'config.json'

if (-not (Test-Path -LiteralPath $ssmDir)) {
    New-Item -ItemType Directory -Path $ssmDir -Force | Out-Null
    # A dot prefix means nothing to Explorer, so hide it the Windows way.
    (Get-Item -LiteralPath $ssmDir -Force).Attributes = 'Directory, Hidden'
}

Write-Info "Downloading ssm.ps1 ($Version) ..."
$staged = "$ssmScript.new"
Invoke-WebRequest -Uri $ssmUrl -OutFile $staged -UseBasicParsing

# A truncated download would install an ssm that cannot even update itself.
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($staged, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) {
    Remove-Item $staged -Force -ErrorAction SilentlyContinue
    Write-Fail "The download from $ssmUrl is not a valid script."
}
Move-Item -LiteralPath $staged -Destination $ssmScript -Force
# Downloaded files carry Mark-of-the-Web, which trips the execution policy.
Unblock-File -LiteralPath $ssmScript -ErrorAction SilentlyContinue
Write-Ok "Installed $ssmScript"

# The shim is written, not downloaded: .ps1 is not in PATHEXT and cmd.exe
# cannot run one, so this is what makes the bare word `ssm` resolve. cmd.exe
# reads batch files lazily and is unforgiving about line endings and a BOM,
# so generating it locally keeps those bytes out of git and off the CDN.
# ssm.ps1 holds the same text and rewrites it on `ssm update`.
# It locates pwsh rather than naming it, because on a fresh machine winget has
# just installed PowerShell 7 into a PATH this process cannot see -- so the
# terminal that ran the installer would otherwise get "'pwsh' is not
# recognized". setlocal keeps the widened PATH inside this one invocation.
$launcherText = @"
@echo off
setlocal
where /q pwsh.exe && goto :run
set "PATH=%ProgramFiles%\PowerShell\7;%LOCALAPPDATA%\Microsoft\PowerShell\7;%PATH%"
where /q pwsh.exe || goto :nopwsh
:run
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssm.ps1" %*
exit /b %ERRORLEVEL%
:nopwsh
echo ssm needs PowerShell 7. Install it with:  winget install Microsoft.PowerShell 1>&2
exit /b 9009
"@
$crlf = ($launcherText -replace "`r?`n", "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($ssmLauncher, $crlf, (New-Object System.Text.ASCIIEncoding))
Write-Ok "Installed $ssmLauncher"

if (-not (Test-Path -LiteralPath $configFile)) {
    [System.IO.File]::WriteAllText($configFile, "{}`n", (New-Object System.Text.UTF8Encoding $false))
    Write-Ok "Created $configFile"
}

# ---------------------------------------------------------------------------
# PATH. The user scope only, so none of this needs admin -- and no symlink,
# which would need Developer Mode.
# ---------------------------------------------------------------------------

# Writing the registry is only half of setting the PATH. Explorer reads the
# environment once and hands that cached copy to every process it starts, so
# until it is told otherwise even a brand-new terminal gets the old PATH and
# `ssm` stays unrecognised until the next sign-out. WM_SETTINGCHANGE is what
# tells it. [Environment]::SetEnvironmentVariable broadcasts this for you, but
# writes the value back as REG_SZ -- which is exactly the REG_EXPAND_SZ
# downgrade the hand-rolled write below exists to avoid. So: write by hand,
# broadcast by hand.
function Publish-SsmEnvironmentChange {
    if (-not ('SsmInstall.NativeMethods' -as [type])) {
        Add-Type -Namespace 'SsmInstall' -Name 'NativeMethods' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $unused = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, five seconds: one
    # hung top-level window must not hold the installer open. Zero back means
    # it timed out or aborted -- the very case those flags exist for -- and it
    # returns that quietly, so the result has to be read or the failure is
    # invisible and the user is back at "ssm is not recognized".
    $sent = [SsmInstall.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$unused)
    return ($sent -ne [IntPtr]::Zero)
}

$key = Get-Item 'HKCU:\Environment'
# DoNotExpandEnvironmentNames: the usual accessor expands %USERPROFILE% and
# friends, and writing that back bakes the expansion in permanently and can
# downgrade REG_EXPAND_SZ to REG_SZ. Never use setx here either -- it
# truncates at 1024 characters and will quietly corrupt a long PATH.
$rawPath = $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
$already = $false
foreach ($part in ($rawPath -split ';')) {
    if ($part -and ($part.TrimEnd('\') -eq $ssmDir.TrimEnd('\'))) { $already = $true }
}
if ($already) {
    Write-Ok 'ssm is already on your PATH'
} else {
    $newPath = $rawPath
    if ($newPath -and -not $newPath.EndsWith(';')) { $newPath += ';' }
    $newPath += $ssmDir
    $kind = 'ExpandString'
    try { $kind = $key.GetValueKind('Path') } catch { }
    [Microsoft.Win32.Registry]::SetValue('HKEY_CURRENT_USER\Environment', 'Path', $newPath, $kind)
    Write-Ok 'Added ssm to your user PATH'
}
# Broadcast in both branches, not just after a write: an earlier install that
# set the entry without announcing it leaves a machine where the registry is
# right and every new terminal still disagrees. Re-running this repairs that.
$announced = $false
try {
    $announced = Publish-SsmEnvironmentChange
} catch {
    Write-Warn "Could not tell Windows the PATH changed: $($_.Exception.Message)"
}
if (-not $announced) {
    Write-Warn 'Windows did not acknowledge the PATH change.'
    Write-Warn 'If a new terminal cannot find ssm, sign out and back in once.'
}
# Usable in this session too, without reopening anything.
$env:Path = "$env:Path;$ssmDir"

# ---------------------------------------------------------------------------
# Shortcuts. This is what makes it app-like: double-click and ssm asks what you
# want to do, because ssm.ps1 with no arguments opens its menu.
# ---------------------------------------------------------------------------
$pwshPath = $null
$pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
if ($pwshCmd) { $pwshPath = $pwshCmd.Source }
if (-not $pwshPath) {
    $guess = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $guess) { $pwshPath = $guess }
}

if (-not $pwshPath) {
    Write-Warn 'Could not find pwsh.exe, so no shortcuts were created. Open a new terminal and run: ssm'
} else {
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    # GetFolderPath, not "$env:USERPROFILE\Desktop": OneDrive Known Folder Move
    # redirects Desktop on most corporate machines, and the hard-coded path
    # would put a dead shortcut in a folder nobody looks at.
    $desktop = [Environment]::GetFolderPath('Desktop')

    $shell = New-Object -ComObject WScript.Shell
    foreach ($dir in @($startMenu, $desktop)) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        try {
            $lnk = $shell.CreateShortcut((Join-Path $dir 'ssm.lnk'))
            $lnk.TargetPath = $pwshPath
            # -NoExit so the window stays put after a session ends, rather than
            # vanishing and taking any error message with it.
            $lnk.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -NoExit -File `"$ssmScript`""
            $lnk.WorkingDirectory = $env:USERPROFILE
            $lnk.Description = 'AWS SSM Manager'
            $lnk.Save()
            Write-Ok "Created shortcut in $dir"
        } catch {
            Write-Warn "Could not create a shortcut in ${dir}: $($_.Exception.Message)"
        }
    }
}

# Prove it rather than promise it, and prove the whole chain: that `ssm`
# resolves, that the shim finds pwsh, and that the downloaded script runs.
# Checking only that the shim exists would pass on a machine where ssm still
# cannot start -- the shim was written a hundred lines ago and its presence was
# never the doubtful part.
$probe = ''
$probeOk = $false
try {
    $probe = (& $ssmLauncher version 2>&1) -join ' '
    $probeOk = ($LASTEXITCODE -eq 0)
} catch {
    $probe = $_.Exception.Message
}
if (-not $probeOk) {
    Write-Warn 'ssm was installed but did not run:'
    Write-Warn "  $probe"
    Write-Warn "Try it directly: $ssmLauncher version"
} elseif (-not (Get-Command ssm -ErrorAction SilentlyContinue)) {
    # It runs, but the bare word does not resolve -- PATHEXT, almost certainly.
    Write-Warn "ssm runs, but the name does not resolve yet; use $ssmLauncher"
}

Write-Host ''
Write-Ok 'ssm installed.'
Write-Host ''
Write-Host '  Double-click the ssm shortcut, or open a NEW terminal and run:'
Write-Host '    ssm              pick what to do from a menu'
Write-Host '    ssm config add   add your first AWS account'
Write-Host '    ssm help         the full flag reference'
Write-Host ''
Write-Host '  Terminals that were already open keep their old PATH; new ones are fine.'
if ($Version -cne 'latest') {
    Write-Host ''
    Write-Warn "Pinned to $Version. Running 'ssm update' later moves it to the latest release."
}
