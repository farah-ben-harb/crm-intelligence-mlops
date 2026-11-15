[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('@sha256:[0-9a-f]{64}$')][string]$Image,
    [Parameter(Mandatory=$true)][string]$ModelPath,
    [Parameter(Mandatory=$true)][string]$ModelVersion,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ModelSha256,
    [string]$InstanceId = "i-049bfd217926eb2b2",
    [string]$Profile = "mini-crm",
    [string]$Region = "eu-north-1",
    [string]$LogGroupName = "/mini-crm/api",
    [string]$ModelSource = "",
    [switch]$UseCloudWatchLogs,
    [switch]$WhatIf
)

# Compatibility entry point with the mission's explicit name. The implementation
# and safety checks remain centralized in deploy-production.ps1.
$implementation = Join-Path $PSScriptRoot "deploy-production.ps1"
& $implementation @PSBoundParameters
exit $LASTEXITCODE
