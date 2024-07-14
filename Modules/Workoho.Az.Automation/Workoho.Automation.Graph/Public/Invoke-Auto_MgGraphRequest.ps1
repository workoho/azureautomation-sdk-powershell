<#
.SYNOPSIS
    Wrapper for Invoke-MgGraphRequest to add retries for rate limiting and service unavailable errors.

.DESCRIPTION
    This script is a wrapper for the Invoke-MgGraphRequest script to add retries in case of rate limiting or service unavailable errors.
    The script will retry the request up to 5 times with an exponential backoff strategy. The script will also handle the Retry-After header for rate limiting errors.
    Note that when using batch requests, each response must be checked for rate limiting separately as this script only handles this for the batch request itself.

.PARAMETER Params
    The parameters to pass to the Invoke-MgGraphRequest cmdlet using splatting.

.OUTPUTS
    The response from the Microsoft Graph REST API request.
#>

function Invoke-Auto_MgGraphRequest {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Params
    )

    Write-Auto_FunctionBegin $MyInvocation -OnceOnly

    $maxRetries = 5
    $retryCount = 0
    $baseWaitTime = 1 # start with 1 second

    do {
        try {
            $response = Invoke-MgGraphRequest @Params
            $rateLimitExceeded = $false
        }
        catch {
            if ($null -eq $_.Exception.Response) {
                Throw "Network error: $($_.Exception.Message)"
            }
            if ($_.Exception.Response.StatusCode -eq 404) {
                $rateLimitExceeded = $false
            }
            elseif (
                $_.Exception.Response.StatusCode -eq 429 -or
                $_.Exception.Response.StatusCode -eq 503
            ) {
                $waitTime = [math]::max($_.Exception.Response.Headers['Retry-After'] -as [int], $baseWaitTime)
                $jitter = Get-Random -Minimum 0 -Maximum 0.5 # random jitter between 0 and 0.5 seconds, with decimal precision
                $waitTime += $jitter
                Clear-Variable -Name response
                [System.GC]::Collect()
                [System.GC]::WaitForPendingFinalizers()

                if ($_.Exception.Response.StatusCode -eq 429) {
                    Write-Verbose "[COMMON]: - Rate limit exceeded, retrying in $waitTime seconds..."
                }
                else {
                    Write-Verbose "[COMMON]: - Service unavailable, retrying in $waitTime seconds..."
                }

                Start-Sleep -Milliseconds ($waitTime * 1000) # convert wait time to milliseconds for Start-Sleep
                $retryCount++
                $baseWaitTime *= 1.5 # client side exponential backoff
                $rateLimitExceeded = $true
            }
            else {
                $errorMessage = $_.Exception.Response.Content.ReadAsStringAsync().Result | ConvertFrom-Json
                Throw "Error $($_.Exception.Response.StatusCode.value__) $($_.Exception.Response.StatusCode): [$($errorMessage.error.code)] $($errorMessage.error.message)"
            }
        }
    } while ($rateLimitExceeded -and $retryCount -lt $maxRetries)

    if ($rateLimitExceeded) {
        Throw "Rate limit exceeded after $maxRetries retries."
    }

    Write-Auto_FunctionEnd $MyInvocation -OnceOnly
    return $response
}