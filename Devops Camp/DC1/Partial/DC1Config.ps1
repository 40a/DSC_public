﻿$ConfigData = @{
                AllNodes = @(
                @{
                    NodeName = "*"
                    Domain = "blah.com"
                    DomainDN = "dc=blah,dc=com"
                    ServersOU = 'OU=Servers,dc=blah,dc=com'
                },
                @{
                    NodeName = "DC1"
                    Role = "AD_ADCS"
                    PSDSCAllowPlainTextPassword = $True
                    PSDSCAllowDomainUser = $True
                    DCDatabasePath = "C:\NTDS"
                    DCLogPath = "C:\NTDS"
                    SysvolPath = "C:\Sysvol"
                    CACN = "blahblahblah root"
                    CADNSuffix = "C=US,L=Somecity,S=Pennsylvania,O=Test Corp"
                    CADatabasePath = "C:\windows\system32\CertLog"
                    CALogPath = "C:\CA_Logs"
                }
                
            )
        }

Configuration DC1Config {

param (
    [parameter(Mandatory=$True)]
    [pscredential]$EACredential,

    [parameter(Mandatory=$True)]
    [pscredential]$SafeModeAdminPW
    )

    import-DSCresource -ModuleName PSDesiredStateConfiguration,CompositeBase,
        @{ModuleName="xActiveDirectory";ModuleVersion="2.11.0.0"},
        @{ModuleName="xNetworking";ModuleVersion="2.9.0.0"},
        @{ModuleName="XADCSDeployment";ModuleVersion="1.0.0.1"},
        @{ModuleName="xDHCPServer";ModuleVersion="1.4.0.0"}
   
    node $AllNodes.Where{$_.Role -eq "AD_ADCS"}.NodeName {
        
 #Region DHCPServer

    WindowsFeature DHCPServer {
        Name = 'DHCP'
        Ensure = 'Present'
        }
        
    xDHCPServerScope Scope1 {
        DependsOn = '[WindowsFeature]DHCPServer'
        Ensure = 'Present'
        IPStartRange = '192.168.2.12'
        IPEndRange = '192.168.2.254'
        SubnetMask = '255.255.255.0'
        State = 'Active'
        Name = "VLAN1"
        }
        
     xDHCPServerOption DHCPDefaults {
        DependsOn = '[xDhcpServerScope]Scope1'
        ScopeID = '192.168.2.0'
        DnsServerIPAddress = '192.168.2.11'
        DnsDomain = $Node.Domain
        Router = '192.168.2.1'
        AddressFamily = 'IPV4'
        Ensure = 'Present'
        } 
       
        
#end region DHCP Server

#region ADDS        
        
        WindowsFeature ADDS
        {
           Ensure = "Present"
           Name   = "AD-Domain-Services"
        }

        WindowsFeature GPMC
        {
            Ensure = 'Present'
            Name = 'GPMC'
        }
 
 #DCPromo
        
        xADDomain FirstDC
        {
            DomainName = $Node.Domain
            DomainAdministratorCredential = $EACredential
            SafemodeAdministratorPassword = $SafeModeAdminPW
            DatabasePath = $Node.DCDatabasePath
            LogPath = $Node.DCLogPath
            SysvolPath = $Node.SysvolPath 
            DependsOn = '[WindowsFeature]ADDS'
        }      

# Add OU for groups

         xADOrganizationalUnit GroupsOU
        {
            Name = 'Groups'
            Path = $Node.DomainDN
            DependsOn = '[xADDomain]FirstDC'
            Ensure = 'Present'
            ProtectedFromAccidentalDeletion = $True
            Credential = $EaCredential
        }

# Add OU for Member Servers

         xADOrganizationalUnit ServersOU
        {
            Name = 'Servers'
            Path = $Node.DomainDN
            DependsOn = '[xADDomain]FirstDC'
            Ensure = 'Present'
            ProtectedFromAccidentalDeletion = $True
            Credential = $EaCredential
        }

#Pre-add member servers to AD

        $MbrSvrs = $AllNodes.Where{$_.NodeName -notmatch "DC1"}
        foreach ($M in $MbrSvrs)
            {
            
            script "AddMbrSvr_$($M.NodeName)" {
                Credential = $EACredential
                DependsOn = '[xADOrganizationalUnit]ServersOU'
                TestScript = {
                                try {
                                    Get-ADComputer -Identity $Using:M.NodeName -ErrorAction Stop
                                    Return $True
                                    }
                                catch {
                                    return $False
                                    }
                            }
                SetScript = {
                                New-ADComputer -Name $Using:M.NodeName -path $Using:M.ServersOU
                            }
                GetScript = {
                                try {
                                    return (Get-ADComputer -Identity $Using:M.NodeName -ErrorAction Stop)
                                    }
                                catch {
                                    return @{Result = $null}
                                    }
                            }
                }
            }

#Add Web Servers group - add pull server as member later

         xADGroup WebServerGroup
        {
            GroupName = 'Web Servers'
            GroupScope = 'Global'
            DependsOn = '[xADOrganizationalUnit]GroupsOU'
            Members = $AllNodes.Where{$_.Role -eq "PullServer"}.sAMAccountName
            Credential = $EACredential
            Category = 'Security'
            Path = "OU=Groups,$($Node.DomainDN)"
            Ensure = 'Present'
        }
#end region ADDS

#region - Add GPO for PKI AutoEnroll
        script CreatePKIAEGpo
        {
            Credential = $EACredential
            TestScript = {
                            if ((get-gpo -name "PKI AutoEnroll" -ErrorAction SilentlyContinue) -eq $Null) {
                                return $False
                            } 
                            else {
                                return $True}
                        }
            SetScript = {
                            new-gpo -name "PKI AutoEnroll"
                        }
            GetScript = {
                            $GPO= (get-gpo -name "PKI AutoEnroll")
                            return @{Result = $GPO}
                        }
            DependsOn = '[xADDomain]FirstDC'
        }
        
        script setAEGPRegSetting1
        {
            Credential = $EACredential
            TestScript = {
                            if ((Get-GPRegistryValue -name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment" -ValueName "AEPolicy" -ErrorAction SilentlyContinue).Value -eq 7) {
                                return $True
                            }
                            else {
                                return $False
                            }
                        }
            SetScript = {
                            Set-GPRegistryValue -name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment" -ValueName "AEPolicy" -Value 7 -Type DWord
                        }
            GetScript = {
                            $RegVal1 = (Get-GPRegistryValue -name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment" -ValueName "AEPolicy")
                            return @{Result = $RegVal1}
                        }
            DependsOn = '[Script]CreatePKIAEGpo'
        }

        script setAEGPRegSetting2 
        {
            Credential = $EACredential
            TestScript = {
                            if ((Get-GPRegistryValue -name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment" -ValueName "OfflineExpirationPercent" -ErrorAction SilentlyContinue).Value -eq 10) {
                                return $True
                                }
                            else {
                                return $False
                                 }
                         }
            SetScript = {
                            Set-GPRegistryValue -Name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment" -ValueName "OfflineExpirationPercent" -value 10 -Type DWord
                        }
            GetScript = {
                            $Regval2 = (Get-GPRegistryValue -name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment" -ValueName "OfflineExpirationPercent")
                            return @{Result = $RegVal2}
                        }
            DependsOn = '[Script]setAEGPRegSetting1'

        }
                                  
        script setAEGPRegSetting3
        {
            Credential = $EACredential
            TestScript = {
                            if ((Get-GPRegistryValue -Name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment" -ValueName "OfflineExpirationStoreNames" -ErrorAction SilentlyContinue).value -match "MY") {
                                return $True
                                }
                            else {
                                return $False
                                }
                        }
            SetScript = {
                            Set-GPRegistryValue -Name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment" -ValueName "OfflineExpirationStoreNames" -value "MY" -Type String
                        }
            GetScript = {
                            $RegVal3 = (Get-GPRegistryValue -Name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\Cryptography\AutoEnrollment" -ValueName "OfflineExpirationStoreNames")
                            return @{Result = $RegVal3}
                        }
            DependsOn = '[Script]setAEGPRegSetting2'
        }
      
      script setAEGPRegSetting4
        {
            Credential = $EACredential
            TestScript = {
                            if ((Get-GPRegistryValue -Name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\SystemCertificates\Root\ProtectedRoots" -ValueName "PeerUsages" -errorAction SilentlyContinue).value -match "1.3.6.1.5.5.7.3.2 1.3.6.1.5.5.7.3.4 1.3.6.1.4.1.311.10.3.4") {
                                return $True
                                }
                            else {
                                return $False
                                }
                        }
            SetScript = {
                            Set-GPRegistryValue -Name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\SystemCertificates\Root\ProtectedRoots" -ValueName "PeerUsages" -value "1.3.6.1.5.5.7.3.2", "1.3.6.1.5.5.7.3.4", "1.3.6.1.4.1.311.10.3.4" -Type String
                        }
            GetScript = {
                            $RegVal3 = (Get-GPRegistryValue -Name "PKI AutoEnroll" -Key "HKLM\SOFTWARE\Policies\Microsoft\SystemCertiticates\Root\ProtectedRoots" -ValueName "PeerUsages")
                            return @{Result = $RegVal3}
                        }
            DependsOn = '[Script]setAEGPRegSetting3'
        }

        Script SetAEGPLink
        {
            Credential = $EACredential
            TestScript = {
                            if (([xml](Get-GPOReport -Name "PKI AutoEnroll" -ReportType XML)).GPO.LinksTo.SOMPath -match $Using:Node.Domain) {
                                write-output "Group policy PKI Autoenroll already linked to domain."
                                return $True
                                }
                            else {
                                write-output "Group policy PKI Autoenroll not linked at domain level."
                                return $False
                                }
                        }
            SetScript = {
                            New-GPLink -name "PKI AutoEnroll" -Target $Using:Node.DomainDN -LinkEnabled Yes 
                        }
            GetScript = {
                            $GPLink = set-GPLink -name "PKI AutoEnroll" -target $Using:Node.DomainDN
                            return @{Result = $GPLink}
                        }
            DependsOn = '[Script]setAEGPRegSetting4'
        }                           

#end region - Add GPO for PKI AutoEnroll

#region - ADCS
                            
        WindowsFeature ADCS
        {
            Ensure = "Present"
            Name = "ADCS-Cert-Authority"
            DependsOn = '[xADDomain]FirstDC'
        }

        xAdcsCertificationAuthority ADCSConfig
        {
            CAType = 'EnterpriseRootCA'
            Credential = $EACredential
            CryptoProviderName = 'RSA#Microsoft Software Key Storage Provider'
            HashAlgorithmName = 'SHA256'
            KeyLength = 2048
            CACommonName = $Node.CACN
            CADistinguishedNameSuffix = $Node.CADNSuffix
            DatabaseDirectory = $Node.CADatabasePath
            LogDirectory = $Node.CALogPath
            ValidityPeriod = 'Years'
            ValidityPeriodUnits = 2
            DependsOn = '[WindowsFeature]ADCS','[xADDomain]FirstDC'    
        }

#Note:  The Test section is pure laziness.  Future enhancement:  test for more than just existence.
        script CreateWebServer2Template
        {
            DependsOn = '[xAdcsCertificationAuthority]ADCSConfig'
            Credential = $EACredential
            TestScript = {
                            try {
                                $WSTemplate=get-ADObject -Identity "CN=WebServer2,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com" -Properties * -ErrorAction Stop
                                return $True
                                }
                            catch {
                                return $False
                                }
                         }
            SetScript = {
                         $WebServerTemplate = @{'flags'='131649';
                        'msPKI-Cert-Template-OID'='1.3.6.1.4.1.311.21.8.8211880.1779723.5195193.12600017.10487781.44.7319704.6725493';
                        'msPKI-Certificate-Application-Policy'='1.3.6.1.5.5.7.3.1';
                        'msPKI-Certificate-Name-Flag'='268435456';
                        'msPKI-Enrollment-Flag'='32';
                        'msPKI-Minimal-Key-Size'='2048';
                        'msPKI-Private-Key-Flag'='50659328';
                        'msPKI-RA-Signature'='0';
                        'msPKI-Supersede-Templates'='WebServer';
                        'msPKI-Template-Minor-Revision'='3';
                        'msPKI-Template-Schema-Version'='2';
                        'pKICriticalExtensions'='2.5.29.15';
                        'pKIDefaultCSPs'='2,Microsoft DH SChannel Cryptographic Provider','1,Microsoft RSA SChannel Cryptographic Provider';
                        'pKIDefaultKeySpec'='1';
                        'pKIExtendedKeyUsage'='1.3.6.1.5.5.7.3.1';
                        'pKIMaxIssuingDepth'='0';
                        'revision'='100'}


                        New-ADObject -name "WebServer2" -Type pKICertificateTemplate -Path "CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com" -DisplayName WebServer2 -OtherAttributes $WebServerTemplate
                        $WSOrig = Get-ADObject -Identity "CN=WebServer,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com" -Properties * | Select-Object pkiExpirationPeriod,pkiOverlapPeriod,pkiKeyUsage
                        Get-ADObject -Identity "CN=WebServer2,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com" | Set-ADObject -Add @{'pKIKeyUsage'=$WSOrig.pKIKeyUsage;'pKIExpirationPeriod'=$WSOrig.pKIExpirationPeriod;'pkiOverlapPeriod'=$WSOrig.pKIOverlapPeriod}
                        }
                GetScript = {
                                try {
                                    return {get-ADObject -Identity "CN=WebServer2,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com" -Properties * -ErrorAction Stop}
                                    }
                                catch {
                                    return @{Result=$Null}
                                    }
                            }
        }
         
        script PublishWebServerTemplate2 
        {       
           DependsOn = '[Script]CreateWebServer2Template'
           Credential = $EACredential
           TestScript = {
                            $Template= Get-CATemplate | Where-Object {$_.Name -match "WebServer2"}
                            if ($Template -eq $Null) {return $False}
                            else {return $True}
                        }
           SetScript = {
                            add-CATemplate -name "WebServer2" -force
                        }
           GetScript = {
                            return {Get-CATemplate | Where-Object {$_.Name -match "WebServer2"}}
                        }
         }
                                                     

#end region - ADCS

#region WebServer Cert setup

#would like to collapse next two into one resource with a foreach loop on the GUIDs, but can't get it working.

        script SetWebServerTemplateAutoenroll
        {
            DependsOn = '[Script]CreateWebServer2Template'
            Credential = $EACredential
            TestScript = {
                Import-Module activedirectory
                $WebServerCertACL = (get-acl "AD:CN=WebServer2,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com").Access | Where-Object {$_.IdentityReference -like "*Web Servers"}
                if ($WebServerCertACL -eq $Null) {
                    write-verbose "Web Servers Group does not have permissions on Web Server template"
                    Return $False
                    }
                elseif (($WebServerCertACL.ActiveDirectoryRights -like "*ExtendedRight*") -and ($WebServerCertACL.ObjectType -notcontains "a05b8cc2-17bc-4802-a710-e7c15ab866a2")) {
                    write-verbose "Web Servers group has permission, but not the correct permission."
                    Return $False
                    }
                else {
                    write-verbose "ACL on Web Server Template is set correctly for this GUID for Web Servers Group"
                    Return $True
                    }
                }
             SetScript = {
                Import-Module activedirectory
                $WebServersGroup = get-adgroup -Identity "Web Servers" | Select-Object SID
                $EnrollGUID = [GUID]::Parse("a05b8cc2-17bc-4802-a710-e7c15ab866a2")
                $ACL = get-acl "AD:CN=WebServer2,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com"
                $ACL.AddAccessRule((New-Object System.DirectoryServices.ExtendedRightAccessRule $WebServersGroup.SID,'Allow',$EnrollGUID,'None'))
                #$ACL.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule $WebServersGroup.SID,'ReadProperty','Allow'))
                #$ACL.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule $WebServersGroup.SID,'GenericExecute','Allow'))
                set-ACL "AD:CN=WebServer2,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com" -AclObject $ACL
                write-verbose "AutoEnroll permissions set for Web Servers Group"
                }
             GetScript = {
                Import-Module activedirectory
                $WebServerCertACL = (get-acl "AD:CN=WebServer2,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com").Access | Where-Object {$_.IdentityReference -like "*Web Servers"}
                if ($WebServerCertACL -ne $Null) {
                    return $WebServerCertACL
                    }
                else {
                    Return @{}
                    }
                }
         }
            
    script SetWebServerTemplateEnroll
        {
            DependsOn = '[Script]CreateWebServer2Template'
            Credential = $EACredential
            TestScript = {
                Import-Module activedirectory
                $WebServerCertACL = (get-acl "AD:CN=WebServer2,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com").Access | Where-Object {$_.IdentityReference -like "*Web Servers"}
                if ($WebServerCertACL -eq $Null) {
                    write-verbose "Web Servers Group does not have permissions on Web Server template"
                    Return $False
                    }
                elseif (($WebServerCertACL.ActiveDirectoryRights -like "*ExtendedRight*") -and ($WebServerCertACL.ObjectType -notcontains "0e10c968-78fb-11d2-90d4-00c04f79dc55")) {
                    write-verbose "Web Servers group has permission, but not the correct permission."
                    Return $False
                    }
                else {
                    write-verbose "ACL on Web Server Template is set correctly for this GUID for Web Servers Group"
                    Return $True
                    }
                }
             SetScript = {
                Import-Module activedirectory
                $WebServersGroup = get-adgroup -Identity "Web Servers" | Select-Object SID
                $EnrollGUID = [GUID]::Parse("0e10c968-78fb-11d2-90d4-00c04f79dc55")
                $ACL = get-acl "AD:CN=WebServer2,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com"
                $ACL.AddAccessRule((New-Object System.DirectoryServices.ExtendedRightAccessRule $WebServersGroup.SID,'Allow',$EnrollGUID,'None'))
                #$ACL.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule $WebServersGroup.SID,'ReadProperty','Allow'))
                #$ACL.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule $WebServersGroup.SID,'GenericExecute','Allow'))
                set-ACL "AD:CN=WebServer2,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com" -AclObject $ACL
                write-verbose "Enroll permissions set for Web Servers Group"
                }
             GetScript = {
                Import-Module activedirectory
                $WebServerCertACL = (get-acl "AD:CN=WebServer2,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=blah,DC=com").Access | Where-Object {$_.IdentityReference -like "*Web Servers"}
                if ($WebServerCertACL -ne $Null) {
                    return $WebServerCertACL
                    }
                else {
                    Return @{}
                    }
                }
         }

#End Region WebServer Cert setup


        
    xDHCPServerAuthorization DHCPAuth {
        DependsOn = '[xADDomain]FirstDC'
        Ensure = 'Present'
        } 
        
      
    } 

}

DC1Config -configurationData $ConfigData -outputpath "C:\DSC\Config" -EACredential (get-credential -username "blah.com\administrator" -Message "EA for ADCS/checking domain presence") -SafeModeAdminPW (get-credential -Username 'Password Only' -Message "Safe Mode Admin PW")
