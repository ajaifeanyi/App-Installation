# PLEASE ENTER THE GITHUB REPO HERE
$gethubRepoLink = "https://github.com/ajaifeanyi/Central-Dashboard.git"



#START INSTALLATION REGION

function Install-DotnetCore {

[cmdletbinding()]
param(
   [string]$Channel="LTS",
   [string]$Version="3.1.101",
   [string]$JSonFile,
   [string]$InstallDir="<auto>",
   [string]$Architecture="<auto>",
   [ValidateSet("dotnet", "aspnetcore", "windowsdesktop", IgnoreCase = $false)]
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
   [switch]$SkipNonVersionedFiles,
   [switch]$NoCdn
)
    
    function Say($str) {
    Write-Host "dotnet-install: $str"
}

function Say-Verbose($str) {
    Write-Verbose "dotnet-install: $str"
}

function Say-Invocation($Invocation) {
    $command = $Invocation.MyCommand;
    $args = (($Invocation.BoundParameters.Keys | foreach { "-$_ `"$($Invocation.BoundParameters[$_])`"" }) -join " ")
    Say-Verbose "$command $args"
}

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
    Write-Host "dotnet-install: $str"
}

function Say-Verbose($str) {
    Write-Verbose "dotnet-install: $str"
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
            return $ScriptBlock.Invoke()
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

    # possible values: amd64, x64, x86, arm64, arm
    return $ENV:PROCESSOR_ARCHITECTURE
}

function Get-CLIArchitecture-From-Architecture([string]$Architecture) {
    Say-Invocation $MyInvocation

    switch ($Architecture.ToLower()) {
        { $_ -eq "<auto>" } { return Get-CLIArchitecture-From-Architecture $(Get-Machine-Architecture) }
        { ($_ -eq "amd64") -or ($_ -eq "x64") } { return "x64" }
        { $_ -eq "x86" } { return "x86" }
        { $_ -eq "arm" } { return "arm" }
        { $_ -eq "arm64" } { return "arm64" }
        default { throw "Architecture not supported. If you think this is a bug, report it at https://github.com/dotnet/sdk/issues" }
    }
}


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

function GetHTTPResponse([Uri] $Uri)
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

            if($ProxyAddress) {
                $HttpClientHandler = New-Object System.Net.Http.HttpClientHandler
                $HttpClientHandler.Proxy =  New-Object System.Net.WebProxy -Property @{Address=$ProxyAddress;UseDefaultCredentials=$ProxyUseDefaultCredentials}
                $HttpClient = New-Object System.Net.Http.HttpClient -ArgumentList $HttpClientHandler
            }
            else {

                $HttpClient = New-Object System.Net.Http.HttpClient
            }
            # Default timeout for HttpClient is 100s.  For a 50 MB download this assumes 500 KB/s average, any less will time out
            # 20 minutes allows it to work over much slower connections.
            $HttpClient.Timeout = New-TimeSpan -Minutes 20
            $Response = $HttpClient.GetAsync("${Uri}${FeedCredential}").Result
            if (($Response -eq $null) -or (-not ($Response.IsSuccessStatusCode))) {
                 # The feed credential is potentially sensitive info. Do not log FeedCredential to console output.
                $ErrorMsg = "Failed to download $Uri."
                if ($Response -ne $null) {
                    $ErrorMsg += "  $Response"
                }

                throw $ErrorMsg
            }

             return $Response
        }
        finally {
             if ($HttpClient -ne $null) {
                $HttpClient.Dispose()
            }
        }
    })
}

function Get-Latest-Version-Info([string]$AzureFeed, [string]$Channel, [bool]$Coherent) {
    Say-Invocation $MyInvocation

    $VersionFileUrl = $null
    if ($Runtime -eq "dotnet") {
        $VersionFileUrl = "$UncachedFeed/Runtime/$Channel/latest.version"
    }
    elseif ($Runtime -eq "aspnetcore") {
        $VersionFileUrl = "$UncachedFeed/aspnetcore/Runtime/$Channel/latest.version"
    }
    # Currently, the WindowsDesktop runtime is manufactured with the .Net core runtime
    elseif ($Runtime -eq "windowsdesktop") {
        $VersionFileUrl = "$UncachedFeed/Runtime/$Channel/latest.version"
    }
    elseif (-not $Runtime) {
        if ($Coherent) {
            $VersionFileUrl = "$UncachedFeed/Sdk/$Channel/latest.coherent.version"
        }
        else {
            $VersionFileUrl = "$UncachedFeed/Sdk/$Channel/latest.version"
        }
    }
    else {
        throw "Invalid value for `$Runtime"
    }
    try {
        $Response = GetHTTPResponse -Uri $VersionFileUrl
    }
    catch {
        throw "Could not resolve version information."
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
        exit 0
    }
    try {
        $JSonContent = Get-Content($JSonFile) -Raw | ConvertFrom-Json | Select-Object -expand "sdk" -ErrorAction SilentlyContinue
    }
    catch {
        throw "Json file unreadable: '$JSonFile'"
        exit 0
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
            throw "Unable to parse the SDK node in '$JSonFile'"
            exit 0
        }
    }
    else {
        throw "Unable to find the SDK node in '$JSonFile'"
        exit 0
    }
    If ($Version -eq $null) {
        throw "Unable to find the SDK:version node in '$JSonFile'"
        exit 0
    }
    return $Version
}

function Get-Specific-Version-From-Version([string]$AzureFeed, [string]$Channel, [string]$Version, [string]$JSonFile) {
    Say-Invocation $MyInvocation

    if (-not $JSonFile) {
        switch ($Version.ToLower()) {
            { $_ -eq "latest" } {
                $LatestVersionInfo = Get-Latest-Version-Info -AzureFeed $AzureFeed -Channel $Channel -Coherent $False
                return $LatestVersionInfo.Version
            }
            { $_ -eq "coherent" } {
                $LatestVersionInfo = Get-Latest-Version-Info -AzureFeed $AzureFeed -Channel $Channel -Coherent $True
                return $LatestVersionInfo.Version
            }
            default { return $Version }
        }
    }
    else {
        return Parse-Jsonfile-For-Version $JSonFile
    }
}

function Get-Download-Link([string]$AzureFeed, [string]$SpecificVersion, [string]$CLIArchitecture) {
    Say-Invocation $MyInvocation

    if ($Runtime -eq "dotnet") {
        $PayloadURL = "$AzureFeed/Runtime/$SpecificVersion/dotnet-runtime-$SpecificVersion-win-$CLIArchitecture.zip"
    }
    elseif ($Runtime -eq "aspnetcore") {
        $PayloadURL = "$AzureFeed/aspnetcore/Runtime/$SpecificVersion/aspnetcore-runtime-$SpecificVersion-win-$CLIArchitecture.zip"
    }
    elseif ($Runtime -eq "windowsdesktop") {
        $PayloadURL = "$AzureFeed/Runtime/$SpecificVersion/windowsdesktop-runtime-$SpecificVersion-win-$CLIArchitecture.zip"
    }
    elseif (-not $Runtime) {
        $PayloadURL = "$AzureFeed/Sdk/$SpecificVersion/dotnet-sdk-$SpecificVersion-win-$CLIArchitecture.zip"
    }
    else {
        throw "Invalid value for `$Runtime"
    }

    Say-Verbose "Constructed primary named payload URL: $PayloadURL"

    return $PayloadURL
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
    Say-Verbose "Is-Dotnet-Package-Installed: Path to a package: $DotnetPackagePath"
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

$CLIArchitecture = Get-CLIArchitecture-From-Architecture $Architecture
$SpecificVersion = Get-Specific-Version-From-Version -AzureFeed $AzureFeed -Channel $Channel -Version $Version -JSonFile $JSonFile
$DownloadLink = Get-Download-Link -AzureFeed $AzureFeed -SpecificVersion $SpecificVersion -CLIArchitecture $CLIArchitecture
$LegacyDownloadLink = Get-LegacyDownload-Link -AzureFeed $AzureFeed -SpecificVersion $SpecificVersion -CLIArchitecture $CLIArchitecture

$InstallRoot = Resolve-Installation-Path $InstallDir
Say-Verbose "InstallRoot: $InstallRoot"
$ScriptName = $MyInvocation.MyCommand.Name

if ($DryRun) {
    Say "Payload URLs:"
    Say "Primary named payload URL: $DownloadLink"
    if ($LegacyDownloadLink) {
        Say "Legacy named payload URL: $LegacyDownloadLink"
    }
    $RepeatableCommand = ".\$ScriptName -Version `"$SpecificVersion`" -InstallDir `"$InstallRoot`" -Architecture `"$CLIArchitecture`""
    if ($Runtime -eq "dotnet") {
       $RepeatableCommand+=" -Runtime `"dotnet`""
    }
    elseif ($Runtime -eq "aspnetcore") {
       $RepeatableCommand+=" -Runtime `"aspnetcore`""
    }
    foreach ($key in $MyInvocation.BoundParameters.Keys) {
        if (-not (@("Architecture","Channel","DryRun","InstallDir","Runtime","SharedRuntime","Version") -contains $key)) {
            $RepeatableCommand+=" -$key `"$($MyInvocation.BoundParameters[$key])`""
        }
    }
    Say "Repeatable invocation: $RepeatableCommand"
    exit 0
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

#  Check if the SDK version is already installed.
$isAssetInstalled = Is-Dotnet-Package-Installed -InstallRoot $InstallRoot -RelativePathToPackage $dotnetPackageRelativePath -SpecificVersion $SpecificVersion
if ($isAssetInstalled) {
    Say "$assetName version $SpecificVersion is already installed."
    Prepend-Sdk-InstallRoot-To-Path -InstallRoot $InstallRoot -BinFolderRelativePath $BinFolderRelativePath
    #exit 0
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null

$installDrive = $((Get-Item $InstallRoot).PSDrive.Name);
$diskInfo = Get-PSDrive -Name $installDrive
if ($diskInfo.Free / 1MB -le 100) {
    Say "There is not enough disk space on drive ${installDrive}:"
    #exit 0
}

$ZipPath = [System.IO.Path]::combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
Say-Verbose "Zip path: $ZipPath"

$DownloadFailed = $false
Say "Downloading link: $DownloadLink"
try {
    DownloadFile -Source $DownloadLink -OutPath $ZipPath
}
catch {
    Say "Cannot download: $DownloadLink"
    if ($LegacyDownloadLink) {
        $DownloadLink = $LegacyDownloadLink
        $ZipPath = [System.IO.Path]::combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
        Say-Verbose "Legacy zip path: $ZipPath"
        Say "Downloading legacy link: $DownloadLink"
        try {
            DownloadFile -Source $DownloadLink -OutPath $ZipPath
        }
        catch {
            Say "Cannot download: $DownloadLink"
            $DownloadFailed = $true
        }
    }
    else {
        $DownloadFailed = $true
    }
}

if ($DownloadFailed) {
    throw "Could not find/download: `"$assetName`" with version = $SpecificVersion`nRefer to: https://aka.ms/dotnet-os-lifecycle for information on .NET Core support"
}

Say "Extracting zip from $DownloadLink"
Extract-Dotnet-Package -ZipPath $ZipPath -OutPath $InstallRoot

#  Check if the SDK version is now installed; if not, fail the installation.
$isAssetInstalled = Is-Dotnet-Package-Installed -InstallRoot $InstallRoot -RelativePathToPackage $dotnetPackageRelativePath -SpecificVersion $SpecificVersion
if (!$isAssetInstalled) {
    throw "`"$assetName`" with version = $SpecificVersion failed to install with an unknown error."
}

Remove-Item $ZipPath

Prepend-Sdk-InstallRoot-To-Path -InstallRoot $InstallRoot -BinFolderRelativePath $BinFolderRelativePath

Say "Dotnetcore3.1 Installation finished"
}


#END INSTALLATION REGION

# write information
function WriteI{
    param(
        [parameter(mandatory = $true)]
        [string]$message
    )
    Write-Host $message -foregroundcolor white
}

# write error
function WriteE{
    param(
        [parameter(mandatory = $true)]
        [string]$message
    )
    Write-Host $message -foregroundcolor red -BackgroundColor black
}

# write warning
function WriteW{
    param(
        [parameter(mandatory = $true)]
        [string]$message
    )
    Write-Host $message -foregroundcolor yellow -BackgroundColor black
}

# write success
function WriteS{
    param(
        [parameter(mandatory = $true)]
        [string]$message
    )
    Write-Host $message -foregroundcolor green -BackgroundColor black
}

WriteW "`n----------------------------"
WriteW " system requirements checking  "
WriteW "----------------------------`n"



#Checking if node is installed
 try
{
    Get-Command node -ErrorAction Stop | Out-Null
   WriteI -message "Node is installed`n"
}
catch [System.Management.Automation.CommandNotFoundException]
{
    WriteW -message "Node not found, Don't worry I will install it..............`n"
    winget install nodejs --version 16.12.0
    #Install-Module posh-git -Scope CurrentUser -Force

    #Checking if git is installed
    try
    {
        Get-Command git -ErrorAction Stop | Out-Null
        WriteI -message "Git is installed`n"
    }
    catch [System.Management.Automation.CommandNotFoundException]
    {
        WriteW -message "Git not found, Don't worry I will install it..............`n"
        #Install-Module posh-git -Scope CurrentUser -Force
        winget install --id Git.Git -e --source winget
    }

    $confirmationTitle = WriteS -message "Nodejs successfully installed however, you need to close this window and relaunch the script to continue..............`n"
    $confirmationQuestion = "Select Y to confirm"
    $confirmationChoices = "&Yes"# 0 = Yes
    $Host.UI.PromptForChoice($confirmationTitle, $confirmationQuestion, $confirmationChoices, 0)
    EXIT
}


#  Check if the SDK version is already installed.
$sysRoot = $env:LOCALAPPDATA+"\Microsoft\dotnet\sdk\3.1.101"
$isDotnetInstalled = Test-Path -Path $sysRoot
if (-not $isDotnetInstalled) {
    #WriteS -message "Dotnetcore sdk version 3.1 is already installed."
    #WriteI -message "dotnetcore3.1 sdk installing`n"
    Install-DotnetCore
}


# Installing required modules
    WriteI -message "Checking if the required modules are installed...`n"
    $isAvailable = $true
 try
 {
     teamsfx -v -ErrorAction Stop | Out-Null
   WriteS -message "teamsfx-cli is available....`n"
 }
 catch [System.Management.Automation.CommandNotFoundException]
 {
   WriteW -message "teamsfx-cli is missing.`n"
           $isAvailable = $false
}
    if ((Get-Module -ListAvailable -Name "Az.*")) {
        WriteS -message "Az module is available....`n"
    } else {
        WriteW -message "Az module is missing.`n"
        $isAvailable = $false
    }

    if ((Get-Module -ListAvailable -Name "AzureAD")) {
        WriteS -message "AzureAD module is available....`n"
    } else {
        WriteW -message "AzureAD module is missing.`n"
        $isAvailable = $false
    }

     if ((Get-Module -ListAvailable -Name "WriteAscii")) {
        WriteS -message "WriteAscii module is available....`n"
    } else {
        WriteW -message "WriteAscii module is missing.`n"
        $isAvailable = $false
    }

    if (-not $isAvailable)
    {
        $confirmationTitle = WriteW -message "The script requires the following modules to deploy:`n `n 1.teamfx-cli`n `n 2.AzureAD module `n `n 3.Az module`n `n 4.WriteAscii`n `nIf you proceed, the script will install the missing modules."
        $confirmationQuestion = "Do you want to proceed?"
        $confirmationChoices = "&Yes", "&No" # 0 = Yes, 1 = No
                
        $updateDecision = $Host.UI.PromptForChoice($confirmationTitle, $confirmationQuestion, $confirmationChoices, 1)
            if ($updateDecision -eq 0) {
             
         try
         {
             teamsfx | Out-Null
           WriteI -message "*********************************************************************"
         }
         catch [System.Management.Automation.CommandNotFoundException]
         {
                       WriteI -message "`n Installing teamsfx-cli...`n"
		            #npm cache verify
                    npm install -g @microsoft/teamsfx-cli@latest
}
                if (-not (Get-Module -ListAvailable -Name "Az.*")) {
                    WriteI -message "Installing AZ module...`n"
                    Install-Module Az -AllowClobber -Scope CurrentUser
                }

                if (-not (Get-Module -ListAvailable -Name "AzureAD")) {
                    WriteI -message "Installing AzureAD module...`n"
                    Install-Module AzureAD -Scope CurrentUser
                }
                
                 if (-not (Get-Module -ListAvailable -Name "WriteAscii")) {
                    WriteI -message "Installing WriteAscii module...`n"
                    Install-Module WriteAscii -Scope CurrentUser
                }
            } else {
                WriteE -message "You may install the modules manually by following the below link. Please re-run the script after the modules are installed. `nhttps://docs.microsoft.com/en-us/powershell/module/powershellget/install-module?view=powershell-7"
                EXIT
            }
    } else {
        WriteS -message "All the needed modules are available!`n"
    }
  #Install-Module posh-git -Scope CurrentUser -Force
  #winget install --id Git.Git -e --source winget

#Use Substring to extract folder path from github repo
$index = $gethubRepoLink.LastIndexOf('/')+1
$length = $gethubRepoLink.LastIndexOf(".")
$lastIndex = $length-$index
$folderPath = $gethubRepoLink.Substring($index,$lastIndex)

cd $HOME
#####Cloning github repo into local system
git clone $gethubRepoLink
cd $HOME/$folderPath




Import-Module Microsoft.PowerShell.Utility
 # Start Deployment.
Write-Ascii -InputObject $folderPath -ForegroundColor Magenta
WriteS -message "`n Company Name: Reliance InfoSystems Limited`n V1.0.0.0`n"


############
teamsfx account logout azure
teamsfx account logout m365
############


try {
    teamsfx account login m365
    WriteI -message "`n ...............`n"
    teamsfx account login azure

    WriteI -message "Setting up teamfx and checking if prod env is available.`n"

    $appEnv = teamsfx env list
    if($appEnv|where{$_ -match "prod"}){WriteI -message "prod env already exists.`n"}else{teamsfx env add prod --env dev}

    
    WriteI -message "`n Resource provision is still in progress. Next check in 5 minutes...............`n"
    teamsfx provision --env prod
 
}
catch [System.Management.Automation.CommandNotFoundException]
{
    WriteE -message "An error occured....."
    Start-Sleep -Seconds 80
    EXIT
}

 #Trying to deploy solution 
 try
 {
    WriteI -message "`n Resource deployment is still in progress. Next check in 3 minutes...................`n"
    teamsfx deploy --env prod
     #WriteI -message "Solution Deployed`n"
 }
 catch [System.Management.Automation.CommandNotFoundException]
 {
     WriteW -message "An error occured.....`n"
     Start-Sleep -Seconds 80
     EXIT
 }


 #Trying to publish solution
 try
 {
    WriteI -message "`n Resource publishing is still in progress................`n"
    teamsfx publish --env prod
 }
 catch [System.Management.Automation.CommandNotFoundException]
 {
    WriteW -message "An error occured.....`n"
    Start-Sleep -Seconds 80
    exit
 }

WriteS -message "Done!!" $folderPath "successfully installed and published on Teams Admin Center, kindly sign in and approve the app before it become available for other users......."
Start-Sleep -Seconds 20
Start-Process chrome.exe '-new-window https://admin.teams.microsoft.com/policies/manage-apps'

#Remove project folder
cd ..
WriteW -message "`n Finishing in progress................ don't close this session, it will close when finishing is completed `n "
Remove-Item -Path .\$folderPath -Recurse -Force

teamsfx account logout azure
teamsfx account logout m365
#Start-Sleep -Seconds 120
