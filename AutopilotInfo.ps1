#Get the device's serial number for the hardware info csv
$DeviceSerial = (gwmi win32_bios).SerialNumber
CD\
#Creates the folder C:\scripts to store data
md scripts
cd scripts
#Sets execution policy so it can use the script provided by MS
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned
#Grabs the script from MS needed to generate hardware info for Autopilot
Save-Script -Name Get-WindowsAutoPilotInfo -Path c:\scripts
#Saves info as a csv in C:\scripts. Use this to import the device to Autopilot.
.\Get-WindowsAutoPilotInfo.ps1 -OutputFile .\$DeviceSerial.csv
