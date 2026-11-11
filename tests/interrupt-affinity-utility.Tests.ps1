BeforeDiscovery {
    $script:isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    $script:scriptPath = Join-Path $PSScriptRoot '..\interrupt-affinity-utility.ps1'
    $script:scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

    function Find-ScriptNode([scriptblock]$Predicate) {
        $scriptAst.Find($Predicate, $true)
    }

    function Get-ShippedFunctionText {
        param([string[]]$Name)
        $all = @($scriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
        $found = @($all | Where-Object { $_.Name -in $Name })
        if ($found.Count -ne $Name.Count) { throw "interrupt-affinity-utility.ps1 does not define all of: $($Name -join ', ')" }
        ($found | ForEach-Object { $_.Extent.Text }) -join "`n"
    }
}

Describe 'PSScriptInfo version placeholder' {
    It 'is exactly .VERSION 0.0.0, the line release.yml stamps' {
        $lines = @(Select-String -LiteralPath $scriptPath -Pattern '^\.VERSION\b' | ForEach-Object Line)
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly '.VERSION 0.0.0'
    }
}

Describe 'the irm | iex rerun forwards the mode switches to powershell.exe -File' {
    BeforeAll {
        $script:rerunStub = Join-Path $TestDrive 'rerun-stub.ps1'
        Set-Content -LiteralPath $rerunStub -Value 'param([switch]$ShowAll, [switch]$Reset, [switch]$Status) "ShowAll=$ShowAll Reset=$Reset Status=$Status"' -Encoding Ascii
    }

    It 'binds <Label> in the rerun when it is the only forwarded switch' -ForEach @(
        @{ Label = 'no switch'; ShowAll = $false; Reset = $false; Status = $false; Expected = 'ShowAll=False Reset=False Status=False' }
        @{ Label = '-ShowAll'; ShowAll = $true; Reset = $false; Status = $false; Expected = 'ShowAll=True Reset=False Status=False' }
        @{ Label = '-Reset'; ShowAll = $false; Reset = $true; Status = $false; Expected = 'ShowAll=False Reset=True Status=False' }
        @{ Label = '-Status'; ShowAll = $false; Reset = $false; Status = $true; Expected = 'ShowAll=False Reset=False Status=True' }
    ) {
        $forwarder = Find-ScriptNode { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-ForwardedSwitchList' }
        $bootstrap = Find-ScriptNode { param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '-not $PSCommandPath' }
        $rerun = @($bootstrap.Clauses[0].Item2.Statements | Where-Object { $_.Extent.Text -match '^(\$fwd\s*=|powershell\s)' })
        $rerun.Count | Should -Be 2
        $code = @('param($ShowAll, $Reset, $Status, $saved)', $forwarder.Extent.Text) + @($rerun | ForEach-Object { $_.Extent.Text })
        & ([scriptblock]::Create($code -join "`n")) $ShowAll $Reset $Status $rerunStub | Should -Be $Expected
    }
}

Describe 'Get-ForwardedSwitchList' {
    It 'forwards exactly the documented switches and never -Elevated' {
        $help = $scriptAst.GetHelpContent()
        $help | Should -Not -BeNullOrEmpty -Because 'GetHelpContent found no comment-based help block'
        $switches = @($scriptAst.ParamBlock.Parameters | Where-Object { $_.StaticType -eq [System.Management.Automation.SwitchParameter] } | ForEach-Object { $_.Name.VariablePath.UserPath })
        $switches | Should -Contain 'Elevated'
        $expected = @($switches | Where-Object { @($help.Parameters.Keys) -contains $_ } | ForEach-Object { "-$_" })
        $expected.Count | Should -BeGreaterThan 0
        $expected | Should -Not -Contain '-Elevated'
        $actual = @(& {
            param($fnText, $names)
            foreach ($n in $names) { Set-Variable -Name $n -Value $true }
            . ([scriptblock]::Create($fnText))
            Get-ForwardedSwitchList
        } (Get-ShippedFunctionText 'Get-ForwardedSwitchList') $switches)
        ($actual | Sort-Object) -join ',' | Should -BeExactly (($expected | Sort-Object) -join ',')
    }
}

Describe 'ConvertTo-CoreList' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ShippedFunctionText 'ConvertTo-CoreList')))
    }

    It 'turns mask <Label> into <Expected>' -ForEach @(
        @{ Label = '0'; Mask = 0; Expected = '-' }
        @{ Label = '1'; Mask = 1; Expected = '0' }
        @{ Label = '0xF'; Mask = 0xF; Expected = '0-3' }
        @{ Label = '0x5000F'; Mask = 0x5000F; Expected = '0-3,16,18' }
        @{ Label = 'UInt64 max'; Mask = [uint64]::MaxValue; Expected = '0-63' }
    ) {
        ConvertTo-CoreList -Mask $Mask | Should -BeExactly $Expected
    }
}

Describe 'ConvertTo-Mask' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ShippedFunctionText 'ConvertTo-Mask')))
    }

    It 'reads <Label> as <Expected>' -ForEach @(
        @{ Label = 'REG_BINARY 0f,00'; Value = [byte[]](0x0f, 0); Expected = [uint64]15 }
        @{ Label = 'a 9-byte REG_BINARY, keeping the first 8 bytes'; Value = [byte[]](1, 0, 0, 0, 0, 0, 0, 0, 255); Expected = [uint64]1 }
        @{ Label = 'REG_DWORD -1'; Value = [int]-1; Expected = [uint64]4294967295 }
        @{ Label = 'REG_QWORD -1'; Value = [long]-1; Expected = [uint64]::MaxValue }
    ) {
        ConvertTo-Mask -Value $Value | Should -Be $Expected
    }

    It 'returns $null for a value type it cannot read' {
        ConvertTo-Mask -Value '0f' | Should -BeNullOrEmpty
    }
}

Describe 'Get-UndoLine' {
    BeforeAll {
        . ([scriptblock]::Create((Get-ShippedFunctionText 'ConvertTo-HexPairs', 'Get-UndoLine')))

        function New-TestKey {
            param([string]$Type, $Value)
            $path = "TestRegistry:\undo_$([guid]::NewGuid().ToString('N'))"
            $null = New-Item -Path $path -Force
            if ($Type) { $null = New-ItemProperty -Path $path -Name 'N' -Value $Value -PropertyType $Type }
            Get-Item -Path $path
        }
    }

    It 'writes a <Type> value of <Label> back in its own registry type' -ForEach @(
        @{ Type = 'DWord'; Label = '4'; Value = 4; Expected = '"N"=dword:00000004' }
        @{ Type = 'DWord'; Label = '-1'; Value = -1; Expected = '"N"=dword:ffffffff' }
        @{ Type = 'QWord'; Label = '48'; Value = 48; Expected = '"N"=hex(b):30,00,00,00,00,00,00,00' }
        @{ Type = 'Binary'; Label = '0f,00'; Value = [byte[]](0x0f, 0); Expected = '"N"=hex:0f,00' }
        @{ Type = 'String'; Label = 'a\b"c'; Value = 'a\b"c'; Expected = '"N"="a\\b\"c"' }
        @{ Type = 'ExpandString'; Label = '%OS%, unexpanded'; Value = '%OS%'; Expected = '"N"=hex(2):25,00,4f,00,53,00,25,00,00,00' }
        @{ Type = 'MultiString'; Label = 'a,b'; Value = @('a', 'b'); Expected = '"N"=hex(7):61,00,00,00,62,00,00,00,00,00' }
    ) {
        $key = New-TestKey -Type $Type -Value $Value
        Get-UndoLine -Key $key -Name 'N' | Should -BeExactly $Expected
    }

    It 'deletes the value on undo when the name is absent from the key' {
        $key = New-TestKey
        Get-UndoLine -Key $key -Name 'N' | Should -BeExactly '"N"=-'
    }

    It 'deletes the value on undo when there is no key' {
        Get-UndoLine -Key $null -Name 'N' | Should -BeExactly '"N"=-'
    }
}

Describe 'whole-script runs with every device, registry and grid command mocked' {
    BeforeAll {
        $script:copy = Join-Path $TestDrive 'interrupt-affinity-utility.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $copy
        Mock Get-CimInstance { 'mock reached' } -ParameterFilter { $ClassName -eq 'Win32_PesterMockProbe' }
        $probe = Join-Path $TestDrive 'mock-probe.ps1'
        Set-Content -LiteralPath $probe -Value 'Get-CimInstance Win32_PesterMockProbe -ErrorAction SilentlyContinue' -Encoding Ascii
        $probeResult = $null
        try { $probeResult = & $probe } catch { $probeResult = $null }
        if ($probeResult -ne 'mock reached') {
            throw 'Pester mocks do not reach a script run with &: the whole-script tests would touch this machine'
        }
    }

    BeforeEach {
        Mock Out-GridView { }
        Mock Read-Host { }
        Mock Start-Process { }
        Mock New-Item { }
        Mock New-ItemProperty { }
        Mock Set-ItemProperty { }
        Mock Remove-ItemProperty { }
        Mock Start-Sleep { }
        Mock Write-Host { if ("$Object" -like 'ERROR:*') { "$Object" } }
    }

    It 'stops before the device scan on Windows Server Core' -Skip:(-not $isAdmin) {
        Mock Get-ItemProperty { [pscustomobject]@{ ServerCore = 1 } } -ParameterFilter { "$Path$LiteralPath" -like '*\Windows NT\CurrentVersion\Server\ServerLevels' }
        Mock Get-PnpDevice { }
        $output = & $copy
        ($output | Where-Object { "$_" -like 'ERROR:*' }) -join "`n" | Should -BeNullOrEmpty -Because 'the run must not end in the trap'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'Out-GridView is not available*' }
        Should -Invoke Get-PnpDevice -Times 0 -Exactly
    }

    It 'does not tell the user to restart when every registry write failed' -Skip:(-not $isAdmin) {
        Mock Get-PnpDevice { [pscustomobject]@{ InstanceId = 'PCI\VEN_FAKE&DEV_FAKE\0'; FriendlyName = 'Fake NIC'; ClassGuid = '{4d36e972-e325-11ce-bfc1-08002be10318}'; Service = 'fakenic' } }
        Mock Test-Path { $true } -ParameterFilter { "$Path$LiteralPath" -like '*\Interrupt Management' }
        Mock Out-GridView { [pscustomobject]@{ Name = 'Fake NIC'; Policy = 'Default'; Cores = '-'; DeviceID = 'PCI\VEN_FAKE&DEV_FAKE\0'; RegPath = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Enum\PCI\VEN_FAKE&DEV_FAKE\0\Device Parameters\Interrupt Management\Affinity Policy' } } -ParameterFilter { $Title -like 'Select devices*' }
        Mock Out-GridView { [pscustomobject]@{ CPU = 0; Type = 'Core' } } -ParameterFilter { $Title -like 'Select CPU core*' }
        Mock New-Item { throw 'registry write denied' }
        $output = & $copy
        ($output | Where-Object { "$_" -like 'ERROR:*' }) -join "`n" | Should -BeNullOrEmpty -Because 'the run must not end in the trap'
        Should -Invoke New-Item -Times 1 -Exactly
        Should -Invoke New-ItemProperty -Times 0 -Exactly
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { "$Object" -like 'Done. 0 of 1*' }
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { "$Object" -like 'Restart the device*' }
    }
}
