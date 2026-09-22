# Install-SCCM.ps1  -  DOAZLab SCCM primary-site installer (plain script).
# Invoked by the Deploy-SCCM DSC bootstrap (Deploy-SCCM.ps1 -> SetScript) which downloads
# and runs this file with powershell.exe. Kept OUT of the DSC scriptblock because WMF 5.1's
# DSC compiler mis-parses a complex inline SetScript. Runs as DOAZLAB\DOAdmin (the DSC
# PsDscRunAsCredential context). Fixed lab: domain doazlab.com / NetBIOS DOAZLab, site SRV01.
#
# !!! The SCCM install sequence is still being validated against a live deploy. Iterate here. !!!

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

# ---- Lab-wide settings (kept in step with Add-DC3-Objects.ps1 and the courseware) ----
$SiteCode   = 'DOZ'
$SiteName   = 'DOAZLab Primary Site'
$SmsDir     = 'C:\Program Files\Microsoft Configuration Manager'
$SiteServer = "$($env:COMPUTERNAME).doazlab.com"    # SRV01.doazlab.com
$NaaUser    = "DOAZLab\svc_sccmnaa"
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
SQLSYSADMINACCOUNTS="DOAZLab\DOAdmin" "DOAZLab\$($env:COMPUTERNAME)`$"
SQLSVCACCOUNT="DOAZLab\DOAdmin"
AGTSVCACCOUNT="DOAZLab\DOAdmin"
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
& dsacls "$smDN" /I:T /G "DOAZLab\$($env:COMPUTERNAME)`$:GA" | Out-Null

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
