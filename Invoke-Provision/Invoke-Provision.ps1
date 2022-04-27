#region Classes
class USBImage {
    [string]                    $winPEDrive = $null
    [string]                    $winPESource = $env:winPESource
    [PSCustomObject]            $volumeInfo = $null
    [string]                    $installPath = $null
    [string]                    $installRoot = $null
    [System.IO.DirectoryInfo]   $scratch = $null
    [string]                    $scRoot = $null
    [System.IO.DirectoryInfo]   $recovery = $null
    [string]                    $reRoot = $null
    [System.IO.DirectoryInfo]   $driverPath = $null
    [System.IO.DirectoryInfo]   $cuPath = $null
    [System.IO.DirectoryInfo]   $ssuPath = $null

    USBImage ([string]$winPEDrive) {
        $this.winPEDrive = $winPEDrive
        $this.volumeInfo = Get-DiskPartVolume -winPEDrive $winPEDrive
        $this.installRoot = (Find-InstallWim -volumeInfo $($this.volumeInfo)).DriveRoot
        $this.installPath = "$($this.installRoot)images"
        $this.cuPath = "$($this.installPath)\CU"
        $this.ssuPath = "$($this.installPath)\SSU"
        $this.driverPath = "$(Split-Path $PSScriptRoot -Parent)\Drivers"
    }
    setScratch ([System.IO.DirectoryInfo]$scratch) {
        $this.scratch = $scratch
        [string]$this.scRoot = $scratch.Root
    }
    setRecovery ([System.IO.DirectoryInfo]$recovery) {
        $this.recovery = $recovery
        [string]$this.reRoot = $recovery.Root
    }
}
#endregion
#region Functions
function Set-PowerPolicy {
    [cmdletbinding()]
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet('PowerSaver', 'Balanced', 'HighPerformance')]
        [string]$powerPlan
    )
    try {
        switch ($powerPlan) {
            PowerSaver {
                Write-Host "Setting power policy to 'Power Saver'.." -ForegroundColor Cyan
                $planGuid = "a1841308-3541-4fab-bc81-f71556f20b4a"
            }
            Balanced {
                Write-Host "Setting power policy to 'Balanced Performance'.." -ForegroundColor Cyan
                $planGuid = "381b4222-f694-41f0-9685-ff5bb260df2e"
            }
            HighPerformance {
                Write-Host "Setting power policy to 'High Performance'.." -ForegroundColor Cyan
                $planGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
            }
            default {
                throw "Incorrect selection.."
            }
        }
        Invoke-CmdLine -application powercfg -argumentList "/s $planGuid" -silent
    }
    catch {
        throw $_
    }
}
function Test-IsUEFI {
    try {
        $pft = Get-ItemPropertyValue -Path HKLM:\SYSTEM\CurrentControlSet\Control -Name 'PEFirmwareType'
        switch ($pft) {
            1 {
                Write-Host "BIOS Mode detected.." -ForegroundColor Cyan
                return "BIOS"
            }
            2 {
                Write-Host "UEFI Mode detected.." -ForegroundColor Cyan
                return "UEFI"
            }
            Default {
                Write-Host "BIOS / UEFI undetected.." -ForegroundColor Red
                return $false
            }
        }
    }
    catch {
        throw $_
    }
}
function Invoke-Cmdline {
    [cmdletbinding()]
    param (
        [parameter(mandatory = $true)]
        [string]$application,

        [parameter(mandatory = $true)]
        [string]$argumentList,

        [parameter(Mandatory = $false)]
        [switch]$silent
    )
    if ($silent) {
        cmd /c "$application $argumentList > nul 2>&1"
    }
    else {
        cmd /c "$application $argumentList"
    }
    if ($LASTEXITCODE -ne 0) {
        throw "An error has occurred.."
    }
}
function Get-DiskPartVolume {
    [cmdletbinding()]
    param (
        [parameter(mandatory = $false)]
        [string]$winPEDrive = "X:"
    )
    try {
        #region Map drive letter for install.wim
        $lvTxt = "$winPEDrive\listvol.txt"
        $lv = @"
List volume
exit
"@
        $lv | Out-File $lvTxt -Encoding ascii -Force -NoNewline
        $dpOutput = Invoke-CmdLine -application "diskpart" -argumentList "/s $lvTxt"
        $dpOutput = $dpOutput[6..($dpOutput.length - 3)]
        $vals = $dpOutput[2..($dpOutput.Length - 1)]
        $res = foreach ($val in $vals) {
            $dr = $val.Substring(10, 6).Replace(" ", "")
            [PSCustomObject]@{
                VolumeNum  = $val.Substring(0, 10).Replace(" ", "")
                DriveRoot  = if ($dr -ne "") { "$dr`:\" } else { $null }
                Label      = $val.Substring(17, 13).Replace(" ", "")
                FileSystem = $val.Substring(30, 7).Replace(" ", "")
                Type       = $val.Substring(37, 12).Replace(" ", "")
                Size       = $val.Substring(49, 9).Replace(" ", "")
                Status     = $val.Substring(58, 11).Replace(" ", "")
                Info       = $val.Substring($val.length - 10, 10).Replace(" ", "")
            }
        }
        return $res
        #endregion
    }
    catch {
        throw $_
    }

}
function Set-DrivePartition {
    [cmdletbinding()]
    param (
        [parameter(mandatory = $false)]
        [string]$winPEDrive = "X:",

        [parameter(mandatory = $false)]
        [string]$targetDrive = "0"
    )
    try {
        $txt = "$winPEDrive\winpart.txt"
        New-Item $txt -ItemType File -Force | Out-Null
        Write-Host "Checking boot system type.." -ForegroundColor Cyan
        $bootType = Test-IsUEFI
        #region Boot type switch
        switch ($bootType) {
            "BIOS" {
                $winpartCmd = @"
select disk $targetDrive
clean
create partition primary size=100
active
format quick fs=fat32 label="System"
assign letter="S"
create partition primary
format quick fs=ntfs label="Windows"
assign letter="W"
shrink desired=450
create partition primary
format quick fs=ntfs label="Recovery"
assign letter="R"
exit
"@
            }
            "UEFI" {
                $winpartCmd = @"
select disk $targetDrive
clean
convert gpt
create partition efi size=100
format quick fs=fat32 label="System"
assign letter="S"
create partition msr size=16
create partition primary
format quick fs=ntfs label="Windows"
assign letter="W"
shrink desired=950
create partition primary
format quick fs=ntfs label="Recovery"
assign letter="R"
set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"
gpt attributes=0x8000000000000001
exit
"@
            }
            default {
                throw "Boot type could not be detected.."
            }
        }
        #endregion
        #region Partition disk
        $winpartCmd | Out-File $txt -Encoding ascii -Force -NoNewline
        Write-Host "Setting up partition table.." -ForegroundColor Cyan
        Invoke-Cmdline -application diskpart -argumentList "/s $txt" -silent
        #endregion

    }
    catch {
        throw $_
    }

}
function Format-USBDisk {
    [cmdletbinding()]
    param (
        [parameter(mandatory = $false)]
        [string]$winPEDrive = "X:",

        [parameter(mandatory = $false)]
        [string]$targetDrive = "1"
    )
    try {
        $txt = "$winPEDrive\winpart.txt"
        New-Item $txt -itemType File -force | Out-Null
        $winpartCmd = @"
select disk $targetDrive
clean
create partition primary
active
format quick fs=ntfs label="PortableUSB"
assign letter=?
exit
"@
        #region Partition disk
        $winpartCmd | Out-File $txt -Encoding ascii -Force -NoNewline
        Write-Host "Formatting target disk.." -ForegroundColor Cyan
        Invoke-Cmdline -application diskpart -argumentList "/s $txt" -silent
        #endregion
    }
    catch {
        throw $_
    }
}
function Find-InstallWim {
    [cmdletbinding()]
    param (
        [parameter(Mandatory = $true)]
        $volumeInfo
    )
    try {
        foreach ($vol in $volumeInfo) {
            if ($vol.DriveRoot) {
                if (Test-Path "$($vol.DriveRoot)images\install.wim" -ErrorAction SilentlyContinue) {
                    Write-Host "Install.wim found on drive: $($vol.DriveRoot)" -ForegroundColor Cyan
                    $res = $vol
                }
            }
        }
    }
    catch {
        Write-Warning $_.Exception.Message
    }
    finally {
        if (!($res)) {
            Write-Warning "Install.wim not found on any drives.."
        }
        else {
            $res
        }
    }
}
function Add-Driver {
    [cmdletbinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$scratchDrive,

        [parameter(Mandatory = $true)]
        [string]$driverPath

    )
    if (!(Get-ChildItem "$driverPath\*.inf" -Recurse -ErrorAction SilentlyContinue)) {
        Write-Host "No drivers found at path: $driverPath" -ForegroundColor Cyan
    }
    else {
        Invoke-Cmdline -application "DISM" -argumentList "/Image:$scratchDrive /Add-Driver /Driver:$driverPath /recurse"
    }
}
function Add-Package {
    [cmdletbinding()]
    param (
        [parameter(Mandatory = $true)]
        [string]$scratchDrive,

        [parameter(Mandatory = $true)]
        [string]$scratchPath,

        [parameter(Mandatory = $true)]
        [string]$packagePath
    )
    if (!(Get-ChildItem $packagePath)) {
        Write-Host "No update packages found at path: $packagePath" -ForegroundColor Cyan
    }
    else {
        Invoke-Cmdline -application "DISM" -argumentList "/Image:$scratchDrive /Add-Package /PackagePath:$packagePath /ScratchDir:$scratchPath"
    }
}

#endregion
#region Main process
try {
    $errorMsg = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    #region Set power policy to High Performance
    Set-PowerPolicy -powerPlan HighPerformance
    #endregion
    #region Warning shots..
    
    #endregion
    #region Set the install path to the location of the Install.wim file
    Write-Host "`nSetting Install.Wim location.." -ForegroundColor Yellow
    #$installPath = Find-InstallWim -volumeInfo (Get-DiskPartVolume -winPEDrive "X:")
    $usb = [USBImage]::new($env:SystemDrive)
    if (!($usb.installRoot)) {
        throw "Coudn't find install.wim anywhere..."
    }
    #endregion
    #region Configure drive partitions
    Write-Host "`nConfiguring drive partitions.." -ForegroundColor Yellow
    Set-DrivePartition -winPEDrive $usb.winPEDrive -targetDrive 0
    #endregion
    #region Set paths
    Write-Host "`nSetting up Scratch & Recovery paths.." -ForegroundColor Yellow
    $usb.setScratch("W:\recycler\scratch")
    $usb.setRecovery("R:\RECOVERY\WINDOWSRE")
    New-Item -Path $usb.scratch.FullName -ItemType Directory -Force | Out-Null
    New-Item -Path $usb.recovery.FullName -ItemType Directory -Force | Out-Null
    #endregion
    #region Applying the windows image from the USB
    Write-Host "`nApplying the windows image from the USB.." -ForegroundColor Yellow
    $imageIndex = Get-Content "$($usb.installPath)\imageIndex.json" -Raw | ConvertFrom-Json -Depth 20
    Invoke-Cmdline -application "DISM" -argumentList "/Apply-Image /ImageFile:$($usb.installPath)\install.wim /Index:$($imageIndex.imageIndex) /ApplyDir:$($usb.scRoot) /EA /ScratchDir:$($usb.scratch)"
    #endregion
    #region Inject the autoPilot configuration file
    if (Test-Path "$PSScriptRoot\AutopilotConfigurationFile.json" -ErrorAction SilentlyContinue) {
        if (Test-Path "$($usb.scRoot)Windows\Provisioning\Autopilot") {
            Write-Host "`nInjecting AutoPilot configuration file.." -ForegroundColor Yellow
            Copy-Item "$PSScriptRoot\AutopilotConfigurationFile.json" -Destination "$($usb.scRoot)Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json" -Force | Out-Null
        }
        else {
            Write-Host "`nCreating new AutoPilot configuration file.." -ForegroundColor Yellow
            New-Item -ItemType Directory -Path "$($usb.scRoot)Windows\Provisioning\Autopilot"
            Write-Host "`nInjecting AutoPilot configuration file.." -ForegroundColor Yellow
            Copy-Item "$PSScriptRoot\AutopilotConfigurationFile.json" -Destination "$($usb.scRoot)Windows\Provisioning\Autopilot\AutopilotConfigurationFile.json" -Force | Out-Null
        }
    }
    #endregion
    #region Setting the recovery environment
    Write-Host "`nMove WinRE to recovery partition.." -ForegroundColor Yellow
    $reWimPath = "$($usb.scRoot)Windows\System32\recovery\winre.wim"
    if (Test-Path $reWimPath -ErrorAction SilentlyContinue) {
        Write-Host "`nMoving the recovery wim into place.." -ForegroundColor Yellow
        (Get-ChildItem -Path $reWimPath -Force).attributes = "NotContentIndexed"
        Move-Item -Path $reWimPath -Destination "$($usb.recovery.FullName)\winre.wim"
        (Get-ChildItem -Path "$($usb.recovery.FullName)\winre.wim" -Force).attributes = "ReadOnly", "Hidden", "System", "Archive", "NotContentIndexed"

        Write-Host "`nSetting the recovery environment.." -ForegroundColor Yellow
        Invoke-Cmdline -application "$($usb.scRoot)Windows\System32\reagentc" -argumentList "/SetREImage /Path $($usb.recovery.FullName) /target $($usb.scRoot)Windows" -silent
    }
    #endregion
    #region Setting the boot environment
    Write-Host "`nSetting the boot environment.." -ForegroundColor Yellow
    Invoke-Cmdline -application "$($usb.scRoot)Windows\System32\bcdboot" -argumentList "$($usb.scRoot)Windows /s s: /f all"
    #endregion
    #region Copying over unattended.xml
    Write-Host "`nLooking for unattented.xml.." -ForegroundColor Yellow
    if (Test-Path "$($usb.winPESource)scripts\unattended.xml" -ErrorAction SilentlyContinue) {
        Write-Host "Found it! Copying over to scratch drive.." -ForegroundColor Green
        Copy-Item -Path "$($usb.winPESource)\scripts\unattended.xml" -Destination "$($usb.scRoot)Windows\Panther\unattended.xml" | Out-Null
    }
    else {
        Write-Host "Nothing found. Moving on.." -ForegroundColor Red
    }
    #endregion
    #region Copying over non scanstate packages
    Write-Host "`nlooking for *.ppkg files.." -ForegroundColor Yellow
    if (Test-Path "$($usb.winPESource)scripts\*.ppkg" -ErrorAction SilentlyContinue) {
        Write-Host "Found them! Copying over to scratch drive.." -ForegroundColor Yellow
        Copy-Item -Path "$($usb.winPESource)\scripts\*.ppkg" -Destination "$($usb.scRoot)Windows\Panther\" | Out-Null
    }
    else {
        Write-Host "Nothing found. Moving on.." -ForegroundColor Yellow
    }
    #endregion
    #region Applying drivers
    if (Get-ChildItem "$($usb.driverPath)\*.inf" -Recurse -ErrorAction SilentlyContinue) {
        Write-Host "`nApplying drivers.." -ForegroundColor Yellow
        Add-Driver -driverPath $usb.driverPath -scratchDrive $usb.scRoot
    }
    #endregion
    $completed = $true
}
catch {
    $errorMsg = $_.Exception.Message
}
finally {
    $sw.stop()
    if ($exitEarly) {
        $errorMsg = $null
    }
    if ($exitEarlyUsbWipe) {
        Format-USBDisk -targetDrive 1
    }
    if ($errorMsg) {
        Write-Warning $errorMsg
    }
    else {
        if ($completed) {
            if ($usbWipe) {
                Format-USBDisk -targetDrive 1
            }
            Write-Host "`nProvisioning process completed..`nTotal time taken: $($sw.elapsed)" -ForegroundColor Green
        }
        else {
            Write-Host "`nProvisioning process stopped prematurely..`nTotal time taken: $($sw.elapsed)" -ForegroundColor Green
        }
    }
}
#endregion
