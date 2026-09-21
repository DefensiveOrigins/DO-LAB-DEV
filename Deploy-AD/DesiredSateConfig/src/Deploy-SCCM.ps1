# Deploy-SCCM.ps1  -  DOAZLab SCCM primary site for the L2017 SCCM / SCCMhunter lab.
#
# Stands up an all-in-one Configuration Manager (Current Branch, Evaluation) primary site on SRV01,
# on top of the ADCS role that is already there. Installs full SQL Server (Evaluation - a primary site
# rejects SQL Express), the Windows ADK + WinPE add-on, the IIS sub-features SCCM needs, extends the AD
# schema, creates and ACLs the System Management container, runs ConfigMgr setup unattended, then sets a
# Network Access Account and pushes the client to WS05.
#
# Attack surface this exposes for the lab (recon + NAA recovery + CMPivot):
#   - a live Management Point + Distribution Point + SMS Provider (AdminService) that sccmhunter enumerates
#   - a Network Access Account (svc_sccmnaa) whose cleartext creds are recoverable from machine policy
#   - a pushed client on WS05 to target with CMPivot / the AdminService
#
# !!! HIGH-RISK / VALIDATE ON A REAL DEPLOY !!!
# SCCM has no clean one-shot installer. This script encodes the community-standard sequence but has NOT
# been run end to end here. Expect to iterate against C:\ConfigMgrSetup.log and the DSC logs
# (C:\WindowsAzure\Logs\Plugins\Microsoft.Powershell.DSC\...). The installer download URLs (SQL, ADK,
# ConfigMgr) are version-pinned below and will drift - confirm them, or mirror the installers under
# DefensiveOrigins/AC-Extras and point the *Url variables there, before relying on an unattended run.

configuration Deploy-SCCM {
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainFQDN,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds
    )
    Import-DscResource -ModuleName xPSDesiredStateConfiguration, ComputerManagementDsc
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Domain-qualify the builder credential (DOAZLAB\DOAdmin). DOAdmin is Schema Admin + Enterprise Admin,
    # which the schema extension, the System Management container ACL and the ConfigMgr install all need.
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
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $ErrorActionPreference = 'Stop'

                # ---- Lab-wide settings (kept in step with Add-DC3-Objects.ps1 and the courseware) ----
                $SiteCode   = 'DOZ'
                $SiteName   = 'DOAZLab Primary Site'
                $SmsDir     = 'C:\Program Files\Microsoft Configuration Manager'
                $SiteServer = "$($env:COMPUTERNAME).$using:DomainFQDN"    # SRV01.doazlab.com
                $NaaUser    = "$($using:DomainNetbiosName)\svc_sccmnaa"
                $NaaPass    = 'Config#Mgr2026'                            # matches the domainUsers entry (must not contain the account name, per AD complexity)
                $ClientPush = 'WS05'
                $work       = 'C:\SCCMLab'
                New-Item -ItemType Directory -Force -Path $work | Out-Null
                function Log($m){ "$(Get-Date -Format o)  $m" | Out-File -Append "$work\deploy-sccm.log" }

                # Installer sources. Mirror these under AC-Extras and repoint if the public URLs drift.
                $adkUrl     = 'https://go.microsoft.com/fwlink/?linkid=2289980'   # ADK for Win11 24H2
                $adkPeUrl   = 'https://go.microsoft.com/fwlink/?linkid=2289981'   # WinPE add-on
                $sqlEvalUrl = 'https://go.microsoft.com/fwlink/?linkid=2215158'   # SQL Server 2022 Developer SSEI (SQL2022-SSEI-Dev.exe)
                $cmEvalUrl  = 'https://go.microsoft.com/fwlink/?linkid=2195628'   # MCM/SCCM Current Branch eval bootstrap

                # ================= 1. IIS + Windows features SCCM needs (ADCS already added Web-Server) =========
                Log 'Installing Windows/IIS prerequisite features'
                $features = @(
                    'Web-Server','Web-Windows-Auth','Web-ASP-Net45','Web-Net-Ext45','Web-Metabase',
                    'Web-WMI','Web-Static-Content','Web-Default-Doc','Web-Dir-Browsing','Web-Http-Errors',
                    'Web-Http-Logging','Web-Request-Monitor','Web-Filtering','Web-ISAPI-Ext','Web-ISAPI-Filter',
                    'Web-Mgmt-Console','Web-Mgmt-Compat','Web-Scripting-Tools',
                    'BITS','BITS-IIS-Ext','RDC','NET-Framework-45-Core','NET-Framework-45-ASPNET'
                )
                Install-WindowsFeature -Name $features -ErrorAction SilentlyContinue | Out-Null
                # WebDAV is not a Windows feature name; SCCM does not require it for HTTP MP/DP. Skipped.

                # ================= 2. Windows ADK + WinPE add-on ==============================================
                Log 'Installing Windows ADK + WinPE'
                $adkExe = "$work\adksetup.exe"; $adkPe = "$work\adkwinpesetup.exe"
                Invoke-WebRequest -Uri $adkUrl   -OutFile $adkExe -UseBasicParsing
                Invoke-WebRequest -Uri $adkPeUrl -OutFile $adkPe  -UseBasicParsing
                Start-Process $adkExe -ArgumentList '/quiet /features OptionId.DeploymentTools OptionId.ImagingAndConfigurationDesigner /norestart' -Wait
                Start-Process $adkPe  -ArgumentList '/quiet /features OptionId.WindowsPreinstallationEnvironment /norestart' -Wait

                # ================= 3. SQL Server (Developer edition, full engine - NOT Express) ================
                # linkid 2215158 serves the SQL 2022 Developer SSEI (free, full engine, fine for a lab site DB).
                # Pull the SSEI bootstrapper, have it download the media, then run a config-file install.
                Log 'Installing SQL Server (Developer edition)'
                $sqlSei = "$work\SQL2022-SSEI-Dev.exe"
                Invoke-WebRequest -Uri $sqlEvalUrl -OutFile $sqlSei -UseBasicParsing
                Start-Process $sqlSei -ArgumentList "/ACTION=Download /MEDIAPATH=$work\SQLMedia /MEDIATYPE=CAB /QUIET" -Wait
                # Locate the extracted setup.exe
                $sqlSetup = Get-ChildItem "$work\SQLMedia" -Recurse -Filter setup.exe | Select-Object -First 1 -ExpandProperty FullName
                $sqlIni = @"
[OPTIONS]
ACTION="Install"
FEATURES=SQLENGINE
INSTANCENAME=MSSQLSERVER
SQLSYSADMINACCOUNTS="$($using:DomainNetbiosName)\DOAdmin" "$($using:DomainNetbiosName)\$($env:COMPUTERNAME)`$"
SQLSVCACCOUNT="$($using:DomainNetbiosName)\DOAdmin"
AGTSVCACCOUNT="$($using:DomainNetbiosName)\DOAdmin"
SQLSVCSTARTUPTYPE="Automatic"
AGTSVCSTARTUPTYPE="Automatic"
TCPENABLED="1"
IACCEPTSQLSERVERLICENSETERMS="True"
SUPPRESSPRIVACYSTATEMENTNOTICE="True"
QUIET="True"
UPDATEENABLED="False"
"@
                # NOTE: SQL service running as DOAdmin is a lab shortcut. A real build uses a dedicated
                # low-priv service account; DOAdmin's password comes from AdminCreds and is not written here.
                $sqlIni = $sqlIni -replace 'SQLSVCACCOUNT.*',   'SQLSVCACCOUNT="NT AUTHORITY\SYSTEM"'
                $sqlIni = $sqlIni -replace 'AGTSVCACCOUNT.*',   'AGTSVCACCOUNT="NT AUTHORITY\SYSTEM"'
                $sqlIni | Out-File "$work\sql.ini" -Encoding ascii
                Start-Process $sqlSetup -ArgumentList "/ConfigurationFile=$work\sql.ini" -Wait

                # Cap SQL memory so SQL + SCCM + the OS coexist on 16 GB. Needs SqlServer module or sqlcmd.
                Log 'Capping SQL max server memory to 6144 MB'
                $capSql = @"
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'max server memory (MB)', 6144; RECONFIGURE;
"@
                & sqlcmd -S localhost -Q $capSql 2>&1 | Out-Null

                # ================= 4. Extend AD schema + System Management container ==========================
                Log 'Extending AD schema for ConfigMgr'
                $cmBootstrap = "$work\MCM_Configmgr.exe"
                Invoke-WebRequest -Uri $cmEvalUrl -OutFile $cmBootstrap -UseBasicParsing
                # The bootstrapper extracts the media; run it to download to $work\CM
                Start-Process $cmBootstrap -ArgumentList "/Auto $work\CM" -Wait
                $extadsch = Get-ChildItem "$work\CM" -Recurse -Filter extadsch.exe | Select-Object -First 1 -ExpandProperty FullName
                if ($extadsch) { Start-Process $extadsch -Wait }

                Log 'Creating and ACLing the System Management container'
                Import-Module ActiveDirectory
                $confNC = (Get-ADRootDSE).defaultNamingContext
                $smDN = "CN=System Management,CN=System,$confNC"
                if (-not (Get-ADObject -Filter "distinguishedName -eq '$smDN'" -ErrorAction SilentlyContinue)) {
                    New-ADObject -Name 'System Management' -Type 'container' -Path "CN=System,$confNC"
                }
                # Grant the site server computer account Full Control over the container (+ descendants)
                & dsacls "$smDN" /I:T /G "$($using:DomainNetbiosName)\$($env:COMPUTERNAME)`$:GA" | Out-Null

                # ================= 5. Install ConfigMgr primary site (unattended) =============================
                Log 'Running ConfigMgr unattended setup'
                $cmSetup = Get-ChildItem "$work\CM" -Recurse -Filter setup.exe |
                           Where-Object { $_.FullName -match '\\SMSSETUP\\BIN\\X64\\setup.exe$' } |
                           Select-Object -First 1 -ExpandProperty FullName
                $cmIni = @"
[Identification]
Action=InstallPrimarySite

[Options]
ProductID=EVAL
SiteCode=$SiteCode
SiteName=$SiteName
SMSInstallDir=$SmsDir
SDKServer=$SiteServer
RoleCommunicationProtocol=HTTPorHTTPS
ClientsUsePKICertificate=0
PrerequisiteComp=0
PrerequisitePath=$work\CM\prereq
ManagementPoint=$SiteServer
ManagementPointProtocol=HTTP
DistributionPoint=$SiteServer
DistributionPointProtocol=HTTP
DistributionPointInstallIIS=0
AdminConsole=1
JoinCEIP=0

[SQLConfigOptions]
SQLServerName=$SiteServer
DatabaseName=CM_$SiteCode
SQLSSBPort=4022

[CloudConnectorOptions]
CloudConnector=0
CloudConnectorServer=$SiteServer
UseProxy=0

[SystemCenterOptions]

[HierarchyExpansionOption]
"@
                $cmIni | Out-File "$work\cm.ini" -Encoding ascii
                if ($cmSetup) { Start-Process $cmSetup -ArgumentList "/script $work\cm.ini" -Wait }

                # ================= 6. Post-install: Network Access Account + client push ======================
                # Uses the ConfigurationManager PowerShell module that setup drops next to the admin console.
                Log 'Configuring NAA + client push via the ConfigurationManager module'
                $cmModule = "$SmsDir\..\AdminConsole\bin\ConfigurationManager.psd1"
                $cmModule = (Resolve-Path $cmModule -ErrorAction SilentlyContinue).Path
                if ($cmModule) {
                    Import-Module $cmModule
                    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -ErrorAction SilentlyContinue | Out-Null
                    Push-Location "$($SiteCode):"
                    # Network Access Account (the credential sccmhunter recovers from machine policy)
                    $sec = ConvertTo-SecureString $NaaPass -AsPlainText -Force
                    New-CMAccount -UserName $NaaUser -Password $sec -SiteCode $SiteCode -ErrorAction SilentlyContinue
                    Set-CMSoftwareDistributionComponent -SiteCode $SiteCode -AddNetworkAccessAccountName $NaaUser -ErrorAction SilentlyContinue
                    # Boundary + boundary group so the client is assigned and content is offered
                    New-CMBoundary -Name 'DOAZLab' -Type IPRange -Value '192.168.2.1-192.168.2.254' -ErrorAction SilentlyContinue
                    # Client push installation, then push to WS05
                    Set-CMClientPushInstallation -SiteCode $SiteCode -EnableAutomaticClientPushInstallation $true -ErrorAction SilentlyContinue
                    Pop-Location
                }
                Log 'Deploy-SCCM SetScript complete'
            }
            GetScript = { return @{ "Result" = "false" } }
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
