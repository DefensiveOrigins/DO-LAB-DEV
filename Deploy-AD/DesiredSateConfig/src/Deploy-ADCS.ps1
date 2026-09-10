# Author: Roberto Rodriguez @Cyb3rWard0g
# License: GPLv3

configuration Deploy-ADCS {
    param 
    ( 
        [Parameter(Mandatory)]
        [String]$DomainFQDN,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds

    ) 
    Import-DscResource -ModuleName ActiveDirectoryDsc, NetworkingDsc, xPSDesiredStateConfiguration, ComputerManagementDsc
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Domain-qualify the builder credential (e.g. DOAZLAB\dolabbuilder). AdminCreds.UserName is
    # unqualified, which on a member server resolves to the LOCAL admin; the Enterprise CA install
    # and template publish/ACL need the DOMAIN account (the forest builder / Enterprise Admin).
    [String] $DomainNetbiosName = (Get-NetBIOSName -DomainFQDN $DomainFQDN)
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($AdminCreds.UserName)", $AdminCreds.Password)

    Node localhost
    {
        LocalConfigurationManager
        {           
            ConfigurationMode   = 'ApplyOnly'
            RebootNodeIfNeeded  = $true
        }

        # ***** Install ADCS *****
        # ADCS now runs on a member server (SRV01), not the DC. A member server's SYSTEM account
        # lacks the Enterprise-Admin rights needed to install an Enterprise Root CA and to
        # publish/ACL templates in the AD Configuration partition, so the resource runs under
        # AdminCreds (the forest builder, an Enterprise Admin). See HARDENING.md for the
        # least-privilege alternative (pre-delegating Public Key Services rights to the SRV01
        # computer account so this can run as SYSTEM instead).
        xScript InstallADCS
        {
            PsDscRunAsCredential = $DomainCreds
            SetScript = {

                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                Get-WindowsFeature -Name AD-Certificate | Install-WindowsFeature
                Add-WindowsFeature Adcs-Cert-Authority -IncludeManagementTools
                Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -Force

                Add-WindowsFeature ADCS-Enroll-Web-Pol -IncludeManagementTools 
                Add-WindowsFeature Adcs-Enroll-Web-Svc -IncludeManagementTools 
                Add-WindowsFeature ADCS-Web-Enrollment -IncludeManagementTools 
                Add-WindowsFeature ADCS-Device-Enrollment -IncludeManagementTools 
                Add-WindowsFeature ADCS-Online-Cert -IncludeManagementTools 
                
                #Install-AdcsEnrollmentPolicyWebService -Force
                #Install-AdcsEnrollmentWebService -Force
                #Install-AdcsNetworkDeviceEnrollmentService -Force
                #Install-AdcsOnlineresponder -Force
		# Add web enrollment
                Install-AdcsWebEnrollment -Force


                #Add Default templates
                Add-CATemplate "ClientAuth" -Force
                Add-CATemplate "CodeSigning" -Force 
                Add-CATemplate "Workstation" -Force
                Add-CATemplate "SmartcardUser" -Force
                Add-CATemplate "ExchangeUser" -Force
                Add-CATemplate "EnrollmentAgent" -Force

                #Install module to manage import/export of templates
                Install-Module ADCSTemplate -Force
                #Export-ADCSTemplate vuln_Template > vuln_template.json

                #Download DOLAB templates 
                $wc = new-object System.Net.WebClient
                $wc.DownloadFile('https://raw.githubusercontent.com/DefensiveOrigins/AC-Extras/refs/heads/main/ADCS/DOAZLab_Computer.json', 'C:\ProgramData\DOAZLab_Computer.json')
                $wc.DownloadFile('https://raw.githubusercontent.com/DefensiveOrigins/AC-Extras/refs/heads/main/ADCS/DOAZLab_User.json', 'C:\ProgramData\DOAZLab_User.json')

                #Import DOLAB templates
                New-ADCSTemplate -DisplayName DOAZLab_Computer -JSON (Get-Content C:\ProgramData\DOAZLab_Computer.json -Raw) -Publish
                New-ADCSTemplate -DisplayName DOAZLab_User -JSON (Get-Content C:\ProgramData\DOAZLab_User.json -Raw) -Publish

		# Set Enrollment Rights
  		Set-ADCSTemplateACL -DisplayName DOAZLab_Computer  -Enroll -Identity 'DOAZLab\Domain Computers'
                Set-ADCSTemplateACL -DisplayName DOAZLab_User  -Enroll -Identity 'DOAZLab\Domain Users'

                #ESC6
                certutil -config "SRV01.doazlab.com\doazlab-SRV01-CA" -setreg policy\Editflags +EDITF_ATTRIBUTESUBJECTALTNAME2

                #Restart CertSrv
                Restart-Service -Name CertSvc

            }
            GetScript =  
            {
                # This block must return a hashtable. The hashtable must only contain one key Result and the value must be of type String.
                return @{ "Result" = "false" }
            }
            TestScript = 
            {
                # If it returns $false, the SetScript block will run. If it returns $true, the SetScript block will not run.
                return $false
            }
        }

        PendingReboot RebootOnSignalFromAADConnect
        {
            Name        = 'RebootOnSignalFromADCS'
            DependsOn   = "[xScript]InstallADCS"
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