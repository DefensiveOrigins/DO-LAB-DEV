# Install-SCCM.ps1  -  DOAZLab SCCM primary-site installer (plain script, idempotent, NO SSEI).
#
# Launched ASYNCHRONOUSLY by the Deploy-SCCM DSC bootstrap (Deploy-SCCM.ps1), which registers a
# scheduled task that runs this file as DOAZLAB\DOAdmin and returns immediately. A full SCCM build
# (SQL + ADK + ConfigMgr primary site) runs far longer than the Azure DSC extension's provisioning
# window, so it must NOT run inline in the DSC SetScript or ARM reports VMExtensionProvisioningTimeout.
#
# Media (deliberately NOT via the SSEI bootstrappers - as of 2026-09 the only SSEI builds Microsoft
# publishes are server-side deprecated and hard-stop with an invisible modal when run headless):
#   SQL 2022 Developer : official direct ISO on download.microsoft.com, mounted + setup /ConfigurationFile
#   ConfigMgr current  : WinRAR self-extractor from fwlink 2195628, extracted headless with -s2 -d
#
# The script is idempotent: every step checks whether it is already done and skips it, so the
# scheduled task can retry (e.g. after a reboot) without restarting from zero. On full success it
# drops a completion flag and unregisters its own scheduled task.
#
# Fixed lab: domain doazlab.com / NetBIOS DOAZLab, site server SRV01, site code DOZ.

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = 'Stop'

# ---- Lab-wide settings (kept in step with Add-DC3-Objects.ps1 and the courseware) ----
$SiteCode   = 'DOZ'
$SiteName   = 'DOAZLab Primary Site'
$SmsDir     = 'C:\Program Files\Microsoft Configuration Manager'
$SiteServer = "$($env:COMPUTERNAME).doazlab.com"    # SRV01.doazlab.com
$SiteAdmin  = 'DOAZLab\DOAdmin'                      # the account this task runs as (site Full Admin)
$MachineAcct= "DOAZLab\$($env:COMPUTERNAME)`$"       # DOAZLab\SRV01$
$NaaUser    = 'DOAZLab\svc_sccmnaa'
$NaaPass    = 'Config#Mgr2026'                       # matches the domainUsers entry (must not contain the account name, per AD complexity)
$work       = 'C:\SCCMLab'
$flag       = "$work\INSTALL-COMPLETE.flag"
New-Item -ItemType Directory -Force -Path $work | Out-Null
function Log($m){ $line = "$(Get-Date -Format o)  $m"; $line | Out-File -Append "$work\deploy-sccm.log"; Write-Host $line }

if (Test-Path $flag) { Log 'INSTALL-COMPLETE.flag present; nothing to do.'; return }
Log '===== Install-SCCM.ps1 starting ====='

# Installer sources. Mirror these under AC-Extras and repoint if the public URLs ever drift.
$isoUrl   = 'https://download.microsoft.com/download/3/8/d/38de7036-2433-4207-8eae-06e247e17b25/SQLServer2022-x64-ENU-Dev.iso'  # SQL 2022 Developer ISO (verified official, ~1.08 GB)
$cmUrl    = 'https://go.microsoft.com/fwlink/?linkid=2195628'   # ConfigMgr current-branch baseline media (WinRAR self-extractor, ~1.2 GB)
$adkUrl   = 'https://go.microsoft.com/fwlink/?linkid=2289980'   # ADK for Win11 24H2
$adkPeUrl = 'https://go.microsoft.com/fwlink/?linkid=2289981'   # WinPE add-on

function Get-File($url, $dest) {
    if (Test-Path $dest) { Log "already present: $dest"; return }
    Log "downloading $url -> $dest"
    Import-Module BitsTransfer -ErrorAction SilentlyContinue
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        Start-BitsTransfer -Source $url -Destination $dest
    } else {
        (New-Object System.Net.WebClient).DownloadFile($url, $dest)
    }
}

# ================= 1. IIS + Windows features SCCM needs (ADCS already added Web-Server) ========
if ((Get-WindowsFeature Web-Server).Installed -and (Get-WindowsFeature BITS).Installed) {
    Log 'Windows/IIS prerequisite features already installed'
} else {
    Log 'Installing Windows/IIS prerequisite features'
    $features = @(
        'Web-Server','Web-Windows-Auth','Web-ASP-Net45','Web-Net-Ext45','Web-Metabase',
        'Web-WMI','Web-Static-Content','Web-Default-Doc','Web-Dir-Browsing','Web-Http-Errors',
        'Web-Http-Logging','Web-Request-Monitor','Web-Filtering','Web-ISAPI-Ext','Web-ISAPI-Filter',
        'Web-Mgmt-Console','Web-Mgmt-Compat','Web-Scripting-Tools',
        'BITS','BITS-IIS-Ext','RDC','NET-Framework-45-Core','NET-Framework-45-ASPNET'
    )
    Install-WindowsFeature -Name $features | Out-Null
    # WebDAV is not a Windows feature name; SCCM does not require it for HTTP MP/DP. Skipped.
}

# ================= 2. Windows ADK + WinPE add-on ==============================================
if (Test-Path 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit') {
    Log 'Windows ADK already installed'
} else {
    Log 'Installing Windows ADK + WinPE'
    $adkExe = "$work\adksetup.exe"; $adkPe = "$work\adkwinpesetup.exe"
    Get-File $adkUrl   $adkExe
    Get-File $adkPeUrl $adkPe
    Start-Process $adkExe -ArgumentList '/quiet /features OptionId.DeploymentTools OptionId.ImagingAndConfigurationDesigner /norestart' -Wait
    Start-Process $adkPe  -ArgumentList '/quiet /features OptionId.WindowsPreinstallationEnvironment /norestart' -Wait
}

# ================= 3. SQL Server 2022 (Developer) from the OFFICIAL DIRECT ISO (no SSEI) =======
if (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue) {
    Log 'SQL Server (MSSQLSERVER) already installed'
} else {
    Log 'Installing SQL Server 2022 Developer from a mounted ISO'
    $iso = "$work\SQL2022-Dev.iso"
    Get-File $isoUrl $iso
    $mount = Mount-DiskImage -ImagePath $iso -PassThru
    try {
        $drive = ($mount | Get-Volume).DriveLetter
        $setup = "${drive}:\setup.exe"
        # NOTE: SQL + Agent run as NT AUTHORITY\SYSTEM here as a lab shortcut (local-only DB, no
        # Kerberos SPN needs). A production build uses dedicated low-priv service accounts.
        $sqlIni = @"
[OPTIONS]
ACTION="Install"
FEATURES=SQLENGINE
INSTANCENAME=MSSQLSERVER
SQLSYSADMINACCOUNTS="$SiteAdmin" "$MachineAcct"
SQLSVCACCOUNT="NT AUTHORITY\SYSTEM"
AGTSVCACCOUNT="NT AUTHORITY\SYSTEM"
SQLSVCSTARTUPTYPE="Automatic"
AGTSVCSTARTUPTYPE="Automatic"
TCPENABLED="1"
IACCEPTSQLSERVERLICENSETERMS="True"
SUPPRESSPRIVACYSTATEMENTNOTICE="True"
QUIET="True"
UPDATEENABLED="False"
"@
        $sqlIni | Out-File "$work\sql.ini" -Encoding ascii
        $p = Start-Process $setup -ArgumentList "/ConfigurationFile=$work\sql.ini" -Wait -PassThru
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "SQL setup exited $($p.ExitCode)" }
        Log "SQL setup exit code $($p.ExitCode)"
    } finally {
        Dismount-DiskImage -ImagePath $iso | Out-Null
    }
}

# ================= 3b. Cap SQL max server memory (sqlcmd is NOT installed with SQLENGINE only) =
# FEATURES=SQLENGINE does not ship sqlcmd.exe, so the cap is set through .NET SqlClient with the
# running account (DOAZLab\DOAdmin, a sysadmin) instead of shelling out to sqlcmd.
Log 'Capping SQL max server memory to 6144 MB'
try {
    $cn = New-Object System.Data.SqlClient.SqlConnection 'Server=localhost;Database=master;Integrated Security=True;TrustServerCertificate=True'
    $cn.Open()
    foreach ($q in @(
        "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;",
        "EXEC sp_configure 'max server memory (MB)', 6144; RECONFIGURE;"
    )) { $cmd = $cn.CreateCommand(); $cmd.CommandText = $q; [void]$cmd.ExecuteNonQuery() }
    $cn.Close()
} catch { Log "memory cap failed (non-fatal): $_" }

# ================= 4. ConfigMgr baseline media (WinRAR self-extractor; no SSEI) ================
$cmSrc = "$work\CM"
function Find-CMSetup { Get-ChildItem $cmSrc -Recurse -Filter setup.exe -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\SMSSETUP\\BIN\\X64\\setup\.exe$' } |
    Select-Object -First 1 -ExpandProperty FullName }
$cmSetup = Find-CMSetup
if ($cmSetup) {
    Log "ConfigMgr media already extracted ($cmSetup)"
} else {
    Log 'Downloading + extracting ConfigMgr baseline media'
    $cmExe = "$work\MCM_Configmgr.exe"
    Get-File $cmUrl $cmExe
    New-Item -ItemType Directory -Force -Path $cmSrc | Out-Null
    # -s2 skips the WinRAR SFX confirmation dialog and auto-extracts with no interaction (verified
    # headless-safe under a scheduled task); -d sets the destination. The old /Auto switch is a
    # non-WinRAR argument that leaves the interactive Extract dialog up and hangs under SYSTEM.
    Start-Process $cmExe -ArgumentList "-s2","-d$cmSrc" -Wait
    $cmSetup = Find-CMSetup
}

# ================= 5. Extend AD schema + System Management container (runs as DOAdmin) =========
$domainNC = $null
try { Import-Module ActiveDirectory -ErrorAction Stop; $domainNC = (Get-ADRootDSE).defaultNamingContext } catch { Log "AD module load failed: $_" }

$extadsch = Get-ChildItem $cmSrc -Recurse -Filter extadsch.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if ($extadsch) { Log 'Extending AD schema (extadsch.exe)'; Start-Process $extadsch -Wait } else { Log 'extadsch.exe not found; skipping schema extension' }

if ($domainNC) {
    $smDN = "CN=System Management,CN=System,$domainNC"
    if (-not (Get-ADObject -Filter "distinguishedName -eq '$smDN'" -ErrorAction SilentlyContinue)) {
        Log 'Creating the System Management container'
        New-ADObject -Name 'System Management' -Type 'container' -Path "CN=System,$domainNC"
    } else { Log 'System Management container already present' }
    Log 'Granting the site server computer account Full Control over the container (+ descendants)'
    & dsacls "$smDN" /I:T /G "${MachineAcct}:GA" | Out-Null
}

# ================= 6. Install the ConfigMgr primary site (unattended) ==========================
if (Get-Service SMS_EXECUTIVE -ErrorAction SilentlyContinue) {
    Log 'ConfigMgr site already installed (SMS_EXECUTIVE present)'
} elseif ($cmSetup) {
    Log 'Running ConfigMgr unattended setup (this stage runs 30-60 min)'
    $prereqPath = "$work\CMPrereq"
    New-Item -ItemType Directory -Force -Path $prereqPath | Out-Null
    # Pre-stage the redistributable prerequisites with setupdl.exe so site setup is deterministic.
    $setupdl = Get-ChildItem $cmSrc -Recurse -Filter setupdl.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ($setupdl) { Log 'Pre-downloading ConfigMgr prerequisites (setupdl.exe)'; Start-Process $setupdl -ArgumentList "$prereqPath" -Wait }
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
PrerequisiteComp=1
PrerequisitePath=$prereqPath
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
    $p = Start-Process $cmSetup -ArgumentList "/script $work\cm.ini" -Wait -PassThru
    Log "ConfigMgr setup exit code $($p.ExitCode)"
}

# ================= 7. Post-install: NAA + boundary GROUP + client push =========================
# NOTE (2026-09-23): section 7 is NOT yet validated against a live site. The mechanics below are
# the standard requirements the old script was missing (a boundary needs a boundary GROUP to
# assign clients/offer content; automatic client push needs AD System Discovery enabled + run so
# WS05 becomes a device first). Verify the ConfigurationManager cmdlet parameter names on the
# first live site build before treating this section as done.
if (Get-Service SMS_EXECUTIVE -ErrorAction SilentlyContinue) {
    Log 'Configuring NAA + boundary group + AD discovery + client push'
    $cmModule = (Resolve-Path (Join-Path $SmsDir '..\AdminConsole\bin\ConfigurationManager.psd1') -ErrorAction SilentlyContinue).Path
    if ($cmModule) {
        Import-Module $cmModule
        if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
            New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -Scope Global -ErrorAction SilentlyContinue | Out-Null
        }
        Push-Location "$($SiteCode):"
        try {
            # Network Access Account (the credential sccmhunter recovers from machine policy)
            if (-not (Get-CMAccount -UserName $NaaUser -ErrorAction SilentlyContinue)) {
                $sec = ConvertTo-SecureString $NaaPass -AsPlainText -Force
                New-CMAccount -UserName $NaaUser -Password $sec -SiteCode $SiteCode -ErrorAction SilentlyContinue
            }
            Set-CMSoftwareDistributionComponent -SiteCode $SiteCode -AddNetworkAccessAccountName $NaaUser -ErrorAction SilentlyContinue

            # Boundary + boundary GROUP (a boundary alone assigns nothing and offers no content)
            if (-not (Get-CMBoundary -BoundaryName 'DOAZLab' -ErrorAction SilentlyContinue)) {
                New-CMBoundary -Name 'DOAZLab' -Type IPRange -Value '192.168.2.1-192.168.2.254' -ErrorAction SilentlyContinue
            }
            if (-not (Get-CMBoundaryGroup -Name 'DOAZLab' -ErrorAction SilentlyContinue)) {
                New-CMBoundaryGroup -Name 'DOAZLab' -DefaultSiteCode $SiteCode -ErrorAction SilentlyContinue
            }
            Add-CMBoundaryToGroup -BoundaryName 'DOAZLab' -BoundaryGroupName 'DOAZLab' -ErrorAction SilentlyContinue
            Set-CMBoundaryGroup -Name 'DOAZLab' -AddSiteSystemServerName $SiteServer -ErrorAction SilentlyContinue

            # AD System Discovery must be enabled + run so WS05 becomes a device before client push
            $adDN = (Get-ADDomain).DistinguishedName
            Set-CMDiscoveryMethod -ActiveDirectorySystemDiscovery -SiteCode $SiteCode -Enabled $true `
                -ActiveDirectoryContainer "LDAP://$adDN" -Recursive -ErrorAction SilentlyContinue
            Invoke-CMSystemDiscovery -SiteCode $SiteCode -ErrorAction SilentlyContinue

            # Automatic site-wide client push, with the push install account
            Set-CMClientPushInstallation -SiteCode $SiteCode -EnableAutomaticClientPushInstallation $true -ErrorAction SilentlyContinue
            Set-CMClientPushInstallation -SiteCode $SiteCode -AddAccount $SiteAdmin -ErrorAction SilentlyContinue
        } finally { Pop-Location }
    } else { Log 'ConfigurationManager.psd1 not found; skipping post-install config' }

    # Success: drop the completion flag and unregister the bootstrap task so it stops re-running.
    'complete' | Out-File $flag
    Log '===== Deploy-SCCM complete; completion flag written ====='
    Unregister-ScheduledTask -TaskName 'InstallSCCM' -Confirm:$false -ErrorAction SilentlyContinue
} else {
    Log 'ConfigMgr site NOT detected after setup; leaving completion flag unwritten so the task retries.'
}
