<#
.SYNOPSIS
    Set-UserFTA - Standardprogramme (Datei- und Protokoll-Zuordnungen) pro Benutzer per Login-Skript setzen.

.DESCRIPTION
    Set-UserFTA.ps1 schreibt fuer den aktuell angemeldeten Benutzer in HKCU die
    UserChoice-Werte (ProgId + gueltigen Hash) fuer Dateiendungen und URL-Protokolle.
    Windows akzeptiert die Zuordnungen dann dauerhaft und setzt sie nicht zurueck
    ("Die App-Standards wurden zurueckgesetzt"). Gedacht fuer den Einsatz als
    Login-Skript (z. B. ueber GPO) in Schul- und Domaenenumgebungen - aehnlich wie
    SetUserFTA.exe, aber als reines PowerShell-Skript ohne zusaetzliche .exe.

    Konfiguration ueber eine Datei (Standard: associations.conf neben dem Skript),
    eine Zuordnung pro Zeile:

        .pdf  = MSEdgePDF
        http  = MSEdgeHTM

    Ein Name mit fuehrendem Punkt ist eine Dateiendung (FileExts), ohne Punkt ein
    URL-Protokoll (UrlAssociations). '#' oder ';' leitet einen Kommentar ein.

    Das Skript muss im Kontext des angemeldeten Benutzers laufen (Profil geladen),
    nicht als SYSTEM oder ein anderer Administrator - der Hash enthaelt die SID
    des Benutzers.

    Der UserChoice-Hash-Algorithmus stammt aus PS-SFTA (MIT License, Copyright 2022
    Danysys), basierend auf der Reverse-Engineering-Arbeit von Christoph Kolbicz
    (SetUserFTA, kolbi.cz) und LMongrain. Details siehe README.md.

.PARAMETER ConfigFile
    Pfad zur Konfigurationsdatei mit den Zuordnungen.

.PARAMETER Association
    Hashtable mit zusaetzlichen bzw. ueberschreibenden Zuordnungen, z. B.
    @{ '.pdf' = 'MSEdgePDF'; 'https' = 'MSEdgeHTM' }

.PARAMETER Get
    Zeigt die aktuell gesetzten UserChoice-Zuordnungen des Benutzers an.

.PARAMETER GetName
    Nur mit -Get: eine einzelne Endung bzw. ein Protokoll anzeigen (z. B. '.pdf' oder 'https').

.PARAMETER Remove
    Entfernt die UserChoice-Eintraege fuer alle konfigurierten Namen.

.PARAMETER SelfTest
    Prueft die Hash-Funktion anhand eines festen Testvektors (schreibt nichts in die Registry).

.PARAMETER LogFile
    Pfad der Logdatei (Standard: %TEMP%\Set-UserFTA.log).

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File \\schule.local\SYSVOL\schule.local\scripts\Set-UserFTA.ps1 -ConfigFile \\schule.local\SYSVOL\schule.local\scripts\associations.conf

.EXAMPLE
    .\Set-UserFTA.ps1 -Get

.EXAMPLE
    .\Set-UserFTA.ps1 -Association @{ '.mp4' = 'Applications\vlc.exe' }
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = (Join-Path -Path $PSScriptRoot -ChildPath 'associations.conf'),
    [hashtable]$Association,
    [switch]$Get,
    [string]$GetName,
    [switch]$Remove,
    [switch]$SelfTest,
    [string]$LogFile = (Join-Path -Path $(if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }) -ChildPath 'Set-UserFTA.log')
)

function Write-Log {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $env:USERNAME, $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch { }
}

function Initialize-NativeMethods {
    if ('SetUserFTA.Native.Reg' -as [type]) { return }
    $code = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace SetUserFTA.Native {
    public static class Reg {
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern uint RegOpenKeyExW(IntPtr hKey, string subKey, uint options, uint samDesired, out IntPtr hkResult);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern uint RegQueryInfoKeyW(IntPtr hKey, StringBuilder lpClass, IntPtr lpcbClass, IntPtr lpReserved, IntPtr lpcSubKeys, IntPtr lpcbMaxSubKeyLen, IntPtr lpcbMaxClassLen, IntPtr lpcValues, IntPtr lpcbMaxValueNameLen, IntPtr lpcbMaxValueLen, IntPtr lpcbSecurityDescriptor, out long lpftLastWriteTime);
        [DllImport("advapi32.dll", SetLastError = true)]
        public static extern uint RegCloseKey(IntPtr hKey);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern uint RegDeleteKeyW(IntPtr hKey, string subKey);
    }
    public static class Shell {
        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(int eventId, int flags, IntPtr item1, IntPtr item2);
    }
}
'@
    Add-Type -TypeDefinition $code -ErrorAction Stop
}

function Get-RegistryKeyLastWriteTimeHex {
    param([string]$SubKey)
    Initialize-NativeMethods
    $hk = [IntPtr]::Zero
    $rc = [SetUserFTA.Native.Reg]::RegOpenKeyExW([IntPtr]0x80000001, $SubKey, 0, 0x20019, [ref]$hk)
    if ($rc -ne 0 -or $hk -eq [IntPtr]::Zero) { throw "RegOpenKeyExW fehlgeschlagen (rc=$rc) fuer '$SubKey'" }
    try {
        $ft = [long]0
        $rc = [SetUserFTA.Native.Reg]::RegQueryInfoKeyW($hk, $null, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [ref]$ft)
        if ($rc -ne 0) { throw "RegQueryInfoKeyW fehlgeschlagen (rc=$rc) fuer '$SubKey'" }
    }
    finally {
        [void][SetUserFTA.Native.Reg]::RegCloseKey($hk)
    }
    $hi = $ft -shr 32
    $low = $ft -band 0xFFFFFFFF
    return ($hi.ToString('X8') + $low.ToString('X8')).ToLower()
}

function Remove-RegistrySubKey {
    param([string]$SubKey)
    Initialize-NativeMethods
    $deleted = $false
    try {
        $rc = [SetUserFTA.Native.Reg]::RegDeleteKeyW([IntPtr]0x80000001, $SubKey)
        $deleted = ($rc -eq 0)
    }
    catch { }
    if (-not $deleted) {
        $p = 'HKCU:\' + $SubKey
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-ShellAssocChanged {
    Initialize-NativeMethods
    [SetUserFTA.Native.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Get-UserSid {
    try {
        if (-not ('System.DirectoryServices.AccountManagement' -as [type])) {
            Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
        }
        return ([System.DirectoryServices.AccountManagement.UserPrincipal]::Current).SID.Value.ToLower()
    }
    catch {
        return ((New-Object System.Security.Principal.NTAccount([Environment]::UserName)).Translate([System.Security.Principal.SecurityIdentifier]).Value).ToLower()
    }
}

function Get-UserExperienceString {
    $fallback = 'User Choice set via Windows User Experience {D18B6DD5-6124-4341-9318-804003BAFA0B}'
    try {
        $shell32 = Join-Path -Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::SystemX86)) -ChildPath 'shell32.dll'
        $fs = [System.IO.File]::Open($shell32, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $br = New-Object System.IO.BinaryReader($fs)
        $bytes = $br.ReadBytes(5MB)
        $br.Close()
        $fs.Close()
        $s = [System.Text.Encoding]::Unicode.GetString($bytes)
        $p1 = $s.IndexOf('User Choice set via Windows User Experience')
        if ($p1 -ge 0) {
            $p2 = $s.IndexOf('}', $p1)
            if ($p2 -gt $p1) { return $s.Substring($p1, $p2 - $p1 + 1) }
        }
    }
    catch { }
    return $fallback
}

  function Get-UserChoiceHash {
    [CmdletBinding()]
    param (
      [Parameter( Position = 0, Mandatory = $True )]
      [string]
      $BaseInfo
    )


    function local:Get-ShiftRight {
      [CmdletBinding()]
      param (
        [Parameter( Position = 0, Mandatory = $true)]
        [long] $iValue, 
            
        [Parameter( Position = 1, Mandatory = $true)]
        [int] $iCount 
      )
    
      if ($iValue -band 0x80000000) {
        Write-Output (( $iValue -shr $iCount) -bxor 0xFFFF0000)
      }
      else {
        Write-Output  ($iValue -shr $iCount)
      }
    }
    

    function local:Get-Long {
      [CmdletBinding()]
      param (
        [Parameter( Position = 0, Mandatory = $true)]
        [byte[]] $Bytes,
    
        [Parameter( Position = 1)]
        [int] $Index = 0
      )
    
      Write-Output ([BitConverter]::ToInt32($Bytes, $Index))
    }
    

    function local:Convert-Int32 {
      param (
        [Parameter( Position = 0, Mandatory = $true)]
        [long] $Value
      )
    
      [byte[]] $bytes = [BitConverter]::GetBytes($Value)
      return [BitConverter]::ToInt32( $bytes, 0) 
    }

    [Byte[]] $bytesBaseInfo = [System.Text.Encoding]::Unicode.GetBytes($baseInfo) 
    $bytesBaseInfo += 0x00, 0x00  
    
    $MD5 = New-Object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider
    [Byte[]] $bytesMD5 = $MD5.ComputeHash($bytesBaseInfo)
    
    $lengthBase = ($baseInfo.Length * 2) + 2 
    $length = (($lengthBase -band 4) -le 1) + (Get-ShiftRight $lengthBase  2) - 1
    $base64Hash = ""

    if ($length -gt 1) {
    
      $map = @{PDATA = 0; CACHE = 0; COUNTER = 0 ; INDEX = 0; MD51 = 0; MD52 = 0; OUTHASH1 = 0; OUTHASH2 = 0;
        R0 = 0; R1 = @(0, 0); R2 = @(0, 0); R3 = 0; R4 = @(0, 0); R5 = @(0, 0); R6 = @(0, 0); R7 = @(0, 0)
      }
    
      $map.CACHE = 0
      $map.OUTHASH1 = 0
      $map.PDATA = 0
      $map.MD51 = (((Get-Long $bytesMD5) -bor 1) + 0x69FB0000L)
      $map.MD52 = ((Get-Long $bytesMD5 4) -bor 1) + 0x13DB0000L
      $map.INDEX = Get-ShiftRight ($length - 2) 1
      $map.COUNTER = $map.INDEX + 1
    
      while ($map.COUNTER) {
        $map.R0 = Convert-Int32 ((Get-Long $bytesBaseInfo $map.PDATA) + [long]$map.OUTHASH1)
        $map.R1[0] = Convert-Int32 (Get-Long $bytesBaseInfo ($map.PDATA + 4))
        $map.PDATA = $map.PDATA + 8
        $map.R2[0] = Convert-Int32 (($map.R0 * ([long]$map.MD51)) - (0x10FA9605L * ((Get-ShiftRight $map.R0 16))))
        $map.R2[1] = Convert-Int32 ((0x79F8A395L * ([long]$map.R2[0])) + (0x689B6B9FL * (Get-ShiftRight $map.R2[0] 16)))
        $map.R3 = Convert-Int32 ((0xEA970001L * $map.R2[1]) - (0x3C101569L * (Get-ShiftRight $map.R2[1] 16) ))
        $map.R4[0] = Convert-Int32 ($map.R3 + $map.R1[0])
        $map.R5[0] = Convert-Int32 ($map.CACHE + $map.R3)
        $map.R6[0] = Convert-Int32 (($map.R4[0] * [long]$map.MD52) - (0x3CE8EC25L * (Get-ShiftRight $map.R4[0] 16)))
        $map.R6[1] = Convert-Int32 ((0x59C3AF2DL * $map.R6[0]) - (0x2232E0F1L * (Get-ShiftRight $map.R6[0] 16)))
        $map.OUTHASH1 = Convert-Int32 ((0x1EC90001L * $map.R6[1]) + (0x35BD1EC9L * (Get-ShiftRight $map.R6[1] 16)))
        $map.OUTHASH2 = Convert-Int32 ([long]$map.R5[0] + [long]$map.OUTHASH1)
        $map.CACHE = ([long]$map.OUTHASH2)
        $map.COUNTER = $map.COUNTER - 1
      }

      [Byte[]] $outHash = @(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
      [byte[]] $buffer = [BitConverter]::GetBytes($map.OUTHASH1)
      $buffer.CopyTo($outHash, 0)
      $buffer = [BitConverter]::GetBytes($map.OUTHASH2)
      $buffer.CopyTo($outHash, 4)
    
      $map = @{PDATA = 0; CACHE = 0; COUNTER = 0 ; INDEX = 0; MD51 = 0; MD52 = 0; OUTHASH1 = 0; OUTHASH2 = 0;
        R0 = 0; R1 = @(0, 0); R2 = @(0, 0); R3 = 0; R4 = @(0, 0); R5 = @(0, 0); R6 = @(0, 0); R7 = @(0, 0)
      }
    
      $map.CACHE = 0
      $map.OUTHASH1 = 0
      $map.PDATA = 0
      $map.MD51 = ((Get-Long $bytesMD5) -bor 1)
      $map.MD52 = ((Get-Long $bytesMD5 4) -bor 1)
      $map.INDEX = Get-ShiftRight ($length - 2) 1
      $map.COUNTER = $map.INDEX + 1

      while ($map.COUNTER) {
        $map.R0 = Convert-Int32 ((Get-Long $bytesBaseInfo $map.PDATA) + ([long]$map.OUTHASH1))
        $map.PDATA = $map.PDATA + 8
        $map.R1[0] = Convert-Int32 ($map.R0 * [long]$map.MD51)
        $map.R1[1] = Convert-Int32 ((0xB1110000L * $map.R1[0]) - (0x30674EEFL * (Get-ShiftRight $map.R1[0] 16)))
        $map.R2[0] = Convert-Int32 ((0x5B9F0000L * $map.R1[1]) - (0x78F7A461L * (Get-ShiftRight $map.R1[1] 16)))
        $map.R2[1] = Convert-Int32 ((0x12CEB96DL * (Get-ShiftRight $map.R2[0] 16)) - (0x46930000L * $map.R2[0]))
        $map.R3 = Convert-Int32 ((0x1D830000L * $map.R2[1]) + (0x257E1D83L * (Get-ShiftRight $map.R2[1] 16)))
        $map.R4[0] = Convert-Int32 ([long]$map.MD52 * ([long]$map.R3 + (Get-Long $bytesBaseInfo ($map.PDATA - 4))))
        $map.R4[1] = Convert-Int32 ((0x16F50000L * $map.R4[0]) - (0x5D8BE90BL * (Get-ShiftRight $map.R4[0] 16)))
        $map.R5[0] = Convert-Int32 ((0x96FF0000L * $map.R4[1]) - (0x2C7C6901L * (Get-ShiftRight $map.R4[1] 16)))
        $map.R5[1] = Convert-Int32 ((0x2B890000L * $map.R5[0]) + (0x7C932B89L * (Get-ShiftRight $map.R5[0] 16)))
        $map.OUTHASH1 = Convert-Int32 ((0x9F690000L * $map.R5[1]) - (0x405B6097L * (Get-ShiftRight ($map.R5[1]) 16)))
        $map.OUTHASH2 = Convert-Int32 ([long]$map.OUTHASH1 + $map.CACHE + $map.R3) 
        $map.CACHE = ([long]$map.OUTHASH2)
        $map.COUNTER = $map.COUNTER - 1
      }
    
      $buffer = [BitConverter]::GetBytes($map.OUTHASH1)
      $buffer.CopyTo($outHash, 8)
      $buffer = [BitConverter]::GetBytes($map.OUTHASH2)
      $buffer.CopyTo($outHash, 12)
    
      [Byte[]] $outHashBase = @(0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
      $hashValue1 = ((Get-Long $outHash 8) -bxor (Get-Long $outHash))
      $hashValue2 = ((Get-Long $outHash 12) -bxor (Get-Long $outHash 4))
    
      $buffer = [BitConverter]::GetBytes($hashValue1)
      $buffer.CopyTo($outHashBase, 0)
      $buffer = [BitConverter]::GetBytes($hashValue2)
      $buffer.CopyTo($outHashBase, 4)
      $base64Hash = [Convert]::ToBase64String($outHashBase) 
    }

    Write-Output $base64Hash
  }

function Get-AssociationTarget {
    param([string]$Name)
    if ($Name.StartsWith('.')) {
        $sub = "Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Name\UserChoice"
    }
    else {
        $sub = "Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$Name\UserChoice"
    }
    [pscustomobject]@{ Name = $Name; SubKey = $sub; HivePath = "HKEY_CURRENT_USER\$sub" }
}

function Read-AssociationConfig {
    param([string]$Path)
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Konfigurationsdatei nicht gefunden: $Path"
        return $map
    }
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $l = $line.Trim()
        if ($l -eq '' -or $l.StartsWith('#') -or $l.StartsWith(';')) { continue }
        $idx = $l.IndexOf('=')
        if ($idx -lt 1) { continue }
        $name = $l.Substring(0, $idx).Trim()
        $progId = $l.Substring($idx + 1).Trim()
        if ($name -ne '' -and $progId -ne '') { $map[$name] = $progId }
    }
    return $map
}

function Show-CurrentAssociations {
    param([string]$Only)
    $results = @()
    $cu = $null
    try { $cu = [Microsoft.Win32.Registry]::CurrentUser } catch { }
    if (-not $cu) { Write-Log 'Registry nicht verfuegbar.'; return }
    foreach ($pair in @(
        @{ Typ = 'Datei';     Root = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts' },
        @{ Typ = 'Protokoll'; Root = 'Software\Microsoft\Windows\Shell\Associations\UrlAssociations' })) {
        $root = $cu.OpenSubKey($pair.Root)
        if (-not $root) { continue }
        foreach ($name in $root.GetSubKeyNames()) {
            if ($Only -and $name -ne $Only) { continue }
            $uc = $root.OpenSubKey("$name\UserChoice")
            if ($uc) {
                $p = $uc.GetValue('ProgId')
                if ($p) { $results += [pscustomobject]@{ Typ = $pair.Typ; Name = $name; ProgId = $p; Hash = $uc.GetValue('Hash') } }
                $uc.Close()
            }
        }
        $root.Close()
    }
    if ($results.Count -gt 0) { $results | Format-Table -AutoSize | Out-Host }
    else { Write-Log 'Keine UserChoice-Eintraege vorhanden.' }
}

function Set-OneAssociation {
    param([string]$Name, [string]$ProgId)
    $target = Get-AssociationTarget -Name $Name
    Remove-RegistrySubKey -SubKey $target.SubKey
    [Microsoft.Win32.Registry]::SetValue($target.HivePath, 'ProgId', $ProgId, [Microsoft.Win32.RegistryValueKind]::String) | Out-Null
    $regdate = Get-RegistryKeyLastWriteTimeHex -SubKey $target.SubKey
    $baseInfo = ($Name + (Get-UserSid) + $ProgId + $regdate + (Get-UserExperienceString)).ToLower()
    $hash = Get-UserChoiceHash -BaseInfo $baseInfo
    if ([string]::IsNullOrEmpty($hash)) { throw "Hash konnte nicht berechnet werden fuer '$Name'" }
    [Microsoft.Win32.Registry]::SetValue($target.HivePath, 'Hash', $hash, [Microsoft.Win32.RegistryValueKind]::String) | Out-Null
    [Microsoft.Win32.Registry]::SetValue('HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts', "${ProgId}_$Name", 0, [Microsoft.Win32.RegistryValueKind]::DWord) | Out-Null
    return $hash
}

function Remove-OneAssociation {
    param([string]$Name, [string]$ProgId)
    $target = Get-AssociationTarget -Name $Name
    Remove-RegistrySubKey -SubKey $target.SubKey
    if ($ProgId) {
        try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts' -Name "${ProgId}_$Name" -ErrorAction Stop } catch { }
    }
}

if ($SelfTest) {
    $vectorBaseInfo = ('.jpg' + 'S-1-5-21-463486358-3398762107-1964875780-1001' + 'Bearly.jpg' + '01d3442a29887400' + 'User Choice set via Windows User Experience {D18B6DD5-6124-4341-9318-804003BAFA0B}').ToLower()
    $vectorHash = Get-UserChoiceHash -BaseInfo $vectorBaseInfo
    if ($vectorHash -eq '9G35hr/FIRY=') {
        Write-Log "SelfTest OK (Hash $vectorHash)"
        exit 0
    }
    else {
        Write-Log "SelfTest FEHLGESCHLAGEN: erwartet '9G35hr/FIRY=', erhalten '$vectorHash'"
        exit 1
    }
}

$entries = Read-AssociationConfig -Path $ConfigFile
if ($null -ne $Association) {
    foreach ($key in @($Association.Keys)) { $entries[$key] = $Association[$key] }
}

if ($Get) {
    Show-CurrentAssociations -Only $GetName
    exit 0
}

if ($entries.Count -eq 0) {
    Write-Log "Keine Zuordnungen konfiguriert (ConfigFile: $ConfigFile). Beende."
    exit 0
}

if ($env:USERNAME -eq 'SYSTEM' -or $env:USERNAME -like '*$') {
    Write-Log "WARNUNG: Skript laeuft offenbar als '$env:USERNAME' - HKCU-Hash gilt nur fuer den jeweiligen Benutzer. Im Benutzerkontext ausfuehren!"
}

$ok = 0
$fail = 0
foreach ($name in @($entries.Keys)) {
    $progId = $entries[$name]
    try {
        if ($Remove) {
            Remove-OneAssociation -Name $name -ProgId $progId
            Write-Log "Entfernt: $name"
            $ok++
        }
        else {
            $hash = Set-OneAssociation -Name $name -ProgId $progId
            Write-Log "Gesetzt: $name = $progId (Hash $hash)"
            $ok++
        }
    }
    catch {
        Write-Log "FEHLER bei ${name}: $($_.Exception.Message)"
        $fail++
    }
}

if (-not $Remove -and $ok -gt 0) { Invoke-ShellAssocChanged }
Write-Log "Fertig: $ok erfolgreich, $fail Fehler."
if ($fail -gt 0) { exit 1 } else { exit 0 }
