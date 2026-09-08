<#
.SYNOPSIS
    The Windows half of the deployment contract: copy the declared payload,
    seed .env missing-only, register services and scheduled tasks.

.DESCRIPTION
    READ THIS FIRST. docs/DEPLOY-CONTRACT.md section 1.2 puts Windows OUT OF
    SCOPE for the six Cockpit plugins, and cockpit-tuner is one of them:
    Cockpit is a Linux service, so there is no /usr/share/cockpit on this
    platform and no page for a browser to load. This script therefore REFUSES
    the Cockpit half by name rather than pretending to do it.

    It exists for two real reasons:

      1. It is the reference implementation of sections 1.2 and 6.5 that the
         deliverables which DO ship on Windows copy from - cockpit-wireguard's
         windows-client, edy-proxy-go's Windows agents. Those projects clone
         this file and fill in SERVICES and TASKS.
      2. It stages a payload and its configuration on a Windows host, which is
         how a Windows build agent or an offline transfer step packages one.

    WHY THERE IS NO SYMLINK MODEL HERE (JC-2). mklink needs elevation or
    Developer Mode, junctions behave differently under every backup and AV
    product on the estate, and SeCreateSymbolicLink is an audited privilege. So
    deploy.ps1 COPIES into payload\, and the Windows equivalent of "in-place
    install" is simply that install.ps1 is RUN FROM payload\ and registers
    services pointing there. The cost - no live-edit dev install on Windows -
    is accepted; the dev loop is "build, deploy to C:\dev\<Project>, restart".

    THE SPLIT, and it is the same one as on Linux:
      C:\Program Files\<Project>\payload\   the payload, replaced wholesale
      C:\ProgramData\<Project>\.env         operator config, seeded missing-only
      C:\ProgramData\<Project>\state\       state that survives an upgrade
      C:\ProgramData\<Project>\logs\
    Program Files is UAC-protected and Administrators-writable only, which is
    the correct home for code a service executes. A service running as
    LocalSystem or a virtual account can be granted write on ProgramData
    WITHOUT being granted write over its own binaries. A SERVICE THAT CAN
    REWRITE ITS OWN EXECUTABLE IS A PERSISTENCE MECHANISM, NOT A SERVICE.

.PARAMETER InstallTo
    Override the install root. Must be absolute.

.PARAMETER Uninstall
    Stop and remove the services and scheduled tasks. Keeps ProgramData.

.PARAMETER Remove
    Uninstall, then delete payload\. Still keeps ProgramData, and says so.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy.ps1
#>
[CmdletBinding()]
param(
    [string] $InstallTo,
    [switch] $Uninstall,
    [switch] $Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Src = Split-Path -Parent $MyInvocation.MyCommand.Path

function Die  ([string] $m) { Write-Error "deploy.ps1: $m"; exit 1 }
function Say  ([string] $m) { Write-Host "  + $m" }
function Note ([string] $m) { Write-Host "  $m" }
function Warn ([string] $m) { Write-Warning $m }

# ---------------------------------------------------------------------------
# THE ONE DECLARATION, read out of install.sh's BEGIN-MANIFEST block. Not
# restated here - two lists that can disagree is the failure being designed
# out, and restating the payload in a second language is the most durable way
# to re-introduce it.
# ---------------------------------------------------------------------------
function Read-Manifest {
    param([string] $InstallSh)
    if (-not (Test-Path $InstallSh)) { Die "no install.sh beside me at $InstallSh" }
    $lines = Get-Content -LiteralPath $InstallSh
    $begin = ($lines | Select-String -SimpleMatch '# BEGIN-MANIFEST' | Select-Object -First 1)
    $end   = ($lines | Select-String -SimpleMatch '# END-MANIFEST'   | Select-Object -First 1)
    if (-not $begin -or -not $end) {
        Die "install.sh has no BEGIN-MANIFEST/END-MANIFEST block. That block is the single source of the payload list; without it this script would have to guess."
    }
    $block = $lines[($begin.LineNumber)..($end.LineNumber - 2)]
    $m = @{}
    foreach ($line in $block) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^([A-Z_]+)=\((.*)\)\s*(#.*)?$') {
            $m[$Matches[1]] = @($Matches[2] -split '\s+' | Where-Object { $_ -ne '' } |
                                ForEach-Object { $_.Trim('"') })
        } elseif ($line -match '^([A-Z_]+)=\(') {
            # An array assignment that did not close on this line. Bash's eval
            # would join the continuation; this parser is line-oriented and
            # would silently hand back a truncated STRING where an array was
            # meant - which is exactly what it did once. Refuse instead.
            Die "install.sh manifest: $($Matches[1])=( does not close on one line. Every assignment in the BEGIN-MANIFEST block must fit on a single line - see the note in that block."
        } elseif ($line -match '^([A-Z_]+)="?([^"#]*)"?\s*(#.*)?$') {
            $m[$Matches[1]] = $Matches[2].Trim()
        } elseif ($line.Trim() -ne '') {
            Die "install.sh manifest: cannot parse line: $line"
        }
    }
    return $m
}

$M       = Read-Manifest (Join-Path $Src 'install.sh')
$Project = $M['PROJECT']
if (-not $Project) { Die 'the manifest block did not define PROJECT.' }

$VersionFile = Join-Path $Src 'VERSION'
if (-not (Test-Path $VersionFile)) {
    Die 'no VERSION file. The payload directory is named payload-<version>; without one there is nothing to name it, and no rollback.'
}
$Version = (Get-Content -LiteralPath $VersionFile -TotalCount 1).Trim()

# Title-cased project name for the Windows paths: cockpit-secrets -> Cockpit-Secrets
$WinName = ($Project -split '-' | ForEach-Object {
    $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join '-'

if (-not $InstallTo) { $InstallTo = Join-Path $env:ProgramFiles $WinName }
if (-not [System.IO.Path]::IsPathRooted($InstallTo)) { Die "-InstallTo must be absolute; got '$InstallTo'" }
$DataRoot = Join-Path $env:ProgramData $WinName
$EnvFile  = Join-Path $DataRoot '.env'
$Payload  = Join-Path $InstallTo "payload-$Version"

# Services and scheduled tasks this project registers. EMPTY for the Cockpit
# plugins - they have none on Windows - and this is where a project that does
# ship on Windows fills in its own. Kept as declarations rather than inline
# calls so that Uninstall can enumerate exactly what Deploy created.
$Services = @()   # @{ Name='Edy'; Exe='bin\svc.exe'; Args='--config "<env>"' }
$Tasks    = @()   # @{ Name='Snapshot'; Exe='bin\snap.exe'; Schedule='Hourly' }
$TaskPath = "\$WinName\"

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Die 'needs an elevated PowerShell: it writes Program Files and registers services.'
    }
}

# ===========================================================================
# the section 1.2 refusal - stated, not silently skipped
# ===========================================================================
Write-Host ''
Write-Host "$Project $Version - Windows deployment"
Warn @"
$Project is a COCKPIT PLUGIN. Cockpit is a Linux service, so the page half of
this deployment - /usr/share/cockpit/$($M['NAME']) and the /usr/local/sbin verb
helper - CANNOT be installed on Windows and is not attempted. See
docs/DEPLOY-CONTRACT.md section 1.2.

What this script will do: stage the payload, seed and validate .env, and
register whatever is declared in `$Services / `$Tasks (nothing, for this
project). Use deploy.sh on the Linux host that actually serves the page.
"@

# ===========================================================================
# uninstall / remove
# ===========================================================================
if ($Uninstall -or $Remove) {
    Assert-Admin
    foreach ($s in $Services) {
        $svc = Get-Service -Name $s.Name -ErrorAction SilentlyContinue
        if ($svc) {
            Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
            & sc.exe delete $s.Name | Out-Null
            Say "removed service $($s.Name)"
        }
    }
    # Registered under a task folder named for the project, never at the root
    # of the task library, so this enumeration cannot reach somebody else's task.
    Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue |
        ForEach-Object {
            Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $TaskPath -Confirm:$false
            Say "removed scheduled task $TaskPath$($_.TaskName)"
        }
    if ($Remove) {
        Get-ChildItem -LiteralPath $InstallTo -Directory -Filter 'payload-*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                # The containment assertion, same as remove_old_payload's: only
                # a payload-* directory directly under the resolved install root.
                $real = (Resolve-Path -LiteralPath $_.FullName).Path
                $rootReal = (Resolve-Path -LiteralPath $InstallTo).Path
                if ($real -notlike (Join-Path $rootReal 'payload-*')) {
                    Die "refusing to recursively remove $real - not a payload dir under $rootReal"
                }
                Remove-Item -LiteralPath $real -Recurse -Force
                Say "removed $real"
            }
    }
    Write-Host ''
    Write-Host "KEPT, deliberately - an uninstall removes software, not data:"
    Write-Host "  $DataRoot"
    Write-Host "      Your .env, your state and your logs. Remove it by hand if you"
    Write-Host "      mean to; this verb is not the one that throws them away."
    exit 0
}

# ===========================================================================
# deploy
# ===========================================================================
Assert-Admin
Write-Host ''
Write-Host 'Copying the declared payload'

$Tmp = "$Payload.tmp"
if (Test-Path $Tmp) { Remove-Item -LiteralPath $Tmp -Recurse -Force }
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null

function Copy-In {
    param([string[]] $Rel)
    foreach ($r in $Rel) {
        $from = Join-Path $Src $r
        if (-not (Test-Path $from)) { Die "declared payload item missing: $r" }
        $to = Join-Path $Tmp $r
        $dir = Split-Path -Parent $to
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $from -Destination $to -Force
    }
}

Copy-In $M['PAGE']
Copy-In @($M['ENVDEFAULT'], 'VERSION', 'install.sh')
foreach ($n in @('LICENSE', 'README.md')) {
    if (Test-Path (Join-Path $Src $n)) { Copy-In @($n) }
}
foreach ($h in $M['HELPERS']) {
    if     (Test-Path (Join-Path $Src "bin\$h")) { Copy-In @("bin\$h") }
    elseif (Test-Path (Join-Path $Src $h))       { Copy-In @($h) }
}
foreach ($l in $M['LIBS']) {
    $leaf = $l -replace '^lib/', ''
    $from = Join-Path $Src $l
    if (-not (Test-Path $from)) { $from = Join-Path $Src $leaf }
    if (Test-Path $from) {
        $dest = Join-Path $Tmp "lib\$leaf"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        # Only the file types the code imports, so a stray __pycache__ or an
        # editor backup cannot reach a host where it would be imported.
        Get-ChildItem -LiteralPath $from -File -Include *.py, *.json |
            Copy-Item -Destination $dest -Force
    }
}

# The payload is complete only now. Move-Item over the final name is the
# closest Windows gets to mv -T: there is no window in which a half-written
# payload-<version> is visible under its real name.
if (Test-Path $Payload) { Remove-Item -LiteralPath $Payload -Recurse -Force }
Move-Item -LiteralPath $Tmp -Destination $Payload
Say "wrote $Payload"

# Keep exactly one previous version, so a rollback is a rename with no network.
Get-ChildItem -LiteralPath $InstallTo -Directory -Filter 'payload-*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "payload-$Version" } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 1 |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force
                     Say "removed superseded $($_.Name)" }

# ===========================================================================
# .env - seeded MISSING-ONLY, and never containing a secret
# ===========================================================================
Write-Host ''
Write-Host 'Configuration'
foreach ($d in @($DataRoot, (Join-Path $DataRoot 'state'), (Join-Path $DataRoot 'logs'))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null; Say "created $d" }
}

function Get-EnvKeys ([string] $Path) {
    Get-Content -LiteralPath $Path |
        Where-Object { $_ -match '^\s*[A-Z][A-Z0-9_]*=' } |
        ForEach-Object { ($_ -split '=', 2)[0].Trim() }
}

if (Test-Path $EnvFile) {
    Note "kept existing $EnvFile (NOT overwritten - it is what you decided)"
    $new = @(Get-EnvKeys (Join-Path $Payload $M['ENVDEFAULT'])) |
           Where-Object { $_ -notin @(Get-EnvKeys $EnvFile) }
    # The known cost of missing-only seeding, paid honestly rather than by
    # silently adding keys to a file the operator owns.
    if ($new) { Warn "this version adds key(s) your .env does not set: $($new -join ', ')" }
} else {
    Copy-Item -LiteralPath (Join-Path $Payload $M['ENVDEFAULT']) -Destination $EnvFile
    Say "seeded $EnvFile - REVIEW IT before first use"
}

# The rule that makes a world-readable .env safe. A deployed .env carries
# locations and settings; the moment one carries a credential, the permissions
# that let a service read a port number also leak the credential.
foreach ($line in Get-Content -LiteralPath $EnvFile) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $k, $v = ($line -split '=', 2)
    $k = $k.Trim(); $v = $v.Trim()
    if ($k -notmatch '(PASS|PASSWORD|SECRET|TOKEN|KEY|CREDENTIAL|PASSPHRASE)') { continue }
    if ($k -match '_(FILE|PATH|DIR|NAME|ID)$' -or $v -eq '') { continue }
    Die @"
$k in $EnvFile looks like a secret VALUE. A deployed .env carries locations
    and settings, never secrets. Put the material in an ACL'd directory under
    $DataRoot and name the FILE here (${k}_FILE=...).
"@
}
Note "no key in $EnvFile holds a secret-shaped value"

# ===========================================================================
# services and scheduled tasks - registered, and NEVER set to start themselves
# ===========================================================================
# Manual, not Automatic, and nothing is started here: the operator starts it,
# which is section 6.1's rule and the same one install.sh obeys on Linux. A
# deployment that silently starts a daemon is not a deployment anyone should
# run twice.
foreach ($s in $Services) {
    $exe = Join-Path $Payload $s.Exe
    if (-not (Test-Path $exe)) { Die "service $($s.Name) names $exe, which the payload does not ship." }
    if (Get-Service -Name $s.Name -ErrorAction SilentlyContinue) {
        & sc.exe config $s.Name binPath= "`"$exe`" $($s.Args)" start= demand | Out-Null
        Say "reconfigured service $($s.Name)"
    } else {
        # A virtual account (NT SERVICE\<Name>) rather than LocalSystem wherever
        # the work does not need machine identity. It is granted write on
        # ProgramData only - never on payload\.
        New-Service -Name $s.Name -BinaryPathName "`"$exe`" $($s.Args)" `
                    -StartupType Manual -Description "$Project $Version" | Out-Null
        Say "registered service $($s.Name) (Manual, NOT started)"
    }
}
foreach ($t in $Tasks) {
    $exe = Join-Path $Payload $t.Exe
    if (-not (Test-Path $exe)) { Die "task $($t.Name) names $exe, which the payload does not ship." }
    $action  = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $DataRoot
    $trigger = New-ScheduledTaskTrigger -Daily -At 3am
    Register-ScheduledTask -TaskName $t.Name -TaskPath $TaskPath -Action $action `
                           -Trigger $trigger -Force | Out-Null
    Say "registered scheduled task $TaskPath$($t.Name)"
}
if (-not $Services -and -not $Tasks) {
    Note 'no services or scheduled tasks declared for this project'
}

Write-Host ''
Write-Host "Done. $InstallTo\payload-$Version"
Write-Host "Config and state: $DataRoot (kept across every upgrade and uninstall)"
