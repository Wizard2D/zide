[cmdletbinding()]
param(
   [string]$Channel="LTS",
   [string]$Quality,
   [string]$Version="Latest",
   [switch]$Internal,
   [string]$JSonFile,
   [string]$InstallDir="<auto>",
   [string]$Architecture="<auto>",
   [string]$Runtime,
   [Obsolete("This parameter may be removed in a future version of this script. The recommended alternative is '-Runtime dotnet'.")]
   [switch]$SharedRuntime,
   [switch]$DryRun,
   [switch]$NoPath,
   [string]$AzureFeed="https://dotnetcli.azureedge.net/dotnet",
   [string]$UncachedFeed="https://dotnetcli.blob.core.windows.net/dotnet",
   [string]$FeedCredential,
   [string]$ProxyAddress,
   [switch]$ProxyUseDefaultCredentials,
   [string[]]$ProxyBypassList=@(),
   [switch]$SkipNonVersionedFiles,
   [switch]$NoCdn
)

Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
$ProgressPreference="SilentlyContinue"

if ($NoCdn) {
    $AzureFeed = $UncachedFeed
}

$BinFolderRelativePath=""

if ($SharedRuntime -and (-not $Runtime)) {
    $Runtime = "dotnet"
}

# example path with regex: shared/1.0.0-beta-12345/somepath
$VersionRegEx="/\d+\.\d+[^/]+/"
$OverrideNonVersionedFiles = !$SkipNonVersionedFiles

function Say($str) {
    try {
        Write-Host "dotnet-install: $str"
    }
    catch {
        # Some platforms cannot utilize Write-Host (Azure Functions, for instance). Fall back to Write-Output
        Write-Output "dotnet-install: $str"
    }
}

function Say-Warning($str) {
    try {
        Write-Warning "dotnet-install: $str"
    }
    catch {
        # Some platforms cannot utilize Write-Warning (Azure Functions, for instance). Fall back to Write-Output
        Write-Output "dotnet-install: Warning: $str"
    }
}

# Writes a line with error style settings.
# Use this function to show a human-readable comment along with an exception.
function Say-Error($str) {
    try {
        # Write-Error is quite oververbose for the purpose of the function, let's write one line with error style settings.
        $Host.UI.WriteErrorLine("dotnet-install: $str")
    }
    catch {
        Write-Output "dotnet-install: Error: $str"
    }
}

function Say-Verbose($str) {
    try {
        Write-Verbose "dotnet-install: $str"
    }
    catch {
        # Some platforms cannot utilize Write-Verbose (Azure Functions, for instance). Fall back to Write-Output
        Write-Output "dotnet-install: $str"
    }
}

function Say-Invocation($Invocation) {
    $command = $Invocation.MyCommand;
    $args = (($Invocation.BoundParameters.Keys | foreach { "-$_ `"$($Invocation.BoundParameters[$_])`"" }) -join " ")
    Say-Verbose "$command $args"
}

function Invoke-With-Retry([ScriptBlock]$ScriptBlock, [int]$MaxAttempts = 3, [int]$SecondsBetweenAttempts = 1) {
    $Attempts = 0

    while ($true) {
        try {
            return & $ScriptBlock
        }
        catch {
            $Attempts++
            if ($Attempts -lt $MaxAttempts) {
                Start-Sleep $SecondsBetweenAttempts
            }
            else {
                throw
            }
        }
    }
}

function Get-Machine-Architecture() {
    Say-Invocation $MyInvocation

    # On PS x86, PROCESSOR_ARCHITECTURE reports x86 even on x64 systems.
    # To get the correct architecture, we need to use PROCESSOR_ARCHITEW6432.
    # PS x64 doesn't define this, so we fall back to PROCESSOR_ARCHITECTURE.
    # Possible values: amd64, x64, x86, arm64, arm

    if( $ENV:PROCESSOR_ARCHITEW6432 -ne $null )
    {    
        return $ENV:PROCESSOR_ARCHITEW6432
    }

    return $ENV:PROCESSOR_ARCHITECTURE
}

function Get-CLIArchitecture-From-Architecture([string]$Architecture) {
    Say-Invocation $MyInvocation

    switch ($Architecture.ToLowerInvariant()) {
        { $_ -eq "<auto>" } { return Get-CLIArchitecture-From-Architecture $(Get-Machine-Architecture) }
        { ($_ -eq "amd64") -or ($_ -eq "x64") } { return "x64" }
        { $_ -eq "x86" } { return "x86" }
        { $_ -eq "arm" } { return "arm" }
        { $_ -eq "arm64" } { return "arm64" }
        default { throw "Architecture '$Architecture' not supported. If you think this is a bug, report it at https://github.com/dotnet/install-scripts/issues" }
    }
}


function Get-NormalizedQuality([string]$Quality) {
    Say-Invocation $MyInvocation

    if ([string]::IsNullOrEmpty($Quality)) {
        return ""
    }

    switch ($Quality) {
        { @("daily", "signed", "validated", "preview") -contains $_ } { return $Quality.ToLowerInvariant() }
        #ga quality is available without specifying quality, so normalizing it to empty
        { $_ -eq "ga" } { return "" }
        default { throw "'$Quality' is not a supported value for -Quality option. Supported values are: daily, signed, validated, preview, ga. If you think this is a bug, report it at https://github.com/dotnet/install-scripts/issues." }
    }
}

function Get-NormalizedChannel([string]$Channel) {
    Say-Invocation $MyInvocation

    if ([string]::IsNullOrEmpty($Channel)) {
        return ""
    }

    if ($Channel.StartsWith('release/')) {
        Say-Warning 'Using branch name with -Channel option is no longer supported with newer releases. Use -Quality option with a channel in X.Y format instead, such as "-Channel 5.0 -Quality Daily."'
    }

    switch ($Channel) {
        { $_ -eq "lts" } { return "LTS" }
        { $_ -eq "current" } { return "current" }
        default { return $Channel.ToLowerInvariant() }
    }
}

function Get-NormalizedProduct([string]$Runtime) {
    Say-Invocation $MyInvocation

    switch ($Runtime) {
        { $_ -eq "dotnet" } { return "dotnet-runtime" }
        { $_ -eq "aspnetcore" } { return "aspnetcore-runtime" }
        { $_ -eq "windowsdesktop" } { return "windowsdesktop-runtime" }
        { [string]::IsNullOrEmpty($_) } { return "dotnet-sdk" }
        default { throw "'$Runtime' is not a supported value for -Runtime option, supported values are: dotnet, aspnetcore, windowsdesktop. If you think this is a bug, report it at https://github.com/dotnet/install-scripts/issues." }
    }
}


# The version text returned from the feeds is a 1-line or 2-line string:
# For the SDK and the dotnet runtime (2 lines):
# Line 1: # commit_hash
# Line 2: # 4-part version
# For the aspnetcore runtime (1 line):
# Line 1: # 4-part version
function Get-Version-Info-From-Version-Text([string]$VersionText) {
    Say-Invocation $MyInvocation

    $Data = -split $VersionText

    $VersionInfo = @{
        CommitHash = $(if ($Data.Count -gt 1) { $Data[0] })
        Version = $Data[-1] # last line is always the version number.
    }
    return $VersionInfo
}

function Load-Assembly([string] $Assembly) {
    try {
        Add-Type -Assembly $Assembly | Out-Null
    }
    catch {
        # On Nano Server, Powershell Core Edition is used.  Add-Type is unable to resolve base class assemblies because they are not GAC'd.
        # Loading the base class assemblies is not unnecessary as the types will automatically get resolved.
    }
}

function GetHTTPResponse([Uri] $Uri, [bool]$HeaderOnly, [bool]$DisableRedirect, [bool]$DisableFeedCredential)
{
    Invoke-With-Retry(
    {

        $HttpClient = $null

        try {
            # HttpClient is used vs Invoke-WebRequest in order to support Nano Server which doesn't support the Invoke-WebRequest cmdlet.
            Load-Assembly -Assembly System.Net.Http

            if(-not $ProxyAddress) {
                try {
                    # Despite no proxy being explicitly specified, we may still be behind a default proxy
                    $DefaultProxy = [System.Net.WebRequest]::DefaultWebProxy;
                    if($DefaultProxy -and (-not $DefaultProxy.IsBypassed($Uri))) {
                        $ProxyAddress = $DefaultProxy.GetProxy($Uri).OriginalString
                        $ProxyUseDefaultCredentials = $true
                    }
                } catch {
                    # Eat the exception and move forward as the above code is an attempt
                    #    at resolving the DefaultProxy that may not have been a problem.
                    $ProxyAddress = $null
                    Say-Verbose("Exception ignored: $_.Exception.Message - moving forward...")
                }
            }

            $HttpClientHandler = New-Object System.Net.Http.HttpClientHandler
            if($ProxyAddress) {
                $HttpClientHandler.Proxy =  New-Object System.Net.WebProxy -Property @{
                    Address=$ProxyAddress;
                    UseDefaultCredentials=$ProxyUseDefaultCredentials;
                    BypassList = $ProxyBypassList;
                }
            }       
            if ($DisableRedirect)
            {
                $HttpClientHandler.AllowAutoRedirect = $false
            }
            $HttpClient = New-Object System.Net.Http.HttpClient -ArgumentList $HttpClientHandler

            # Default timeout for HttpClient is 100s.  For a 50 MB download this assumes 500 KB/s average, any less will time out
            # 20 minutes allows it to work over much slower connections.
            $HttpClient.Timeout = New-TimeSpan -Minutes 20

            if ($HeaderOnly){
                $completionOption = [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            }
            else {
                $completionOption = [System.Net.Http.HttpCompletionOption]::ResponseContentRead
            }

            if ($DisableFeedCredential) {
                $UriWithCredential = $Uri
            }
            else {
                $UriWithCredential = "${Uri}${FeedCredential}"
            }

            $Task = $HttpClient.GetAsync("$UriWithCredential", $completionOption).ConfigureAwait("false");
            $Response = $Task.GetAwaiter().GetResult();

            if (($null -eq $Response) -or ((-not $HeaderOnly) -and (-not ($Response.IsSuccessStatusCode)))) {
                # The feed credential is potentially sensitive info. Do not log FeedCredential to console output.
                $DownloadException = [System.Exception] "Unable to download $Uri."

                if ($null -ne $Response) {
                    $DownloadException.Data["StatusCode"] = [int] $Response.StatusCode
                    $DownloadException.Data["ErrorMessage"] = "Unable to download $Uri. Returned HTTP status code: " + $DownloadException.Data["StatusCode"]
                }

                throw $DownloadException
            }

            return $Response
        }
        catch [System.Net.Http.HttpRequestException] {
            $DownloadException = [System.Exception] "Unable to download $Uri."

            # Pick up the exception message and inner exceptions' messages if they exist
            $CurrentException = $PSItem.Exception
            $ErrorMsg = $CurrentException.Message + "`r`n"
            while ($CurrentException.InnerException) {
              $CurrentException = $CurrentException.InnerException
              $ErrorMsg += $CurrentException.Message + "`r`n"
            }

            # Check if there is an issue concerning TLS.
            if ($ErrorMsg -like "*SSL/TLS*") {
                $ErrorMsg += "Ensure that TLS 1.2 or higher is enabled to use this script.`r`n"
            }

            $DownloadException.Data["ErrorMessage"] = $ErrorMsg
            throw $DownloadException
        }
        finally {
             if ($HttpClient -ne $null) {
                $HttpClient.Dispose()
            }
        }
    })
}

function Get-Latest-Version-Info([string]$AzureFeed, [string]$Channel) {
    Say-Invocation $MyInvocation

    $VersionFileUrl = $null
    if ($Runtime -eq "dotnet") {
        $VersionFileUrl = "$UncachedFeed/Runtime/$Channel/latest.version"
    }
    elseif ($Runtime -eq "aspnetcore") {
        $VersionFileUrl = "$UncachedFeed/aspnetcore/Runtime/$Channel/latest.version"
    }
    elseif ($Runtime -eq "windowsdesktop") {
        $VersionFileUrl = "$UncachedFeed/WindowsDesktop/$Channel/latest.version"
    }
    elseif (-not $Runtime) {
        $VersionFileUrl = "$UncachedFeed/Sdk/$Channel/latest.version"
    }
    else {
        throw "Invalid value for `$Runtime"
    }

    Say-Verbose "Constructed latest.version URL: $VersionFileUrl"

    try {
        $Response = GetHTTPResponse -Uri $VersionFileUrl
    }
    catch {
        Say-Error "Could not resolve version information."
        throw
    }
    $StringContent = $Response.Content.ReadAsStringAsync().Result

    switch ($Response.Content.Headers.ContentType) {
        { ($_ -eq "application/octet-stream") } { $VersionText = $StringContent }
        { ($_ -eq "text/plain") } { $VersionText = $StringContent }
        { ($_ -eq "text/plain; charset=UTF-8") } { $VersionText = $StringContent }
        default { throw "``$Response.Content.Headers.ContentType`` is an unknown .version file content type." }
    }

    $VersionInfo = Get-Version-Info-From-Version-Text $VersionText

    return $VersionInfo
}

function Parse-Jsonfile-For-Version([string]$JSonFile) {
    Say-Invocation $MyInvocation

    If (-Not (Test-Path $JSonFile)) {
        throw "Unable to find '$JSonFile'"
    }
    try {
        $JSonContent = Get-Content($JSonFile) -Raw | ConvertFrom-Json | Select-Object -expand "sdk" -ErrorAction SilentlyContinue
    }
    catch {
        Say-Error "Json file unreadable: '$JSonFile'"
        throw
    }
    if ($JSonContent) {
        try {
            $JSonContent.PSObject.Properties | ForEach-Object {
                $PropertyName = $_.Name
                if ($PropertyName -eq "version") {
                    $Version = $_.Value
                    Say-Verbose "Version = $Version"
                }
            }
        }
        catch {
            Say-Error "Unable to parse the SDK node in '$JSonFile'"
            throw
        }
    }
    else {
        throw "Unable to find the SDK node in '$JSonFile'"
    }
    If ($Version -eq $null) {
        throw "Unable to find the SDK:version node in '$JSonFile'"
    }
    return $Version
}

function Get-Specific-Version-From-Version([string]$AzureFeed, [string]$Channel, [string]$Version, [string]$JSonFile) {
    Say-Invocation $MyInvocation

    if (-not $JSonFile) {
        if ($Version.ToLowerInvariant() -eq "latest") {
            $LatestVersionInfo = Get-Latest-Version-Info -AzureFeed $AzureFeed -Channel $Channel
            return $LatestVersionInfo.Version
        }
        else {
            return $Version 
        }
    }
    else {
        return Parse-Jsonfile-For-Version $JSonFile
    }
}

function Get-Download-Link([string]$AzureFeed, [string]$SpecificVersion, [string]$CLIArchitecture) {
    Say-Invocation $MyInvocation

    # If anything fails in this lookup it will default to $SpecificVersion
    $SpecificProductVersion = Get-Product-Version -AzureFeed $AzureFeed -SpecificVersion $SpecificVersion

    if ($Runtime -eq "dotnet") {
        $PayloadURL = "$AzureFeed/Runtime/$SpecificVersion/dotnet-runtime-$SpecificProductVersion-win-$CLIArchitecture.zip"
    }
    elseif ($Runtime -eq "aspnetcore") {
        $PayloadURL = "$AzureFeed/aspnetcore/Runtime/$SpecificVersion/aspnetcore-runtime-$SpecificProductVersion-win-$CLIArchitecture.zip"
    }
    elseif ($Runtime -eq "windowsdesktop") {
        # The windows desktop runtime is part of the core runtime layout prior to 5.0
        $PayloadURL = "$AzureFeed/Runtime/$SpecificVersion/windowsdesktop-runtime-$SpecificProductVersion-win-$CLIArchitecture.zip"
        if ($SpecificVersion -match '^(\d+)\.(.*)$')
        {
            $majorVersion = [int]$Matches[1]
            if ($majorVersion -ge 5)
            {
                $PayloadURL = "$AzureFeed/WindowsDesktop/$SpecificVersion/windowsdesktop-runtime-$SpecificProductVersion-win-$CLIArchitecture.zip"
            }
        }
    }
    elseif (-not $Runtime) {
        $PayloadURL = "$AzureFeed/Sdk/$SpecificVersion/dotnet-sdk-$SpecificProductVersion-win-$CLIArchitecture.zip"
    }
    else {
        throw "Invalid value for `$Runtime"
    }

    Say-Verbose "Constructed primary named payload URL: $PayloadURL"

    return $PayloadURL, $SpecificProductVersion
}

function Get-LegacyDownload-Link([string]$AzureFeed, [string]$SpecificVersion, [string]$CLIArchitecture) {
    Say-Invocation $MyInvocation

    if (-not $Runtime) {
        $PayloadURL = "$AzureFeed/Sdk/$SpecificVersion/dotnet-dev-win-$CLIArchitecture.$SpecificVersion.zip"
    }
    elseif ($Runtime -eq "dotnet") {
        $PayloadURL = "$AzureFeed/Runtime/$SpecificVersion/dotnet-win-$CLIArchitecture.$SpecificVersion.zip"
    }
    else {
        return $null
    }

    Say-Verbose "Constructed legacy named payload URL: $PayloadURL"

    return $PayloadURL
}

function Get-Product-Version([string]$AzureFeed, [string]$SpecificVersion, [string]$PackageDownloadLink) {
    Say-Invocation $MyInvocation

    # Try to get the version number, using the productVersion.txt file located next to the installer file.
    $ProductVersionTxtURLs = (Get-Product-Version-Url $AzureFeed $SpecificVersion $PackageDownloadLink -Flattened $true),
                             (Get-Product-Version-Url $AzureFeed $SpecificVersion $PackageDownloadLink -Flattened $false)
    
    Foreach ($ProductVersionTxtURL in $ProductVersionTxtURLs) {
        Say-Verbose "Checking for the existence of $ProductVersionTxtURL"

        try {
            $productVersionResponse = GetHTTPResponse($productVersionTxtUrl)

            if ($productVersionResponse.StatusCode -eq 200) {
                $productVersion = $productVersionResponse.Content.ReadAsStringAsync().Result.Trim()
                if ($productVersion -ne $SpecificVersion)
                {
                    Say "Using alternate version $productVersion found in $ProductVersionTxtURL"
                }
                return $productVersion
            }
            else {
                Say-Verbose "Got StatusCode $($productVersionResponse.StatusCode) when trying to get productVersion.txt at $productVersionTxtUrl."
            }
        } 
        catch {
            Say-Verbose "Could not read productVersion.txt at $productVersionTxtUrl (Exception: '$($_.Exception.Message)'. )"
        }
    }

    # Getting the version number with productVersion.txt has failed. Try parsing the download link for a version number.
    if ([string]::IsNullOrEmpty($PackageDownloadLink))
    {
        Say-Verbose "Using the default value '$SpecificVersion' as the product version."
        return $SpecificVersion
    }

    $productVersion = Get-ProductVersionFromDownloadLink $PackageDownloadLink $SpecificVersion
    return $productVersion
}

function Get-Product-Version-Url([string]$AzureFeed, [string]$SpecificVersion, [string]$PackageDownloadLink, [bool]$Flattened) {
    Say-Invocation $MyInvocation

    $majorVersion=$null
    if ($SpecificVersion -match '^(\d+)\.(.*)') {
        $majorVersion = $Matches[1] -as[int]
    }

    $pvFileName='productVersion.txt'
    if($Flattened) {
        if(-not $Runtime) {
            $pvFileName='sdk-productVersion.txt'
        }
        elseif($Runtime -eq "dotnet") {
            $pvFileName='runtime-productVersion.txt'
        }
        else {
            $pvFileName="$Runtime-productVersion.txt"
        }
    }

    if ([string]::IsNullOrEmpty($PackageDownloadLink)) {
        if ($Runtime -eq "dotnet") {
            $ProductVersionTxtURL = "$AzureFeed/Runtime/$SpecificVersion/$pvFileName"
        }
        elseif ($Runtime -eq "aspnetcore") {
            $ProductVersionTxtURL = "$AzureFeed/aspnetcore/Runtime/$SpecificVersion/$pvFileName"
        }
        elseif ($Runtime -eq "windowsdesktop") {
            # The windows desktop runtime is part of the core runtime layout prior to 5.0
            $ProductVersionTxtURL = "$AzureFeed/Runtime/$SpecificVersion/$pvFileName"
            if ($majorVersion -ne $null -and $majorVersion -ge 5) {
                $ProductVersionTxtURL = "$AzureFeed/WindowsDesktop/$SpecificVersion/$pvFileName"
            }
        }
        elseif (-not $Runtime) {
            $ProductVersionTxtURL = "$AzureFeed/Sdk/$SpecificVersion/$pvFileName"
        }
        else {
            throw "Invalid value '$Runtime' specified for `$Runtime"
        }
    }
    else {
        $ProductVersionTxtURL = $PackageDownloadLink.Substring(0, $PackageDownloadLink.LastIndexOf("/"))  + "/$pvFileName"
    }

    Say-Verbose "Constructed productVersion link: $ProductVersionTxtURL"

    return $ProductVersionTxtURL
}

function Get-ProductVersionFromDownloadLink([string]$PackageDownloadLink, [string]$SpecificVersion)
{
    Say-Invocation $MyInvocation

    #product specific version follows the product name
    #for filename 'dotnet-sdk-3.1.404-win-x64.zip': the product version is 3.1.400
    $filename = $PackageDownloadLink.Substring($PackageDownloadLink.LastIndexOf("/") + 1)
    $filenameParts = $filename.Split('-')
    if ($filenameParts.Length -gt 2)
    {
        $productVersion = $filenameParts[2]
        Say-Verbose "Extracted product version '$productVersion' from download link '$PackageDownloadLink'."
    }
    else {
        Say-Verbose "Using the default value '$SpecificVersion' as the product version."
        $productVersion = $SpecificVersion
    }
    return $productVersion 
}

function Get-User-Share-Path() {
    Say-Invocation $MyInvocation

    $InstallRoot = $env:DOTNET_INSTALL_DIR
    if (!$InstallRoot) {
        $InstallRoot = "$env:LocalAppData\Microsoft\dotnet"
    }
    return $InstallRoot
}

function Resolve-Installation-Path([string]$InstallDir) {
    Say-Invocation $MyInvocation

    if ($InstallDir -eq "<auto>") {
        return Get-User-Share-Path
    }
    return $InstallDir
}

function Is-Dotnet-Package-Installed([string]$InstallRoot, [string]$RelativePathToPackage, [string]$SpecificVersion) {
    Say-Invocation $MyInvocation

    $DotnetPackagePath = Join-Path -Path $InstallRoot -ChildPath $RelativePathToPackage | Join-Path -ChildPath $SpecificVersion
    Say-Verbose "Is-Dotnet-Package-Installed: DotnetPackagePath=$DotnetPackagePath"
    return Test-Path $DotnetPackagePath -PathType Container
}

function Get-Absolute-Path([string]$RelativeOrAbsolutePath) {
    # Too much spam
    # Say-Invocation $MyInvocation

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RelativeOrAbsolutePath)
}

function Get-Path-Prefix-With-Version($path) {
    $match = [regex]::match($path, $VersionRegEx)
    if ($match.Success) {
        return $entry.FullName.Substring(0, $match.Index + $match.Length)
    }

    return $null
}

function Get-List-Of-Directories-And-Versions-To-Unpack-From-Dotnet-Package([System.IO.Compression.ZipArchive]$Zip, [string]$OutPath) {
    Say-Invocation $MyInvocation

    $ret = @()
    foreach ($entry in $Zip.Entries) {
        $dir = Get-Path-Prefix-With-Version $entry.FullName
        if ($dir -ne $null) {
            $path = Get-Absolute-Path $(Join-Path -Path $OutPath -ChildPath $dir)
            if (-Not (Test-Path $path -PathType Container)) {
                $ret += $dir
            }
        }
    }

    $ret = $ret | Sort-Object | Get-Unique

    $values = ($ret | foreach { "$_" }) -join ";"
    Say-Verbose "Directories to unpack: $values"

    return $ret
}

# Example zip content and extraction algorithm:
# Rule: files if extracted are always being extracted to the same relative path locally
# .\
#       a.exe   # file does not exist locally, extract
#       b.dll   # file exists locally, override only if $OverrideFiles set
#       aaa\    # same rules as for files
#           ...
#       abc\1.0.0\  # directory contains version and exists locally
#           ...     # do not extract content under versioned part
#       abc\asd\    # same rules as for files
#            ...
#       def\ghi\1.0.1\  # directory contains version and does not exist locally
#           ...         # extract content
function Extract-Dotnet-Package([string]$ZipPath, [string]$OutPath) {
    Say-Invocation $MyInvocation

    Load-Assembly -Assembly System.IO.Compression.FileSystem
    Set-Variable -Name Zip
    try {
        $Zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)

        $DirectoriesToUnpack = Get-List-Of-Directories-And-Versions-To-Unpack-From-Dotnet-Package -Zip $Zip -OutPath $OutPath

        foreach ($entry in $Zip.Entries) {
            $PathWithVersion = Get-Path-Prefix-With-Version $entry.FullName
            if (($PathWithVersion -eq $null) -Or ($DirectoriesToUnpack -contains $PathWithVersion)) {
                $DestinationPath = Get-Absolute-Path $(Join-Path -Path $OutPath -ChildPath $entry.FullName)
                $DestinationDir = Split-Path -Parent $DestinationPath
                $OverrideFiles=$OverrideNonVersionedFiles -Or (-Not (Test-Path $DestinationPath))
                if ((-Not $DestinationPath.EndsWith("\")) -And $OverrideFiles) {
                    New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $DestinationPath, $OverrideNonVersionedFiles)
                }
            }
        }
    }
    finally {
        if ($Zip -ne $null) {
            $Zip.Dispose()
        }
    }
}

function DownloadFile($Source, [string]$OutPath) {
    if ($Source -notlike "http*") {
        #  Using System.IO.Path.GetFullPath to get the current directory
        #    does not work in this context - $pwd gives the current directory
        if (![System.IO.Path]::IsPathRooted($Source)) {
            $Source = $(Join-Path -Path $pwd -ChildPath $Source)
        }
        $Source = Get-Absolute-Path $Source
        Say "Copying file from $Source to $OutPath"
        Copy-Item $Source $OutPath
        return
    }

    $Stream = $null

    try {
        $Response = GetHTTPResponse -Uri $Source
        $Stream = $Response.Content.ReadAsStreamAsync().Result
        $File = [System.IO.File]::Create($OutPath)
        $Stream.CopyTo($File)
        $File.Close()
    }
    finally {
        if ($Stream -ne $null) {
            $Stream.Dispose()
        }
    }
}

function SafeRemoveFile($Path) {
    try {
        if (Test-Path $Path) {
            Remove-Item $Path
            Say-Verbose "The temporary file `"$Path`" was removed."
        }
        else
        {
            Say-Verbose "The temporary file `"$Path`" does not exist, therefore is not removed."
        }
    }
    catch
    {
        Say-Warning "Failed to remove the temporary file: `"$Path`", remove it manually."
    }
}

function Prepend-Sdk-InstallRoot-To-Path([string]$InstallRoot, [string]$BinFolderRelativePath) {
    $BinPath = Get-Absolute-Path $(Join-Path -Path $InstallRoot -ChildPath $BinFolderRelativePath)
    if (-Not $NoPath) {
        $SuffixedBinPath = "$BinPath;"
        if (-Not $env:path.Contains($SuffixedBinPath)) {
            Say "Adding to current process PATH: `"$BinPath`". Note: This change will not be visible if PowerShell was run as a child process."
            $env:path = $SuffixedBinPath + $env:path
        } else {
            Say-Verbose "Current process PATH already contains `"$BinPath`""
        }
    }
    else {
        Say "Binaries of dotnet can be found in $BinPath"
    }
}

function Get-AkaMSDownloadLink([string]$Channel, [string]$Quality, [bool]$Internal, [string]$Product, [string]$Architecture) {
    Say-Invocation $MyInvocation 

    #quality is not supported for LTS or current channel
    if (![string]::IsNullOrEmpty($Quality) -and (@("LTS", "current") -contains $Channel)) {
        $Quality = ""
        Say-Warning "Specifying quality for current or LTS channel is not supported, the quality will be ignored."
    }
    Say-Verbose "Retrieving primary payload URL from aka.ms link for channel: '$Channel', quality: '$Quality' product: '$Product', os: 'win', architecture: '$Architecture'." 
   
    #construct aka.ms link
    $akaMsLink = "https://aka.ms/dotnet"
    if ($Internal) {
        $akaMsLink += "/internal"
    }
    $akaMsLink += "/$Channel"
    if (-not [string]::IsNullOrEmpty($Quality)) {
        $akaMsLink +="/$Quality"
    }
    $akaMsLink +="/$Product-win-$Architecture.zip"
    Say-Verbose  "Constructed aka.ms link: '$akaMsLink'."
    $akaMsDownloadLink=$null

    for ($maxRedirections = 9; $maxRedirections -ge 0; $maxRedirections--)
    {
        #get HTTP response
        #do not pass credentials as a part of the $akaMsLink and do not apply credentials in the GetHTTPResponse function
        #otherwise the redirect link would have credentials as well
        #it would result in applying credentials twice to the resulting link and thus breaking it, and in echoing credentials to the output as a part of redirect link
        $Response= GetHTTPResponse -Uri $akaMsLink -HeaderOnly $true -DisableRedirect $true -DisableFeedCredential $true
        Say-Verbose "Received response:`n$Response"

        if ([string]::IsNullOrEmpty($Response)) {
            Say-Verbose "The link '$akaMsLink' is not valid: failed to get redirect location. The resource is not available."
            return $null
        }

        #if HTTP code is 301 (Moved Permanently), the redirect link exists
        if  ($Response.StatusCode -eq 301)
        {
            try {
                $akaMsDownloadLink = $Response.Headers.GetValues("Location")[0]

                if ([string]::IsNullOrEmpty($akaMsDownloadLink)) {
                    Say-Verbose "The link '$akaMsLink' is not valid: server returned 301 (Moved Permanently), but the headers do not contain the redirect location."
                    return $null
                }

                Say-Verbose "The redirect location retrieved: '$akaMsDownloadLink'."
                # This may yet be a link to another redirection. Attempt to retrieve the page again.
                $akaMsLink = $akaMsDownloadLink
                continue
            }
            catch {
                Say-Verbose "The link '$akaMsLink' is not valid: failed to get redirect location."
                return $null
            }
        }
        elseif ((($Response.StatusCode -lt 300) -or ($Response.StatusCode -ge 400)) -and (-not [string]::IsNullOrEmpty($akaMsDownloadLink)))
        {
            # Redirections have ended.
            return $akaMsDownloadLink
        }

        Say-Verbose "The link '$akaMsLink' is not valid: failed to retrieve the redirection location."
        return $null
    }

    Say-Verbose "Aka.ms links have redirected more than the maximum allowed redirections. This may be caused by a cyclic redirection of aka.ms links."
    return $null

}

Say "Note that the intended use of this script is for Continuous Integration (CI) scenarios, where:"
Say "- The SDK needs to be installed without user interaction and without admin rights."
Say "- The SDK installation doesn't need to persist across multiple CI runs."
Say "To set up a development environment or to run apps, use installers rather than this script. Visit https://dotnet.microsoft.com/download to get the installer.`r`n"

if ($Internal -and [string]::IsNullOrWhitespace($FeedCredential)) {
    $message = "Provide credentials via -FeedCredential parameter."
    if ($DryRun) {
        Say-Warning "$message"
    } else {
        throw "$message"
    }
}

#FeedCredential should start with "?", for it to be added to the end of the link.
#adding "?" at the beginning of the FeedCredential if needed.
if ((![string]::IsNullOrWhitespace($FeedCredential)) -and ($FeedCredential[0] -ne '?')) {
    $FeedCredential = "?" + $FeedCredential
}

$CLIArchitecture = Get-CLIArchitecture-From-Architecture $Architecture
$NormalizedQuality = Get-NormalizedQuality $Quality
Say-Verbose "Normalized quality: '$NormalizedQuality'"
$NormalizedChannel = Get-NormalizedChannel $Channel
Say-Verbose "Normalized channel: '$NormalizedChannel'"
$NormalizedProduct = Get-NormalizedProduct $Runtime
Say-Verbose "Normalized product: '$NormalizedProduct'"
$DownloadLink = $null

#try to get download location from aka.ms link
#not applicable when exact version is specified via command or json file
if ([string]::IsNullOrEmpty($JSonFile) -and ($Version -eq "latest")) {
    $AkaMsDownloadLink = Get-AkaMSDownloadLink -Channel $NormalizedChannel -Quality $NormalizedQuality -Internal $Internal -Product $NormalizedProduct -Architecture $CLIArchitecture
   
    if ([string]::IsNullOrEmpty($AkaMsDownloadLink)){
        if (-not [string]::IsNullOrEmpty($NormalizedQuality)) {
            # if quality is specified - exit with error - there is no fallback approach
            Say-Error "Failed to locate the latest version in the channel '$NormalizedChannel' with '$NormalizedQuality' quality for '$NormalizedProduct', os: 'win', architecture: '$CLIArchitecture'."
            Say-Error "Refer to: https://aka.ms/dotnet-os-lifecycle for information on .NET Core support."
            throw "aka.ms link resolution failure"
        }
        Say-Verbose "Falling back to latest.version file approach."
    }
    else {
        Say-Verbose "Retrieved primary named payload URL from aka.ms link: '$AkaMsDownloadLink'."
        $DownloadLink = $AkaMsDownloadLink
        Say-Verbose  "Downloading using legacy url will not be attempted."
        $LegacyDownloadLink = $null

        #get version from the path
        $pathParts = $DownloadLink.Split('/')
        if ($pathParts.Length -ge 2) { 
            $SpecificVersion = $pathParts[$pathParts.Length - 2]
            Say-Verbose "Version: '$SpecificVersion'."
        }
        else {
            Say-Error "Failed to extract the version from download link '$DownloadLink'."
        }

        #retrieve effective (product) version
        $EffectiveVersion = Get-Product-Version -AzureFeed $AzureFeed -SpecificVersion $SpecificVersion -PackageDownloadLink $DownloadLink
        Say-Verbose "Product version: '$EffectiveVersion'."
    }
}

if ([string]::IsNullOrEmpty($DownloadLink)) {
    $SpecificVersion = Get-Specific-Version-From-Version -AzureFeed $AzureFeed -Channel $Channel -Version $Version -JSonFile $JSonFile
    $DownloadLink, $EffectiveVersion = Get-Download-Link -AzureFeed $AzureFeed -SpecificVersion $SpecificVersion -CLIArchitecture $CLIArchitecture
    $LegacyDownloadLink = Get-LegacyDownload-Link -AzureFeed $AzureFeed -SpecificVersion $SpecificVersion -CLIArchitecture $CLIArchitecture
}


$InstallRoot = Resolve-Installation-Path $InstallDir
Say-Verbose "InstallRoot: $InstallRoot"
$ScriptName = $MyInvocation.MyCommand.Name

if ($DryRun) {
    Say "Payload URLs:"
    Say "Primary named payload URL: ${DownloadLink}"
    if ($LegacyDownloadLink) {
        Say "Legacy named payload URL: ${LegacyDownloadLink}"
    }
    $RepeatableCommand = ".\$ScriptName -Version `"$SpecificVersion`" -InstallDir `"$InstallRoot`" -Architecture `"$CLIArchitecture`""
    if ($Runtime -eq "dotnet") {
       $RepeatableCommand+=" -Runtime `"dotnet`""
    }
    elseif ($Runtime -eq "aspnetcore") {
       $RepeatableCommand+=" -Runtime `"aspnetcore`""
    }

    if (-not [string]::IsNullOrEmpty($NormalizedQuality))
    {
        $RepeatableCommand+=" -Quality `"$NormalizedQuality`""
    }

    foreach ($key in $MyInvocation.BoundParameters.Keys) {
        if (-not (@("Architecture","Channel","DryRun","InstallDir","Runtime","SharedRuntime","Version","Quality","FeedCredential") -contains $key)) {
            $RepeatableCommand+=" -$key `"$($MyInvocation.BoundParameters[$key])`""
        }
    }
    if ($MyInvocation.BoundParameters.Keys -contains "FeedCredential") {
        $RepeatableCommand+=" -FeedCredential `"<feedCredential>`""
    }
    Say "Repeatable invocation: $RepeatableCommand"
    if ($SpecificVersion -ne $EffectiveVersion)
    {
        Say "NOTE: Due to finding a version manifest with this runtime, it would actually install with version '$EffectiveVersion'"
    }

    return
}

if ($Runtime -eq "dotnet") {
    $assetName = ".NET Core Runtime"
    $dotnetPackageRelativePath = "shared\Microsoft.NETCore.App"
}
elseif ($Runtime -eq "aspnetcore") {
    $assetName = "ASP.NET Core Runtime"
    $dotnetPackageRelativePath = "shared\Microsoft.AspNetCore.App"
}
elseif ($Runtime -eq "windowsdesktop") {
    $assetName = ".NET Core Windows Desktop Runtime"
    $dotnetPackageRelativePath = "shared\Microsoft.WindowsDesktop.App"
}
elseif (-not $Runtime) {
    $assetName = ".NET Core SDK"
    $dotnetPackageRelativePath = "sdk"
}
else {
    throw "Invalid value for `$Runtime"
}

if ($SpecificVersion -ne $EffectiveVersion)
{
   Say "Performing installation checks for effective version: $EffectiveVersion"
   $SpecificVersion = $EffectiveVersion
}

#  Check if the SDK version is already installed.
$isAssetInstalled = Is-Dotnet-Package-Installed -InstallRoot $InstallRoot -RelativePathToPackage $dotnetPackageRelativePath -SpecificVersion $SpecificVersion
if ($isAssetInstalled) {
    Say "$assetName version $SpecificVersion is already installed."
    Prepend-Sdk-InstallRoot-To-Path -InstallRoot $InstallRoot -BinFolderRelativePath $BinFolderRelativePath
    return
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

$installDrive = $((Get-Item $InstallRoot -Force).PSDrive.Name);
$diskInfo = $null
try{
    $diskInfo = Get-PSDrive -Name $installDrive
}
catch{
    Say-Warning "Failed to check the disk space. Installation will continue, but it may fail if you do not have enough disk space."
}

if ( ($diskInfo -ne $null) -and ($diskInfo.Free / 1MB -le 100)) {
    throw "There is not enough disk space on drive ${installDrive}:"
}

$ZipPath = [System.IO.Path]::combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
Say-Verbose "Zip path: $ZipPath"

$DownloadFailed = $false

$PrimaryDownloadStatusCode = 0
$LegacyDownloadStatusCode = 0

$PrimaryDownloadFailedMsg = ""
$LegacyDownloadFailedMsg = ""

Say "Downloading primary link $DownloadLink"
try {
    DownloadFile -Source $DownloadLink -OutPath $ZipPath
}
catch {
    if ($PSItem.Exception.Data.Contains("StatusCode")) {
        $PrimaryDownloadStatusCode = $PSItem.Exception.Data["StatusCode"]
    }

    if ($PSItem.Exception.Data.Contains("ErrorMessage")) {
        $PrimaryDownloadFailedMsg = $PSItem.Exception.Data["ErrorMessage"]
    } else {
        $PrimaryDownloadFailedMsg = $PSItem.Exception.Message
    }

    if ($PrimaryDownloadStatusCode -eq 404) {
        Say "The resource at $DownloadLink is not available."
    } else {
        Say $PSItem.Exception.Message
    }

    SafeRemoveFile -Path $ZipPath

    if ($LegacyDownloadLink) {
        $DownloadLink = $LegacyDownloadLink
        $ZipPath = [System.IO.Path]::combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
        Say-Verbose "Legacy zip path: $ZipPath"
        Say "Downloading legacy link $DownloadLink"
        try {
            DownloadFile -Source $DownloadLink -OutPath $ZipPath
        }
        catch {
            if ($PSItem.Exception.Data.Contains("StatusCode")) {
                $LegacyDownloadStatusCode = $PSItem.Exception.Data["StatusCode"]
            }

            if ($PSItem.Exception.Data.Contains("ErrorMessage")) {
                $LegacyDownloadFailedMsg = $PSItem.Exception.Data["ErrorMessage"]
            } else {
                $LegacyDownloadFailedMsg = $PSItem.Exception.Message
            }

            if ($LegacyDownloadStatusCode -eq 404) {
                Say "The resource at $DownloadLink is not available."
            } else {
                Say $PSItem.Exception.Message
            }

            SafeRemoveFile -Path $ZipPath
            $DownloadFailed = $true
        }
    }
    else {
        $DownloadFailed = $true
    }
}

if ($DownloadFailed) {
    if (($PrimaryDownloadStatusCode -eq 404) -and ((-not $LegacyDownloadLink) -or ($LegacyDownloadStatusCode -eq 404))) {
        throw "Could not find `"$assetName`" with version = $SpecificVersion`nRefer to: https://aka.ms/dotnet-os-lifecycle for information on .NET Core support"
    } else {
        # 404-NotFound is an expected response if it goes from only one of the links, do not show that error.
        # If primary path is available (not 404-NotFound) then show the primary error else show the legacy error.
        if ($PrimaryDownloadStatusCode -ne 404) {
            throw "Could not download `"$assetName`" with version = $SpecificVersion`r`n$PrimaryDownloadFailedMsg"
        }
        if (($LegacyDownloadLink) -and ($LegacyDownloadStatusCode -ne 404)) {
            throw "Could not download `"$assetName`" with version = $SpecificVersion`r`n$LegacyDownloadFailedMsg"
        }
        throw "Could not download `"$assetName`" with version = $SpecificVersion"
    }
}

Say "Extracting zip from $DownloadLink"
Extract-Dotnet-Package -ZipPath $ZipPath -OutPath $InstallRoot

#  Check if the SDK version is installed; if not, fail the installation.
$isAssetInstalled = $false

# if the version contains "RTM" or "servicing"; check if a 'release-type' SDK version is installed.
if ($SpecificVersion -Match "rtm" -or $SpecificVersion -Match "servicing") {
    $ReleaseVersion = $SpecificVersion.Split("-")[0]
    Say-Verbose "Checking installation: version = $ReleaseVersion"
    $isAssetInstalled = Is-Dotnet-Package-Installed -InstallRoot $InstallRoot -RelativePathToPackage $dotnetPackageRelativePath -SpecificVersion $ReleaseVersion
}

#  Check if the SDK version is installed.
if (!$isAssetInstalled) {
    Say-Verbose "Checking installation: version = $SpecificVersion"
    $isAssetInstalled = Is-Dotnet-Package-Installed -InstallRoot $InstallRoot -RelativePathToPackage $dotnetPackageRelativePath -SpecificVersion $SpecificVersion
}

# Version verification failed. More likely something is wrong either with the downloaded content or with the verification algorithm.
if (!$isAssetInstalled) {
    Say-Error "Failed to verify the version of installed `"$assetName`".`nInstallation source: $DownloadLink.`nInstallation location: $InstallRoot.`nReport the bug at https://github.com/dotnet/install-scripts/issues."
    throw "`"$assetName`" with version = $SpecificVersion failed to install with an unknown error."
}

SafeRemoveFile -Path $ZipPath

Prepend-Sdk-InstallRoot-To-Path -InstallRoot $InstallRoot -BinFolderRelativePath $BinFolderRelativePath

Say "Note that the script does not resolve dependencies during installation."
Say "To check the list of dependencies, go to https://docs.microsoft.com/dotnet/core/install/windows#dependencies"
Say "Installation finished"
# SIG # Begin signature block
# MIIjkgYJKoZIhvcNAQcCoIIjgzCCI38CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAGF/0aIv/nK8pL
# ube4cwR/nwps7FSM0D5vjXxuQe3LXaCCDYEwggX/MIID56ADAgECAhMzAAAB32vw
# LpKnSrTQAAAAAAHfMA0GCSqGSIb3DQEBCwUAMH4xCzAJBgNVBAYTAlVTMRMwEQYD
# VQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25p
# bmcgUENBIDIwMTEwHhcNMjAxMjE1MjEzMTQ1WhcNMjExMjAyMjEzMTQ1WjB0MQsw
# CQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9u
# ZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYDVQQDExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB
# AQC2uxlZEACjqfHkuFyoCwfL25ofI9DZWKt4wEj3JBQ48GPt1UsDv834CcoUUPMn
# s/6CtPoaQ4Thy/kbOOg/zJAnrJeiMQqRe2Lsdb/NSI2gXXX9lad1/yPUDOXo4GNw
# PjXq1JZi+HZV91bUr6ZjzePj1g+bepsqd/HC1XScj0fT3aAxLRykJSzExEBmU9eS
# yuOwUuq+CriudQtWGMdJU650v/KmzfM46Y6lo/MCnnpvz3zEL7PMdUdwqj/nYhGG
# 3UVILxX7tAdMbz7LN+6WOIpT1A41rwaoOVnv+8Ua94HwhjZmu1S73yeV7RZZNxoh
# EegJi9YYssXa7UZUUkCCA+KnAgMBAAGjggF+MIIBejAfBgNVHSUEGDAWBgorBgEE
# AYI3TAgBBggrBgEFBQcDAzAdBgNVHQ4EFgQUOPbML8IdkNGtCfMmVPtvI6VZ8+Mw
# UAYDVR0RBEkwR6RFMEMxKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVyYXRpb25zIFB1
# ZXJ0byBSaWNvMRYwFAYDVQQFEw0yMzAwMTIrNDYzMDA5MB8GA1UdIwQYMBaAFEhu
# ZOVQBdOCqhc3NyK1bajKdQKVMFQGA1UdHwRNMEswSaBHoEWGQ2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvY3JsL01pY0NvZFNpZ1BDQTIwMTFfMjAxMS0w
# Ny0wOC5jcmwwYQYIKwYBBQUHAQEEVTBTMFEGCCsGAQUFBzAChkVodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NlcnRzL01pY0NvZFNpZ1BDQTIwMTFfMjAx
# MS0wNy0wOC5jcnQwDAYDVR0TAQH/BAIwADANBgkqhkiG9w0BAQsFAAOCAgEAnnqH
# tDyYUFaVAkvAK0eqq6nhoL95SZQu3RnpZ7tdQ89QR3++7A+4hrr7V4xxmkB5BObS
# 0YK+MALE02atjwWgPdpYQ68WdLGroJZHkbZdgERG+7tETFl3aKF4KpoSaGOskZXp
# TPnCaMo2PXoAMVMGpsQEQswimZq3IQ3nRQfBlJ0PoMMcN/+Pks8ZTL1BoPYsJpok
# t6cql59q6CypZYIwgyJ892HpttybHKg1ZtQLUlSXccRMlugPgEcNZJagPEgPYni4
# b11snjRAgf0dyQ0zI9aLXqTxWUU5pCIFiPT0b2wsxzRqCtyGqpkGM8P9GazO8eao
# mVItCYBcJSByBx/pS0cSYwBBHAZxJODUqxSXoSGDvmTfqUJXntnWkL4okok1FiCD
# Z4jpyXOQunb6egIXvkgQ7jb2uO26Ow0m8RwleDvhOMrnHsupiOPbozKroSa6paFt
# VSh89abUSooR8QdZciemmoFhcWkEwFg4spzvYNP4nIs193261WyTaRMZoceGun7G
# CT2Rl653uUj+F+g94c63AhzSq4khdL4HlFIP2ePv29smfUnHtGq6yYFDLnT0q/Y+
# Di3jwloF8EWkkHRtSuXlFUbTmwr/lDDgbpZiKhLS7CBTDj32I0L5i532+uHczw82
# oZDmYmYmIUSMbZOgS65h797rj5JJ6OkeEUJoAVwwggd6MIIFYqADAgECAgphDpDS
# AAAAAAADMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMTAeFw0xMTA3MDgyMDU5MDlaFw0yNjA3MDgyMTA5MDla
# MH4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMT
# H01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMTEwggIiMA0GCSqGSIb3DQEB
# AQUAA4ICDwAwggIKAoICAQCr8PpyEBwurdhuqoIQTTS68rZYIZ9CGypr6VpQqrgG
# OBoESbp/wwwe3TdrxhLYC/A4wpkGsMg51QEUMULTiQ15ZId+lGAkbK+eSZzpaF7S
# 35tTsgosw6/ZqSuuegmv15ZZymAaBelmdugyUiYSL+erCFDPs0S3XdjELgN1q2jz
# y23zOlyhFvRGuuA4ZKxuZDV4pqBjDy3TQJP4494HDdVceaVJKecNvqATd76UPe/7
# 4ytaEB9NViiienLgEjq3SV7Y7e1DkYPZe7J7hhvZPrGMXeiJT4Qa8qEvWeSQOy2u
# M1jFtz7+MtOzAz2xsq+SOH7SnYAs9U5WkSE1JcM5bmR/U7qcD60ZI4TL9LoDho33
# X/DQUr+MlIe8wCF0JV8YKLbMJyg4JZg5SjbPfLGSrhwjp6lm7GEfauEoSZ1fiOIl
# XdMhSz5SxLVXPyQD8NF6Wy/VI+NwXQ9RRnez+ADhvKwCgl/bwBWzvRvUVUvnOaEP
# 6SNJvBi4RHxF5MHDcnrgcuck379GmcXvwhxX24ON7E1JMKerjt/sW5+v/N2wZuLB
# l4F77dbtS+dJKacTKKanfWeA5opieF+yL4TXV5xcv3coKPHtbcMojyyPQDdPweGF
# RInECUzF1KVDL3SV9274eCBYLBNdYJWaPk8zhNqwiBfenk70lrC8RqBsmNLg1oiM
# CwIDAQABo4IB7TCCAekwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFEhuZOVQ
# BdOCqhc3NyK1bajKdQKVMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMAsGA1Ud
# DwQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB8GA1UdIwQYMBaAFHItOgIxkEO5FAVO
# 4eqnxzHRI4k0MFoGA1UdHwRTMFEwT6BNoEuGSWh0dHA6Ly9jcmwubWljcm9zb2Z0
# LmNvbS9wa2kvY3JsL3Byb2R1Y3RzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcmwwXgYIKwYBBQUHAQEEUjBQME4GCCsGAQUFBzAChkJodHRwOi8vd3d3Lm1p
# Y3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dDIwMTFfMjAxMV8wM18y
# Mi5jcnQwgZ8GA1UdIASBlzCBlDCBkQYJKwYBBAGCNy4DMIGDMD8GCCsGAQUFBwIB
# FjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2RvY3MvcHJpbWFyeWNw
# cy5odG0wQAYIKwYBBQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AcABvAGwAaQBjAHkA
# XwBzAHQAYQB0AGUAbQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAGfyhqWY
# 4FR5Gi7T2HRnIpsLlhHhY5KZQpZ90nkMkMFlXy4sPvjDctFtg/6+P+gKyju/R6mj
# 82nbY78iNaWXXWWEkH2LRlBV2AySfNIaSxzzPEKLUtCw/WvjPgcuKZvmPRul1LUd
# d5Q54ulkyUQ9eHoj8xN9ppB0g430yyYCRirCihC7pKkFDJvtaPpoLpWgKj8qa1hJ
# Yx8JaW5amJbkg/TAj/NGK978O9C9Ne9uJa7lryft0N3zDq+ZKJeYTQ49C/IIidYf
# wzIY4vDFLc5bnrRJOQrGCsLGra7lstnbFYhRRVg4MnEnGn+x9Cf43iw6IGmYslmJ
# aG5vp7d0w0AFBqYBKig+gj8TTWYLwLNN9eGPfxxvFX1Fp3blQCplo8NdUmKGwx1j
# NpeG39rz+PIWoZon4c2ll9DuXWNB41sHnIc+BncG0QaxdR8UvmFhtfDcxhsEvt9B
# xw4o7t5lL+yX9qFcltgA1qFGvVnzl6UJS0gQmYAf0AApxbGbpT9Fdx41xtKiop96
# eiL6SJUfq/tHI4D1nvi/a7dLl+LrdXga7Oo3mXkYS//WsyNodeav+vyL6wuA6mk7
# r/ww7QRMjt/fdW1jkT3RnVZOT7+AVyKheBEyIXrvQQqxP/uozKRdwaGIm1dxVk5I
# RcBCyZt2WwqASGv9eZ/BvW1taslScxMNelDNMYIVZzCCFWMCAQEwgZUwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMQITMwAAAd9r8C6Sp0q00AAAAAAB3zAN
# BglghkgBZQMEAgEFAKCBrjAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgor
# BgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQgJROF4V78
# d/qQulLV5Z+ncgFZgk9r0UoE37o5jTCDpSowQgYKKwYBBAGCNwIBDDE0MDKgFIAS
# AE0AaQBjAHIAbwBzAG8AZgB0oRqAGGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbTAN
# BgkqhkiG9w0BAQEFAASCAQB74lkh+M6W7qWNERtX5/xMFrSgaVCptxuBlBl93FN3
# aQJiCaToMeDXG3Nsf/GhIFCBz4fReYrMmZg5pmjs+d8s1dgXz2oOWVwx6bhnzdXS
# ce5dMqkUCzvN4QeJxTIhpeXsHwupWVbuqeTo5DdZHouTi4UFzgM0/K+sSbRI/FEe
# rS/vxtMbrtMz57kKjB/Z86dKJeDxQydKSapL/YIamfmYx26rjpXJqEs7W+FVRJwK
# nNNT0OGt7tdkL6k+7XQtK3f5yUqKMdTlmPyZ73z69tAtJclkIFC3liFVTMAf4MK+
# nheQal7OPNth86h4Lek3E19n2hrABTUeW2cLZ2WWEspFoYIS8TCCEu0GCisGAQQB
# gjcDAwExghLdMIIS2QYJKoZIhvcNAQcCoIISyjCCEsYCAQMxDzANBglghkgBZQME
# AgEFADCCAVUGCyqGSIb3DQEJEAEEoIIBRASCAUAwggE8AgEBBgorBgEEAYRZCgMB
# MDEwDQYJYIZIAWUDBAIBBQAEIEIDAx5adVXZRJeNOj9JW7M03Sl8XvjtY9M98TvW
# cUwSAgZgieWmNfwYEzIwMjEwNTE5MTcwMDI4LjY0OVowBIACAfSggdSkgdEwgc4x
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKTAnBgNVBAsTIE1p
# Y3Jvc29mdCBPcGVyYXRpb25zIFB1ZXJ0byBSaWNvMSYwJAYDVQQLEx1UaGFsZXMg
# VFNTIEVTTjpEOURFLUUzOUEtNDNGRTElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUt
# U3RhbXAgU2VydmljZaCCDkQwggT1MIID3aADAgECAhMzAAABYfWiM16gKiRpAAAA
# AAFhMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNo
# aW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEw
# MB4XDTIxMDExNDE5MDIyMVoXDTIyMDQxMTE5MDIyMVowgc4xCzAJBgNVBAYTAlVT
# MRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKTAnBgNVBAsTIE1pY3Jvc29mdCBPcGVy
# YXRpb25zIFB1ZXJ0byBSaWNvMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjpEOURF
# LUUzOUEtNDNGRTElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vydmlj
# ZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJeInahBrU//GzTqhxUy
# AC8UXct6UJCkb2xEZKV3gjggmLAheBrxJk7tH+Pw2tTcyarLRfmV2xo5oBk5pW/O
# cDc/n/TcTeQU6JIN5PlTcn0C9RlKQ6t9OuU/WAyAxGTjKE4ENnUjXtxiNlD/K2ZG
# MLvjpROBKh7TtkUJK6ZGWw/uTRabNBxRg13TvjkGHXEUEDJ8imacw9BCeR9L6und
# r32tj4duOFIHD8m1es3SNN98Zq4IDBP3Ccb+HQgxpbeHIUlK0y6zmzIkvfN73Zxw
# fGvFv0/Max79WJY0cD8poCnZFijciWrf0eD1T2/+7HgewzrdxPdSFockUQ8QovID
# IYkCAwEAAaOCARswggEXMB0GA1UdDgQWBBRWHpqd1hv71SVj5LAdPfNE7PhLLzAf
# BgNVHSMEGDAWgBTVYzpcijGQ80N7fEYbxTNoWoVtVTBWBgNVHR8ETzBNMEugSaBH
# hkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20vcGtpL2NybC9wcm9kdWN0cy9NaWNU
# aW1TdGFQQ0FfMjAxMC0wNy0wMS5jcmwwWgYIKwYBBQUHAQEETjBMMEoGCCsGAQUF
# BzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY1RpbVN0
# YVBDQV8yMDEwLTA3LTAxLmNydDAMBgNVHRMBAf8EAjAAMBMGA1UdJQQMMAoGCCsG
# AQUFBwMIMA0GCSqGSIb3DQEBCwUAA4IBAQAQTA9bqVBmx5TTMhzj+Q8zWkPQXgCc
# SQiqy2YYWF0hWr5GEiN2LtA+EWdu1y8oysZau4CP7SzM8VTSq31CLJiOy39Z4RvE
# q2mr0EftFvmX2CxQ7ZyzrkhWMZaZQLkYbH5oabIFwndW34nh980BOY395tfnNS/Y
# 6N0f+jXdoFn7fI2c43TFYsUqIPWjOHJloMektlD6/uS6Zn4xse/lItFm+fWOcB2A
# xyXEB3ZREeSg9j7+GoEl1xT/iJuV/So7TlWdwyacQu4lv3MBsvxzRIbKhZwrDYog
# moyJ+rwgQB8mKS4/M1SDRtIptamoTFJ56Tk6DuUXx1JudToelgjEZPa5MIIGcTCC
# BFmgAwIBAgIKYQmBKgAAAAAAAjANBgkqhkiG9w0BAQsFADCBiDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFJv
# b3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5IDIwMTAwHhcNMTAwNzAxMjEzNjU1WhcN
# MjUwNzAxMjE0NjU1WjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3Rv
# bjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0
# aW9uMSYwJAYDVQQDEx1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDCCASIw
# DQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKkdDbx3EYo6IOz8E5f1+n9plGt0
# VBDVpQoAgoX77XxoSyxfxcPlYcJ2tz5mK1vwFVMnBDEfQRsalR3OCROOfGEwWbEw
# RA/xYIiEVEMM1024OAizQt2TrNZzMFcmgqNFDdDq9UeBzb8kYDJYYEbyWEeGMoQe
# dGFnkV+BVLHPk0ySwcSmXdFhE24oxhr5hoC732H8RsEnHSRnEnIaIYqvS2SJUGKx
# Xf13Hz3wV3WsvYpCTUBR0Q+cBj5nf/VmwAOWRH7v0Ev9buWayrGo8noqCjHw2k4G
# kbaICDXoeByw6ZnNPOcvRLqn9NxkvaQBwSAJk3jN/LzAyURdXhacAQVPIk0CAwEA
# AaOCAeYwggHiMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBTVYzpcijGQ80N7
# fEYbxTNoWoVtVTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTALBgNVHQ8EBAMC
# AYYwDwYDVR0TAQH/BAUwAwEB/zAfBgNVHSMEGDAWgBTV9lbLj+iiXGJo0T2UkFvX
# zpoYxDBWBgNVHR8ETzBNMEugSaBHhkVodHRwOi8vY3JsLm1pY3Jvc29mdC5jb20v
# cGtpL2NybC9wcm9kdWN0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0yMy5jcmwwWgYI
# KwYBBQUHAQEETjBMMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpL2NlcnRzL01pY1Jvb0NlckF1dF8yMDEwLTA2LTIzLmNydDCBoAYDVR0g
# AQH/BIGVMIGSMIGPBgkrBgEEAYI3LgMwgYEwPQYIKwYBBQUHAgEWMWh0dHA6Ly93
# d3cubWljcm9zb2Z0LmNvbS9QS0kvZG9jcy9DUFMvZGVmYXVsdC5odG0wQAYIKwYB
# BQUHAgIwNB4yIB0ATABlAGcAYQBsAF8AUABvAGwAaQBjAHkAXwBTAHQAYQB0AGUA
# bQBlAG4AdAAuIB0wDQYJKoZIhvcNAQELBQADggIBAAfmiFEN4sbgmD+BcQM9naOh
# IW+z66bM9TG+zwXiqf76V20ZMLPCxWbJat/15/B4vceoniXj+bzta1RXCCtRgkQS
# +7lTjMz0YBKKdsxAQEGb3FwX/1z5Xhc1mCRWS3TvQhDIr79/xn/yN31aPxzymXlK
# kVIArzgPF/UveYFl2am1a+THzvbKegBvSzBEJCI8z+0DpZaPWSm8tv0E4XCfMkon
# /VWvL/625Y4zu2JfmttXQOnxzplmkIz/amJ/3cVKC5Em4jnsGUpxY517IW3DnKOi
# PPp/fZZqkHimbdLhnPkd/DjYlPTGpQqWhqS9nhquBEKDuLWAmyI4ILUl5WTs9/S/
# fmNZJQ96LjlXdqJxqgaKD4kWumGnEcua2A5HmoDF0M2n0O99g/DhO3EJ3110mCII
# YdqwUB5vvfHhAN/nMQekkzr3ZUd46PioSKv33nJ+YWtvd6mBy6cJrDm77MbL2IK0
# cs0d9LiFAR6A+xuJKlQ5slvayA1VmXqHczsI5pgt6o3gMy4SKfXAL1QnIffIrE7a
# KLixqduWsqdCosnPGUFN4Ib5KpqjEWYw07t0MkvfY3v1mYovG8chr1m1rtxEPJdQ
# cdeh0sVV42neV8HR3jDA/czmTfsNv11P6Z0eGTgvvM9YBS7vDaBQNdrvCScc1bN+
# NR4Iuto229Nfj950iEkSoYIC0jCCAjsCAQEwgfyhgdSkgdEwgc4xCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKTAnBgNVBAsTIE1pY3Jvc29mdCBP
# cGVyYXRpb25zIFB1ZXJ0byBSaWNvMSYwJAYDVQQLEx1UaGFsZXMgVFNTIEVTTjpE
# OURFLUUzOUEtNDNGRTElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAFW5ShAw5ekTEXvL/4V1s0rbDz3mggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQUFAAIF
# AORPamMwIhgPMjAyMTA1MTkxNDQzNDdaGA8yMDIxMDUyMDE0NDM0N1owdzA9Bgor
# BgEEAYRZCgQBMS8wLTAKAgUA5E9qYwIBADAKAgEAAgIYCAIB/zAHAgEAAgIRJjAK
# AgUA5FC74wIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIB
# AAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBBQUAA4GBAEP3zVlXXAn4O1Ms
# 68s11f0LWnsKutmWLnJls7YN9alFuA+jJcq/S8x2VoJAWAZTdWtdT5N7Gf/BeTAe
# 8D0krUvAYkKN9sIFxBsV9Zum88+HNP6X3yn+CD+ZzOlhtqvgG+fuuRXPutLZfLc/
# BMw0pVKop8ty4t9o1C5cghIH1n8uMYIDDTCCAwkCAQEwgZMwfDELMAkGA1UEBhMC
# VVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNV
# BAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRp
# bWUtU3RhbXAgUENBIDIwMTACEzMAAAFh9aIzXqAqJGkAAAAAAWEwDQYJYIZIAWUD
# BAIBBQCgggFKMBoGCSqGSIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0B
# CQQxIgQgYzAzV5OthXnPmIpD3kPIVmwz+sGvwSbjTEW5rOqHhyUwgfoGCyqGSIb3
# DQEJEAIvMYHqMIHnMIHkMIG9BCBhz4un6mkSLd/zA+0N5YLDGp4vW/VBtNW/lpmh
# tAk4bzCBmDCBgKR+MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9u
# MRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRp
# b24xJjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAAB
# YfWiM16gKiRpAAAAAAFhMCIEIArbvJb5j55rDAQa7Rx5K7mjnxUY6RgiRY1AROOp
# m2rLMA0GCSqGSIb3DQEBCwUABIIBAFS544uO7FOimzTwMDkFNhMT7GmZBc9L2wDF
# EjcDlHvcdELdWpqa8Au6rCdhW6618btwdFqR7fkNMH7F0TrY1ktOae5fZUaybIRV
# EMWAAqXLkVyePlssQamjt1+BYvxzYFh3T5JBr2R/rzaGJIck49r1cEsLBV0JaSQT
# QKiOsR+QEbSCNWXQaq/koJrKR5Ugro0y4SmSejnOj5+1/4PlTolFoJAM4pIiT2A1
# uMs5f219BvkwyRmF32z9EpYQvBdoGpT65DQDuZQ5F6wV1Ph4H7yOzarcdnwPohT+
# BeH2jrcR3BMAxC3umgRUmTxnzPsoq9FJuRTyHCNygGn+VMImNfk=
# SIG # End signature block
