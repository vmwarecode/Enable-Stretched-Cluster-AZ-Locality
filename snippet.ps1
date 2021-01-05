<#
.SYNOPSIS 
Configure a VMConAWS Stretched Cluster for reduced availability.

.DESCRIPTION
Configure a VMConAWS Stretched Cluster for reduced availability by creating the necessary tags, compute, and storage policies to pin a workload in one AZ or the other. 

.Notes
Glenn Sizemore - VMware 2021
Sample script not for production use without independent testing. 

.Example
Enable-StretchedClusterReducedAvabilaibliity.ps1 -viserver vcenter.sddc-44-242-91-5.vmwarevmc.com -credentials CloudAdmin@vmc.local

Enable reduced availability via AZ pinning on every cluster using the defaults. 

.Example
Enable-StretchedClusterReducedAvabilaibliity.ps1 -cluster Cluster-1 -viserver vcenter.sddc-44-242-91-5.vmwarevmc.com -credentials CloudAdmin@vmc.local

Enable reduced availability via AZ pinning on only Cluster-1.

.Example
Enable-StretchedClusterReducedAvabilaibliity.ps1 -CatagoryName AvailbilityZone -cluster Cluster-1 -viserver vcenter.sddc-44-242-91-5.vmwarevmc.com -credentials CloudAdmin@vmc.local

Enable reduced availability via AZ pinning on only Cluster-1 specifying Tag Catagory name.

.Example
Enable-StretchedClusterReducedAvabilaibliity.ps1 -FTT 2 -viserver vcenter.sddc-44-242-91-5.vmwarevmc.com -credentials CloudAdmin@vmc.local

Enable reduced availability via AZ pinning specifying 2 failure - Raid-1 protection inside each AZ. 

.Example
Enable-StretchedClusterReducedAvabilaibliity.ps1 -Raid5 -viserver vcenter.sddc-44-242-91-5.vmwarevmc.com -credentials CloudAdmin@vmc.local

Enable reduced availability via AZ pinning on specifying Raid-5 inside each AZ.
#>
[CmdletBinding(DefaultParameterSetName='R1')]
Param(
    # Name of the Tag Catagory to create, defaults to "AZ"
    [Parameter( 
            ValueFromPipelineByPropertyName=$true,
            Mandatory=$False
    )]
    [string]
    $CatagoryName = 'AZ',

    # Name of the Cluster to tag, use to limit the scope of the script. 
    [Parameter( 
        ValueFromPipelineByPropertyName=$true,
        Mandatory=$False
    )]
    [Alias('Name')]
    [string]
    $Cluster, 

    # How many Host Failures to protect from using Raid-1 Mirroring, default 1 Failure - Raid-1
    [Parameter( 
        ParameterSetName='R1',
        ValueFromPipelineByPropertyName=$true,
        Mandatory=$false
    )]
    [Int]
    [ValidateRange(0,3)]
    $FTT, 

    # Use Raid-5 Failure protection inside each AZ.
    [Parameter( 
        ParameterSetName='R5',
        Mandatory=$true
    )]
    [switch]
    $Raid5, 
    
    # Use Raid-6 Failure protection inside each AZ.
    [Parameter( 
        ParameterSetName='R6',
        Mandatory=$true
    )]
    [switch]
    $Raid6,

    # Output any Tags assigned or Policies created/verified.
    [Parameter( 
        Mandatory=$False
    )]
    [switch]
    $Passthru,

    # VI server url or IP
    [Parameter(
        Mandatory=$true
    )]
    [string]
    $VIServer,

    # Credentials
    [Parameter(
        Mandatory=$true
    )]
    [pscredential]
    $Credentials
)
begin
{
    #Simple funtion to route all messaging. 
    function write-log ($message) 
    {
        Write-Output $message
    }

    # Connect to VC
    $_vi = Connect-VIServer -Server $VIServer -Credential $Credentials -EA Stop
 
    #connect to the CIS service
    $_cis = Connect-CisServer -Server $VIServer -Credential $Credentials -NotDefault -EA Stop

    #tag cache to reduce vc calls.
    $fdTags = [hashtable]::new()
    
    # configure cluster filter if one was passed.
    If ($PSBoundParameters.ContainsKey('Cluster'))
    { 
        $ClusterSplat = @{
            Name = $Cluster
        }
    }
    else 
    {
        $ClusterSplat = @{
            Name = '*'
        }
    }

    # Build vSAN Policy based on parameters
    $vSANRules = [hashtable]::new()
    $vSANRules.Add('VSAN.hostFailuresToTolerate',0)
    $vSANRules.Add('VSAN.locality','')

    if ($PSBoundParameters.keys.Contains('FTT'))
    {
        $vSANRules.Add('VSAN.replicaPreference','RAID-1 (Mirroring) - Performance')
        $vSANRules.Add('VSAN.subFailuresToTolerate',$FTT)
    } 
    Elseif ($PSBoundParameters.keys.Contains('R5'))
    {
        $vSANRules.Add('VSAN.replicaPreference','RAID-5/6 (Erasure Coding) - Capacity')
        $vSANRules.Add('VSAN.subFailuresToTolerate',1)
    }
    Elseif ($PSBoundParameters.keys.Contains('R6'))
    {
        $vSANRules.Add('VSAN.replicaPreference','RAID-5/6 (Erasure Coding) - Capacity')
        $vSANRules.Add('VSAN.subFailuresToTolerate',2)
    }
    Else
    {
        $vSANRules.Add('VSAN.replicaPreference','RAID-1 (Mirroring) - Performance')
        $vSANRules.Add('VSAN.subFailuresToTolerate',1)
    }
    $vSANSC = Get-VsanView 'VimClusterVsanVcStretchedClusterSystem-vsan-stretched-cluster-system' -Server $_vi
}
Process
{
    Foreach ($vCluster in (Get-Cluster -Server $_vi @ClusterSplat))
    {
        write-log ("Checking Cluster [{0}]..." -f $vCluster.Name)
        # Make sure the relevant tags are present
        if (-NOT (Get-TagCategory -Name $CatagoryName -ErrorAction SilentlyContinue -Server $_vi))
        {
            write-log "    Creating Tag Catagory ${CatagoryName}..."
            New-TagCategory -Name $CatagoryName -Cardinality Multiple -Server $_vi
            Foreach ($vsanFaultDomain in (Get-VsanFaultDomain -Cluster $vCluster -Server $_vi))
            {
                write-log ("        Adding Tag {0}" -f $vsanFaultDomain.Name)
                $fdTags.Add($vSANFaultDomain.Name,(New-Tag -Category $CatagoryName -Name $vsanFaultDomain.Name -Server $_vi))
            }
        }
        else 
        {
            write-log "    Tag Catagory already present, checking Tags..."
            Foreach ($vsanFaultDomain in (Get-VsanFaultDomain @ClusterSplat -Server $_vi))
            {
                $_tempTag = Get-Tag -Category $CatagoryName -Name $vsanFaultDomain.Name -Server $_vi -ErrorAction SilentlyContinue
                if ($_tempTag)
                {
                    write-log ("        {0} Tag found." -f $vsanFaultDomain.Name)
                    $fdTags.Add($vsanFaultDomain.Name,$_tempTag)
                }
                Else
                {
                    write-log ("        Creating Tag {0}... " -f $vsanFaultDomain.Name)
                    $fdTags.Add($vsanFaultDomain.Name,(New-Tag -Category $CatagoryName -Name $vsanFaultDomain.Name -Server $_vi))
                }
                $_tempTag = $null
            }
        }
        
        $service = get-cisservice 'com.vmware.vcenter.compute.policies' -Server $_cis
        $computePolicies = $service.list()
        Foreach ($k in $fdTags.Keys)
        {
            $fd = $fdTags.$k
            $_tempPolicy = $computePolicies | Where-Object Name -eq $fd.Name
            # if policy is present check the settings.
            if ($_tempPolicy)
            {
                write-log ("        {0} Compute policy found checking tag membership..." -f $_tempPolicy.name)
                $_cpPolicy = $service.get($_tempPolicy.Policy)
                if (($_cpPolicy.vm_tag -ne $fd.id) -or ($_cpPolicy.host_tag -ne $fd.id))
                {
                    Throw ("Conflicting policy present. {0} already exists but is configured to use a different tag, please delete the conflicting policy and run again." -f $_cpPolicy.name)
                }
                else 
                {
                    write-log ("            {0} Compute policy is compliant." -f $_tempPolicy.name)
                }
            }
            else 
            {
                write-log ("        Creating {0} Compute policy..." -f $fd.name)
                $vmhostaffinityspecType = $service.Help.create.spec.GetInheritors("com.vmware.vcenter.compute.policies.capabilities.vm_host_affinity.create_spec")
                $spec = $vmhostaffinityspecType.Create()
                $spec.Name = $fd.name
                $spec.Description = 'Keep VMs contained within the {0} Availability Zone.' -f $fd.name
                $spec.vm_tag = $fd.id
                $spec.host_tag = $fd.id
                $service.create($spec)
            }
            $_tempPolicy = $null
        }
        write-log ('    Compute Policies are Ready for {0}' -f $vCluster.Name)
        $t_out = @()
        write-log ("    Checking Host Tag assignment within Cluster {0}..." -f $vCluster.Name)
        Foreach ($vHost in ($vCluster|Get-VMhost -Server $_vi))
        {
            $_currentTag = $null
            $tag = $fdTags."$((Get-VsanFaultDomain -VMHost $vHost.Name -Server $_vi).Name)"
            # Check to see if the tag is already present, if not apply.
            $_currentTag = Get-TagAssignment -Entity $vHost -Category $tag.Catagory.Name -Server $_vi| 
                Where-Object -Property Tag -EQ $tag
            if ($_currentTag -eq $null)
            {
                write-log "        Adding AZ tag to ${vHost}..."
                $t_out += New-TagAssignment -Entity $vHost -Tag $tag -Server $_vi
            }
            else {
                write-log "        Tag already present on ${vHost}."
                $t_out += $_currentTag 
            }
        }
        if ($Passthru) { $t_out }
        # Check vSAN Policies
        write-log ("    Verify vSAN policy dependence for Cluster {0}..." -f $vCluster.Name)
        $p_out =@()
        $preferredFaultDomain = $vSANSC.VSANVcGetPreferredFaultDomain($vCluster.id).PreferredFaultDomainName
        write-log ('        {0} is the preffered fault domain for {1}' -f $preferredFaultDomain, $vCluster.Name)
        foreach ($_fd in (Get-VsanFaultDomain -Cluster $vCluster -Server $_vi))
        {
            $_rulez = $vSANRules
            if ($_fd.Name -eq $preferredFaultDomain)
            {
                $_rulez.'VSAN.locality'='Preferred Fault Domain'
            }
            else 
            {
                $_rulez.'VSAN.locality'='Secondary Fault Domain'
            }

            $_currentpolicy = Get-SpbmStoragePolicy -Name $_fd.Name -Server $_vi -ErrorAction SilentlyContinue
            if (-Not $_currentpolicy)
            {
                write-log ('        policy not found creating locality policy for {0}' -f $_fd.Name)
                $p_out += New-SpbmStoragePolicy -Name $_fd.name -Server $_vi `
                    -Description ('Constrain VM data to the {0} AZ.' -f $_fd.name) `
                    -AnyOfRuleSets ( `
                        New-SpbmRuleSet -AllofRules (
                            $_rulez.Keys | ForEach-Object {
                                New-SpbmRule -Server $_vi  -Capability (Get-SpbmCapability -Name $_ -Server $_vi) -Value $_rulez.$_
                            }
                        )
                    ) 
            }
            else 
            {
                $_currentPolicyRulez = [hashtable]::new()
                $_currentpolicy.AnyOfRuleSets.AllOfRules | 
                    ForEach-Object {
                        $_currentPolicyRulez.Add($_.Capability.Name,$_.Value)
                    }
                write-log ('        {0} Policy Found, Checking rules' -f $_fd.Name)
                foreach ($rule in $_rulez.Keys)
                {
                    if ($_rulez.$rule -eq $_currentPolicyRulez.$rule ) 
                    {
                        Write-Verbose ("{0} - Desired {1}: Configured {2}" -f $rule, $_rulez.$rule, $_currentPolicyRulez.$rule)
                    }
                    else 
                    {
                        Throw ("VM Storage Policy '{0}' has a configuration error. Please manually correct, or delete the policy and run again. {1} - Desired {2}: Configured {3}" -f $_currentpolicy.Name,$rule, $_rulez.$rule, $_currentPolicyRulez.$rule)
                    }
                }
                $p_out += $_currentpolicy
            }
        }
        if ($Passthru) { $p_out }
        write-log '    vSAN Policies are ready.'
        write-log ('{0} is ready for reduced availability/AZ pinning.' -f $vCluster.Name)
    }
}

