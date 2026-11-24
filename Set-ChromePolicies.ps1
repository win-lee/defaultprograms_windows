<#
.SYNOPSIS
    Set-ChromePolicies - Chrome-Richtlinien gegen First-Run-, Standardbrowser- und Suchmaschinen-Abfragen setzen.

.DESCRIPTION
    Schreibt unter HKLM\SOFTWARE\Policies\Google\Chrome die Chrome-Enterprise-Richtlinien,
    damit Chrome beim ersten Start nicht fragt ("Als Standardbrowser festlegen?",
    "Standardsuchmaschine waehlen?"), sondern direkt eingabebereit oeffnet:

      DefaultBrowserSettingEnabled = 0   kein Default-Browser-Check/Prompt mehr
      HideFirstRunExperience       = 1   First-Run-/Welcome-Seite unterdruecken
      MetricsReportingEnabled      = 0   keine "Statistiken senden"-Abfrage
      BrowserAddPersonEnabled      = 0   kein "Weitere Person hinzufuegen"
      RestoreOnStartup             = 5   beim Start neuer Tab (keine Wiederherstellungs-Meldung)
      DefaultSearchProviderEnabled = 1   Standardsuchmaschine per Richtlinie festlegen (Google)
      DefaultSearchProviderName / Keyword / SearchURL / SuggestURL = Google

    Standard: maschinenweit (HKLM) -> braucht Administratorrechte, z. B. als
    Computer-Startskript per GPO (laeuft als SYSTEM beim Boot, keine Admin-Anmeldung noetig),
    ueber GPO-Registrierungseinstellungen oder mit den chrome.admx-Templates im zentralen Speicher.

    Mit -Scope User schreibt das Skript stattdessen nach HKCU\Software\Policies\Google\Chrome
    (Chrome liest Richtlinien aus HKLM UND HKCU; bei Konflikten gewinnt HKLM). Dann braucht es
    KEINE Admin-Rechte und kann als normales Benutzer-Anmeldeskript laufen - z. B. als zweite
    Zeile derselben GPO wie Set-UserFTA.ps1:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...\Set-ChromePolicies.ps1 -Scope User

    Mit -Remove werden die Werte wieder entfernt.

    Hinweis: Set-UserFTA.ps1 setzt Chrome bereits pro Benutzer als Standardbrowser
    (UserChoice). Diese Richtlinien stellen sicher, dass Chrome auch dann nicht nachfragt,
    wenn die UserChoice-Schreibzugriffe z. B. durch UCPD.sys blockiert werden (http/https).

.EXAMPLE
    .\Set-ChromePolicies.ps1            # Richtlinien setzen (als Admin)
    .\Set-ChromePolicies.ps1 -Remove   # Richtlinien entfernen
#>
[CmdletBinding()]
param(
    [ValidateSet('Machine', 'User')]
    [string]$Scope = 'Machine',
    [switch]$Remove,
    [string]$LogFile = (Join-Path -Path $(if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }) -ChildPath 'Set-ChromePolicies.log')
)

function Write-Log {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $env:USERNAME, $Message
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch { }
}

if ($env:OS -ne 'Windows_NT') {
    Write-Log 'Dieses Skript laeuft nur unter Windows.'
    exit 1
}

$admin = $false
try {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
catch { }
if ($Scope -eq 'Machine' -and -not $admin -and -not $Remove) {
    Write-Log 'FEHLER: HKLM-Richtlinien brauchen Administratorrechte. Bitte als Admin ausfuehren (z. B. Computer-Startskript per GPO) oder -Scope User verwenden.'
    exit 1
}

$keyPath = if ($Scope -eq 'User') { 'HKEY_CURRENT_USER\Software\Policies\Google\Chrome' } else { 'HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Google\Chrome' }
Write-Log "Set-ChromePolicies Start: Scope=$Scope, Ziel=$keyPath, User=$env:USERNAME, Admin=$admin"

$policies = @(
    [pscustomobject]@{ Name = 'DefaultBrowserSettingEnabled';       Type = 'DWord';  Value = 0 },
    [pscustomobject]@{ Name = 'HideFirstRunExperience';             Type = 'DWord';  Value = 1 },
    [pscustomobject]@{ Name = 'MetricsReportingEnabled';            Type = 'DWord';  Value = 0 },
    [pscustomobject]@{ Name = 'BrowserAddPersonEnabled';            Type = 'DWord';  Value = 0 },
    [pscustomobject]@{ Name = 'RestoreOnStartup';                   Type = 'DWord';  Value = 5 },
    [pscustomobject]@{ Name = 'DefaultSearchProviderEnabled';       Type = 'DWord';  Value = 1 },
    [pscustomobject]@{ Name = 'DefaultSearchProviderName';          Type = 'String'; Value = 'Google' },
    [pscustomobject]@{ Name = 'DefaultSearchProviderKeyword';       Type = 'String'; Value = 'google.com' },
    [pscustomobject]@{ Name = 'DefaultSearchProviderSearchURL';     Type = 'String'; Value = 'https://www.google.com/search?q={searchTerms}' },
    [pscustomobject]@{ Name = 'DefaultSearchProviderSuggestURL';    Type = 'String'; Value = 'https://www.google.com/complete/search?output=chrome&q={searchTerms}' }
)

$ok = 0
$fail = 0
foreach ($p in $policies) {
    try {
        if ($Remove) {
            Remove-ItemProperty -Path $keyPath -Name $p.Name -ErrorAction Stop
            Write-Log "Entfernt: $($p.Name)"
        }
        else {
            $kind = if ($p.Type -eq 'DWord') { [Microsoft.Win32.RegistryValueKind]::DWord } else { [Microsoft.Win32.RegistryValueKind]::String }
            [Microsoft.Win32.Registry]::SetValue($keyPath, $p.Name, $p.Value, $kind) | Out-Null
            Write-Log "Gesetzt: $($p.Name) = $($p.Value) ($($p.Type))"
        }
        $ok++
    }
    catch {
        Write-Log "FEHLER bei $($p.Name): $($_.Exception.Message)"
        $fail++
    }
}

if (-not $Remove -and $ok -gt 0) {
    Write-Log "Fertig ($Scope). Die Richtlinien greifen beim naechsten Chrome-Start (chrome://policy zeigt sie als \"enforced\")."
}
Write-Log "Ergebnis: $ok ok, $fail Fehler."
if ($fail -gt 0) { exit 1 } else { exit 0 }
