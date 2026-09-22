# Deploy-SCCM.ps1  -  thin DSC bootstrap for the SCCM primary-site install.
#
# The heavy install logic lives in Install-SCCM.ps1 (a plain script), which this SetScript
# downloads and runs with powershell.exe. The complex logic was ORIGINALLY inline in this
# SetScript, but WMF 5.1's DSC compiler mis-parses a large inline SetScript (a cascade of
# "Unexpected token" errors at compile time, though the same script parses clean as ordinary
# PowerShell). Keeping the SetScript trivial avoids that entirely and lets the installer be
# run/iterated by hand on SRV01.
#
# Runs as DOAZLAB\DOAdmin (PsDscRunAsCredential) so the child powershell.exe inherits the
# rights the schema extension / container ACL / SQL / ConfigMgr setup need.

configuration Deploy-SCCM {
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainFQDN,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds
    )
    Import-DscResource -ModuleName xPSDesiredStateConfiguration, ComputerManagementDsc

    [String] $DomainNetbiosName = (Get-NetBIOSName -DomainFQDN $DomainFQDN)
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($AdminCreds.UserName)", $AdminCreds.Password)

    Node localhost
    {
        LocalConfigurationManager
        {
            ConfigurationMode  = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }

        xScript InstallSCCM
        {
            PsDscRunAsCredential = $DomainCreds
            SetScript = {
                $ErrorActionPreference = 'Stop'
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                New-Item -ItemType Directory -Force -Path 'C:\SCCMLab' | Out-Null
                $installUrl = 'https://raw.githubusercontent.com/DefensiveOrigins/DO-LAB-DEV/sccm-sccmhunter/Deploy-AD/DesiredSateConfig/Install-SCCM.ps1'
                $installPs1 = 'C:\SCCMLab\Install-SCCM.ps1'
                Invoke-WebRequest -Uri $installUrl -OutFile $installPs1 -UseBasicParsing
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installPs1
                if ($LASTEXITCODE -ne 0) { throw "Install-SCCM.ps1 exited with code $LASTEXITCODE" }
            }
            GetScript  = { return @{ "Result" = "false" } }
            TestScript = { return $false }
        }

        PendingReboot RebootAfterSCCM
        {
            Name      = 'RebootAfterSCCM'
            DependsOn = "[xScript]InstallSCCM"
        }
    }
}

function Get-NetBIOSName {
    [OutputType([string])]
    param(
        [string]$DomainFQDN
    )

    if ($DomainFQDN.Contains('.')) {
        $length = $DomainFQDN.IndexOf('.')
        if ( $length -ge 16) {
            $length = 15
        }
        return $DomainFQDN.Substring(0, $length)
    }
    else {
        if ($DomainFQDN.Length -gt 15) {
            return $DomainFQDN.Substring(0, 15)
        }
        else {
            return $DomainFQDN
        }
    }
}
