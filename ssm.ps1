#Requires -Version 7.2
# ssm for Windows 11 -- the PowerShell counterpart of ssm.sh.
#
# The two files are one CLI with two implementations: every command and every
# flag exists in both, and test/parity_test.sh fails the build if they drift.
# Each function below carries a "# bash:" anchor naming the function it mirrors
# and the line it starts on, so the two can be read side by side.
#
# Where the platforms legitimately differ -- jq vs ConvertFrom-Json, the db
# tunnel hostname, Homebrew vs winget, the PATH mechanism -- the difference is
# recorded in docs/src/reference/platforms.md and nowhere else.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# A native command exiting non-zero is data here, not an error: kubectl_exec
# retries /bin/sh after /bin/bash fails, discover_ecs_services falls back to the
# slow path, and fzf exits 130 when a menu is cancelled. Without this, PowerShell
# 7.3+ turns each of those into a terminating error.
$PSNativeCommandUseErrorActionPreference = $false
# Quote native-command arguments the way the target expects, which matters for
# the JSON payloads that ssm start-session takes.
$PSNativeCommandArgumentPassing = 'Standard'

$CONFIG_FILE = Join-Path $HOME '.ssm/config.json'
# The release workflow rewrites this line to the release tag (stamp_version in
# .github/scripts/release.sh), so it must stay exactly $SSM_VERSION = 'dev' here.
$SSM_VERSION = 'dev'
# Set by the dispatch block at the bottom. Only used to name the command in
# error and usage messages.
$COMMAND = ''

$SSM_CDN_BASE = 'https://cdn.supplycart.my/shells/aws-ssm-manager'

# There is no jq gate to mirror from ssm.sh:12-15. PowerShell parses JSON
# itself, so Windows has one fewer dependency and nothing to check for.

# ---------------------------------------------------------------------------
# The flag set, per command. ssm.sh keeps these inline in each cmd_* call to
# parse_args; here they live in one table because test/parity_test.sh reads it,
# and because a command then physically cannot accept a flag it never declared.
# Adding a flag means editing this table, ssm.sh, and commands.manifest.
# ---------------------------------------------------------------------------
$SSM_COMMANDS = [ordered]@{
    ssh       = @{ Value = '--env --app --type --instance --container --task'; Bool = '--host' }
    pod       = @{ Value = '--env --cluster --namespace --pod --container'; Bool = '' }
    db        = @{ Value = '--env --app --db --instance'; Bool = '' }
    config    = @{
        Value = '--env --name --profile --region --access-key --secret-key --db --port'
        Bool  = '--skip-credentials --force --yes --delete-profile'
    }
    update    = @{ Value = ''; Bool = '' }
    uninstall = @{ Value = ''; Bool = '--yes --purge --with-deps' }
    version   = @{ Value = ''; Bool = '' }
    help      = @{ Value = ''; Bool = '' }
}

# ---------------------------------------------------------------------------
# Terminal styling. Colour is on only when stdout is a terminal, so piped or
# redirected output stays plain text; NO_COLOR turns it off everywhere.
# ---------------------------------------------------------------------------
# bash: the colour block (ssm.sh:21)
if (-not [Console]::IsOutputRedirected -and -not $env:NO_COLOR) {
    $C_RESET = "`e[0m"; $C_BOLD = "`e[1m"; $C_DIM = "`e[2m"
    $C_GREEN = "`e[32m"; $C_YELLOW = "`e[33m"
} else {
    $C_RESET = ''; $C_BOLD = ''; $C_DIM = ''; $C_GREEN = ''; $C_YELLOW = ''
}

# ---------------------------------------------------------------------------
# Infrastructure with no bash counterpart: bash gets these from the shell.
# ---------------------------------------------------------------------------

# Every `>&2` in ssm.sh maps to this. Deliberately not Write-Error, which emits
# an ErrorRecord with an "At line:N char:M" block and, under the Stop
# preference set above, throws.
function Write-SsmErr {
    param([string]$Message = '')
    [Console]::Error.WriteLine($Message)
}

# stdout, straight to the console rather than into the pipeline. Anything a
# function writes to its output stream is the function's return value, so a
# caller that discards the return -- or, as with --help below, a throw that
# unwinds past it -- would swallow it.
function Write-SsmOut {
    param([string]$Message = '')
    [Console]::Out.WriteLine($Message)
}

# `exit N` inside a function. A bare `exit` would kill the test host, because
# the suite dot-sources this file rather than running it; bash gets away with
# `exit` because args_test.sh runs each case in a subshell.
class SsmExitException : System.Exception {
    [int]$Code
    SsmExitException([int]$code) : base("ssm exit $code") { $this.Code = $code }
}

function Exit-Ssm {
    param([int]$Code = 0)
    throw [SsmExitException]::new($Code)
}

# Config and credential writes go through a temp file in the same directory, so
# a crash mid-write cannot truncate the real one. UTF-8 without a BOM is not
# the default everywhere and a BOM breaks both jq on a shared config and
# botocore on ~/.aws/credentials.
function Write-SsmFile {
    param([string]$Path, [string]$Content)
    $tmp = "$Path.tmp.$PID"
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# aws may be a .exe or a .cmd shim depending on how it was installed; the .cmd
# re-parses its arguments through cmd.exe, which mangles the JSON payloads.
# Prefer the real executable, and resolve it once.
$script:SsmAwsCli = $null
function Get-SsmAwsCli {
    if ($script:SsmAwsCli) { return $script:SsmAwsCli }
    $found = @(Get-Command aws -CommandType Application -ErrorAction SilentlyContinue)
    if (-not $found) {
        Write-SsmErr 'Error: the AWS CLI is required but not installed. Run: winget install Amazon.AWSCLI'
        Exit-Ssm 1
    }
    $exe = $found | Where-Object { $_.Source -like '*.exe' } | Select-Object -First 1
    $script:SsmAwsCli = if ($exe) { $exe.Source } else { $found[0].Source }
    return $script:SsmAwsCli
}

# ---------------------------------------------------------------------------
# Config. jq's job on macOS; ConvertFrom-Json's here.
# ---------------------------------------------------------------------------

function Get-SsmConfig {
    if (-not (Test-Path -LiteralPath $script:CONFIG_FILE)) { return [pscustomobject]@{} }
    $raw = Get-Content -LiteralPath $script:CONFIG_FILE -Raw
    if (-not $raw -or -not $raw.Trim()) { return [pscustomobject]@{} }
    # Not -AsHashtable: a PSCustomObject keeps the file's key order, the way jq
    # does, so writing the config back does not reshuffle it.
    return $raw | ConvertFrom-Json
}

# -Depth 100 everywhere, never the default of 2. The config nests
# account -> databases -> port, and at the default depth that last level
# serialises as the string "System.Management.Automation.PSCustomObject".
function Save-SsmConfig {
    param($Config)
    Write-SsmFile $script:CONFIG_FILE (($Config | ConvertTo-Json -Depth 100) + "`n")
}

# Property lookup that tolerates a missing key under StrictMode, and is
# case-sensitive because jq's .["name"] is.
function Get-SsmMember {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    foreach ($p in $Object.PSObject.Properties) {
        if ($p.Name -ceq $Name) { return $p.Value }
    }
    return $null
}

# bash: load_config (ssm.sh:28)
function Get-SsmConfigValue {
    param([string]$Account, [string]$Field)
    $value = Get-SsmMember (Get-SsmMember (Get-SsmConfig) $Account) $Field
    if ($null -eq $value) { return '' }
    return [string]$value
}

# bash: list_accounts (ssm.sh:32)
function Get-SsmAccountList {
    # jq 'keys[]' sorts by codepoint; Sort-Object is culture-aware by default,
    # which would order the menu differently from macOS.
    # One property at a time, never .Properties.Name: PowerShell's member
    # enumeration throws under StrictMode when the collection is empty, and an
    # empty config.json -- what install.ps1 writes -- is exactly that. It made
    # every account command fail on a fresh install with "The property 'Name'
    # cannot be found on this object."
    $names = [string[]]@(foreach ($p in (Get-SsmConfig).PSObject.Properties) { $p.Name })
    # The leading comma, as everywhere else that returns an array: without it
    # a one-account config comes back as a bare string, and the caller's
    # .Count then throws "The property 'Count' cannot be found on this
    # object." -- which is every ssh, db and pod on a machine with exactly one
    # account, the state `ssm config add` leaves behind.
    return , ([string[]]([System.Linq.Enumerable]::OrderBy(
                [string[]]$names, [Func[string, string]] { param($s) $s }, [System.StringComparer]::Ordinal)))
}

# ---------------------------------------------------------------------------
# Argument handling.
# ---------------------------------------------------------------------------

# Every flag the script knows about, in any command. Read-SsmArgs clears all of
# them on entry so a second call in the same session starts clean.
$ALL_ARG_FLAGS = @(
    'env', 'app', 'type', 'instance', 'container', 'task', 'host', 'db', 'cluster',
    'namespace', 'pod', 'profile', 'region', 'access-key', 'secret-key',
    'skip-credentials', 'yes', 'delete-profile', 'name', 'port', 'force', 'purge',
    'with-deps'
)

# bash: arg_var (ssm.sh:164)
# --access-key -> ARG_ACCESS_KEY
function Get-SsmArgVarName {
    param([string]$Flag)
    return 'ARG_' + ($Flag -replace '^--', '').ToUpperInvariant().Replace('-', '_')
}

# bash: normalize_flag (ssm.sh:171)
# Short and legacy spellings resolve to one canonical flag. Case-sensitive,
# because bash's `case` is: -e and -E are not the same flag.
function ConvertTo-SsmCanonicalFlag {
    param([string]$Flag)
    switch -CaseSensitive ($Flag) {
        '-e' { return '--env' }
        '--account' { return '--env' }
        '-n' { return '--namespace' }
        '-c' { return '--container' }
        '-h' { return '--help' }
        default { return $Flag }
    }
}

# bash: die_usage (ssm.sh:181)
function Write-SsmUsageError {
    param([string]$Message)
    Write-SsmErr "Error: $Message"
    Write-SsmErr ''
    Get-SsmUsage $script:COMMAND | ForEach-Object { Write-SsmErr $_ }
}

# bash: parse_args (ssm.sh:193)
#
# Sets $script:ARG_<UPPER_SNAKE> -- --app adam sets ARG_APP, --host sets
# ARG_HOST='1'. Each command passes only the flags it accepts, so a flag that
# belongs to another command is rejected instead of silently ignored.
#
# Returns $true on success and $false where bash returns 1. Every comparison is
# ordinal: PowerShell's -eq, -contains and switch are case-insensitive by
# default, which would make --ENV a valid spelling of --env.
function Read-SsmArgs {
    param([string]$ValueFlags, [string]$BoolFlags, [string[]]$Rest)

    $value = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($ValueFlags -split '\s+' | Where-Object { $_ }),
        [System.StringComparer]::Ordinal)
    $bool = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@($BoolFlags -split '\s+' | Where-Object { $_ }),
        [System.StringComparer]::Ordinal)

    # bash unsets these (ssm.sh:198-200). Under StrictMode reading an unset
    # variable throws, so clear to '' instead: identical for every [[ -z ]] /
    # if (-not $ARG_X) test, and it keeps StrictMode on.
    foreach ($n in $script:ALL_ARG_FLAGS) {
        Set-Variable -Scope Script -Name (Get-SsmArgVarName "--$n") -Value ''
    }

    if ($null -eq $Rest) { return $true }

    $i = 0
    while ($i -lt $Rest.Count) {
        $raw = $Rest[$i]
        $val = ''
        $hasVal = $false

        if ($raw -clike '--*=*') {
            $eq = $raw.IndexOf('=')
            $key = $raw.Substring(0, $eq)
            $val = $raw.Substring($eq + 1)
            $hasVal = $true
        } else {
            $key = $raw
        }
        $key = ConvertTo-SsmCanonicalFlag $key

        if ($key -ceq '--help') {
            # Written straight to stdout: Exit-Ssm throws, and the exception
            # unwinds past the caller collecting this function's output, so
            # anything returned through the pipeline here is lost.
            Get-SsmUsage $script:COMMAND | ForEach-Object { Write-SsmOut $_ }
            Exit-Ssm 0
        }

        if ($bool.Contains($key)) {
            if ($hasVal) { Write-SsmUsageError "Option $key takes no value."; return $false }
            Set-Variable -Scope Script -Name (Get-SsmArgVarName $key) -Value '1'
            $i++
        } elseif ($value.Contains($key)) {
            if (-not $hasVal) {
                if ($Rest.Count - $i -lt 2) {
                    Write-SsmUsageError "Option $key requires a value."
                    return $false
                }
                $val = $Rest[$i + 1]
                $i++
            }
            # A bare "-" is a real value for --secret-key (read stdin). Anything
            # else starting with a dash is a missing value, not a value.
            if ($val -eq '' -or ($val -clike '-*' -and $val -cne '-')) {
                Write-SsmUsageError "Option $key requires a value."
                return $false
            }
            Set-Variable -Scope Script -Name (Get-SsmArgVarName $key) -Value $val
            $i++
        } else {
            $cmd = if ($script:COMMAND) { $script:COMMAND } else { '<command>' }
            Write-SsmUsageError "Unknown option '$raw' for ssm $cmd."
            return $false
        }
    }
    return $true
}

# Read-SsmArgs for a named command, taking the flag set from $SSM_COMMANDS so a
# command cannot drift from the table the parity test reads.
function Read-SsmCommandArgs {
    param([string]$Command, [string[]]$Rest)
    $spec = $script:SSM_COMMANDS[$Command]
    return Read-SsmArgs $spec.Value $spec.Bool $Rest
}

# bash: resolve_selection (ssm.sh:252)
#
#   Wanted       the flag value; '' means ask interactively
#   Context      where we looked, for the error message
#   Fields       comma-separated 1-based tab-field numbers to match Wanted
#                against, so an instance matches on either its id or its Name
#   Auto         'auto' to auto-select when there is exactly one candidate
#
# Returns the chosen row; the caller splits out the columns it wants. Returns
# $null rather than exiting, mirroring the bash `return 1` -- and here the
# diagnostics must go to stderr for the same reason they do there, because the
# caller is capturing the success stream.
function Resolve-SsmSelection {
    param(
        [string]$Wanted, [string]$Label, [string]$Context, [string]$Prompt,
        [string]$Fields, [string]$Auto, [string[]]$Rows
    )

    if (-not $Wanted) {
        if ($Rows.Count -eq 1 -and $Auto -eq 'auto') {
            Write-SsmChoice $Label "$($Rows[0]) (only one)"
            return $Rows[0]
        }
        $picked = Invoke-SsmMenu $Prompt $Rows
        if ($picked) { Write-SsmChoice $Label $picked }
        return $picked
    }

    $matched = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $Rows) {
        $cols = $row -split "`t"
        foreach ($field in ($Fields -split ',')) {
            $idx = [int]$field - 1
            if ($idx -ge 0 -and $idx -lt $cols.Count -and $cols[$idx] -ceq $Wanted) {
                $matched.Add($row)
                break
            }
        }
    }

    if ($matched.Count -eq 1) {
        Write-SsmChoice $Label $matched[0]
        return $matched[0]
    }

    if ($matched.Count -eq 0) {
        Write-SsmErr "Error: no $Label '$Wanted' in $Context."
        Write-SsmErr 'Available:'
        foreach ($row in $Rows) { Write-SsmErr "  $row" }
    } else {
        Write-SsmErr "Error: ambiguous $Label '$Wanted' in $Context. Matches:"
        foreach ($row in $matched) { Write-SsmErr "  $row" }
    }
    return $null
}

# bash: read_secret_value (ssm.sh:296)
#
# Secrets never come from a flag value -- that puts them in shell history and in
# the process list. Env var first, then one line on stdin via '--secret-key -',
# then a hidden prompt.
function Read-SsmSecretValue {
    param([string]$Flag)

    if ($env:SSM_AWS_SECRET_KEY) { return $env:SSM_AWS_SECRET_KEY }

    if ($Flag -ceq '-') {
        $secret = [Console]::In.ReadLine()
        if (-not $secret) {
            Write-SsmErr 'Error: no secret key on stdin.'
            return $null
        }
        return $secret
    }

    if ($Flag) {
        Write-SsmErr 'Error: do not pass a secret key as a flag value -- it is recorded in your shell history.'
        Write-SsmErr "Use SSM_AWS_SECRET_KEY=... or '--secret-key -' to read one line from stdin."
        return $null
    }

    $secure = Read-Host -Prompt 'Secret Access Key' -AsSecureString
    return ConvertFrom-SecureString $secure -AsPlainText
}

# ---------------------------------------------------------------------------
# Menus. fzf when it is there, a built-in picker when it is not -- unlike
# ssm.sh:43-46, which makes fzf a hard requirement for every menu. Keeping the
# tool usable without it is what lets install.ps1 treat fzf as optional.
# ---------------------------------------------------------------------------

# A seam, so the tests can point the picker at a stub the way args_test.sh
# redefines fzf as a shell function.
$script:SsmFzfCommand = 'fzf'

function Test-SsmFzf {
    return [bool](Get-Command $script:SsmFzfCommand -ErrorAction SilentlyContinue)
}

function Test-SsmInteractive {
    return (-not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected)
}

# The filter behind the built-in picker, kept pure so it can be tested without
# a console. Case-insensitive substring, which is close enough to fzf's default
# for a list of account names and instance ids.
function Select-SsmPickerView {
    param([string[]]$Items, [string]$Filter)
    if (-not $Filter) { return , ([string[]]$Items) }
    return , ([string[]]@($Items | Where-Object {
                $_.IndexOf($Filter, [StringComparison]::OrdinalIgnoreCase) -ge 0
            }))
}

# What Enter means with a filter typed: the first match, or -- with -AllowNew
# and nothing matching -- the typed text as a new entry. Pure, so the tests can
# pin it without a console.
function Select-SsmPickerChoice {
    param([string[]]$Items, [string]$Filter, [switch]$AllowNew)
    $view = Select-SsmPickerView -Items $Items -Filter $Filter
    if ($view.Count) { return $view[0] }
    if ($AllowNew -and $Filter) { return $Filter }
    return $null
}

function Clear-SsmDrawnLines {
    param([int]$Count)
    if ($Count -le 0) { return }
    $width = [Math]::Max(1, $Host.UI.RawUI.WindowSize.Width - 1)
    $blank = ' ' * $width
    for ($i = 0; $i -lt $Count; $i++) {
        $pos = $Host.UI.RawUI.CursorPosition
        $pos.Y = [Math]::Max(0, $pos.Y - 1)
        $pos.X = 0
        $Host.UI.RawUI.CursorPosition = $pos
        [Console]::Write($blank)
        $Host.UI.RawUI.CursorPosition = $pos
    }
}

# Draws the frame and returns how many lines it drew, so the next pass can
# erase exactly those. Everything here goes to the host, never to the success
# stream: the caller is capturing the return value.
function Write-SsmPickerFrame {
    param([string]$Prompt, [string]$Filter, [string[]]$View, [int]$Cursor, [int]$Top, [int]$Rows,
        [string]$Header = '', [switch]$AllowNew)
    $drawn = 0
    if ($Header) { Write-Host "  $Header" -ForegroundColor DarkGray; $drawn++ }
    Write-Host "$Prompt $Filter"
    $drawn++
    if ($View.Count -eq 0) {
        if ($AllowNew -and $Filter) {
            Write-Host "> $Filter (new -- press Enter to create it)" -ForegroundColor Green
        } else {
            Write-Host '  (no matches)'
        }
        return $drawn + 1
    }
    $last = [Math]::Min($Top + $Rows, $View.Count)
    for ($i = $Top; $i -lt $last; $i++) {
        if ($i -eq $Cursor) {
            Write-Host "> $($View[$i])" -ForegroundColor Green
        } else {
            Write-Host "  $($View[$i])"
        }
        $drawn++
    }
    return $drawn
}

# The fallback for when there is no console to draw on at all -- a redirected
# stdin, mostly. Numbered, read one line, no cursor games.
function Show-SsmNumberedPrompt {
    param([string]$Prompt, [string[]]$Items)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-SsmErr ("{0,3}) {1}" -f ($i + 1), $Items[$i])
    }
    Write-SsmErr "$Prompt [1-$($Items.Count)]: "
    $answer = [Console]::In.ReadLine()
    if (-not $answer) { return $null }
    $n = 0
    if (-not [int]::TryParse($answer.Trim(), [ref]$n)) { return $null }
    if ($n -lt 1 -or $n -gt $Items.Count) { return $null }
    return $Items[$n - 1]
}

# -AllowNew is the console picker's --print-query: Enter on a filter that
# matches nothing returns the filter text itself, which is how a new profile
# name is typed in.
function Show-SsmConsolePicker {
    param([string]$Prompt, [string[]]$Items, [string]$Header = '', [switch]$AllowNew)

    if ([Console]::IsInputRedirected) {
        if ($Header) { Write-SsmErr $Header }
        if ($AllowNew) {
            if ($Items.Count) { for ($i = 0; $i -lt $Items.Count; $i++) { Write-SsmErr ("{0,3}) {1}" -f ($i + 1), $Items[$i]) } }
            Write-SsmErr "$Prompt [number, or a new name]: "
            $answer = [Console]::In.ReadLine()
            if (-not $answer) { return $null }
            $n = 0
            if ([int]::TryParse($answer.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1] }
            # A typed name is taken whole here -- there is no live filter to
            # show what a partial one would match.
            foreach ($item in $Items) { if (($item -split "`t")[0] -ceq $answer.Trim()) { return $item } }
            return $answer.Trim()
        }
        return Show-SsmNumberedPrompt $Prompt $Items
    }

    $filter = ''
    $cursor = 0
    $top = 0
    $drawn = 0
    $rows = [Math]::Min(10, [Math]::Max(3, $Host.UI.RawUI.WindowSize.Height - 3))

    # Ctrl-C must cancel the menu, not kill the process mid-draw and leave the
    # cursor hidden. Restored in the finally below.
    $prevCtrlC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    [Console]::CursorVisible = $false
    try {
        while ($true) {
            $view = Select-SsmPickerView -Items $Items -Filter $filter
            if ($cursor -ge $view.Count) { $cursor = [Math]::Max(0, $view.Count - 1) }
            if ($cursor -lt $top) { $top = $cursor }
            if ($cursor -ge $top + $rows) { $top = $cursor - $rows + 1 }

            Clear-SsmDrawnLines $drawn
            $drawn = Write-SsmPickerFrame $Prompt $filter $view $cursor $top $rows -Header $Header -AllowNew:$AllowNew

            $k = [Console]::ReadKey($true)
            if (($k.Modifiers -band [ConsoleModifiers]::Control) -and $k.Key -eq 'C') { return $null }
            switch ($k.Key) {
                'Escape' { return $null }
                'Enter' {
                    if ($view.Count) { return $view[$cursor] }
                    return (Select-SsmPickerChoice -Items $Items -Filter $filter -AllowNew:$AllowNew)
                }
                'UpArrow' { if ($cursor -gt 0) { $cursor-- } }
                'DownArrow' { if ($cursor -lt $view.Count - 1) { $cursor++ } }
                'PageUp' { $cursor = [Math]::Max(0, $cursor - $rows) }
                'PageDown' { $cursor = [Math]::Min($view.Count - 1, $cursor + $rows) }
                'Home' { $cursor = 0 }
                'End' { $cursor = $view.Count - 1 }
                'Backspace' {
                    if ($filter) { $filter = $filter.Substring(0, $filter.Length - 1); $cursor = 0 }
                }
                default {
                    if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar)) {
                        $filter += $k.KeyChar
                        $cursor = 0
                    }
                }
            }
        }
    } finally {
        Clear-SsmDrawnLines $drawn
        [Console]::CursorVisible = $true
        [Console]::TreatControlCAsInput = $prevCtrlC
    }
}

# bash: select_menu (ssm.sh:42), and select_menu_header when -Header is given
function Invoke-SsmMenu {
    param([string]$Prompt, [string[]]$Items, [string]$Header = '')
    if (-not $Items -or $Items.Count -eq 0) { return $null }

    if (Test-SsmFzf) {
        if ($Header) {
            $out = $Items | & $script:SsmFzfCommand --prompt="$Prompt " --header="$Header" --height=~15 --layout=reverse --border
        } else {
            $out = $Items | & $script:SsmFzfCommand --prompt="$Prompt " --height=~10 --layout=reverse --border
        }
        # 130 is a cancelled menu, not a failure.
        if ($LASTEXITCODE -ne 0) { return $null }
        return $out
    }
    return Show-SsmConsolePicker -Prompt $Prompt -Items $Items -Header $Header
}

# bash: print_choice (ssm.sh:75)
#
# fzf clears its menu once you pick, so without this nothing on screen says
# what was chosen. Tabs in a menu row become spaces here.
function Write-SsmChoice {
    param([string]$Label, [string]$Value)
    $mark = if ([Console]::OutputEncoding.CodePage -eq 65001) { '✓' } else { '*' }
    $Label = $Label.Substring(0, 1).ToUpperInvariant() + $Label.Substring(1)
    Write-SsmErr "$C_BOLD$C_GREEN$mark ${Label}:$C_RESET $($Value -replace "`t", ' ')"
}

# bash: select_multi (ssm.sh:60)
#
# Checklist counterpart of Invoke-SsmMenu. Each row is "key<TAB>label"; returns
# the key of every row picked.
#
# fzf prints the row under the cursor when Enter is pressed with nothing marked,
# so a "none" row goes first: pressing Enter straight away picks nothing.
function Invoke-SsmMultiMenu {
    param([string]$Prompt, [string]$Header, [string[]]$Rows)

    if (-not (Test-SsmFzf)) {
        $picked = [System.Collections.Generic.List[string]]::new()
        foreach ($row in $Rows) {
            $label = $row.Substring($row.IndexOf("`t") + 1)
            Write-Host "$Prompt $label [y/N]: " -NoNewline
            $answer = [Console]::In.ReadLine()
            if ($answer -ceq 'y' -or $answer -ceq 'Y') {
                $picked.Add($row.Substring(0, $row.IndexOf("`t")))
            }
        }
        return , ([string[]]$picked)
    }

    # Not $input: that is the automatic pipeline-input enumerator.
    $rowsWithNone = @("none`tNothing -- keep all of these") + $Rows
    $out = $rowsWithNone | & $script:SsmFzfCommand --multi --prompt="$Prompt " --header="$Header" `
        --delimiter="`t" --with-nth=2.. --height=~15 --layout=reverse --border
    if ($LASTEXITCODE -ne 0) { return $null }

    $keys = foreach ($line in @($out)) {
        if (-not $line) { continue }
        $key = $line.Substring(0, [Math]::Max(0, $line.IndexOf("`t")))
        if ($key -cne 'none') { $key }
    }
    return , ([string[]]@($keys))
}

# ---------------------------------------------------------------------------
# The db tunnel banner.
# ---------------------------------------------------------------------------

# bash: print_tunnel_banner (ssm.sh:87)
#
# Draws the "connect to this, not to that" box for `ssm db`. Padding is measured
# on the label and the value alone, because measuring the coloured string would
# pull the right border left by the length of the escapes.
#
# Note the parameter is TunnelHost, not Host: $Host is a PowerShell automatic
# variable holding the host UI object, and shadowing it breaks the picker.
function Write-SsmTunnelBanner {
    param([string]$TunnelHost, [string]$Port, [string]$RealHost, [string]$RealPort)

    # ssm.sh reads LC_ALL/LC_CTYPE/LANG, which Windows does not set even in a
    # UTF-8 capable terminal, so the box would always fall back to ASCII.
    if ([Console]::OutputEncoding.CodePage -eq 65001) {
        $tl = '┌'; $tr = '┐'; $bl = '└'; $br = '┘'; $ml = '├'; $mr = '┤'
        $hz = '─'; $vt = '│'; $ell = '…'; $dash = '—'
    } else {
        $tl = '+'; $tr = '+'; $bl = '+'; $br = '+'; $ml = '+'; $mr = '+'
        $hz = '-'; $vt = '|'; $ell = '...'; $dash = '-'
    }

    $cols = 0
    if ($env:COLUMNS -match '^[0-9]+$') { $cols = [int]$env:COLUMNS }
    if ($cols -lt 20) {
        try { $cols = $Host.UI.RawUI.WindowSize.Width } catch { $cols = 0 }
    }
    if ($cols -lt 20) { $cols = 80 }

    # Two border characters plus a space of padding on each side.
    $maxInner = $cols - 4
    if ($maxInner -lt 28) { $maxInner = 28 }

    $title = "DB TUNNEL $dash connect using THESE values"

    $labels = @('Host  ', 'Port  ', '', '', '  ')
    $values = @($TunnelHost, $Port, '', 'real endpoint, do NOT use directly:', "${RealHost}:${RealPort}")
    $colors = @("$C_BOLD$C_GREEN", "$C_BOLD$C_GREEN", '', $C_DIM, $C_DIM)

    if ($title.Length -gt $maxInner) {
        $title = $title.Substring(0, $maxInner - $ell.Length) + $ell
    }

    $inner = $title.Length
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $room = $maxInner - $labels[$i].Length
        if ($values[$i].Length -gt $room) {
            $values[$i] = $values[$i].Substring(0, $room - $ell.Length) + $ell
        }
        $width = $labels[$i].Length + $values[$i].Length
        if ($width -gt $inner) { $inner = $width }
    }

    $rule = $hz * ($inner + 2)

    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("$tl$rule$tr")
    $pad = ' ' * ($inner - $title.Length)
    $out.Add("$vt $C_BOLD$C_YELLOW$title$C_RESET$pad $vt")
    $out.Add("$ml$rule$mr")
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $pad = ' ' * ($inner - $labels[$i].Length - $values[$i].Length)
        if ($colors[$i]) {
            $out.Add("$vt $($labels[$i])$($colors[$i])$($values[$i])$C_RESET$pad $vt")
        } else {
            $out.Add("$vt $($labels[$i])$($values[$i])$pad $vt")
        }
    }
    $out.Add("$bl$rule$br")

    # The success stream, matching ssm.sh where the banner goes to stdout.
    return $out.ToArray()
}

# ---------------------------------------------------------------------------
# Local tunnel ports.
# ---------------------------------------------------------------------------

# Every number anywhere in the config, the equivalent of jq's '[.. | numbers]'.
# A port stored as a JSON string is deliberately not a number here, exactly as
# it is not one to jq -- which is why Set-SsmDbPort writes ints.
function Get-SsmConfigNumbers {
    $stack = [System.Collections.Stack]::new()
    $stack.Push((Get-SsmConfig))
    while ($stack.Count) {
        $node = $stack.Pop()
        if ($null -eq $node) { continue }
        # A string is IEnumerable in .NET and would otherwise be walked one
        # character at a time.
        if ($node -is [string]) { continue }
        if ($node -is [int] -or $node -is [long] -or $node -is [double] -or $node -is [decimal]) {
            $node
        } elseif ($node -is [System.Collections.IEnumerable]) {
            foreach ($item in $node) { $stack.Push($item) }
        } elseif ($node -is [psobject]) {
            foreach ($p in $node.PSObject.Properties) { $stack.Push($p.Value) }
        }
    }
}

# bash: find_free_port (ssm.sh:627)
#
# lsof does not exist on Windows. IPGlobalProperties is an in-process .NET call
# that needs no child process and no admin, and listeners plus connections
# together cover what `lsof -i :port` matched.
function Get-SsmFreePort {
    param([int]$Port)

    $busy = [System.Collections.Generic.HashSet[int]]::new()
    $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    foreach ($ep in $props.GetActiveTcpListeners()) { [void]$busy.Add($ep.Port) }
    foreach ($c in $props.GetActiveTcpConnections()) { [void]$busy.Add($c.LocalEndPoint.Port) }
    foreach ($n in Get-SsmConfigNumbers) { [void]$busy.Add([int]$n) }

    while ($busy.Contains($Port)) { $Port++ }
    return $Port
}

# bash: get_db_port (ssm.sh:637)
function Get-SsmDbPort {
    param([string]$Account, [string]$Identifier)

    $config = Get-SsmConfig
    $databases = Get-SsmMember (Get-SsmMember $config $Account) 'databases'
    $existing = Get-SsmMember $databases $Identifier
    if ($null -ne $existing -and $existing -ne '') { return [int]$existing }

    $port = Get-SsmFreePort 15432
    Set-SsmDbPort $Account $Identifier $port | Out-Null
    # stderr, so a caller capturing the port does not capture this too.
    Write-SsmErr "Assigned port $port to $Identifier (saved to $script:CONFIG_FILE)"
    return $port
}

# ---------------------------------------------------------------------------
# AWS. Every invocation below is the one from ssm.sh, argument for argument.
# ---------------------------------------------------------------------------

# Runs the AWS CLI and returns its stdout lines, dropping stderr. The bash side
# writes `2>/dev/null` on the calls that are allowed to fail; Quiet does that.
function Invoke-SsmAws {
    param([switch]$Quiet, [Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $exe = Get-SsmAwsCli
    if ($Quiet) {
        $out = & $exe @Arguments 2>$null
    } else {
        $out = & $exe @Arguments
    }
    return , ([string[]]@($out))
}

# `--output text` gives tab-separated rows; this is the shared shape.
function Split-SsmTextRows {
    param([string[]]$Lines)
    return , ([string[]]@($Lines | Where-Object { $_ -ne '' }))
}

# bash: list_apps (ssm.sh:320)
function Get-SsmApps {
    param([string]$Profile, [string]$Region)
    $out = Invoke-SsmAws ec2 describe-instances `
        --profile $Profile --region $Region `
        --filters 'Name=instance-state-name,Values=running' `
        --query 'Reservations[].Instances[].Tags[?Key==`App`].Value[]' `
        --output text
    $names = foreach ($line in $out) {
        foreach ($name in ($line -split "`t")) {
            if ($name -and $name -cne 'None') { $name }
        }
    }
    return , ([string[]]([System.Linq.Enumerable]::OrderBy(
                [string[]]@($names | Sort-Object -Unique),
                [Func[string, string]] { param($s) $s }, [System.StringComparer]::Ordinal)))
}

# bash: list_instances (ssm.sh:330)
function Get-SsmInstances {
    param([string]$Profile, [string]$Region, [string]$App)
    $out = Invoke-SsmAws ec2 describe-instances `
        --profile $Profile --region $Region `
        --filters "Name=tag:App,Values=$App" 'Name=instance-state-name,Values=running' `
        --query 'Reservations[].Instances[].[InstanceId, Tags[?Key==`Name`].Value|[0]]' `
        --output text
    return Split-SsmTextRows $out
}

# bash: list_rds_instances (ssm.sh:340)
function Get-SsmRdsInstances {
    param([string]$Profile, [string]$Region, [string]$App)
    $out = Invoke-SsmAws rds describe-db-instances `
        --profile $Profile --region $Region `
        --query "DBInstances[?TagList[?Key=='App' && Value=='$App']].[DBInstanceIdentifier, Endpoint.Address, Endpoint.Port]" `
        --output text
    return Split-SsmTextRows $out
}

# ---------------------------------------------------------------------------
# ECS. Additive: on an account with no ECS these return nothing and every EC2
# path behaves exactly as before.
# ---------------------------------------------------------------------------

# One "cluster<TAB>service<TAB>app" row per App-tagged ECS service, populated
# once per run.
$script:ECS_SERVICES = @()
$script:ECS_DISCOVERY_DONE = $false

# bash: discover_ecs_services_slow (ssm.sh:359)
function Get-SsmEcsServicesSlow {
    param([string]$Profile, [string]$Region)

    $clusters = @((Invoke-SsmAws -Quiet ecs list-clusters --profile $Profile --region $Region `
                --query 'clusterArns[]' --output text) -split "`t" | Where-Object { $_ -and $_ -cne 'None' })
    if (-not $clusters) { return , ([string[]]@()) }

    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($cluster in $clusters) {
        $services = @((Invoke-SsmAws -Quiet ecs list-services --profile $Profile --region $Region `
                    --cluster $cluster --query 'serviceArns[]' --output text) -split "`t" |
            Where-Object { $_ -and $_ -cne 'None' })
        if (-not $services) { continue }

        # describe-services takes at most 10 services per call.
        for ($i = 0; $i -lt $services.Count; $i += 10) {
            $batch = $services[$i..([Math]::Min($i + 9, $services.Count - 1))]
            $out = Invoke-SsmAws -Quiet ecs describe-services --profile $Profile --region $Region `
                --cluster $cluster --services @batch --include TAGS `
                --query 'services[].[clusterArn, serviceName, tags[?key==`App`].value|[0]]' `
                --output text
            foreach ($line in $out) {
                $c = $line -split "`t"
                if ($c.Count -lt 3 -or -not $c[2] -or $c[2] -ceq 'None') { continue }
                $parts = $c[0] -split '/'
                $rows.Add("$($parts[-1])`t$($c[1])`t$($c[2])")
            }
        }
    }
    return , ([string[]]$rows)
}

# bash: discover_ecs_services (ssm.sh:397)
function Get-SsmEcsServices {
    param([string]$Profile, [string]$Region)
    if ($script:ECS_DISCOVERY_DONE) { return }
    $script:ECS_DISCOVERY_DONE = $true

    # Fast path: one call to the Resource Groups Tagging API. Service ARNs are
    # arn:aws:ecs:<region>:<acct>:service/<cluster>/<service>, so cluster and
    # service both fall out of the ARN.
    $raw = Invoke-SsmAws -Quiet resourcegroupstaggingapi get-resources `
        --profile $Profile --region $Region `
        --tag-filters Key=App --resource-type-filters ecs:service `
        --query 'ResourceTagMappingList[].[ResourceARN, Tags[?Key==`App`].Value|[0]]' `
        --output text

    if ($LASTEXITCODE -eq 0) {
        $rows = foreach ($line in $raw) {
            $c = $line -split "`t"
            if ($c.Count -lt 2 -or -not $c[1] -or $c[1] -ceq 'None') { continue }
            $p = $c[0] -split '/'
            if ($p.Count -ge 3) { "$($p[-2])`t$($p[-1])`t$($c[1])" }
        }
        $script:ECS_SERVICES = [string[]]@($rows)
        return
    }

    # Slower fallback for accounts without tag:GetResources. Stay silent unless
    # it actually turned something up, so a pure-EC2 account sees no new output.
    $script:ECS_SERVICES = Get-SsmEcsServicesSlow $Profile $Region
    if ($script:ECS_SERVICES.Count) {
        Write-SsmErr 'Note: tagging API unavailable, enumerated ECS services instead.'
    }
}

# bash: list_ecs_apps (ssm.sh:432)
function Get-SsmEcsApps {
    $apps = foreach ($row in $script:ECS_SERVICES) {
        $c = $row -split "`t"
        if ($c.Count -ge 3) { $c[2] }
    }
    return , ([string[]]@($apps))
}

# bash: ecs_services_for_app (ssm.sh:437)
function Get-SsmEcsServicesForApp {
    param([string]$App)
    $rows = foreach ($row in $script:ECS_SERVICES) {
        $c = $row -split "`t"
        if ($c.Count -ge 3 -and $c[2] -ceq $App) { "$($c[0])`t$($c[1])" }
    }
    return , ([string[]]@($rows))
}

# bash: detect_ecs_container_instance (ssm.sh:446)
#
# Is this EC2 instance registered as an ECS container instance? Returns
# "cluster<TAB>containerInstanceArn" on a hit and nothing on a miss. A missing
# ECS policy is treated as a miss, so it can never block an EC2 login.
function Find-SsmEcsContainerInstance {
    param([string]$Profile, [string]$Region, [string]$InstanceId)

    $clusters = @((Invoke-SsmAws -Quiet ecs list-clusters --profile $Profile --region $Region `
                --query 'clusterArns[]' --output text) -split "`t" | Where-Object { $_ -and $_ -cne 'None' })

    foreach ($cluster in $clusters) {
        $arn = (Invoke-SsmAws -Quiet ecs list-container-instances --profile $Profile --region $Region `
                --cluster $cluster --filter "ec2InstanceId == '$InstanceId'" `
                --query 'containerInstanceArns[0]' --output text) -join ''
        if ($arn -and $arn -cne 'None') {
            return "$(($cluster -split '/')[-1])`t$arn"
        }
    }
    return $null
}

# bash: list_ecs_task_rows (ssm.sh:475)
#
# One row per running container:
#   taskId<TAB>container<TAB>launchType<TAB>exec:on|exec:off<TAB>cluster
function Get-SsmEcsTaskRows {
    param([string]$Profile, [string]$Region, [string]$Cluster, [string[]]$Tasks)
    if (-not $Tasks -or $Tasks.Count -eq 0) { return , ([string[]]@()) }

    $json = (Invoke-SsmAws -Quiet ecs describe-tasks --profile $Profile --region $Region `
            --cluster $Cluster --tasks @Tasks `
            --query 'tasks[?lastStatus==`RUNNING`].[taskArn, launchType, enableExecuteCommand, containers[].name]' `
            --output json) -join "`n"
    if (-not $json) { return , ([string[]]@()) }

    $tasks = $json | ConvertFrom-Json
    $rows = foreach ($t in @($tasks)) {
        $id = ($t[0] -split '/')[-1]
        $launch = if ($t[1]) { $t[1] } else { '-' }
        $exec = if ($t[2]) { 'exec:on' } else { 'exec:off' }
        foreach ($name in @($t[3])) {
            "$id`t$name`t$launch`t$exec`t$Cluster"
        }
    }
    return , ([string[]]@($rows))
}

# bash: ecs_exec (ssm.sh:495)
function Invoke-SsmEcsExec {
    param([string]$Profile, [string]$Region, [string]$Cluster, [string]$Task, [string]$Container)

    if (-not (Get-Command session-manager-plugin -ErrorAction SilentlyContinue)) {
        Write-SsmErr 'Error: session-manager-plugin is required for ECS Exec.'
        Write-SsmErr 'Re-run the installer to add it: winget install Amazon.SessionManagerPlugin'
        Exit-Ssm 1
    }

    Write-SsmErr ''
    Write-Host "Connecting to container $Container in task $Task via ECS Exec ..."
    # Pick the shell inside the container rather than retrying out here:
    # `aws ecs execute-command` exits 0 even when the requested shell is missing.
    #
    # Not captured and not piped: the session needs the real console handles.
    & (Get-SsmAwsCli) ecs execute-command `
        --profile $Profile --region $Region `
        --cluster $Cluster --task $Task --container $Container --interactive `
        --command "/bin/sh -c 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'"
}

# Starts an SSM session. The parameters go through a temp file rather than the
# command line: the JSON contains quotes, braces and spaces, and if aws resolves
# to a .cmd shim, cmd.exe re-parses the argument and the quoting changes.
function Invoke-SsmStartSession {
    param(
        [string]$Profile, [string]$Region, [string]$Target,
        [string]$Document, [hashtable]$Parameters
    )
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "ssm-params-$PID-$([guid]::NewGuid().ToString('N')).json"
    try {
        Write-SsmFile $tmp ($Parameters | ConvertTo-Json -Depth 10 -Compress)
        & (Get-SsmAwsCli) ssm start-session `
            --profile $Profile --region $Region --target $Target `
            --document-name $Document --parameters "file://$tmp"
    } finally {
        # finally runs on Ctrl-C in PowerShell 7, which is what makes this the
        # counterpart of bash's `trap ... EXIT`.
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# bash: ecs_pick_and_exec (ssm.sh:519)
function Invoke-SsmEcsPickAndExec {
    param([string]$Profile, [string]$Region, [string]$WantContainer, [string]$WantTask, [string[]]$Rows)

    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-SsmErr 'No running ECS tasks found.'
        Exit-Ssm 1
    }

    # --task narrows the rows first, so --container only has to be unique
    # within the task the user named.
    if ($WantTask) {
        $kept = @($Rows | Where-Object { ($_ -split "`t")[0] -ceq $WantTask })
        if ($kept.Count -eq 0) {
            Write-SsmErr "Error: no task '$WantTask' among the running tasks."
            Write-SsmErr 'Available:'
            foreach ($row in $Rows) { Write-SsmErr "  $row" }
            Exit-Ssm 1
        }
        $Rows = [string[]]$kept
    }

    $selected = Resolve-SsmSelection $WantContainer 'container' 'the running tasks' `
        'Select container:' '2' 'auto' $Rows
    if ($null -eq $selected) {
        if ($WantContainer) { Write-SsmErr 'Narrow it further with --task <id>.' }
        Exit-Ssm 1
    }
    if (-not $selected) { Exit-Ssm 0 }

    $c = $selected -split "`t"
    $task = $c[0]; $container = $c[1]; $execFlag = $c[3]; $cluster = $c[4]

    if ($execFlag -ceq 'exec:off') {
        Write-SsmErr ''
        Write-SsmErr 'ECS Exec is not enabled for this task.'
        Write-SsmErr 'Enable it on the service and redeploy:'
        Write-SsmErr "  aws ecs update-service --cluster $cluster --service <service> \"
        Write-SsmErr '    --enable-execute-command --force-new-deployment'
        Write-SsmErr ''
        Write-SsmErr 'The task role also needs ssmmessages:CreateControlChannel,'
        Write-SsmErr 'CreateDataChannel, OpenControlChannel and OpenDataChannel.'
        Exit-Ssm 1
    }

    Invoke-SsmEcsExec $Profile $Region $cluster $task $container
}

# bash: ssh_ecs_app (ssm.sh:575)
# Fargate / service path: every running task of the app's ECS services.
function Invoke-SsmSshEcsApp {
    param([string]$Profile, [string]$Region, [string]$App)
    Write-SsmErr "Fetching ECS tasks for $App..."

    $rows = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (Get-SsmEcsServicesForApp $App)) {
        $c = $line -split "`t"
        if ($c.Count -lt 2 -or -not $c[0] -or -not $c[1]) { continue }
        $tasks = @((Invoke-SsmAws -Quiet ecs list-tasks --profile $Profile --region $Region `
                    --cluster $c[0] --service-name $c[1] --desired-status RUNNING `
                    --query 'taskArns[]' --output text) -split "`t" |
            Where-Object { $_ -and $_ -cne 'None' })
        if (-not $tasks) { continue }
        foreach ($row in (Get-SsmEcsTaskRows $Profile $Region $c[0] $tasks)) {
            if ($row) { $rows.Add($row) }
        }
    }

    Invoke-SsmEcsPickAndExec $Profile $Region $script:ARG_CONTAINER $script:ARG_TASK ([string[]]$rows)
}

# bash: ssh_ecs_container_instance (ssm.sh:601)
# ECS-on-EC2 path: the tasks running on one container instance.
function Invoke-SsmSshEcsContainerInstance {
    param([string]$Profile, [string]$Region, [string]$Cluster, [string]$ContainerInstanceArn)
    Write-SsmErr 'Fetching tasks on this container instance...'

    $tasks = @((Invoke-SsmAws -Quiet ecs list-tasks --profile $Profile --region $Region `
                --cluster $Cluster --container-instance $ContainerInstanceArn `
                --desired-status RUNNING --query 'taskArns[]' --output text) -split "`t" |
        Where-Object { $_ -and $_ -cne 'None' })

    if (-not $tasks) {
        Write-SsmErr 'No running tasks on this container instance.'
        Exit-Ssm 1
    }

    $rows = @(Get-SsmEcsTaskRows $Profile $Region $Cluster $tasks | Where-Object { $_ })
    Invoke-SsmEcsPickAndExec $Profile $Region $script:ARG_CONTAINER $script:ARG_TASK ([string[]]$rows)
}

# ---------------------------------------------------------------------------
# The pickers.
# ---------------------------------------------------------------------------

# bash: pick_account (ssm.sh:651)
function Select-SsmAccount {
    param([string]$Wanted)
    $accounts = Get-SsmAccountList
    if (-not $accounts -or $accounts.Count -eq 0) {
        Write-SsmErr "No accounts found in $script:CONFIG_FILE"
        return $null
    }
    # Each row carries the account's masked access key; matching is on the
    # name alone (field 1), and only the name is returned.
    $table = Get-SsmAwsProfileKeys
    $rows = [string[]]@(foreach ($a in $accounts) {
            "$a`t" + (Get-SsmKeyHint $table (Get-SsmConfigValue $a 'profile'))
        })
    $selected = Resolve-SsmSelection $Wanted 'account' $script:CONFIG_FILE 'Select account:' '1' '' $rows
    if ($null -eq $selected) { return $null }
    return ($selected -split "`t")[0]
}

# ---------------------------------------------------------------------------
# AWS CLI profiles and regions, for `ssm config add` and `ssm config edit`.
# ---------------------------------------------------------------------------

# bash: aws_profile_keys (ssm.sh:833)
#
# "profile<TAB>access-key-id" for every profile in the AWS CLI's shared files,
# key empty for a profile without one. Read directly, not through
# `aws configure get` per profile, which would make every account menu slow.
function Get-SsmAwsProfileKeys {
    $cred = if ($env:AWS_SHARED_CREDENTIALS_FILE) { $env:AWS_SHARED_CREDENTIALS_FILE } else { Join-Path $HOME '.aws/credentials' }
    $conf = if ($env:AWS_CONFIG_FILE) { $env:AWS_CONFIG_FILE } else { Join-Path $HOME '.aws/config' }
    $order = [System.Collections.Generic.List[string]]::new()
    $keys = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($file in @($cred, $conf)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $isCred = ($file -ceq $cred)
        $cur = ''
        foreach ($line in [System.IO.File]::ReadAllLines($file)) {
            if ($line -match '^\s*\[(.*)\]\s*$') {
                $s = $Matches[1].Trim()
                # ~/.aws/config names a profile "[profile x]", except
                # "[default]"; [sso-session x] and the like are not profiles.
                if (-not $isCred -and $s -cne 'default') {
                    if ($s -cmatch '^profile\s+(.+)$') { $s = $Matches[1] } else { $cur = ''; continue }
                }
                $cur = $s
                if (-not $keys.ContainsKey($cur)) { $keys[$cur] = ''; $order.Add($cur) }
                continue
            }
            if ($cur -and $line -match '^\s*aws_access_key_id\s*=(.*)$') {
                # The credentials file wins, as it does for the CLI.
                if ($isCred -or -not $keys[$cur]) { $keys[$cur] = $Matches[1].Trim() }
            }
        }
    }
    $sorted = [string[]]([System.Linq.Enumerable]::OrderBy(
            [string[]]$order.ToArray(), [Func[string, string]] { param($s) $s }, [System.StringComparer]::Ordinal))
    return , ([string[]]@(foreach ($p in $sorted) { "$p`t$($keys[$p])" }))
}

# bash: key_hint_for (ssm.sh:866) -- "(AKIA****WXYZ)"
function Get-SsmKeyHint {
    param([string[]]$Table, [string]$Profile)
    if ($Profile) {
        foreach ($row in $Table) {
            $c = $row -split "`t", 2
            if ($c[0] -ceq $Profile) {
                $key = if ($c.Count -gt 1) { $c[1] } else { '' }
                if (-not $key) { return '(no access key)' }
                if ($key.Length -lt 8) { return '(****)' }
                return '(' + $key.Substring(0, 4) + '****' + $key.Substring($key.Length - 4) + ')'
            }
        }
    }
    return '(no such AWS profile)'
}

# bash: aws_profile_exists (ssm.sh:877)
function Test-SsmAwsProfileExists {
    param([string]$Profile)
    foreach ($row in (Get-SsmAwsProfileKeys)) {
        if (($row -split "`t")[0] -ceq $Profile) { return $true }
    }
    return $false
}

# bash: validate_profile_name (ssm.sh:883)
function Test-SsmProfileName {
    param([string]$Profile)
    if ($Profile -cmatch '^[A-Za-z0-9][A-Za-z0-9._@+-]*$') { return $true }
    if (Test-SsmAwsProfileExists $Profile) { return $true }
    Write-SsmErr "Error: '$Profile' is not a valid AWS CLI profile name."
    Write-SsmErr 'Use letters, digits and . _ - @ +, starting with a letter or digit.'
    return $false
}

$PROFILE_HELP = 'An AWS CLI profile is a named set of keys saved in ~/.aws. Pick one, or type a new name and press Enter to create it.'

# bash: pick_profile (ssm.sh:897)
#
# The existing profiles plus whatever you type: a name matching nothing is a
# new profile. fzf reports that as exit 1 with the query on its first line;
# the console picker does the same through -AllowNew.
function Select-SsmProfile {
    param([string]$Wanted)
    if ($Wanted) {
        if (-not (Test-SsmProfileName $Wanted)) { return $null }
        return $Wanted
    }

    $table = Get-SsmAwsProfileKeys
    $rows = [string[]]@(foreach ($row in $table) {
            $name = ($row -split "`t")[0]
            "$name`t" + (Get-SsmKeyHint $table $name)
        })

    $picked = $null
    $isNew = $false
    if (Test-SsmFzf) {
        $out = @($rows | & $script:SsmFzfCommand --print-query --prompt="AWS CLI profile: " `
                --header="$PROFILE_HELP" --height=~15 --layout=reverse --border)
        $rc = $LASTEXITCODE
        $query = if ($out.Count -ge 1) { [string]$out[0] } else { '' }
        if ($rc -eq 0 -and $out.Count -ge 2 -and $out[1]) {
            $picked = [string]$out[1]
        } elseif ($rc -eq 1 -and $query) {
            $picked = $query; $isNew = $true
        } else {
            return $null
        }
    } else {
        $picked = Show-SsmConsolePicker -Prompt 'AWS CLI profile:' -Items $rows -Header $PROFILE_HELP -AllowNew
        if (-not $picked) { return $null }
        $isNew = -not $picked.Contains("`t")
    }

    if ($isNew) {
        if (-not (Test-SsmProfileName $picked)) { return $null }
        Write-SsmChoice 'profile' "$picked (new)"
        return $picked
    }
    Write-SsmChoice 'profile' $picked
    return ($picked -split "`t")[0]
}

# The region list behind the picker, fetched when it opens. Public and needs no
# AWS credentials. Must match SSM_REGIONS_URL in ssm.sh; test/parity_test.sh
# checks. The env override is for test/commands_test.sh.
$SSM_REGIONS_URL = if ($env:SSM_REGIONS_URL) { $env:SSM_REGIONS_URL } else { 'https://xcrone.github.io/aws-regions/data.json' }

# bash: fetch_regions (ssm.sh:946)
#
# "code<TAB>name" per region that is open and has a code yet; an empty array
# when the list cannot be fetched.
function Get-SsmRegionRows {
    try {
        $data = Invoke-RestMethod -Uri $script:SSM_REGIONS_URL -TimeoutSec 5 -ErrorAction Stop
    } catch {
        return , ([string[]]@())
    }
    $regions = Get-SsmMember $data 'regions'
    if ($null -eq $regions) { return , ([string[]]@()) }
    return , ([string[]]@(foreach ($r in $regions) {
                $code = [string](Get-SsmMember $r 'code')
                if ((Get-SsmMember $r 'available') -eq $true -and $code) {
                    "$code`t$([string](Get-SsmMember $r 'name'))"
                }
            }))
}

# bash: validate_region (ssm.sh:955)
function Test-SsmRegion {
    param([string]$Region)
    if ($Region -cmatch '^[a-z]{2,}(-[a-z]+)+-[0-9]+$') { return $true }
    Write-SsmErr "Error: '$Region' is not an AWS region code, like ap-southeast-1."
    Write-SsmErr 'Leave out --region to pick one from a list.'
    return $false
}

# bash: pick_region (ssm.sh:965)
function Select-SsmRegion {
    param([string]$Wanted, [string]$Current = '')
    if ($Wanted) {
        if (-not (Test-SsmRegion $Wanted)) { return $null }
        return $Wanted
    }
    Write-SsmErr 'Fetching AWS regions...'
    $rows = Get-SsmRegionRows

    # Offline, or the list moved: asking for the code beats refusing to add.
    if ($rows.Count -eq 0) {
        Write-SsmErr "Could not fetch the region list from $script:SSM_REGIONS_URL."
        $typed = Read-SsmLine 'AWS region code (e.g. ap-southeast-1): '
        if (-not $typed) { return $null }
        if (-not (Test-SsmRegion $typed)) { return $null }
        return $typed
    }

    $header = 'Type to filter by code or city, e.g. singapore.'
    if ($Current) { $header = "Currently $Current. $header" }
    $picked = Invoke-SsmMenu 'AWS region:' $rows -Header $header
    if (-not $picked) { return $null }
    Write-SsmChoice 'region' $picked
    return ($picked -split "`t")[0]
}

# bash: profile_create_prompt (ssm.sh:996)
function Invoke-SsmProfileCreate {
    param([string]$Profile, [string]$Region)
    Write-Host "Creating AWS CLI profile '$Profile'. Paste the access key pair from the AWS console (IAM > Security credentials)."
    $key = $script:ARG_ACCESS_KEY
    if (-not $key) { $key = Read-SsmLine 'Access Key ID: ' }
    if (-not $key) { Write-SsmErr 'Aborted: no access key given.'; return $false }
    $secret = Read-SsmSecretValue $script:ARG_SECRET_KEY
    if ($null -eq $secret) { return $false }
    if (-not $secret) { Write-SsmErr 'Aborted: no secret key given.'; return $false }
    Set-SsmAwsProfile $Profile $key $secret $Region
    Write-Host "AWS CLI profile '$Profile' configured."
    return $true
}

# bash: pick_app (ssm.sh:666)
function Select-SsmApp {
    param([string]$Wanted, [string]$Account, [string]$Profile, [string]$Region)
    Write-SsmErr 'Fetching apps...'

    # No @() around either call. Both return `, ([string[]]...)` so that a
    # one-item result survives, and @() around that gives an array holding the
    # array -- which the [string[]] cast below then flattens into a single
    # "adam beatrice charlie" item, so --app never matched and the menu drew
    # one unusable row. Parentheses unroll the wrapper; + concatenates.
    $all = [string[]]@((Get-SsmApps $Profile $Region) + (Get-SsmEcsApps))
    $apps = [string[]]([System.Linq.Enumerable]::OrderBy(
            [string[]]@($all | Where-Object { $_ -and $_ -cne 'None' } | Sort-Object -Unique),
            [Func[string, string]] { param($s) $s }, [System.StringComparer]::Ordinal))

    if (-not $apps -or $apps.Count -eq 0) {
        Write-SsmErr 'No running instances or ECS services with an App tag found.'
        return $null
    }
    return Resolve-SsmSelection $Wanted 'app' "account $Account" 'Select application:' '1' '' $apps
}

# bash: pick_instance (ssm.sh:683)
function Select-SsmInstance {
    param([string]$Wanted, [string]$Profile, [string]$Region, [string]$App)
    Write-SsmErr "Fetching instances for $App..."

    $rows = Get-SsmInstances $Profile $Region $App
    if (-not $rows -or $rows.Count -eq 0) {
        Write-SsmErr "No running instances found for app: $App"
        return $null
    }

    # Matched on the instance id or on its Name tag, whichever the user typed.
    $selected = Resolve-SsmSelection $Wanted 'instance' "app $App" 'Select instance:' '1,2' 'auto' $rows
    if ($null -eq $selected) { return $null }
    if (-not $selected) { return '' }
    # Split on the tab, not on whitespace: a Name tag can contain spaces, which
    # would confuse the `awk '{print $1}'` the bash side uses here.
    return ($selected -split "`t")[0]
}

# bash: ssh_pick_target (ssm.sh:707)
# The "Connect to:" menu, or the flags that stand in for it.
function Select-SsmSshTarget {
    if ($script:ARG_TYPE -ceq 'ec2' -or $script:ARG_INSTANCE) { $target = 'EC2 instance' }
    elseif ($script:ARG_TYPE -ceq 'ecs' -or $script:ARG_CONTAINER -or $script:ARG_TASK) { $target = 'ECS task' }
    else { $target = Invoke-SsmMenu 'Connect to:' @('EC2 instance', 'ECS task') }
    if ($target) { Write-SsmChoice 'target' $target }
    return $target
}

# bash: ssh_pick_shell (ssm.sh:718)
function Select-SsmSshShell {
    if ($script:ARG_HOST) { $shell = 'Host shell' }
    elseif ($script:ARG_CONTAINER -or $script:ARG_TASK) { $shell = 'Container shell (ECS Exec)' }
    else { $shell = Invoke-SsmMenu 'Open which shell?' @('Host shell', 'Container shell (ECS Exec)') }
    if ($shell) { Write-SsmChoice 'shell' $shell }
    return $shell
}

# ---------------------------------------------------------------------------
# ssm ssh
# ---------------------------------------------------------------------------

# bash: cmd_ssh (ssm.sh:728)
function Invoke-SsmSsh {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Rest)
    if (-not (Read-SsmCommandArgs 'ssh' $Rest)) { Exit-Ssm 1 }

    if ($script:ARG_TYPE -and $script:ARG_TYPE -cne 'ec2' -and $script:ARG_TYPE -cne 'ecs') {
        Write-SsmErr "Error: --type must be 'ec2' or 'ecs', not '$($script:ARG_TYPE)'."
        Exit-Ssm 1
    }
    if ($script:ARG_INSTANCE -and $script:ARG_TYPE -ceq 'ecs') {
        Write-SsmErr 'Error: --instance names an EC2 instance and cannot be used with --type ecs.'
        Exit-Ssm 1
    }
    if ($script:ARG_HOST -and ($script:ARG_CONTAINER -or $script:ARG_TASK)) {
        Write-SsmErr 'Error: --host opens the host shell and cannot be used with --container or --task.'
        Exit-Ssm 1
    }

    $account = Select-SsmAccount $script:ARG_ENV
    if ($null -eq $account) { Exit-Ssm 1 }
    if (-not $account) { Exit-Ssm 0 }
    $profile = Get-SsmConfigValue $account 'profile'
    $region = Get-SsmConfigValue $account 'region'

    Get-SsmEcsServices $profile $region

    $app = Select-SsmApp $script:ARG_APP $account $profile $region
    if ($null -eq $app) { Exit-Ssm 1 }
    if (-not $app) { Exit-Ssm 0 }

    # If the app also has ECS services, offer the choice. An app backed only by
    # EC2 skips this entirely and follows the original flow.
    if ((Get-SsmEcsServicesForApp $app).Count) {
        $target = 'ECS task'
        if ((Get-SsmInstances $profile $region $app).Count) {
            $target = Select-SsmSshTarget
            if (-not $target) { Exit-Ssm 0 }
        }
        if ($target -ceq 'ECS task') {
            Invoke-SsmSshEcsApp $profile $region $app
            return
        }
    }

    $instanceId = Select-SsmInstance $script:ARG_INSTANCE $profile $region $app
    if ($null -eq $instanceId) { Exit-Ssm 1 }
    if (-not $instanceId) { Exit-Ssm 0 }

    # Autocheck: is this a plain EC2 box or an ECS container instance?
    $ecsNode = Find-SsmEcsContainerInstance $profile $region $instanceId
    if ($ecsNode) {
        $c = $ecsNode -split "`t"
        $cluster = $c[0]; $ciArn = $c[1]
        Write-SsmErr ''
        Write-SsmErr "This instance is an ECS container instance in cluster $cluster."
        $shellChoice = Select-SsmSshShell
        if (-not $shellChoice) { Exit-Ssm 0 }
        if ($shellChoice -ceq 'Container shell (ECS Exec)') {
            Invoke-SsmSshEcsContainerInstance $profile $region $cluster $ciArn
            return
        }

        # ECS container instances run the ECS-optimized AMI (Amazon Linux),
        # which has no `ubuntu` user, so pick the login user on the box.
        Write-SsmErr ''
        Write-Host "Connecting to $instanceId via SSM ..."
        Invoke-SsmStartSession -Profile $profile -Region $region -Target $instanceId `
            -Document 'AWS-StartInteractiveCommand' -Parameters @{
            command = @('if id ubuntu >/dev/null 2>&1; then sudo su - ubuntu; else sudo su - ec2-user; fi')
        }
        return
    }

    # A plain EC2 box runs no ECS tasks, so asking for a container here can only
    # be a mistake -- say so rather than silently dropping the user on the host.
    if ($script:ARG_CONTAINER -or $script:ARG_TASK) {
        Write-SsmErr "Error: $instanceId is a plain EC2 instance, not an ECS container instance."
        Write-SsmErr 'There is no container to exec into. Drop --container/--task for a host shell.'
        Exit-Ssm 1
    }

    Write-SsmErr ''
    Write-Host "Connecting to $instanceId via SSM ..."
    Invoke-SsmStartSession -Profile $profile -Region $region -Target $instanceId `
        -Document 'AWS-StartInteractiveCommand' -Parameters @{ command = @('sudo su - ubuntu') }
}

# ---------------------------------------------------------------------------
# EKS. Pods are not reachable over SSM at all -- they need kubectl -- so this is
# a separate funnel behind `ssm pod`, not a branch of `ssm ssh`.
# ---------------------------------------------------------------------------

# Our own kubeconfig, so ~/.kube/config and the current context are never touched.
$KUBECONFIG_FILE = Join-Path $HOME '.ssm/kubeconfig'

# bash: require_kubectl (ssm.sh:828)
function Assert-SsmKubectl {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-SsmErr 'Error: kubectl is required for pod access but is not installed.'
        Write-SsmErr 'Install it with: winget install Kubernetes.kubectl'
        Exit-Ssm 1
    }
}

# bash: list_eks_clusters (ssm.sh:836)
function Get-SsmEksClusters {
    param([string]$Profile, [string]$Region)
    $out = (Invoke-SsmAws -Quiet eks list-clusters --profile $Profile --region $Region `
            --query 'clusters[]' --output text) -split "`t"
    return , ([string[]]@($out | Where-Object { $_ -and $_ -cne 'None' }))
}

# bash: use_eks_cluster (ssm.sh:847)
function Use-SsmEksCluster {
    param([string]$Profile, [string]$Region, [string]$Cluster)
    Write-SsmErr "Updating kubeconfig for $Cluster..."

    # Out-Null, not a capture: the caller is not capturing us, but aws prints a
    # confirmation line here that the bash side sends to /dev/null.
    & (Get-SsmAwsCli) eks update-kubeconfig --profile $Profile --region $Region `
        --name $Cluster --kubeconfig $script:KUBECONFIG_FILE 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-SsmErr "Failed to fetch kubeconfig for $Cluster."
        Write-SsmErr "Check that your IAM principal is mapped in the cluster's aws-auth or access entries."
        Exit-Ssm 1
    }

    $env:KUBECONFIG = $script:KUBECONFIG_FILE
}

# bash: list_namespaces (ssm.sh:864)
function Get-SsmNamespaces {
    $json = (kubectl get namespaces -o json 2>$null) -join "`n"
    if (-not $json) { return , ([string[]]@()) }
    return , ([string[]]@(($json | ConvertFrom-Json).items | ForEach-Object { $_.metadata.name }))
}

# bash: list_pods (ssm.sh:870)
# pod<TAB>ready<TAB>node
function Get-SsmPods {
    param([string]$Namespace)
    $json = (kubectl get pods -n $Namespace -o json 2>$null) -join "`n"
    if (-not $json) { return , ([string[]]@()) }

    $rows = foreach ($pod in ($json | ConvertFrom-Json).items) {
        if ($pod.status.phase -cne 'Running') { continue }
        $statuses = @()
        if ($pod.status.PSObject.Properties['containerStatuses']) {
            $statuses = @($pod.status.containerStatuses | Where-Object { $_.ready })
        }
        $ready = "$($statuses.Count)/$(@($pod.spec.containers).Count)"
        $node = if ($pod.spec.PSObject.Properties['nodeName'] -and $pod.spec.nodeName) { $pod.spec.nodeName } else { '-' }
        "$($pod.metadata.name)`t$ready`t$node"
    }
    return , ([string[]]@($rows))
}

# bash: list_pod_containers (ssm.sh:883)
function Get-SsmPodContainers {
    param([string]$Namespace, [string]$Pod)
    $json = (kubectl get pod $Pod -n $Namespace -o json 2>$null) -join "`n"
    if (-not $json) { return , ([string[]]@()) }
    return , ([string[]]@(($json | ConvertFrom-Json).spec.containers | ForEach-Object { $_.name }))
}

# bash: kubectl_exec (ssm.sh:889)
function Invoke-SsmKubectlExec {
    param([string]$Namespace, [string]$Pod, [string]$Container)

    Write-SsmErr ''
    Write-Host "Connecting to container $Container in pod $Pod ..."
    # Statement-level, never captured: -it needs the real console handles. The
    # non-zero exit is expected data here, which is what
    # $PSNativeCommandUseErrorActionPreference = $false at the top is for.
    kubectl exec -it -n $Namespace $Pod -c $Container -- /bin/bash
    if ($LASTEXITCODE -ne 0) {
        Write-SsmErr ''
        Write-SsmErr 'Retrying with /bin/sh ...'
        kubectl exec -it -n $Namespace $Pod -c $Container -- /bin/sh
    }
}

# bash: pick_eks_cluster (ssm.sh:901)
function Select-SsmEksCluster {
    param([string]$Wanted, [string]$Profile, [string]$Region)
    Write-SsmErr 'Fetching EKS clusters...'
    $clusters = Get-SsmEksClusters $Profile $Region
    if (-not $clusters -or $clusters.Count -eq 0) {
        Write-SsmErr "No EKS clusters found in $Region."
        return $null
    }
    return Resolve-SsmSelection $Wanted 'cluster' "region $Region" 'Select cluster:' '1' 'auto' $clusters
}

# bash: pick_namespace (ssm.sh:919)
function Select-SsmNamespace {
    param([string]$Wanted)
    Write-SsmErr 'Fetching namespaces...'
    $namespaces = Get-SsmNamespaces
    if (-not $namespaces -or $namespaces.Count -eq 0) {
        Write-SsmErr 'No namespaces found. Check your access to this cluster.'
        return $null
    }
    return Resolve-SsmSelection $Wanted 'namespace' 'this cluster' 'Select namespace:' '1' '' $namespaces
}

# bash: pick_pod (ssm.sh:937)
function Select-SsmPod {
    param([string]$Wanted, [string]$Namespace)
    Write-SsmErr "Fetching pods in $Namespace..."
    $rows = Get-SsmPods $Namespace
    if (-not $rows -or $rows.Count -eq 0) {
        Write-SsmErr "No running pods found in namespace: $Namespace"
        return $null
    }
    $selected = Resolve-SsmSelection $Wanted 'pod' "namespace $Namespace" 'Select pod:' '1' 'auto' $rows
    if ($null -eq $selected) { return $null }
    if (-not $selected) { return '' }
    return ($selected -split "`t")[0]
}

# bash: pick_pod_container (ssm.sh:958)
function Select-SsmPodContainer {
    param([string]$Wanted, [string]$Namespace, [string]$Pod)
    $containers = Get-SsmPodContainers $Namespace $Pod
    if (-not $containers -or $containers.Count -eq 0) {
        Write-SsmErr "No containers found in pod: $Pod"
        return $null
    }
    return Resolve-SsmSelection $Wanted 'container' "pod $Pod" 'Select container:' '1' 'auto' $containers
}

# bash: cmd_pod (ssm.sh:975)
function Invoke-SsmPod {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Rest)
    if (-not (Read-SsmCommandArgs 'pod' $Rest)) { Exit-Ssm 1 }

    Assert-SsmKubectl

    $account = Select-SsmAccount $script:ARG_ENV
    if ($null -eq $account) { Exit-Ssm 1 }
    if (-not $account) { Exit-Ssm 0 }
    $profile = Get-SsmConfigValue $account 'profile'
    $region = Get-SsmConfigValue $account 'region'

    $cluster = Select-SsmEksCluster $script:ARG_CLUSTER $profile $region
    if ($null -eq $cluster) { Exit-Ssm 1 }
    if (-not $cluster) { Exit-Ssm 0 }

    Use-SsmEksCluster $profile $region $cluster

    $namespace = Select-SsmNamespace $script:ARG_NAMESPACE
    if ($null -eq $namespace) { Exit-Ssm 1 }
    if (-not $namespace) { Exit-Ssm 0 }

    $pod = Select-SsmPod $script:ARG_POD $namespace
    if ($null -eq $pod) { Exit-Ssm 1 }
    if (-not $pod) { Exit-Ssm 0 }

    $container = Select-SsmPodContainer $script:ARG_CONTAINER $namespace $pod
    if ($null -eq $container) { Exit-Ssm 1 }
    if (-not $container) { Exit-Ssm 0 }

    Invoke-SsmKubectlExec $namespace $pod $container
}

# ---------------------------------------------------------------------------
# ssm db
# ---------------------------------------------------------------------------

# bash: cmd_db (ssm.sh:1004)
#
# The one command that behaves differently from macOS. ssm.sh:1050-1061 adds a
# "<db>.tunnel" alias to /etc/hosts so a DB client can use a friendly name, and
# strips it again in an EXIT trap. The Windows hosts file needs admin, which
# would mean a UAC prompt on every single `ssm db` -- and an elevated write is
# harder to undo reliably than the macOS one, which already leaks the entry on
# a hard kill. So Windows skips the alias and the banner shows 127.0.0.1.
# Documented in docs/src/reference/platforms.md.
function Invoke-SsmDb {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Rest)
    if (-not (Read-SsmCommandArgs 'db' $Rest)) { Exit-Ssm 1 }

    $account = Select-SsmAccount $script:ARG_ENV
    if ($null -eq $account) { Exit-Ssm 1 }
    if (-not $account) { Exit-Ssm 0 }
    $profile = Get-SsmConfigValue $account 'profile'
    $region = Get-SsmConfigValue $account 'region'
    $app = Select-SsmApp $script:ARG_APP $account $profile $region
    if ($null -eq $app) { Exit-Ssm 1 }
    if (-not $app) { Exit-Ssm 0 }

    Write-SsmErr "Fetching RDS instances for $app..."
    $rdsRows = Get-SsmRdsInstances $profile $region $app
    if (-not $rdsRows -or $rdsRows.Count -eq 0) {
        Write-SsmErr "No RDS instances found for app: $app"
        Exit-Ssm 1
    }

    $selectedRds = Resolve-SsmSelection $script:ARG_DB 'database' "app $app" `
        'Select database:' '1' 'auto' $rdsRows
    if ($null -eq $selectedRds) { Exit-Ssm 1 }
    if (-not $selectedRds) { Exit-Ssm 0 }

    $c = $selectedRds -split "`t"
    $dbIdentifier = $c[0]; $rdsHost = $c[1]; $rdsPort = $c[2]
    $localPort = Get-SsmDbPort $account $dbIdentifier

    Write-SsmErr "Fetching jump-host for $app..."
    if ($script:ARG_INSTANCE) {
        $instanceId = Select-SsmInstance $script:ARG_INSTANCE $profile $region $app
        if ($null -eq $instanceId) { Exit-Ssm 1 }
    } else {
        $rows = Get-SsmInstances $profile $region $app
        $instanceId = if ($rows.Count) { ($rows[0] -split "`t")[0] } else { '' }
    }
    if (-not $instanceId -or $instanceId -ceq 'None') {
        Write-SsmErr "No running EC2 instances found for app: $app"
        Exit-Ssm 1
    }

    Write-Host ''
    Write-SsmTunnelBanner '127.0.0.1' $localPort $rdsHost $rdsPort | ForEach-Object { Write-Output $_ }
    Write-Host ''
    Write-Host "$C_DIM""For a hostname instead, add ""127.0.0.1 $dbIdentifier.tunnel"" to" -NoNewline
    Write-Host " $env:SystemRoot\System32\drivers\etc\hosts (needs admin).$C_RESET"
    Write-Host ''
    Write-Host "Opening tunnel via $instanceId ..."
    try {
        Invoke-SsmStartSession -Profile $profile -Region $region -Target $instanceId `
            -Document 'AWS-StartPortForwardingSessionToRemoteHost' -Parameters @{
            host           = @($rdsHost)
            portNumber     = @("$rdsPort")
            localPortNumber = @("$localPort")
        }
    } finally {
        Write-Host ''
        Write-Host 'Tunnel closed.'
    }
}

# ---------------------------------------------------------------------------
# ssm config
# ---------------------------------------------------------------------------

# A prompt that reads one line. Write-Host so nothing lands on the success
# stream, which the caller may be capturing.
function Read-SsmLine {
    param([string]$Prompt)
    Write-Host $Prompt -NoNewline
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { return '' }
    return $line
}

function Test-SsmYes {
    param([string]$Answer)
    return ($Answer -ceq 'y' -or $Answer -ceq 'Y')
}

# bash: config_set_field (ssm.sh:1114)
function Set-SsmConfigField {
    param([string]$Account, [string]$Field, [string]$Value)
    $config = Get-SsmConfig
    # Not $account: PowerShell variable names are case-insensitive, so that
    # would overwrite the $Account parameter with the object it names.
    $entry = Get-SsmMember $config $Account
    if ($null -eq $entry) { return $false }
    $entry | Add-Member -NotePropertyName $Field -NotePropertyValue $Value -Force
    Save-SsmConfig $config
    Write-Host "Updated $Account.$Field -> '$Value'."
    return $true
}

# bash: validate_port (ssm.sh:1123)
#
# A regex, not [int]::TryParse: TryParse accepts "+5", surrounding whitespace
# and thousands separators, none of which are a port.
function Test-SsmPort {
    param([string]$Port)
    if ($Port -notmatch '^[0-9]+$') {
        Write-SsmErr "Error: port must be a whole number in 1-65535, got '$Port'."
        return $false
    }
    $n = [int]::Parse($Port, [Globalization.NumberStyles]::None, [cultureinfo]::InvariantCulture)
    if ($n -lt 1 -or $n -gt 65535) {
        Write-SsmErr "Error: port must be a whole number in 1-65535, got '$Port'."
        return $false
    }
    return $true
}

# bash: config_account_exists (ssm.sh:1137)
function Test-SsmAccountExists {
    param([string]$Name)
    return ($null -ne (Get-SsmMember (Get-SsmConfig) $Name))
}

# bash: config_rename_account (ssm.sh:1144)
#
# Moves the whole account object, so the profile, region and db port map all
# follow the new name. The AWS CLI profile is a field, not the key, so renaming
# an account never touches ~/.aws.
function Rename-SsmAccount {
    param([string]$Old, [string]$New)
    if (Test-SsmAccountExists $New) {
        Write-SsmErr "Error: account '$New' already exists in $script:CONFIG_FILE."
        return $false
    }
    $config = Get-SsmConfig
    $value = Get-SsmMember $config $Old
    if ($null -eq $value) {
        Write-SsmErr "Error: account '$Old' does not exist in $script:CONFIG_FILE."
        return $false
    }
    # Rebuilt in order so the renamed account keeps its place in the file,
    # rather than jumping to the end the way a delete-then-add would.
    $rebuilt = [ordered]@{}
    foreach ($p in $config.PSObject.Properties) {
        if ($p.Name -ceq $Old) { $rebuilt[$New] = $value } else { $rebuilt[$p.Name] = $p.Value }
    }
    Save-SsmConfig ([pscustomobject]$rebuilt)
    Write-Host "Renamed account '$Old' -> '$New'."
    return $true
}

# bash: config_set_db_port (ssm.sh:1156)
function Set-SsmDbPort {
    param([string]$Account, [string]$Db, [string]$Port)
    if (-not (Test-SsmPort $Port)) { return $false }
    # Canonical decimal, so "015432" is stored as 15432.
    $n = [int]::Parse($Port, [Globalization.NumberStyles]::None, [cultureinfo]::InvariantCulture)

    $config = Get-SsmConfig

    # Get-SsmDbPort avoids collisions when it picks a port for you; a port you
    # name yourself is your call, so this warns and still writes it.
    $clash = foreach ($a in $config.PSObject.Properties) {
        $dbs = Get-SsmMember $a.Value 'databases'
        if ($null -eq $dbs) { continue }
        foreach ($d in $dbs.PSObject.Properties) {
            if ($d.Value -eq $n -and ($a.Name -cne $Account -or $d.Name -cne $Db)) {
                "$($a.Name).$($d.Name)"
            }
        }
    }
    if ($clash) { Write-SsmErr "Warning: port $n is already assigned to $($clash -join ', ')." }

    # Not $account: variable names are case-insensitive here, so that name
    # would overwrite the $Account parameter with the object it names.
    $entry = Get-SsmMember $config $Account
    if ($null -eq $entry) {
        $entry = [pscustomobject]@{}
        $config | Add-Member -NotePropertyName $Account -NotePropertyValue $entry -Force
    }
    $dbs = Get-SsmMember $entry 'databases'
    if ($null -eq $dbs) {
        $dbs = [pscustomobject]@{}
        $entry | Add-Member -NotePropertyName 'databases' -NotePropertyValue $dbs -Force
    }
    # [int], so the port is a JSON number. Stored as a string it would drop out
    # of Get-SsmConfigNumbers and stop protecting anyone from a collision.
    $dbs | Add-Member -NotePropertyName $Db -NotePropertyValue $n -Force

    Save-SsmConfig $config
    Write-Host "Set $Account.$Db port -> $n."
    return $true
}

# bash: config_unset_db_port (ssm.sh:1179)
function Remove-SsmDbPort {
    param([string]$Account, [string]$Db)
    $config = Get-SsmConfig
    $dbs = Get-SsmMember (Get-SsmMember $config $Account) 'databases'
    $existing = Get-SsmMember $dbs $Db
    if ($null -eq $existing -or $existing -eq '') {
        Write-SsmErr "Error: no port assignment for '$Db' in account '$Account'."
        return $false
    }
    $dbs.PSObject.Properties.Remove($Db)
    Save-SsmConfig $config
    Write-Host "Removed port $existing for '$Db' in account '$Account'."
    return $true
}

# bash: aws_profile_configure (ssm.sh:1193)
function Set-SsmAwsProfile {
    param([string]$Profile, [string]$Key, [string]$Secret, [string]$Region)
    $aws = Get-SsmAwsCli
    & $aws configure set aws_access_key_id $Key --profile $Profile
    & $aws configure set aws_secret_access_key $Secret --profile $Profile
    & $aws configure set region $Region --profile $Profile
    & $aws configure set output json --profile $Profile
}

function Get-SsmAwsConfigValue {
    param([string]$Profile, [string]$Key)
    return ((& (Get-SsmAwsCli) configure get $Key --profile $Profile 2>$null) -join '').Trim()
}

# bash: config_view (ssm.sh:1201)
function Show-SsmConfig {
    $config = Get-SsmConfig
    if ($script:ARG_ENV) {
        if ($null -eq (Select-SsmAccount $script:ARG_ENV)) { Exit-Ssm 1 }
        Write-Output ((Get-SsmMember $config $script:ARG_ENV) | ConvertTo-Json -Depth 100)
        $accounts = @($script:ARG_ENV)
    } else {
        Write-Output ($config | ConvertTo-Json -Depth 100)
        $accounts = Get-SsmAccountList
    }

    Write-Output ''
    Write-Output 'AWS CLI profiles:'
    foreach ($account in $accounts) {
        $profile = Get-SsmConfigValue $account 'profile'
        $key = Get-SsmAwsConfigValue $profile 'aws_access_key_id'
        $cliRegion = Get-SsmAwsConfigValue $profile 'region'
        $masked = if ($key) { $key.Substring(0, 4) + '****' + $key.Substring($key.Length - 4) } else { '(not set)' }
        if (-not $cliRegion) { $cliRegion = '(not set)' }
        Write-Output ("  {0,-20} profile={1,-20} key={2,-16} region={3}" -f $account, $profile, $masked, $cliRegion)
    }
}

# bash: config_add (ssm.sh:1226)
function Add-SsmAccount {
    $name = $script:ARG_ENV
    if (-not $name) { $name = Read-SsmLine 'Account name (your label for this AWS account in ssm, e.g. staging): ' }
    if (-not $name) { Write-SsmErr 'Aborted.'; return $false }

    # Adding over an existing account used to replace it silently, taking its db
    # port assignments with it. --force keeps that behaviour, deliberately.
    if (Test-SsmAccountExists $name) {
        if (-not $script:ARG_FORCE) {
            Write-SsmErr "Error: account '$name' already exists in $script:CONFIG_FILE."
            Write-SsmErr "Use 'ssm config edit --env $name' to change it, or --force to replace it."
            return $false
        }
        Write-Host "Replacing existing account '$name'."
    }

    $profile = Select-SsmProfile $script:ARG_PROFILE
    if (-not $profile) { Write-SsmErr 'Aborted.'; return $false }
    $region = Select-SsmRegion $script:ARG_REGION
    if (-not $region) { Write-SsmErr 'Aborted.'; return $false }

    # The AWS CLI profile is settled before the account is written, so backing
    # out of the key prompts leaves nothing half-added.
    $credsGiven = [bool]($script:ARG_ACCESS_KEY -or $script:ARG_SECRET_KEY -or $env:SSM_AWS_SECRET_KEY)
    if ($script:ARG_SKIP_CREDENTIALS) {
        if (-not (Test-SsmAwsProfileExists $profile)) {
            Write-SsmErr "Warning: AWS CLI profile '$profile' does not exist yet; ssm cannot reach AWS until it is set up."
        }
    } elseif ((Test-SsmAwsProfileExists $profile) -and -not $credsGiven) {
        Write-Host "Using existing AWS CLI profile '$profile' $(Get-SsmKeyHint (Get-SsmAwsProfileKeys) $profile)."
    } else {
        if (-not (Invoke-SsmProfileCreate $profile $region)) { return $false }
    }

    $config = Get-SsmConfig
    $config | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{
            profile   = $profile
            region    = $region
            databases = [pscustomobject]@{}
        }) -Force
    Save-SsmConfig $config
    Write-Host "Account '$name' added."
    return $true
}

# bash: the python3/configparser heredoc in config_delete (ssm.sh:1314)
#
# A line filter rather than a parse-and-rewrite: configparser drops comments,
# normalises "key=value" to "key = value" and can reorder, which is an
# unpleasant side effect of deleting one profile. This touches nothing but the
# section being removed.
function Remove-SsmAwsProfile {
    param([string]$Profile)

    $credentials = if ($env:AWS_SHARED_CREDENTIALS_FILE) { $env:AWS_SHARED_CREDENTIALS_FILE }
    else { Join-Path $HOME '.aws/credentials' }
    $configPath = if ($env:AWS_CONFIG_FILE) { $env:AWS_CONFIG_FILE }
    else { Join-Path $HOME '.aws/config' }

    $targets = @(
        @{ Path = $credentials; Section = $Profile },
        @{ Path = $configPath; Section = "profile $Profile" }
    )

    foreach ($t in $targets) {
        if (-not (Test-Path -LiteralPath $t.Path)) { continue }

        $lines = [System.IO.File]::ReadAllLines($t.Path)
        $out = [System.Collections.Generic.List[string]]::new()
        $inTarget = $false
        $removed = $false

        foreach ($line in $lines) {
            $m = [regex]::Match($line, '^\s*\[(?<name>[^\]]+)\]\s*$')
            if ($m.Success) {
                # AWS profile names are case-sensitive to botocore, so -ceq.
                $inTarget = ($m.Groups['name'].Value.Trim() -ceq $t.Section)
                if ($inTarget) { $removed = $true; continue }
            }
            if (-not $inTarget) { $out.Add($line) }
        }

        # Untouched files are not rewritten, so their timestamps stay put.
        if ($removed) { Write-SsmFile $t.Path (($out -join "`n") + "`n") }
    }
}

# bash: config_delete (ssm.sh:1276)
function Remove-SsmAccount {
    $account = Select-SsmAccount $script:ARG_ENV
    if ($null -eq $account) { Exit-Ssm 1 }
    if (-not $account) { Exit-Ssm 0 }

    # --db narrows the delete to a single port assignment; without it the whole
    # account goes, as before.
    if ($script:ARG_DB) {
        if (-not $script:ARG_YES) {
            $confirmDb = Read-SsmLine "Delete port assignment '$($script:ARG_DB)' from account '$account'? [y/N]: "
            if (-not (Test-SsmYes $confirmDb)) { Write-SsmErr 'Aborted.'; return $true }
        }
        return (Remove-SsmDbPort $account $script:ARG_DB)
    }

    # Deleting is the one destructive action here, so it still asks unless --yes.
    if (-not $script:ARG_YES) {
        $confirm = Read-SsmLine "Delete account '$account'? [y/N]: "
        if (-not (Test-SsmYes $confirm)) { Write-SsmErr 'Aborted.'; return $true }
    }

    $profile = Get-SsmConfigValue $account 'profile'

    $config = Get-SsmConfig
    $config.PSObject.Properties.Remove($account)
    Save-SsmConfig $config
    Write-Host "Account '$account' deleted."

    $delProfile = [bool]$script:ARG_DELETE_PROFILE
    if (-not $delProfile -and -not $script:ARG_YES) {
        $answer = Read-SsmLine "Also delete AWS CLI profile '$profile'? [y/N]: "
        $delProfile = Test-SsmYes $answer
    }
    if ($delProfile) {
        Remove-SsmAwsProfile $profile
        Write-Host "AWS CLI profile '$profile' removed."
    }
    return $true
}

# bash: config_edit (ssm.sh:1334)
function Edit-SsmAccount {
    $account = Select-SsmAccount $script:ARG_ENV
    if ($null -eq $account) { Exit-Ssm 1 }
    if (-not $account) { Exit-Ssm 0 }

    $profile = Get-SsmConfigValue $account 'profile'

    # Field flags apply every field they name in one pass, so --profile and
    # --region together take one command instead of two trips through the menu.
    if ($script:ARG_NAME -or $script:ARG_PROFILE -or $script:ARG_REGION -or $script:ARG_ACCESS_KEY `
            -or $script:ARG_SECRET_KEY -or $env:SSM_AWS_SECRET_KEY -or $script:ARG_DB -or $script:ARG_PORT) {

        # Rename first so every other edit in this pass lands on the new name.
        if ($script:ARG_NAME) {
            if (-not (Rename-SsmAccount $account $script:ARG_NAME)) { return $false }
            $account = $script:ARG_NAME
        }
        # Both are checked before anything is written, so a bad value changes nothing.
        if ($script:ARG_PROFILE -and -not (Test-SsmProfileName $script:ARG_PROFILE)) { return $false }
        if ($script:ARG_REGION -and -not (Test-SsmRegion $script:ARG_REGION)) { return $false }
        if ($script:ARG_PROFILE) {
            if (-not (Set-SsmConfigField $account 'profile' $script:ARG_PROFILE)) { return $false }
            # Credential edits below belong to the profile we just moved to.
            $profile = $script:ARG_PROFILE
        }
        if ($script:ARG_REGION) {
            if (-not (Set-SsmConfigField $account 'region' $script:ARG_REGION)) { return $false }
        }
        if ($script:ARG_ACCESS_KEY) {
            & (Get-SsmAwsCli) configure set aws_access_key_id $script:ARG_ACCESS_KEY --profile $profile
            Write-Host "Updated AWS access key for profile '$profile'."
        }
        if ($script:ARG_SECRET_KEY -or $env:SSM_AWS_SECRET_KEY) {
            $secret = Read-SsmSecretValue $script:ARG_SECRET_KEY
            if ($null -eq $secret) { return $false }
            if (-not $secret) { Write-SsmErr 'Aborted.'; return $false }
            & (Get-SsmAwsCli) configure set aws_secret_access_key $secret --profile $profile
            Write-Host "Updated AWS secret key for profile '$profile'."
        }
        if ($script:ARG_DB -or $script:ARG_PORT) {
            if (-not $script:ARG_DB -or -not $script:ARG_PORT) {
                Write-SsmErr 'Error: --db and --port go together -- --db names the database, --port its local port.'
                return $false
            }
            if (-not (Set-SsmDbPort $account $script:ARG_DB $script:ARG_PORT)) { return $false }
        }
        return $true
    }

    $field = Invoke-SsmMenu 'Select field to edit:' `
    @('name', 'profile', 'region', 'aws-access-key', 'aws-secret-key', 'database-port')
    if (-not $field) { Exit-Ssm 0 }

    switch -CaseSensitive ($field) {
        'name' {
            $value = Read-SsmLine "New account name [$account]: "
            if (-not $value -or $value -ceq $account) { Write-Host 'Unchanged.'; return $true }
            return (Rename-SsmAccount $account $value)
        }
        'database-port' {
            $dbs = Get-SsmMember (Get-SsmMember (Get-SsmConfig) $account) 'databases'
            # Property by property, for the reason in Get-SsmAccountList: an
            # account whose "db" object is {} would otherwise throw here.
            $names = [string[]]@(foreach ($p in $dbs.PSObject.Properties) { $p.Name })
            if ($names.Count -eq 0) {
                Write-SsmErr "No port assignments for '$account' yet. 'ssm db' creates one on first use."
                return $false
            }
            $db = Invoke-SsmMenu 'Select database:' $names
            if ($null -eq $db) { return $false }
            if (-not $db) { return $true }
            $current = Get-SsmMember $dbs $db
            $value = Read-SsmLine "Local port for $db [$current] (or 'none' to remove): "
            if (-not $value) { $value = "$current" }
            if ($value -ceq 'none') { return (Remove-SsmDbPort $account $db) }
            return (Set-SsmDbPort $account $db $value)
        }
        'profile' {
            $value = Select-SsmProfile ''
            if (-not $value) { return $false }
            if (-not (Test-SsmAwsProfileExists $value)) {
                if (-not (Invoke-SsmProfileCreate $value (Get-SsmConfigValue $account 'region'))) { return $false }
            }
            return (Set-SsmConfigField $account 'profile' $value)
        }
        'region' {
            $value = Select-SsmRegion '' (Get-SsmConfigValue $account 'region')
            if (-not $value) { return $false }
            return (Set-SsmConfigField $account 'region' $value)
        }
        'aws-access-key' {
            $current = Get-SsmAwsConfigValue $profile 'aws_access_key_id'
            $shown = if ($current) { $current } else { 'not set' }
            $value = Read-SsmLine "Access Key ID [$shown]: "
            if (-not $value) { $value = $current }
            & (Get-SsmAwsCli) configure set aws_access_key_id $value --profile $profile
            Write-Host "Updated AWS access key for profile '$profile'."
            return $true
        }
        'aws-secret-key' {
            $value = Read-SsmSecretValue ''
            if ($null -eq $value) { return $false }
            if (-not $value) { Write-SsmErr 'Aborted.'; return $true }
            & (Get-SsmAwsCli) configure set aws_secret_access_key $value --profile $profile
            Write-Host "Updated AWS secret key for profile '$profile'."
            return $true
        }
    }
    return $true
}

# bash: cmd_config (ssm.sh:1082)
function Invoke-SsmConfig {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Rest)

    # The action is a verb, so it reads as a subcommand rather than a flag value.
    $action = ''
    # $words, not $rest or $args: variable names are case-insensitive, so a
    # local $rest IS the $Rest parameter and clearing it throws every argument
    # away, and $args is automatic. And not @($Rest) either: a command called
    # with no arguments binds $Rest to $null, which @() turns into a
    # one-element array holding $null -- an empty string by the time the parser
    # sees it, which it rejects as "Unknown option ''". That is what bare
    # `ssm config` did.
    $words = [string[]]@()
    if ($null -ne $Rest) { $words = [string[]]@($Rest) }
    if ($words.Count -gt 0) {
        switch -CaseSensitive ($words[0]) {
            { $_ -ceq 'view' -or $_ -ceq 'add' -or $_ -ceq 'edit' -or $_ -ceq 'delete' } {
                $action = $words[0]
                $words = [string[]]@($words | Select-Object -Skip 1)
            }
            default {
                if ($words[0] -and -not ($words[0] -clike '-*')) {
                    Write-SsmErr "Error: unknown config action '$($words[0])'."
                    Write-SsmErr ''
                    Get-SsmUsage 'config' | ForEach-Object { Write-SsmErr $_ }
                    Exit-Ssm 1
                }
            }
        }
    }

    if (-not (Read-SsmCommandArgs 'config' $words)) { Exit-Ssm 1 }

    if (-not $action) {
        $action = Invoke-SsmMenu 'Config action:' @('view', 'add', 'edit', 'delete')
        if (-not $action) { Exit-Ssm 0 }
    }

    switch -CaseSensitive ($action) {
        'view' { Show-SsmConfig | ForEach-Object { Write-Output $_ } }
        'add' { if (-not (Add-SsmAccount)) { Exit-Ssm 1 } }
        'edit' { if (-not (Edit-SsmAccount)) { Exit-Ssm 1 } }
        'delete' { if (-not (Remove-SsmAccount)) { Exit-Ssm 1 } }
    }
}

# ---------------------------------------------------------------------------
# ssm update
# ---------------------------------------------------------------------------

$SSM_DIR = Join-Path $HOME '.ssm'
$SSM_SCRIPT = Join-Path $SSM_DIR 'ssm.ps1'
# Only bin\ goes on the PATH, the way only /usr/local/bin/ssm does on macOS.
# PowerShell resolves a bare `ssm` to ssm.ps1 ahead of ssm.cmd when both sit in
# one PATH directory, so with %USERPROFILE%\.ssm itself on the PATH, Windows
# PowerShell 5.1 ran this script directly -- past the shim that hands it to
# pwsh -- and stopped at #Requires -Version 7.2.
$SSM_BIN_DIR = Join-Path $SSM_DIR 'bin'
$SSM_LAUNCHER = Join-Path $SSM_BIN_DIR 'ssm.cmd'
# Where v1.2.5 and earlier put the shim, with %USERPROFILE%\.ssm on the PATH.
$SSM_LEGACY_LAUNCHER = Join-Path $SSM_DIR 'ssm.cmd'

# The shim that makes the bare word `ssm` resolve from cmd.exe, PowerShell and
# Windows Terminal: .ps1 is not in PATHEXT and cmd.exe cannot run one anyway.
# Kept here rather than downloaded, because cmd.exe reads batch files lazily and
# is unforgiving about both line endings and a BOM -- generating it locally keeps
# those bytes out of git and off the CDN. install.ps1 writes the same text.
# It locates pwsh rather than naming it: a machine that has just installed
# PowerShell 7 has it on the machine PATH but not in the environment of any
# process started before that. setlocal keeps the widened PATH to one run.
$SSM_LAUNCHER_TEXT = @"
@echo off
setlocal
where /q pwsh.exe && goto :run
set "PATH=%ProgramFiles%\PowerShell\7;%LOCALAPPDATA%\Microsoft\PowerShell\7;%PATH%"
where /q pwsh.exe || goto :nopwsh
:run
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\ssm.ps1" %*
exit /b %ERRORLEVEL%
:nopwsh
echo ssm needs PowerShell 7. Install it with:  winget install Microsoft.PowerShell 1>&2
exit /b 9009
"@

# Shims written by an earlier ssm. Uninstall asks "is this shim ours?" by
# comparing content, so a shim from before the pwsh-locating rewrite must still
# be recognised -- otherwise upgrading and then uninstalling leaves ssm.cmd
# behind with "it is not the shim ssm installed".
$SSM_LAUNCHER_LEGACY_TEXT = @(
    @"
@echo off
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ssm.ps1" %*
exit /b %ERRORLEVEL%
"@,
    # v1.2.4-v1.2.5: the same shim, when it lived beside ssm.ps1.
    @"
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
)

function Write-SsmLauncher {
    param([string]$Path)
    # CRLF and ASCII, no BOM: all three matter to cmd.exe.
    $text = ($script:SSM_LAUNCHER_TEXT -replace "`r?`n", "`r`n") + "`r`n"
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force)
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.ASCIIEncoding]::new())
}

# Replaces a file that may be open. ssm.sh:1435-1439 relies on POSIX rename
# semantics; Windows inverts both halves of that. PowerShell parses a script
# fully before running it, so replacing the content is not the hazard it is for
# bash -- but Windows refuses to delete a file with an open handle, which may
# belong to Defender or the indexer rather than to us. Renaming is far more
# likely to succeed than deleting, so rename first and fall back to ReplaceFile.
function Invoke-SsmSelfReplace {
    param([string]$Target, [string]$Staged)

    $old = "$Target.old"
    Remove-Item $old -Force -ErrorAction SilentlyContinue

    $renamed = $false
    foreach ($attempt in 1..5) {
        try {
            Move-Item -LiteralPath $Target -Destination $old -Force
            $renamed = $true
            break
        } catch {
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }

    if ($renamed) {
        Move-Item -LiteralPath $Staged -Destination $Target -Force
    } else {
        # Designed for exactly this, and more tolerant of an open destination.
        [System.IO.File]::Replace($Staged, $Target, $old)
    }

    # Best effort. A .old left behind is swept up by the janitor on the next
    # run, so a locked handle never blocks or delays the update itself.
    Remove-Item $old -Force -ErrorAction SilentlyContinue
}

# bash: script_version (ssm.sh:1477)
#
# Reads both stamp forms: this is pointed at a downloaded file, and a user who
# has run `ssm update` on a machine that once held the bash copy should still
# get a version rather than "unknown".
function Get-SsmScriptVersion {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'unknown' }
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $m = [regex]::Match($line, '^\$SSM_VERSION = ''(.*)''$')
        if ($m.Success) { return $m.Groups[1].Value }
        $m = [regex]::Match($line, '^SSM_VERSION="(.*)"$')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return 'unknown'
}

# bash: cmd_update (ssm.sh:1440)
function Invoke-SsmUpdate {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Rest)
    if (-not (Read-SsmCommandArgs 'update' $Rest)) { Exit-Ssm 1 }

    $url = "$script:SSM_CDN_BASE/ssm.ps1"
    # Staged in $SSM_DIR, not the temp dir, so the rename below is same-volume
    # and therefore atomic.
    $tmp = "$script:SSM_SCRIPT.new.$PID"

    try {
        Write-Host 'Downloading latest ssm.ps1 from CDN...'
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
        } catch {
            Write-SsmErr "Update failed. Could not download from $url"
            Exit-Ssm 1
        }

        # A truncated download would otherwise replace a working ssm with one
        # that cannot even run `ssm update` again. Parsing is the counterpart of
        # `bash -n`; the #Requires line stands in for the shebang check.
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errors)
        $firstLine = (Get-Content -LiteralPath $tmp -TotalCount 1) -join ''
        if ($errors.Count -or $firstLine -notlike '#Requires*') {
            Write-SsmErr "Update failed. The download from $url is not a valid script."
            Exit-Ssm 1
        }

        $newVersion = Get-SsmScriptVersion $tmp
        # The CDN download carries Mark-of-the-Web; without this, running
        # ssm.ps1 directly trips the execution policy.
        Unblock-File -LiteralPath $tmp -ErrorAction SilentlyContinue

        Invoke-SsmSelfReplace $script:SSM_SCRIPT $tmp
        # Refresh the shim too, so a future change to it can actually ship.
        Write-SsmLauncher $script:SSM_LAUNCHER
        # Installers up to v1.2.3 wrote the PATH entry without broadcasting it,
        # leaving machines where the Start Menu shortcut is the only way in.
        # Such a user reaches update but not a terminal, so repair it here --
        # otherwise the one command they can run cannot fix what is wrong.
        Repair-SsmUserPath

        if ($newVersion -ceq $script:SSM_VERSION) {
            Write-Host "ssm is already at $($script:SSM_VERSION)."
        } else {
            Write-Host "ssm updated: $($script:SSM_VERSION) -> $newVersion"
        }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# bash: cmd_version (ssm.sh:1483)
function Invoke-SsmVersion {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Rest)
    if (-not (Read-SsmCommandArgs 'version' $Rest)) { Exit-Ssm 1 }
    Write-Output "ssm $($script:SSM_VERSION)"
}

# ---------------------------------------------------------------------------
# Uninstall. Paths are where install.ps1 puts things; they are script-scope so
# the test suite can point them at a scratch directory.
# ---------------------------------------------------------------------------
# These environment variables only exist on Windows. The unit tests and the
# parity check run under pwsh on Linux in CI, where the script still has to
# load, so fall back rather than letting Join-Path throw on a null.
function Get-SsmEnvPath {
    param([string]$Name, [string]$Fallback)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($value) { return $value }
    return $Fallback
}

$AWS_CLI_DIR = Join-Path (Get-SsmEnvPath 'ProgramFiles' '/nonexistent') 'Amazon/AWSCLIV2'
$SSM_PLUGIN_DIR = Join-Path (Get-SsmEnvPath 'ProgramFiles' '/nonexistent') 'Amazon/SessionManagerPlugin'
# No jq: Windows never installs one.
$UNINSTALL_WINGET_PACKAGES = @('junegunn.fzf', 'Kubernetes.kubectl')
$SSM_START_MENU_LNK = Join-Path (Get-SsmEnvPath 'APPDATA' '/nonexistent') 'Microsoft/Windows/Start Menu/Programs/ssm.lnk'

# bash: tilde_path (ssm.sh:1500)
function Get-SsmShortPath {
    param([string]$Path)
    if ($Path -like "$HOME*") { return '%USERPROFILE%' + $Path.Substring($HOME.Length) }
    return $Path
}

# bash: uninstall_link_into (ssm.sh:1508)
#
# There are no symlinks here -- install.ps1 writes a shim rather than linking,
# which sidesteps Windows needing Developer Mode for symlinks. The equivalent
# question is "is this shim ours?", answered by comparing its content.
function Test-SsmOwnLauncher {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $actual = ([System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n").Trim()
    foreach ($known in @($script:SSM_LAUNCHER_TEXT) + $script:SSM_LAUNCHER_LEGACY_TEXT) {
        if ($actual -ceq ($known -replace "`r`n", "`n").Trim()) { return $true }
    }
    return $false
}

# bash: uninstall_rm (ssm.sh:1517)
#
# No sudo. A transient lock is retried; a genuine permission problem is
# reported with the command that would fix it, rather than springing a UAC
# prompt in the middle of an uninstall.
function Remove-SsmPath {
    param([string]$Path, [string]$ElevatedHint = '')
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    foreach ($attempt in 1..3) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return $true
        } catch [System.UnauthorizedAccessException] {
            Write-SsmErr "Could not remove $Path -- it needs an elevated shell."
            if ($ElevatedHint) {
                Write-SsmErr 'Run this from an Administrator terminal:'
                Write-SsmErr "  $ElevatedHint"
            }
            return $false
        } catch {
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
    Write-SsmErr "Could not remove $Path."
    return $false
}

# Pure, so it can be tested without touching the registry. Compares trimmed of
# a trailing backslash, which is how the same directory ends up spelled twice.
function Remove-SsmPathEntry {
    param([string]$PathValue, [string]$Entry)
    return (($PathValue -split ';' |
            Where-Object { $_ -and ($_.TrimEnd('\') -ne $Entry.TrimEnd('\')) }) -join ';')
}

# Explorer caches the environment it gives every process it starts, so a
# registry write alone leaves new terminals on the old PATH until the next
# sign-out. WM_SETTINGCHANGE is what tells it to re-read. The same broadcast
# lives in install.ps1, for the same reason and with the same caveat about
# [Environment]::SetEnvironmentVariable downgrading REG_EXPAND_SZ to REG_SZ.
function Publish-SsmEnvironmentChange {
    if (-not ('SsmUninstall.NativeMethods' -as [type])) {
        Add-Type -Namespace 'SsmUninstall' -Name 'NativeMethods' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
    }
    $unused = [UIntPtr]::Zero
    # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, five seconds.
    [void][SsmUninstall.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 0x0002, 5000, [ref]$unused)
}

# The user PATH with ssm's entry in place: bin\ added if missing, and the
# %USERPROFILE%\.ssm entry that v1.2.5 and earlier used taken out -- left in, it
# keeps PowerShell resolving `ssm` to ssm.ps1 instead of the shim. Every other
# entry keeps its place and its spelling.
function Get-SsmRepairedPath {
    param([string]$PathValue, [string]$BinDir, [string]$LegacyDir)
    $kept = Remove-SsmPathEntry $PathValue $LegacyDir
    foreach ($part in ($kept -split ';')) {
        if ($part -and ($part.TrimEnd('\') -eq $BinDir.TrimEnd('\'))) { return $kept }
    }
    if ($kept) { return "$kept;$BinDir" }
    return $BinDir
}

# Puts ssm's bin\ back on the user PATH if it has gone missing, moves an old
# install off the %USERPROFILE%\.ssm entry, and announces the environment either
# way. Idempotent, and deliberately silent on failure: nothing here is worth
# failing an update over.
function Repair-SsmUserPath {
    param([switch]$Quiet)
    try {
        $key = Get-Item 'HKCU:\Environment'
        $raw = $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
        $updated = Get-SsmRepairedPath $raw $script:SSM_BIN_DIR $script:SSM_DIR
        if ($updated -cne $raw) {
            $kind = 'ExpandString'
            try { $kind = $key.GetValueKind('Path') } catch { }
            [Microsoft.Win32.Registry]::SetValue('HKEY_CURRENT_USER\Environment', 'Path', $updated, $kind)
            if (-not $Quiet) { Write-Host 'Updated the ssm entry in your user PATH.' }
        }
        Publish-SsmEnvironmentChange
    } catch {
        Write-SsmErr "Could not refresh your PATH: $($_.Exception.Message)"
    }
}

function Remove-SsmUserPathEntry {
    param([string]$Entry)
    $key = Get-Item 'HKCU:\Environment'
    # DoNotExpandEnvironmentNames matters: the usual accessor expands
    # %USERPROFILE% and friends, and writing that back bakes the expansion in
    # permanently and can downgrade REG_EXPAND_SZ to REG_SZ.
    $raw = $key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
    $new = Remove-SsmPathEntry $raw $Entry
    if ($new -cne $raw) {
        $kind = $key.GetValueKind('Path')
        [Microsoft.Win32.Registry]::SetValue('HKEY_CURRENT_USER\Environment', 'Path', $new, $kind)
        # Best effort: the entry is already gone from the registry, and failing
        # to announce it is not a reason to fail the uninstall.
        try { Publish-SsmEnvironmentChange } catch { }
        Write-Host 'Removed the ssm entry from your user PATH (open a new terminal to see it).'
    }
}

function Get-SsmWingetPackages {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return , ([string[]]@()) }
    # One capture, parsed once: `winget list --id` costs about a second a call.
    $listed = (winget list --disable-interactivity --accept-source-agreements 2>$null) -join "`n"
    $found = foreach ($id in $script:UNINSTALL_WINGET_PACKAGES) {
        if ($listed -match [regex]::Escape($id)) { $id }
    }
    return , ([string[]]@($found))
}

# bash: uninstall_optional_rows (ssm.sh:1524)
# The checklist rows: "key<TAB>label" for each optional item actually present.
function Get-SsmUninstallRows {
    $rows = [System.Collections.Generic.List[string]]::new()

    $leftovers = @(Get-ChildItem -LiteralPath $script:SSM_DIR -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -cne 'ssm.ps1' -and $_.Name -cne 'ssm.cmd' -and $_.Name -cne 'bin' })
    if ($leftovers.Count) {
        # The -f expression is parenthesised: without it, the comma is read as
        # an argument separator for .Add() rather than as part of the format.
        $rows.Add(("config`t{0,-24} {1}" -f (Get-SsmShortPath $script:SSM_DIR), 'config.json, db ports, kubeconfig'))
    }

    foreach ($id in (Get-SsmWingetPackages)) {
        $label = if ($id -ceq 'Kubernetes.kubectl') { 'kubectl' } elseif ($id -ceq 'junegunn.fzf') { 'fzf' } else { $id }
        $rows.Add(("$id`t{0,-24} winget uninstall {1}" -f $label, $id))
    }

    if (Test-Path -LiteralPath $script:AWS_CLI_DIR) {
        $rows.Add(("Amazon.AWSCLI`t{0,-24} {1} (admin)" -f 'AWS CLI v2', $script:AWS_CLI_DIR))
    }
    if (Test-Path -LiteralPath $script:SSM_PLUGIN_DIR) {
        $rows.Add(("Amazon.SessionManagerPlugin`t{0,-24} {1} (admin)" -f 'session-manager-plugin', $script:SSM_PLUGIN_DIR))
    }
    return , ([string[]]$rows)
}

# bash: uninstall_flagged_keys (ssm.sh:1544)
function Get-SsmUninstallFlaggedKeys {
    param([string[]]$Rows)
    $keys = foreach ($row in $Rows) {
        $key = $row.Substring(0, [Math]::Max(0, $row.IndexOf("`t")))
        if ($key -ceq 'config') {
            if ($script:ARG_PURGE) { $key }
        } else {
            if ($script:ARG_WITH_DEPS) { $key }
        }
    }
    return , ([string[]]@($keys))
}

# bash: uninstall_core (ssm.sh:1562)
#
# The part of an uninstall that always happens. A shim that is not ours belongs
# to some other ssm and is left alone, the way ssm.sh refuses to remove a
# symlink pointing elsewhere.
function Invoke-SsmUninstallCore {
    $ok = $true

    # PATH first: a failure part-way through then leaves a broken PATH entry
    # rather than one pointing at a file that is already gone.
    # Both entries: bin\ now, and %USERPROFILE%\.ssm from v1.2.5 and earlier.
    try { Remove-SsmUserPathEntry $script:SSM_BIN_DIR } catch { $ok = $false }
    try { Remove-SsmUserPathEntry $script:SSM_DIR } catch { $ok = $false }

    if (Test-Path -LiteralPath $script:SSM_START_MENU_LNK) {
        if (Remove-SsmPath $script:SSM_START_MENU_LNK) { Write-Host "Removed $($script:SSM_START_MENU_LNK)" }
        else { $ok = $false }
    }
    $desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ssm.lnk'
    if (Test-Path -LiteralPath $desktopLnk) {
        if (Remove-SsmPath $desktopLnk) { Write-Host "Removed $desktopLnk" } else { $ok = $false }
    }

    # The running script. Renamed rather than deleted: Windows refuses to delete
    # an open file, and the janitor at the top of the next run sweeps the .old.
    if (Test-Path -LiteralPath $script:SSM_SCRIPT) {
        try {
            $old = "$($script:SSM_SCRIPT).old"
            Remove-Item $old -Force -ErrorAction SilentlyContinue
            Move-Item -LiteralPath $script:SSM_SCRIPT -Destination $old -Force
            Remove-Item $old -Force -ErrorAction SilentlyContinue
            Write-Host "Removed $(Get-SsmShortPath $script:SSM_SCRIPT)"
        } catch {
            $ok = $false
            Write-SsmErr "Could not remove $($script:SSM_SCRIPT)."
        }
    }

    foreach ($launcher in @($script:SSM_LAUNCHER, $script:SSM_LEGACY_LAUNCHER)) {
        if (Test-Path -LiteralPath $launcher) {
            if (Test-SsmOwnLauncher $launcher) {
                if (Remove-SsmPath $launcher) {
                    Write-Host "Removed $(Get-SsmShortPath $launcher)"
                } else {
                    # cmd.exe reads batch files lazily and holds the handle, so the
                    # shell running this uninstall can still own it. There is no
                    # next run of ssm to clean it up, so hand the job to cmd itself
                    # -- printing the command first, so nothing happens invisibly.
                    Write-SsmErr 'ssm.cmd is still open by the shell running this uninstall.'
                    Write-SsmErr "Scheduling its removal:  del `"$launcher`""
                    Start-Process cmd.exe -WindowStyle Hidden -ArgumentList '/c', `
                        "timeout /t 3 /nobreak >nul & del /q `"$launcher`" & rd `"$($script:SSM_BIN_DIR)`" 2>nul"
                }
            } else {
                Write-SsmErr "Left $launcher alone: it is not the shim ssm installed."
            }
        }
    }
    try { Remove-Item -LiteralPath $script:SSM_BIN_DIR -ErrorAction Stop } catch { }

    # Only succeeds when nothing the user might want back is still in there.
    try { Remove-Item -LiteralPath $script:SSM_DIR -ErrorAction Stop } catch { }
    return $ok
}

# bash: uninstall_remove (ssm.sh:1592)
function Remove-SsmDependency {
    param([string]$Key)
    switch -CaseSensitive ($Key) {
        'config' {
            if (-not (Remove-SsmPath $script:SSM_DIR)) { return $false }
            Write-Host "Removed $(Get-SsmShortPath $script:SSM_DIR)"
            return $true
        }
        'Amazon.AWSCLI' {
            return (Remove-SsmWingetPackage 'Amazon.AWSCLI' 'AWS CLI v2' $script:AWS_CLI_DIR)
        }
        'Amazon.SessionManagerPlugin' {
            return (Remove-SsmWingetPackage 'Amazon.SessionManagerPlugin' 'session-manager-plugin' $script:SSM_PLUGIN_DIR)
        }
        default {
            if ($script:UNINSTALL_WINGET_PACKAGES -cnotcontains $Key) {
                Write-SsmErr "Unknown item '$Key'."
                return $false
            }
            return (Remove-SsmWingetPackage $Key $Key '')
        }
    }
}

function Remove-SsmWingetPackage {
    param([string]$Id, [string]$Label, [string]$Directory)
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget uninstall --id $Id --exact --silent --disable-interactivity 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Removed $Label"
            return $true
        }
    }
    if ($Directory -and (Test-Path -LiteralPath $Directory)) {
        if (-not (Remove-SsmPath $Directory "winget uninstall --id $Id -e")) { return $false }
        Write-Host "Removed $Label ($Directory)"
        return $true
    }
    Write-SsmErr "Could not remove $Label."
    return $false
}

# bash: cmd_uninstall (ssm.sh:1614)
function Invoke-SsmUninstall {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Rest)
    if (-not (Read-SsmCommandArgs 'uninstall' $Rest)) { Exit-Ssm 1 }

    $rows = Get-SsmUninstallRows

    Write-Host 'ssm uninstall removes:'
    Write-Host "  $(Get-SsmShortPath $script:SSM_LAUNCHER)"
    Write-Host "  $(Get-SsmShortPath $script:SSM_SCRIPT)"
    Write-Host '  the ssm entry in your user PATH, and its shortcuts'
    Write-Host 'It never touches ~/.aws or winget itself.'
    Write-Host ''

    if (-not $script:ARG_YES) {
        $confirm = Read-SsmLine 'Uninstall ssm? [y/N]: '
        if (-not (Test-SsmYes $confirm)) { Write-SsmErr 'Aborted.'; return }
    }

    $selected = [string[]]@()
    if ($script:ARG_YES -or $script:ARG_PURGE -or $script:ARG_WITH_DEPS) {
        $selected = Get-SsmUninstallFlaggedKeys $rows
    } elseif ($rows.Count -gt 0) {
        $selected = Invoke-SsmMultiMenu 'Also remove?' `
            'Tab marks, Enter confirms. Other tools on this PC may rely on these.' $rows
        if ($null -eq $selected) { Write-SsmErr 'Aborted.'; return }
    }

    $failed = $false
    if (-not (Invoke-SsmUninstallCore)) { $failed = $true }
    foreach ($key in $selected) {
        if (-not (Remove-SsmDependency $key)) { $failed = $true }
    }

    Write-Host ''
    if ($failed) {
        Write-SsmErr 'Some items could not be removed -- see the errors above.'
        Exit-Ssm 1
    }
    Write-Host 'ssm uninstalled.'
    if (Test-Path -LiteralPath $script:SSM_DIR) {
        Write-Host "Kept $(Get-SsmShortPath $script:SSM_DIR); a reinstall picks it up. Delete it by hand once you are done with it."
    }
}

# ---------------------------------------------------------------------------
# Usage. Generated from ssm.sh's usage_for and cmd_help, so the two are
# byte-identical apart from the platform tokens listed below.
#
# test/parity_test.sh reads these PLATFORM-TOKEN lines, inverts them, and diffs
# the real `--help` output of both implementations. Adding a difference means
# adding a line here; there is nowhere else to declare one.
#
# PLATFORM-TOKEN	~/.ssm/config.json	%USERPROFILE%\.ssm\config.json
# PLATFORM-TOKEN	~/.ssm/kubeconfig	%USERPROFILE%\.ssm\kubeconfig
# PLATFORM-TOKEN	~/.ssm/ssm.sh	%USERPROFILE%\.ssm\ssm.ps1
# PLATFORM-TOKEN	/usr/local/bin/ssm	%USERPROFILE%\.ssm\bin\ssm.cmd
# PLATFORM-TOKEN	~/.ssm	%USERPROFILE%\.ssm
# PLATFORM-TOKEN	~/.aws	%USERPROFILE%\.aws
# PLATFORM-TOKEN	brew install kubernetes-cli	winget install Kubernetes.kubectl
# PLATFORM-TOKEN	brew install jq	winget install jqlang.jq
# PLATFORM-TOKEN	brew install fzf	winget install junegunn.fzf
# PLATFORM-TOKEN	fzf, jq, kubectl	fzf, kubectl
# PLATFORM-TOKEN	install.sh adds	install.ps1 adds
# PLATFORM-TOKEN	bash install.sh	install.ps1
# PLATFORM-TOKEN	Homebrew packages	winget packages
# PLATFORM-TOKEN	Homebrew itself	winget itself
# PLATFORM-TOKEN	Homebrew	winget
# PLATFORM-TOKEN	this Mac	this PC
# ---------------------------------------------------------------------------

# bash: usage_for (ssm.sh:1662)
function Get-SsmUsage {
    param([string]$Command)
    switch -CaseSensitive ($Command) {
        { $_ -ceq 'ssh' } {
            return @'
ssm ssh — Shell into an EC2 instance, an ECS container instance, or an
          ECS/Fargate container.

  ssm ssh [--env <name>] [--app <name>] [--type ec2|ecs]
          [--instance <id|Name>] [--container <name>] [--task <id>] [--host]

  --env, -e     account in %USERPROFILE%\.ssm\config.json    (default: pick from a menu)
  --app         App tag                          (default: pick from a menu)
  --type        ec2 or ecs, when the app has both
  --instance    EC2 instance id or Name tag; implies --type ec2
  --container   container name; implies --type ecs, or the container shell
                on an ECS container instance
  --task        ECS task id, to disambiguate when --container matches several
  --host        on an ECS container instance, open the host shell

EXAMPLES
  ssm ssh                                       fully interactive
  ssm ssh --env staging                         skips the account menu
  ssm ssh --env staging --app adam              no prompts if the app has one instance
  ssm ssh --env staging --instance web-01       match an EC2 Name tag
  ssm ssh --env staging --instance i-0abc123    or an instance id
  ssm ssh --env staging --app adam --container php-fpm
  ssm ssh --env staging --app adam --container php-fpm --task 7d9f2a
  ssm ssh --env staging --app adam --type ecs   when the app has both EC2 and ECS
  ssm ssh --env staging --app adam --host       host shell on an ECS node
'@ -split "`n"
        }
        { $_ -ceq 'pod' } {
            return @'
ssm pod — Shell into an EKS pod via kubectl.

  ssm pod [--env <name>] [--cluster <name>] [--namespace|-n <ns>]
          [--pod <name>] [--container|-c <name>]

  --env, -e       account in %USERPROFILE%\.ssm\config.json  (default: pick from a menu)
  --cluster       EKS cluster name
  --namespace, -n Kubernetes namespace
  --pod           pod name (running pods only)
  --container, -c container name within the pod

EXAMPLES
  ssm pod                                       fully interactive
  ssm pod --env staging                         skips the account menu
  ssm pod --env staging --cluster sc-staging-eks
  ssm pod --env staging -n default              skips the namespace menu
  ssm pod --env staging -n default --pod api-7d9f
  ssm pod --env staging -n default --pod api-7d9f -c sidecar
'@ -split "`n"
        }
        { $_ -ceq 'db' } {
            return @'
ssm db — Open an RDS tunnel via SSM port forwarding.

  ssm db [--env <name>] [--app <name>] [--db <identifier>] [--instance <id|Name>]

  --env, -e     account in %USERPROFILE%\.ssm\config.json    (default: pick from a menu)
  --app         App tag                          (default: pick from a menu)
  --db          RDS DBInstanceIdentifier
  --instance    EC2 instance to tunnel through   (default: the first one found)

The local port is assigned on first use and remembered in %USERPROFILE%\.ssm\config.json.
Change it with `ssm config edit --env <name> --db <id> --port <n>`.

EXAMPLES
  ssm db                                        fully interactive
  ssm db --env staging                          skips the account menu
  ssm db --env staging --app adam               no prompts if the app has one database
  ssm db --env staging --app adam --db sc-staging-adam-rds
  ssm db --env staging --app adam --db sc-staging-adam-rds --instance web-01
'@ -split "`n"
        }
        { $_ -ceq 'config' } {
            return @'
ssm config — Manage account profiles and AWS CLI credentials.

  ssm config [view|add|edit|delete] [flags]      (no action: pick from a menu)

  ssm config view   [--env <name>]
  ssm config add    --env <name> [--profile <p>] [--region <r>]
                    [--access-key <k>] [--secret-key -] [--skip-credentials]
                    [--force]
  ssm config edit   --env <name> [--name <new>] [--profile <p>] [--region <r>]
                    [--access-key <k>] [--secret-key -]
                    [--db <id> --port <n>]
  ssm config delete --env <name> [--yes] [--delete-profile]
  ssm config delete --env <name> --db <id> [--yes]

  --name            rename the account; keeps its region and db ports, and does
                    not touch the AWS CLI profile
  --db, --port      set the local tunnel port for one database (both required)
  --force           let `add` replace an account that already exists
  --yes             skip the delete confirmation
  --delete-profile  also remove the profile from %USERPROFILE%\.aws/credentials and config

EXAMPLES
  ssm config                                    pick an action from a menu
  ssm config view                               every account
  ssm config view --env staging                 one account
  ssm config add --env staging --profile sc-staging --region ap-southeast-5
  ssm config add --env staging --profile sc-staging --region ap-southeast-5 \
    --skip-credentials                          config only, no AWS CLI setup
  SSM_AWS_SECRET_KEY=... ssm config add --env staging --profile sc-staging \
    --region ap-southeast-5 --access-key AKIA...
  ssm config edit --env staging --region ap-southeast-1
  ssm config edit --env staging --name stg      rename the account
  ssm config edit --env staging --db sc-staging-adam-rds --port 15433
  ssm config delete --env staging --db sc-staging-adam-rds --yes
  ssm config delete --env staging --yes --delete-profile

Never pass a secret as a flag value -- it lands in your shell history. Set
SSM_AWS_SECRET_KEY=... or use '--secret-key -' to read one line from stdin.
'@ -split "`n"
        }
        { $_ -ceq 'version' } {
            return @'
ssm version — Print the installed ssm version.

  ssm version

A released copy prints its tag, e.g. v1.2.3. A copy run straight from a git
checkout prints "dev".
'@ -split "`n"
        }
        { $_ -ceq 'uninstall' } {
            return @'
ssm uninstall — Remove ssm, and optionally its config and dependencies.

  ssm uninstall [--yes] [--purge] [--with-deps]

Always removes %USERPROFILE%\.ssm\bin\ssm.cmd and %USERPROFILE%\.ssm\ssm.ps1, then opens a checklist of
what else is present: %USERPROFILE%\.ssm (config, db ports, kubeconfig) and the dependencies
install.ps1 adds -- fzf, kubectl, AWS CLI v2 and the Session Manager plugin.
Nothing on the checklist is removed unless you mark it; other tools may rely on
those dependencies. %USERPROFILE%\.aws and winget are never touched.

  --yes         skip the confirmation; remove only what the other flags name
  --purge       also delete %USERPROFILE%\.ssm
  --with-deps   also remove every installed dependency listed above

Passing --purge or --with-deps answers the checklist instead of opening it.

EXAMPLES
  ssm uninstall                                 confirm, then pick from a checklist
  ssm uninstall --yes                           the command only; keep config and deps
  ssm uninstall --yes --purge                   the command and %USERPROFILE%\.ssm
  ssm uninstall --yes --purge --with-deps       everything install.sh added
'@ -split "`n"
        }
        default { return Show-SsmHelp }
    }
}

# bash: cmd_help (ssm.sh:1849)
function Show-SsmHelp {
    return @'

USAGE
  ssm <command> [flags]      every flag you omit falls back to its menu

  ssm ssh        Shell into an EC2 instance, an ECS container instance, or an
                 ECS/Fargate container. Detects ECS nodes and asks whether you
                 want the host shell or a container shell.
  ssm pod        Shell into an EKS pod via kubectl (cluster -> namespace -> pod)
  ssm db         Open an RDS tunnel via SSM port forwarding
  ssm config     View, add, edit, or delete AWS account profiles
  ssm update     Replace this script with the latest version from CDN
  ssm uninstall  Remove ssm, and optionally its config and dependencies
  ssm version    Print the installed version
  ssm help       Show this text

  Run `ssm <command> --help` for that command's flags.

FLAGS
  ssm ssh        [--env <name>] [--app <name>] [--type ec2|ecs]
                 [--instance <id|Name>] [--container <name>] [--task <id>]
                 [--host]
  ssm pod        [--env <name>] [--cluster <name>] [-n <namespace>]
                 [--pod <name>] [-c <container>]
  ssm db         [--env <name>] [--app <name>] [--db <identifier>]
                 [--instance <id|Name>]
  ssm config     [view|add|edit|delete] [--env <name>] [--name <new>]
                 [--profile <p>] [--region <r>] [--db <id> --port <n>]
                 [--access-key <k>] [--secret-key -] [--skip-credentials]
                 [--force] [--yes] [--delete-profile]
  ssm uninstall  [--yes] [--purge] [--with-deps]

EXAMPLES
  ssm ssh                                     fully interactive, as before
  ssm ssh --env staging                       skips the account menu
  ssm ssh --env staging --app adam            no prompts if the app has one instance
  ssm ssh --env staging --app adam --container php-fpm
  ssm ssh --env staging --instance web-01     match an EC2 Name tag or id
  ssm db  --env staging --app adam --db sc-staging-adam-rds
  ssm pod --env staging -n default --pod api-7d9f
  ssm config view --env staging
  ssm config add --env staging --profile sc-staging --region ap-southeast-5
  ssm config edit --env staging --name stg --region ap-southeast-1
  ssm config edit --env staging --db sc-staging-adam-rds --port 15433
  ssm config delete --env staging --yes --delete-profile

  A value that does not exist is an error listing the valid ones, so a fully
  flagged command never stops to ask a question.

  Run `ssm <command> --help` for that command's full flag list and examples.

SECRETS
  Never pass a secret key as a flag value -- it is recorded in your shell
  history. Use SSM_AWS_SECRET_KEY=... or '--secret-key -' to read one line
  from stdin.

CONFIG FILE
  %USERPROFILE%\.ssm\config.json — maps account names to AWS CLI profiles and regions.
  DB port assignments are auto-saved here on first use.
  %USERPROFILE%\.ssm\kubeconfig  — written by `ssm pod`. Your ~/.kube/config is never touched.

'@ -split "`n"
}

# bash: cmd_menu (ssm.sh:1820)
#
# `ssm` with no command asks what to do, rather than printing a usage block at
# someone who just wants to connect to something. This is what the Start Menu
# shortcut launches.
#
# Returns the chosen command name, or nothing when the menu is cancelled.
function Show-SsmCommandMenu {
    $items = @(
        'ssh        Shell into an EC2 instance or an ECS container'
        'pod        Shell into an EKS pod'
        'db         Open an RDS tunnel'
        'config     View, add, edit, or delete AWS account profiles'
        'update     Replace this script with the latest version'
        'uninstall  Remove ssm, and optionally its config and dependencies'
        'version    Print the installed version'
        'help       Show the full flag reference'
    )
    $choice = Invoke-SsmMenu 'What do you want to do?' $items
    if (-not $choice) { return $null }
    return ($choice -split ' ')[0]
}

# ---------------------------------------------------------------------------
# Dispatch. Dot-sourcing the script (the test suite does) must not run a
# command; InvocationName is '.' only when the file is dot-sourced.
# ---------------------------------------------------------------------------
function Invoke-SsmMain {
    param([string[]]$Argv)

    # A previous update or uninstall may have left a .old it could not delete
    # while the file was still open. Sweeping here costs nothing and never
    # blocks, which is why the replace itself can give up on the cleanup.
    Get-ChildItem -LiteralPath $script:SSM_DIR -Filter '*.old' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }

    # An install from v1.2.5 or earlier, including one that `ssm update` moved
    # to this version: the update ran the old script's code, which rewrote the
    # old shim beside ssm.ps1. Move it into bin\ once, here. The old shim stays
    # where it is -- it may be the batch file running us, and cmd.exe reads
    # those lazily -- but off the PATH it resolves nothing; uninstall removes it.
    # Not before an uninstall, which removes both anyway.
    if (($Argv.Count -eq 0 -or $Argv[0] -cne 'uninstall') -and
        (Test-SsmOwnLauncher $script:SSM_LEGACY_LAUNCHER) -and
        -not (Test-Path -LiteralPath $script:SSM_LAUNCHER)) {
        try {
            # stderr, and once: a scripted `ssm ... | ...` must not see it.
            Write-SsmLauncher $script:SSM_LAUNCHER
            Repair-SsmUserPath -Quiet
            Write-SsmErr "Moved the ssm shim to $(Get-SsmShortPath $script:SSM_LAUNCHER); open a new terminal to pick it up."
        } catch {
            Write-SsmErr "Could not move the ssm shim: $($_.Exception.Message)"
        }
    }

    $script:COMMAND = if ($Argv.Count -gt 0) { $Argv[0] } else { '' }
    # Assigned in two statements on purpose: `$x = if (...) {...} else { @() }`
    # unrolls the empty array to $null, and splatting that passes one empty
    # string, which every command then rejects as an unknown option.
    $rest = [string[]]@()
    if ($Argv.Count -gt 1) { $rest = [string[]]@($Argv[1..($Argv.Count - 1)]) }

    # No command: ask, but only when there is someone there to ask. Piped or
    # redirected, bare `ssm` keeps printing the usage line and exiting 1 the way
    # it always has, so nothing scripted against it changes.
    if (-not $script:COMMAND -and (Test-SsmInteractive)) {
        $picked = Show-SsmCommandMenu
        if (-not $picked) { return }
        $script:COMMAND = $picked
    }

    switch -CaseSensitive ($script:COMMAND) {
        'ssh' { Invoke-SsmSsh @rest }
        'pod' { Invoke-SsmPod @rest }
        'db' { Invoke-SsmDb @rest }
        'config' { Invoke-SsmConfig @rest }
        'update' { Invoke-SsmUpdate @rest }
        'uninstall' { Invoke-SsmUninstall @rest }
        { $_ -ceq 'version' -or $_ -ceq '--version' } { Invoke-SsmVersion @rest }
        { $_ -ceq 'help' -or $_ -ceq '-h' -or $_ -ceq '--help' } {
            Show-SsmHelp | ForEach-Object { Write-Output $_ }
        }
        default {
            Write-SsmErr 'Usage: ssm [ssh|pod|db|config|update|uninstall|version|help] [flags]'
            Write-SsmErr "Run 'ssm help' for the full flag reference."
            Exit-Ssm 1
        }
    }
}

# The exit code travels as an exception, never as a return value: a PowerShell
# function returns everything written to the success stream, so `exit (Invoke-
# SsmMain ...)` would swallow every line the command printed.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-SsmMain ([string[]]@($args))
        exit 0
    } catch [SsmExitException] {
        exit $_.Exception.Code
    }
}
