<#
.SYNOPSIS
  Windows launcher for the Claude Code multi-provider patch.

.DESCRIPTION
  Thin wrapper around claude_patch.py (the real, cross-platform installer).
  Its only job is to locate a WORKING Python interpreter and forward the
  arguments — on Windows `python3` frequently resolves to the Microsoft Store
  stub, which exits silently without running anything, so we probe candidates
  and verify each one actually reports a version.

.EXAMPLE
  .\patch-claude-routing.ps1
  Patch the active Claude Code installation.

.EXAMPLE
  .\patch-claude-routing.ps1 --update
  Download the latest build from npm, install it, repoint the launcher, patch it.

.EXAMPLE
  .\patch-claude-routing.ps1 --update 2.1.220
  Same, pinned to a specific version.

.NOTES
  If PowerShell refuses to run this file ("running scripts is disabled"), either
  invoke it as
      powershell -ExecutionPolicy Bypass -File .\patch-claude-routing.ps1 --update
  or call the Python entrypoint directly
      py -3 claude_patch.py --update

  Close every Claude Code session (including VS Code) before running: Windows
  locks a running .exe and the patched binary cannot replace it.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Args
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$patcher = Join-Path $scriptDir 'claude_patch.py'
if (-not (Test-Path -LiteralPath $patcher)) {
    [Console]::Error.WriteLine("ERROR: claude_patch.py not found next to this script ($patcher)")
    exit 1
}

# Candidate interpreters, best first. `py -3` is the official Windows launcher
# and is immune to the Store-stub problem.
$candidates = @(
    @{ Exe = 'py';      Pre = @('-3') },
    @{ Exe = 'python';  Pre = @() },
    @{ Exe = 'python3'; Pre = @() }
)

function Test-Python {
    param([string]$Exe, [string[]]$Pre)
    if (-not (Get-Command $Exe -ErrorAction SilentlyContinue)) { return $false }
    try {
        # The Store stub produces no output and a non-zero exit code here.
        $out = & $Exe @Pre '--version' 2>&1
        return ($LASTEXITCODE -eq 0) -and ("$out" -match 'Python\s+3\.')
    } catch {
        return $false
    }
}

$python = $null
foreach ($c in $candidates) {
    if (Test-Python -Exe $c.Exe -Pre $c.Pre) { $python = $c; break }
}

if (-not $python) {
    # Plain stderr, not Write-Error: with ErrorActionPreference=Stop the latter
    # decorates a user-facing "install Python" notice with a PowerShell stack.
    [Console]::Error.WriteLine(@'
No working Python 3 interpreter found.

Install Python from https://www.python.org/downloads/windows/ (tick "Add
python.exe to PATH"), or from the Microsoft Store, then re-run this script.
Note: a bare `python3` on PATH is often the Store *stub*, which does nothing --
this script deliberately rejects it.
'@)
    exit 1
}

& $python.Exe @($python.Pre) $patcher @Args
exit $LASTEXITCODE
