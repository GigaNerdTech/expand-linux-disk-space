# Filesystem resizing script
# For Pure Storage, vSphere 6.5, Red Hat Enterprise Linux 7 on XFS
# Written by Joshua Woleben
# 3/1/19
# Requirements:
# PowerCLI for VMware
# PureStorage PowerShell SDK for Pure array
# Authentication credentials for Pure, vSphere and RHEL root

# Command line parameters:
[CmdletBinding()]
Param (
    [Parameter(Mandatory=$true)]
    [string] $linux_host,

    [Parameter(Mandatory=$true)]
    [string] $filesystem,

    [Parameter(Mandatory=$true)]
    [string] $vsphere_host,

    [Parameter(Mandatory=$true)]
    [string] $pure_array,

    [Parameter(Mandatory=$true)]
    [int] $space_gb,

    [Parameter(Mandatory=$true)]
    [string] $vsphere_user,

    [Parameter(Mandatory=$false)]
    [switch] $actually_execute=$false
)

$TranscriptFile = "C:\Temp\LinuxExpandScript_$(get-date -f MMddyyyyHHmmss).txt"
Start-Transcript -Path $TranscriptFile
Write-Output "Initializing..."

# Import required modules
Import-Module PureStoragePowerShellSDK
Import-Module VMware.VimAutomation.Core

# Define a gigabyte in bytes
$gb = 1073741824

# Gather authentication credentials
Write-Output "Please enter the following credentials: `n`n"

# Collect vSphere credentials
Write-Output "`n`nvSphere credentials:`n"
Write-Output "vSphere user: $vsphere_user"
$vsphere_pwd = Read-Host -Prompt "Enter the password for connecting to vSphere: " -AsSecureString

# Collect Linux credentials
Write-Output "`n`nRed Hat Linux credentials:`n"
Write-Output "Linux User: root"
$linux_user = "root"
$linux_pwd = Read-Host -Prompt "Enter the password for Linux: " -AsSecureString

# Create credential objects for all layers

$vsphere_creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $vsphere_user,$vsphere_pwd -ErrorAction Stop
$linux_creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $linux_user,$linux_pwd -ErrorAction Stop

Connect-VIServer -Server $vsphere_host -Credential $vsphere_creds -ErrorAction Stop

################################
# Connect to VM, get SCSI ID list and physical disks
################################

# Determine logical volume for filesystem
Write-Output "Getting logical volume for filesystem $filesystem ..."
$lv_command = "/usr/bin/grep `"$filesystem`" /etc/fstab | /usr/bin/awk -F`" `" '{print `$1}'| /usr/bin/head -1 2>/dev/null"
Write-Verbose "Logical volume command: $lv_command"
$lv_to_extend = (Invoke-VMScript -VM $linux_host -GuestCredential $linux_creds -ScriptText $lv_command -ErrorAction Stop).Trim()

Write-Verbose "LV to extend: $lv_to_extend"

# Determine volume group for located logical volume
Write-Output "Getting volume group for logical volume $lv_to_extend ..."
$vg_command = "export LVM_SUPPRESS_FD_WARNINGS=1; /usr/sbin/lvdisplay `"$lv_to_extend`" | /usr/bin/grep `"VG Name`" | /usr/bin/sed -e `"s/VG Name//g`" | /usr/bin/tr -d `"[:space:]`" 2>/dev/null"
Write-Verbose "Volume group command: $vg_command"
$vg_to_extend = (Invoke-VMScript -VM $linux_host -GuestCredential $linux_creds -ScriptText $vg_command -ErrorAction Stop)
Write-Verbose "Volume group to manage: $vg_to_extend"

# Build list of physical volumes in located volume group
Write-Output "Gathering list of physical volumes in volume group $vg_to_extend ..."
$pvs_command = "export LVM_SUPPRESS_FD_WARNINGS=1; /usr/sbin/pvs -q 2>/dev/null | /usr/bin/awk -F' ' '{print `$1, `$2}' | /usr/bin/grep `"$vg_to_extend`" | /usr/bin/cut -f1 -d`" `""
Write-Verbose "Physical volume command: $pvs_command"
$pv_list = (Invoke-VMScript -VM $linux_host -GuestCredential $linux_creds -ScriptText $pvs_command -ErrorAction Stop).ToString().Split("`n")
Write-Verbose "PV List in above volume group: "
Write-Verbose ($pv_list -join "`n")

# Build list of UUIDs in Linux for each PV
Write-Output "Gathering WWNs for all physical volume groups in $vg_to_extend ..."
$pv_uuid_list = @()
$pv_array = @()
ForEach ($pv in $pv_list) {
    if ($pv -match "\/dev") {
        Write-Verbose "PV $pv added!"
        $pv_array += ($pv + " ")
    }
}
$pv_uuid_command = "for PV in $pv_array ; do /usr/sbin/udevadm info -q all -n `$PV | /usr/bin/grep `"ID_WWN_WITH_EXTENSION`" | /usr/bin/cut -f2 -d= ; done"
Write-Verbose "PV WWN Command: $pv_uuid_command"
$pv_uuid_list += (Invoke-VMScript -VM $linux_host -GuestCredential $linux_creds -ScriptText $pv_uuid_command -ErrorAction Stop).ToString().Trim().Split("`n")

Write-Verbose "PV WWN List:"
Write-Verbose ($pv_uuid_list -join "`n").ToString()

# Determine disk expansion mode by checking for the presence of a WWN property in Linux
Write-Output "Determining appropriate mode for disk expansions..."
if (($pv_uuid_list -join " ").ToString() -NotMatch "0x") {
    Write-Output "VMDK mode engaged."
    $vmdk_mode = $true
}
else {
    Write-Output "RDM mode engaged."
    $rdm_mode = $true
}

# If RDM mode detected, gather pure credentials
if ($rdm_mode) {
    Write-Output "Pure Storage Credentials:`n"
    Write-Output "Pure user: wojo032043"
    $pure_user = "wojo032043"
    $pure_pwd = Read-Host -Prompt "Enter the password for the Pure storage array user: " -AsSecureString
    $pure_creds = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $pure_user,$pure_pwd -ErrorAction Stop
    $pure_connect = New-PfaArray -EndPoint $pure_array -Credentials $pure_creds -IgnoreCertificateError -ErrorAction Stop
}

# Build list of SCSI ID to physical disks if in VMDK mode
if ($vmdk_mode) {
    Write-Output "Gathering SCSI ports from  host $linux_host ..."
    $scsi_command = "/usr/bin/lsscsi | /usr/bin/grep -v 'dvd' | /usr/bin/sed -e `"s/Virtual disk/Virtualdisk/`" | /usr/bin/awk -F`" `" '{print `$1, `$6}' 2>/dev/null"
    Write-Verbose "SCSI command to issue: $scsi_command"
    $scsi_ids = (Invoke-VMScript -VM $linux_host -GuestCredential $linux_creds -ScriptText $scsi_command -ErrorAction Stop).Split("`n")

    $scsi_list=@{}

    ForEach ($line in $scsi_ids) {
          $line | Select-String -Pattern '\[(\d+):\d+:(\d+):\d\]' -AllMatches | ForEach-Object -Process { if ($_.Matches.Captures.Groups[2].Value -ne $null) { $device = $_.Matches.Captures.Groups[2].Value.ToString()}; if ($_.Matches.Captures.Groups[1].Value -ne $null) { $controller = $_.Matches.Captures.Groups[1].Value.ToString() } }

          $id = ($controller + ":" + $device)
          $line -match "(/dev/.*)"
          $disk = $Matches[0]
          if ($disk -ne $null) {
            $scsi_list[$disk]=$id
         }
    }
    Write-Verbose "SCSI List: "
    Write-Verbose $scsi_list
}
# Get list of VM disks in Linux guest with their UUID
Write-Output "Gathering list of virtual disks attached to VM $linux_host ..."
$vm_disk_list = @{}
$vm_disks = Get-HardDisk -VM $linux_host -ErrorAction Stop
Write-Verbose "VM disks discovered: "

# If RDM mode, get WWN for each virtual disk and build index hash -- key: WWN; value: VM disk ID
if ($rdm_mode) {
    Write-Output "Gathering WWN list for disks attached to VM $linux_host ..."
    ForEach ($vmdk in $vm_disks) {
        if (Get-Member -InputObject $vmdk -Name "ScsiCanonicalName" -MemberType Properties) {
            $vm_disk_list[($vmdk | Select -ExpandProperty "ScsiCanonicalName")]=$vmdk
        }
    }
}

# If VMMDK mode, get SCSI ports from each virtual disk and build index hash -- key: SCSI port; value: VMDK ID
if ($vmdk_mode) {
    Write-Output "Gathering SCSI port properties for each disk attached to $linux_host ..."
    Get-HardDisk -VM $linux_host | ForEach-Object -Process { $hd = $_; $ctrl=$_.Parent.Extensiondata.Config.Hardware.Device | where {$_.Key -eq $hd.ExtensionData.ControllerKey}; $vm_disk_list[(($ctrl.BusNumber).ToString() + ":" + ($_.ExtensionData.UnitNumber).ToString())]=$hd }
}

# Output list of built disks if in verbose mode
Write-Verbose "Disks discovered on VM $linux_host :"
foreach ($key in $vm_disk_list.Keys) {
    Write-Verbose $key
    Write-Verbose $vm_disk_list[$key]
}

# Set up variable arrays for VM disks to expand, associated with physical disks on VM
$uuid_list=@()
$vm_disks_to_expand = @()

# if RDM mode, find VM disks needing expansion by matching physical volume with virtual disk using WWN
if ($rdm_mode) {
    Write-Output "Matching physical disks on $linux_host with virtual disks needing expansion using WWNs..."

    # Loop through all discovered associated physical volumes for the volume group
    ForEach ($pv_uuid in $pv_uuid_list) {

        # Translate the Linux WWN to a vMWare WWN by removing the 0x and adding "naa."
        $vm_uuid = ("naa." + (($pv_uuid.ToString()) -replace "0x",""))

        # cross reference the VM disk list given the index to the UUID and add to list
        $vm_disks_to_expand += ($vm_disk_list[$vm_uuid])
        if ($vm_disk_list[$vm_uuid] -ne $null) {
            $uuid_list += $vm_uuid
        }

    }
}

# If VMDK mode, find VM disks needing expansion by matching physical volumes with virtual disks using SCSI port information
if ($vmdk_mode) {
    Write-Output "Matching physical disks on $linux_host with virtual disks needing expansion using SCSI port information..."
    # Loop through each physical volume
    ForEach ($pv in $pv_list) {

        # Check for null output, sometimes Linux returns blank lines
        if ($pv -match 'dev') {

            # Cross reference physical volume to virtual disk using index of SCSI port configurations
            $vm_disks_to_expand += $vm_disk_list[$scsi_list[$pv]]
        }
   }
}

# Write out VMDK list if in verbose mode
Write-Verbose "VMDKs needing expansion: "
Write-Verbose ($vm_disks_to_expand -join "`n").ToString()

# If in RDM mode, also output the UUIDs of the RDMs to expand 
if ($rdm_mode) {
    Write-Verbose "UUIDs of RDMs to expand: "
    Write-Verbose ($uuid_list -join "`n").ToString()
}
# Get list of LUNs from Pure Array
if ($rdm_mode) {
$pure_vols = @()
    
    # Loop through each discovered UUID from the VM
    ForEach ($uuid in $uuid_list) {

        # Translate WWN from vMWare to Pure by removing the "naa." and the first 8 digits of the WWN, then capitalizing it
        $pure_uuid = ($uuid -replace "naa\.\w{8}","").ToUpper()
        Write-Verbose "Pure WWN: $pure_uuid"

        # Connect to Pure array and get volume information based on WWN
        $pure_vols += (Get-PfaVolumes -Array $pure_connect -Filter "serial='$pure_uuid'" -ErrorAction Stop)
    }
    Write-Verbose "Pure Volumes to expand: "
    Write-Verbose (($pure_vols | Select -ExpandPropert "name") -join "`n").ToString()
}

# only do this if actually_execute is set
if ($actually_execute) {
#  Pause for confirmation
$stop_var = Read-Host -Prompt "Please review output and press any key to continue, or Ctrl + C to stop:"

$total_requested_space_gb = $space_gb
################################
# Resize appropriate Pure Volumes
################################

# calculate per-volume space requirements
$pure_vol_count = $pure_vols.Count
$per_vol_sizing = ($total_requested_space_gb * $gb) / $pure_vol_count

# Expand each volume
if ($rdm_mode) {
    Write-Output "Expanding all identified Pure volumes..."
    ForEach ($vol in $pure_vols) {
        # Get currrent size
        $current_size = (Get-PfaVolume -Array $pure_connect -Name ($vol | Select  -ExpandProperty "name").ToString() -ErrorAction Stop | Select -ExpandProperty Size)
        
        Write-Verbose "Current size: $current_size"
        # Calculate new size
        $new_total_size = [int64]($current_size + $per_vol_sizing)

        Write-Verbose "New size: $new_total_size"
        # Issue resize command to volume
        Resize-PfaVolume -Array $pure_connect -VolumeName ($vol | Select -ExpandProperty "name").ToString() -NewSize ([int64]$new_total_size) -ErrorAction Stop
    }

    # Disconnect from Pure Array
    Write-Output "Disconnecting from Pure array..."
    Disconnect-PfaArray -Array $pure_connect
}


if ($vmdk_mode) {
# Calculate per VM disk space requirements
$vm_disk_count = $vm_disks_to_expand.Count
$per_vm_disk_sizing = $total_requested_space_gb / $vm_disk_count

    # Resize virtual disks
    Write-Output "Resizing specified virtual disks..."
    ForEach ($vm_disk in $vm_disks_to_expand) {

        # Get current size
        $current_size = ($vm_disk | Select -ExpandProperty "CapacityGB")
        Write-Verbose "Current size: $current_size"

        # Calculate total size
        $new_total_size = $current_size + $per_vm_disk_sizing
        Write-Verbose "New size: $new_total_size"

        # Expand VMDK
        Set-HardDisk -HardDisk $vm_disk -CapacityGB $new_total_size -Confirm:$false -ErrorAction Stop
    }
}
<#
# Issue storage rescan to proper cluster (this is likely unneeded and therefore commented out)
Write-Output "Issuing rescan of vSphere storage..."
$vm_host = Get-VMHost -VM $linux_host
Get-VMHostStorage -VMHost $vm_host  -Refresh -RescanAllHba -RescanVmfs -ErrorAction Stop
#>

# Execute rescan-scsi-bus.sh --resize command in Linux
Write-Output "Issuing rescan to Linux host..."
$rescan_scsi_command = "/bin/rescan-scsi-bus.sh --resize"
Invoke-VMScript -VM $linux_host -GuestCredential $linux_creds -ScriptText $rescan_scsi_command -ErrorAction Stop

# Execute partprobe command in Linux
Write-Output "Probing partitions on Linux host..."
$partprobe_command = "/sbin/partprobe"
Invoke-VMScript -VM $linux_host -GuestCredential $linux_creds -ScriptText $partprobe_command -ErrorAction Stop

# Execute pvresize command on virtual disks
Write-Output "Executing pvresize on each physical volume..."
$pv_resize_command = ("export LVM_SUPPRESS_FD_WARNINGS=1; for PV in " + ($pv_list -join " ") + " ; do /sbin/pvresize `$PV; done")
Invoke-VMScript -VM $linux_host -GuestCredential $linux_creds -ScriptText $pv_resize_command -ErrorAction Stop

# issue lvextend command in Linux (if you use -r on this commmand we can skip the next call)
Write-Output "Executing lvextend in Linux..."
$lvextend_command = "export LVM_SUPPRESS_FD_WARNINGS=1; /sbin/lvextend -r  -l 100%VG $lv_to_extend"
Invoke-VMScript -VM $linux_host -GuestCredential $linux_creds -ScriptText $lvextend_command -ErrorAction Stop

# Store output of df for filesystem
Write-Output "Gathering new size..."
$df_command = "/bin/df -h $filesystem"
$df_output = (Invoke-VMScript -VM $linux_host -GuestCredential $linux_creds -ScriptText $df_command -ErrorAction Stop) 
Write-Output $df_output

# Disconnect from vCenter
Disconnect-VIServer -Server $vsphere_host -Force -Confirm:$false

}
# Send emailed report

# Generate email report
$email_list=@("cachedba@mhd.com")
$subject = "Disk expansion analysis report"
if ($actually_execute) {
    $subject = $subject + " - Action Taken!"
    $body = "DISK ANALYSIS REPORT FOR SERVER " + $linux_host + " (Action taken)`n`n`n"
}
else {
    $body = "DISK ANALYSIS REPORT FOR SERVER " + $linux_host + " (Analysis only - no action taken)`n`n`n"
}
if ($rdm_mode) {
    $body = $body + "Mode: RDM`n`n"
}
if ($vmdk_mode) {
    $body = $body + "Mode: VMDK`n`n"
}
$body = $body + "Filesystem requested: " + $filesystem + "`n`n"
$body = $body + "Space requested: " + $space_gb + " GB`n`n"
$body = $body + "Logical volume discovered: " + $lv_to_extend + "`n`n"
$body = $body + "Volume group discovered: " + $vg_to_extend + "`n`n"
$body = $body + "Physical disks discovered in volume group:`n"
$body = $body + ($pv_list -join "`n") + "`n`n"
$body = $body + "`n`nVirtual disks requiring expansion:`n"
ForEach ($vmdisk in $vm_disks_to_expand) {
    $body = $body + ($vmdisk | Select -ExpandProperty "Id").ToString() + "`n"
}
if ($rdm_mode) {
    $body = $body + "`n`nPure volumes requiring expansion:`n"
    ForEach ($vol in $pure_vols) {
        $body = $body + ($vol | Select -ExpandProperty "name").ToString() + "`n"
    }
}
$body = $body + "`n`nEND OF REPORT"

Stop-Transcript

$MailMessage = @{
    To = $email_list
    From = "DiskAnalysisReport<Donotreply@example.com>"
    Subject = $subject
    Body = $body
    SmtpServer = "smtp.example.com"
    ErrorAction = "Stop"
    Attachment = $TranscriptFile
}
Send-MailMessage @MailMessage

