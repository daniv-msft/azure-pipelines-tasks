Trace-VstsEnteringInvocation $MyInvocation
Import-VstsLocStrings "$PSScriptRoot\Task.json"

function Get-AssemblyReference {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath)

    $ErrorActionPreference = 'Stop'
    Write-Warning "Not supported for use during task execution. This function is only intended to help developers resolve the minimal set of DLLs that need to be bundled when consuming the VSTS REST SDK or TFS Extended Client SDK. The interface and output may change between patch releases of the VSTS Task SDK."
    Write-Output ''
    Write-Warning "Only a subset of the referenced assemblies may actually be required, depending on the functionality used by your task. It is best to bundle only the DLLs required for your scenario."
    $directory = [System.IO.Path]::GetDirectoryName($LiteralPath)
    $hashtable = @{ }
    $queue = @( [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($LiteralPath).GetName() )
    while ($queue.Count) {
        # Add a blank line between assemblies.
        Write-Output ''

        # Pop.
        $assemblyName = $queue[0]
        $queue = @( $queue | Select-Object -Skip 1 )

        # Attempt to find the assembly in the same directory.
        $assembly = $null
        $path = "$directory\$($assemblyName.Name).dll"
        if ((Test-Path -LiteralPath $path -PathType Leaf)) {
            $assembly = [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($path)
        } else {
            $path = "$directory\$($assemblyName.Name).exe"
            if ((Test-Path -LiteralPath $path -PathType Leaf)) {
                $assembly = [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($path)
            }
        }

        # Make sure the assembly full name matches, not just the file name.
        if ($assembly -and $assembly.GetName().FullName -ne $assemblyName.FullName) {
            $assembly = $null
        }

        # Print the assembly.
        if ($assembly) {
            Write-Output $assemblyName.FullName
        } else {
            if ($assemblyName.FullName -eq 'Newtonsoft.Json, Version=6.0.0.0, Culture=neutral, PublicKeyToken=30ad4fe6b2a6aeed') {
                Write-Warning "*** NOT FOUND $($assemblyName.FullName) *** This is an expected condition when using the HTTP clients from the 15.x VSTS REST SDK. Use Get-VstsVssHttpClient to load the HTTP clients (which applies a binding redirect assembly resolver for Newtonsoft.Json). Otherwise you will need to manage the binding redirect yourself."
            } else {
                Write-Warning "*** NOT FOUND $($assemblyName.FullName) ***"
            }

            continue
        }

        # Walk the references.
        $refAssemblyNames = @( $assembly.GetReferencedAssemblies() )
        for ($i = 0 ; $i -lt $refAssemblyNames.Count ; $i++) {
            $refAssemblyName = $refAssemblyNames[$i]

            # Skip framework assemblies.
            $fxPaths = @(
                "$env:windir\Microsoft.Net\Framework64\v4.0.30319\$($refAssemblyName.Name).dll"
                "$env:windir\Microsoft.Net\Framework64\v4.0.30319\WPF\$($refAssemblyName.Name).dll"
            )
            $fxPath = $fxPaths |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Where-Object { [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($_).GetName().FullName -eq $refAssemblyName.FullName }
            if ($fxPath) {
                continue
            }

            # Print the reference.
            Write-Output "    $($refAssemblyName.FullName)"

            # Add new references to the queue.
            if (!$hashtable[$refAssemblyName.FullName]) {
                $queue += $refAssemblyName
                $hashtable[$refAssemblyName.FullName] = $true
            }
        }
    }
}

try {

    $ServiceName = Get-VstsInput -Name ServiceName -Require
    $ResourceGroupName = Get-VstsInput -Name ResourceGroupName -Require
    $ServiceLocation = Get-VstsInput -Name ServiceLocation -Require
    $CsCfg = Get-VstsInput -Name CsCfg -Require
    $CsDef = Get-VstsInput -Name CsDef -Require
    $CsPkg = Get-VstsInput -Name CsPkg -Require
    $StorageAccount = Get-VstsInput -Name ARMStorageAccount -Require
    $KeyVault = Get-VstsInput -Name KeyVault
    $DeploymentLabel = Get-VstsInput -Name DeploymentLabel
    $AppendDateTimeToLabel = Get-VstsInput -Name AppendDateTimeToLabel -AsBool
    $UpgradeMode = Get-VstsInput -Name UpgradeMode
    $AllowUpgrade = Get-VstsInput -Name AllowUpgrade -Require -AsBool
    $VerifyRoleInstanceStatus = Get-VstsInput -Name VerifyRoleInstanceStatus -AsBool
    $DiagnosticStorageAccountKeys = Get-VstsInput -Name DiagnosticStorageAccountKeys
    $ARMConnectedServiceName = Get-VstsInput -Name ARMConnectedServiceName -Require
    $endpoint = Get-VstsEndpoint -Name $ARMConnectedServiceName -Require

    # Initialize helpers
    Import-Module $PSScriptRoot\ps_modules\VstsAzureHelpers_
    . $PSScriptRoot/Utility.ps1

    Update-PSModulePathForHostedAgent

    $troubleshoot = "https://aka.ms/azurepowershelltroubleshooting"
    try {
        # Initialize Azure.
        $vstsEndpoint = Get-VstsEndpoint -Name SystemVssConnection -Require
        $vstsAccessToken = $vstsEndpoint.auth.parameters.AccessToken

        Initialize-AzModule -Endpoint $endpoint -connectedServiceNameARM $ARMConnectedServiceName -vstsAccessToken $vstsAccessToken
        Write-Host "## Az module initialization Complete"
        $success = $true
    }
    finally {
        if (!$success) {
            Write-VstsTaskError "Initializing Az module failed: For troubleshooting, refer: $troubleshoot"
        }
    }

    $vsServicesDll = [System.IO.Path]::Combine($PSScriptRoot, "ps_modules\VstsAzureHelpers_\Microsoft.VisualStudio.Services.WebApi.dll")
    Get-AssemblyReference $vsServicesDll

    $storageAccountKeysMap = Parse-StorageKeys -StorageAccountKeys $DiagnosticStorageAccountKeys

    Write-Host "Finding $CsCfg"
    $serviceConfigFile = Find-VstsFiles -LegacyPattern "$CsCfg"
    Write-Host "serviceConfigFile= $serviceConfigFile"
    $serviceConfigFile = Get-SingleFile $serviceConfigFile $CsCfg

    Write-Host "Find-VstsFiles -LegacyPattern $CsPkg"
    $servicePackageFile = Find-VstsFiles -LegacyPattern "$CsPkg"
    Write-Host "servicePackageFile= $servicePackageFile"
    $servicePackageFile = Get-SingleFile $servicePackageFile $CsPkg

    $label = $DeploymentLabel
    if ($label -and $AppendDateTimeToLabel) {
        $label += " "
        $label += [datetime]::now
    }
    $tag=@{}
    if ($label) {
        $tag["Label"] = $label
    }

    $diagnosticExtensions = Get-DiagnosticsExtensions $ServiceName $StorageAccount $serviceConfigFile $storageAccountKeysMap

    Write-Host "##[command]Get-AzCloudService -Name $ServiceName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue -ErrorVariable azureServiceError"
    $azureService = Get-AzCloudService -Name $ServiceName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue -ErrorVariable azureServiceError
    if ($azureServiceError) {
       $azureServiceError | ForEach-Object { Write-Verbose $_.Exception.ToString() }
    }

    if (!$azureService) {
        Create-AzureCloudService $ServiceName $ResourceGroupName $ServiceLocation $CsCfg $CsDef $CsPkg $StorageAccount $tag $KeyVault $diagnosticExtensions $UpgradeMode
    }
    elseif ($AllowUpgrade -eq $false) {
        #Remove and then Re-create
        Write-Host "##[command]Remove-AzCloudService -Name $ServiceName -ResourceGroupName $ResourceGroupName"
        Remove-AzCloudService -Name $ServiceName -ResourceGroupName $ResourceGroupName
        Create-AzureCloudService $ServiceName $ResourceGroupName $ServiceLocation $CsCfg $CsDef $CsPkg $StorageAccount $tag $KeyVault $diagnosticExtensions $UpgradeMode
    }
    else {
        $tagChanged = $false
        foreach ($key in $tag.Keys) {
            if (!$azureService.Tag.ContainsKey($key) -or ($tag[$key] -ne $azureService.Tag[$key])) {
                $azureService.Tag[$key] = $tag[$key]
                Write-Host "Updating a tag with [$key=$($tag[$key])]"
                $tagChanged = $true
            }
        }
        if (!$UpgradeMode) {
            $UpgradeMode = "Auto"
        }
        $upgradeModeChanged = $azureService.UpgradeMode -ne $UpgradeMode
        if ($tagChanged -or $upgradeModeChanged) {
            if ($upgradeModeChanged) {
                Write-Host "Updating upgrade mode to $UpgradeMode"
                $azureService.UpgradeMode = $UpgradeMode
            }
            Write-Host "##[command]Update-AzCloudService"
            $azureService | Update-AzCloudService
        }
    }

    if ($VerifyRoleInstanceStatus -eq $true) {
        Validate-AzureCloudServiceStatus -cloudServiceName $ServiceName -resourceGroupName $ResourceGroupName
    }
} finally {
	Trace-VstsLeavingInvocation $MyInvocation
}
