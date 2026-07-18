<#
.SYNOPSIS
    Interrupt affinity policy manager for PCI devices.
.DESCRIPTION
    Lists PCI devices with their current interrupt affinity policy in
    Out-GridView, then pins the interrupts of the devices you select to the
    CPU cores you pick in a second grid (P/E-cores labeled on hybrid CPUs).
    Writes the documented DevicePolicy / AssignmentSetOverride registry
    values. Zero external dependencies. Windows PowerShell 5.1+.
.PARAMETER ShowAll
    Show every PCI device with an Interrupt Management key, including
    bridges and abstract controllers (hidden by default).
.PARAMETER Reset
    Remove the affinity policy override from the selected devices
    (restore the machine default) instead of setting one.
.NOTES
    Restart the device (disable/enable in Device Manager) or reboot for
    changes to take effect.
    Revert: apply the affinity_undo_*.reg file written before each change.
    Each undo file is a per-run snapshot: after several runs touching the
    same device, apply them newest-to-oldest - only the oldest file holds
    the original state.
    (-Reset deletes both values; if another tool wrote a policy you want
    back, only the undo file restores it.)
#>
[CmdletBinding()]
param(
    [switch]$ShowAll,
    [switch]$Reset,
    [switch]$Elevated   # internal: set by the self-elevation relaunch
)

$ErrorActionPreference = 'Stop'

# Keep the self-elevated window open so the user can read the output.
function Wait-IfElevatedWindow {
    if ($Elevated) { Read-Host "Press Enter to close" | Out-Null }
}

# Without this, an unhandled error closes the self-elevated window before
# the user can read the message.
trap {
    Write-Host "ERROR: $_" -ForegroundColor Red
    Wait-IfElevatedWindow
    exit 1
}

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Not running as Administrator. Requesting elevation..." -ForegroundColor Yellow
    try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                     '-File', "`"$PSCommandPath`"", '-Elevated')
        if ($ShowAll) { $argList += '-ShowAll' }
        if ($Reset)   { $argList += '-Reset' }
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    } catch {
        Write-Host "ERROR: elevation was refused. Run this script as Administrator." -ForegroundColor Red
    }
    return
}

# PowerShell 7 ships without Out-GridView (Server Core has none at all);
# fail up front with instructions instead of a raw CommandNotFound mid-run.
if (-not (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
    Write-Host "Out-GridView is not available in this PowerShell. Run the script with Windows PowerShell (powershell.exe), or install the Microsoft.PowerShell.GraphicalTools module." -ForegroundColor Red
    Wait-IfElevatedWindow
    return
}

# Latency-critical classes kept when -ShowAll is NOT set. Matched by ClassGUID,
# not display name: names are localized and OEM-specific (a real xHCI controller
# can be named "(Intel(R),3.20,1.20)"), so keyword matching silently misses devices.
$IncludeClassGuids = @(
    '{4d36e968-e325-11ce-bfc1-08002be10318}',  # Display (GPU)
    '{4d36e972-e325-11ce-bfc1-08002be10318}',  # Net (NIC)
    '{4d36e96c-e325-11ce-bfc1-08002be10318}',  # Media (sound cards)
    '{36fc9e60-c465-11cf-8056-444553540000}'   # USB host controllers
)

$PolicyNames = @{
    0 = 'MachineDefault'
    1 = 'AllCloseProcessors'
    2 = 'OneCloseProcessor'
    3 = 'AllProcessors'
    4 = 'SpecifiedProcessors'
    5 = 'SpreadMessages'
    6 = 'Steered (system)'
}

function Get-DeviceName {
    param([Microsoft.Win32.RegistryKey]$Key)
    $fn = $Key.GetValue('FriendlyName')
    if ([string]::IsNullOrWhiteSpace($fn)) { $fn = $Key.GetValue('DeviceDesc') }
    if ($fn -and $fn -match ';') {
        # Strip the @res;Text prefix; keep the raw string if nothing follows ';'
        # (a malformed indirect string) so the device stays visible.
        $text = $fn.Split(';')[-1]
        if (-not [string]::IsNullOrWhiteSpace($text)) { $fn = $text }
    }
    return $fn
}

# Logical processors with their efficiency class (P/E on hybrid CPUs) and
# physical core, via GetSystemCpuSetInformation - the documented source of
# EfficiencyClass; WMI has no per-core equivalent.
function Get-CpuTopology {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CpuSets {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetSystemCpuSetInformation(
        IntPtr information, uint bufferLength, out uint returnedLength, IntPtr process, uint flags);
}
'@
    $len = [uint32]0
    [void][CpuSets]::GetSystemCpuSetInformation([IntPtr]::Zero, 0, [ref]$len, [IntPtr]::Zero, 0)
    if ($len -eq 0) { throw "GetSystemCpuSetInformation returned no data" }
    $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal([int]$len)
    try {
        if (-not [CpuSets]::GetSystemCpuSetInformation($buf, $len, [ref]$len, [IntPtr]::Zero, 0)) {
            throw "GetSystemCpuSetInformation failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
        $bytes = New-Object byte[] $len
        [Runtime.InteropServices.Marshal]::Copy($buf, $bytes, 0, [int]$len)
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
    }
    # SYSTEM_CPU_SET_INFORMATION (x64): Size u32 @0, Type u32 @4, Group u16 @12,
    # LogicalProcessorIndex u8 @14, CoreIndex u8 @15, EfficiencyClass u8 @18
    $cpus = New-Object System.Collections.Generic.List[object]
    $pos = 0
    while ($pos -lt $bytes.Length) {
        $size = [BitConverter]::ToUInt32($bytes, $pos)
        if ($size -eq 0) { break }
        if ([BitConverter]::ToUInt32($bytes, $pos + 4) -eq 0) {   # CpuSetInformation
            $cpus.Add([PSCustomObject]@{
                CPU      = [int]$bytes[$pos + 14]
                Core     = [int]$bytes[$pos + 15]
                Group    = [BitConverter]::ToUInt16($bytes, $pos + 12)
                EffClass = [int]$bytes[$pos + 18]
            })
        }
        $pos += $size
    }
    return $cpus
}

# "0-3,16,18" from a KAFFINITY mask, for the Cores column.
function ConvertTo-CoreList {
    param([uint64]$Mask)
    $set = 0..63 | Where-Object { ($Mask -shr $_) -band 1 }
    if (-not $set) { return '-' }
    $ranges = New-Object System.Collections.Generic.List[string]
    $start = $prev = $set[0]
    foreach ($i in ($set | Select-Object -Skip 1)) {
        if ($i -ne $prev + 1) {
            $ranges.Add($(if ($start -eq $prev) { "$start" } else { "$start-$prev" }))
            $start = $i
        }
        $prev = $i
    }
    $ranges.Add($(if ($start -eq $prev) { "$start" } else { "$start-$prev" }))
    return $ranges -join ','
}

# AssignmentSetOverride may be REG_BINARY (little endian), REG_DWORD or
# REG_QWORD - all documented; normalize to a uint64 mask.
function ConvertTo-Mask {
    param($Value)
    if ($Value -is [byte[]]) {
        $padded = New-Object byte[] 8
        [Array]::Copy($Value, $padded, [Math]::Min($Value.Length, 8))
        return [BitConverter]::ToUInt64($padded, 0)
    }
    if ($Value -is [int])  { return [BitConverter]::ToUInt32([BitConverter]::GetBytes($Value), 0) }
    if ($Value -is [long]) { return [BitConverter]::ToUInt64([BitConverter]::GetBytes($Value), 0) }
    return [uint64]0
}

# One .reg line restoring a value in its ORIGINAL registry type, or deleting
# it if it was absent - so undo round-trips values written by other tools too.
function Get-UndoLine {
    param([Microsoft.Win32.RegistryKey]$Key, [string]$Name)
    if ($null -eq $Key -or $Name -notin $Key.GetValueNames()) { return "`"$Name`"=-" }
    $raw = $Key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
    switch ($Key.GetValueKind($Name)) {
        'DWord'  { return ('"{0}"=dword:{1:x8}' -f $Name,
                   [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$raw), 0)) }
        'QWord'  { return ('"{0}"=hex(b):{1}' -f $Name,
                   (([BitConverter]::GetBytes([long]$raw) | ForEach-Object { '{0:x2}' -f $_ }) -join ',')) }
        'Binary' { return ('"{0}"=hex:{1}' -f $Name,
                   (($raw | ForEach-Object { '{0:x2}' -f $_ }) -join ',')) }
        # Any other type here is broken config; deleting it restores the default.
        default  { return "`"$Name`"=-" }
    }
}

Write-Host "Scanning PCI devices..." -ForegroundColor Cyan
$pciRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'
$rows = New-Object System.Collections.Generic.List[object]

$hidden = 0
foreach ($devClass in Get-ChildItem $pciRoot -ErrorAction SilentlyContinue) {
    foreach ($inst in Get-ChildItem $devClass.PSPath -ErrorAction SilentlyContinue) {
        $name = Get-DeviceName -Key $inst
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        # Interrupt-capable devices expose "Device Parameters\Interrupt Management".
        $imPath = Join-Path $inst.PSPath 'Device Parameters\Interrupt Management'
        if (-not (Test-Path $imPath)) { continue }

        if (-not $ShowAll) {
            # HD Audio controllers register under the System class, not Media;
            # their locale-invariant marker is the HDAudBus service.
            $classGuid = $inst.GetValue('ClassGUID')
            if ($classGuid -notin $IncludeClassGuids -and
                $inst.GetValue('Service') -ne 'HDAudBus') { $hidden++; continue }
        }

        # Absent key/values = no override: the OS picks the processors.
        $apPath = Join-Path $imPath 'Affinity Policy'
        $policy = 'Default'; $cores = '-'
        if (Test-Path $apPath) {
            $apKey = Get-Item $apPath
            $dp = $apKey.GetValue('DevicePolicy')
            if ($null -ne $dp) {
                $policy = $PolicyNames[[int]$dp]
                if (-not $policy) { $policy = "Unknown ($dp)" }
            }
            $aso = $apKey.GetValue('AssignmentSetOverride')
            if ($null -ne $aso) { $cores = ConvertTo-CoreList -Mask (ConvertTo-Mask $aso) }
        }

        $rows.Add([PSCustomObject]@{
            Name     = $name
            Policy   = $policy
            Cores    = $cores
            DeviceID = $inst.PSChildName
            RegPath  = $apPath   # target key we will write
        })
    }
}

if ($rows.Count -eq 0) {
    Write-Host "No matching devices found. Try -ShowAll." -ForegroundColor Yellow
    Wait-IfElevatedWindow
    return
}
if ($hidden) {
    Write-Host "$hidden more device(s) (storage controllers, bridges, ...) are hidden by the default filter. Use -ShowAll to include them." -ForegroundColor DarkGray
}

if ($Reset) { $title = 'Select devices to RESET interrupt affinity to machine default' }
else        { $title = 'Select devices whose interrupts to pin' }
$selected = $rows |
    Sort-Object Policy, Name |
    Out-GridView -Title "$title (Ctrl-click for multiple)" -PassThru

if (-not $selected) {
    Write-Host "No devices selected. No changes made." -ForegroundColor Yellow
    Wait-IfElevatedWindow
    return
}

$mask = [uint64]0
if (-not $Reset) {
    $cpus = Get-CpuTopology
    $extra = @($cpus | Where-Object { $_.Group -ne 0 -or $_.CPU -gt 63 })
    if ($extra) {
        # KAFFINITY covers 64 processors of group 0; beyond that needs group-aware
        # tools (this machine class is server hardware, not the target here).
        Write-Host "$($extra.Count) processor(s) beyond CPU 63 / group 0 cannot be targeted and are not listed." -ForegroundColor Yellow
        $cpus = @($cpus | Where-Object { $_.Group -eq 0 -and $_.CPU -le 63 })
    }
    # Higher efficiency class = performance core (Intel hybrid: P=1, E=0).
    $maxClass = ($cpus | Measure-Object EffClass -Maximum).Maximum
    $smtCores = $cpus | Group-Object Core | Where-Object Count -gt 1 | ForEach-Object { $_.Name }
    $coreRows = foreach ($c in $cpus) {
        [PSCustomObject]@{
            CPU          = $c.CPU
            Type         = if ($maxClass -eq 0) { 'Core' }
                           elseif ($c.EffClass -eq $maxClass) { 'P-Core' } else { 'E-Core' }
            PhysicalCore = $c.Core   # two CPUs sharing one PhysicalCore = SMT/HT pair
        }
    }
    if (-not $smtCores) { $coreRows = $coreRows | Select-Object CPU, Type }

    $picked = $coreRows | Sort-Object CPU |
        Out-GridView -Title "Select CPU core(s) to handle interrupts of $(@($selected).Count) device(s)" -PassThru
    if (-not $picked) {
        Write-Host "No cores selected. No changes made." -ForegroundColor Yellow
        Wait-IfElevatedWindow
        return
    }
    foreach ($c in $picked) { $mask = $mask -bor ([uint64]1 -shl $c.CPU) }
    Write-Host ("Target cores: {0} (mask 0x{1:X})" -f (ConvertTo-CoreList -Mask $mask), $mask) -ForegroundColor Cyan
}

# Lightweight rollback: record the CURRENT state of every selected key into a
# .reg file BEFORE changing anything. Double-clicking it reverts everything.
# Undo is value-level on purpose: a "[-key]" stanza would also wipe values the
# tool never wrote (e.g. DevicePriority set by a driver or another tweak);
# deleting the values may leave an empty key behind, which is harmless.
# The suffix loop keeps two runs within the same second from clobbering
# each other's undo file.
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$undoFile = Join-Path $PSScriptRoot "affinity_undo_$stamp.reg"
$n = 1
while (Test-Path $undoFile) { $undoFile = Join-Path $PSScriptRoot ("affinity_undo_{0}_{1}.reg" -f $stamp, $n++) }
$undo = New-Object System.Text.StringBuilder
[void]$undo.AppendLine('Windows Registry Editor Version 5.00')
[void]$undo.AppendLine('')
foreach ($d in $selected) {
    # Provider path -> raw path for the .reg format
    $raw = $d.RegPath -replace '^.*Registry::', ''
    $apKey = if (Test-Path $d.RegPath) { Get-Item $d.RegPath } else { $null }
    [void]$undo.AppendLine("[$raw]")
    [void]$undo.AppendLine((Get-UndoLine -Key $apKey -Name 'DevicePolicy'))
    [void]$undo.AppendLine((Get-UndoLine -Key $apKey -Name 'AssignmentSetOverride'))
    [void]$undo.AppendLine('')
}
Set-Content -Path $undoFile -Value $undo.ToString() -Encoding Unicode
Write-Host "Undo file saved: $undoFile (double-click it to revert, then restart the device or reboot)" -ForegroundColor Cyan

$updated = 0
$failed  = 0
foreach ($d in $selected) {
    try {
        if ($Reset) {
            if (Test-Path $d.RegPath) {
                Remove-ItemProperty -Path $d.RegPath -Name 'DevicePolicy' -ErrorAction SilentlyContinue
                Remove-ItemProperty -Path $d.RegPath -Name 'AssignmentSetOverride' -ErrorAction SilentlyContinue
            }
            Write-Host ("  [RESET] {0}" -f $d.Name) -ForegroundColor Green
        } else {
            if (-not (Test-Path $d.RegPath)) {
                New-Item -Path $d.RegPath -Force | Out-Null      # create subkey if absent
            }
            # DevicePolicy 4 = IrqPolicySpecifiedProcessors; the mask is only
            # honored with this policy. REG_BINARY little endian, as documented.
            New-ItemProperty -Path $d.RegPath -Name 'DevicePolicy' `
                -Value 4 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path $d.RegPath -Name 'AssignmentSetOverride' `
                -Value ([BitConverter]::GetBytes($mask)) -PropertyType Binary -Force | Out-Null
            Write-Host ("  [PIN {0}] {1}" -f (ConvertTo-CoreList -Mask $mask), $d.Name) -ForegroundColor Green
        }
        $updated++
    } catch {
        Write-Host ("  [ERR] {0}: {1}" -f $d.Name, $_) -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "Done. $updated of $(@($selected).Count) device(s) updated." -ForegroundColor Green
if ($failed) {
    # The undo file lists the failed devices too; reverting an unchanged value is a no-op.
    Write-Host "$failed device(s) failed - see errors above." -ForegroundColor Yellow
}
Write-Host "Restart the device (disable/enable in Device Manager) or REBOOT for changes to take effect." -ForegroundColor Green
Wait-IfElevatedWindow
