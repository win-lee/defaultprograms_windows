# Installation – Set-UserFTA + Chrome-Richtlinien

Skript-Ablage in dieser Umgebung: **`\\hbla\netlogon\default`**
(andere Ablage: die UNC-Pfade unten einfach anpassen)

## 1. Dateien nach `\\hbla\netlogon\default` kopieren

Aus diesem Repo kopieren:

```
Set-UserFTA.ps1
Set-ChromePolicies.ps1
associations.conf.example   -> umbenennen in: associations.conf   (und anpassen, siehe 2.)
README.md
INSTALL.md
```

Berechtigung auf der Freigabe: „Authentifizierte Benutzer“ (und Domänen-Computer) brauchen **Lesen**.

## 2. `associations.conf` anpassen (eine Zeile pro Zuordnung: `Name = ProgID`)

```ini
# Name MIT Punkt = Dateiendung, OHNE Punkt = URL-Protokoll
# ProgIDs am Test-PC ermitteln:  powershell -File "\\hbla\netlogon\default\Set-UserFTA.ps1" -Get
.html  = ChromeHTML
.htm   = ChromeHTML
http   = ChromeHTML
https  = ChromeHTML
# .pdf  = MSEdgePDF            # Achtung: .pdf/http/https blockiert UCPD.sys auf neueren Builds -> README
.docx  = Word.Document.12
.xlsx  = Excel.Sheet.12
.pptx  = PowerPoint.Show.12
# .mp4  = Applications\vlc.exe
```

## 3. GPO einrichten (Benutzer-Anmeldeskripts)

GPO an die **OU der Schüler-Clients** binden, dann:
**Benutzerkonfiguration → Richtlinien → Windows-Einstellungen → Skripts (Anmeldung) → Hinzufügen**

**Eintrag 1**
- Skriptname: `powershell.exe`
- Skriptparameter (alles in das eine Parameter-Feld kopieren):
```
-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "\\hbla\netlogon\default\Set-UserFTA.ps1" -ConfigFile "\\hbla\netlogon\default\associations.conf"
```

**Eintrag 2**
- Skriptname: `powershell.exe`
- Skriptparameter:
```
-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "\\hbla\netlogon\default\Set-ChromePolicies.ps1" -Scope User
```

Danach auf einem Testclient: `gpupdate /force`, dann ab-/anmelden.

## 4. Empfohlene Richtlinien (optional)

- **„Anmeldeskripts synchron ausführen“** aktivieren: Computerkonfiguration → Administrative Vorlagen → System → Anmeldeskripts (damit das Schreiben fertig ist, bevor die Shell die Zuordnungen liest).
- Nur wenn ihr statt „Skripts (Anmeldung)“ den Tab **„PowerShell-Skripte“** verwendet: „Skriptausführung aktivieren“ (Computer → Administrative Vorlagen → Windows PowerShell) auf „Lokale Skripte zulassen“ setzen.
- Zum Debuggen vorübergehend „Anmeldeskripts sichtbar ausführen“ aktivieren.

## 5. Kontrolle nach dem Anmelden (Test-User)

```powershell
Get-Content "$env:TEMP\Set-UserFTA.log" -Tail 15
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.html\UserChoice" /v ProgId
reg query "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.html\UserChoiceLatest"
# im Chrome: chrome://policy  (Richtlinien als "enforced" sichtbar)
```

Manueller Testlauf (als angemeldeter Benutzer, keine Admin-Rechte nötig):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "\\hbla\netlogon\default\Set-UserFTA.ps1" -ConfigFile "\\hbla\netlogon\default\associations.conf"
powershell -NoProfile -ExecutionPolicy Bypass -File "\\hbla\netlogon\default\Set-UserFTA.ps1" -SelfTest
```

## 6. Wichtige Hinweise

- **Kein Admin nötig:** Beide Skripte laufen als Benutzer-Anmeldeskripts im Schüler-Kontext (HKCU). Nichts nach HKLM, kein SYSTEM.
- `Set-UserFTA.ps1` schreibt bei Windows 11 24H2/25H2+ automatisch **beide** Schlüssel (`UserChoice` + `UserChoiceLatest`); `-SelfTest` zeigt die Kanarienprüfung (`ok` = Hash-Schema erkannt).
- **`http`, `https`, `.pdf`** werden auf neueren Windows-Builds (UCPD.sys) gegen Skript-Schreibzugriffe geschützt → die nimmt das Skript nicht vor; für diese ggf. GPO-XML („Standard-Zuordnungskonfigurationsdatei“) nutzen. Chrome fragt dank `Set-ChromePolicies.ps1 -Scope User` trotzdem nicht nach.
- Probleme? Siehe README: „Fehlerbehebung“, „GPO: Skript läuft beim Anmelden nicht / greift nicht“, „Einschränkungen“.
