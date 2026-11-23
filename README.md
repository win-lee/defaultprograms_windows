# Set-UserFTA (PowerShell)

Ein SetUserFTA-ähnliches Werkzeug als reines PowerShell-Skript: Es setzt **pro Benutzer** (HKCU) die Standardprogramme für Dateiendungen und URL-Protokolle — inklusive des gültigen `UserChoice`-Hashes, damit Windows die Zuordnungen nicht wieder zurücksetzt. Gedacht für **Login-Skripte** in Schul-/Domänenumgebungen.

## Dateien

| Datei | Zweck |
|---|---|
| `Set-UserFTA.ps1` | Das Skript (Windows PowerShell 5.1 und PowerShell 7+, UTF-8 mit BOM) |
| `associations.conf.example` | Beispiel-Konfiguration → zu `associations.conf` umbenennen |
| `README.md` | Diese Anleitung |

## Schnellstart: Login-Skript per GPO

1. Skript + `associations.conf` in eine Freigabe legen, z. B. `\\schule.local\SYSVOL\schule.local\scripts\` (SYSVOL wird automatisch auf alle DCs repliziert; NTFS-Rechte: Domänen-Computer + angemeldete Benutzer brauchen Lesezugriff).
2. GPO (an die OU der Schüler/Studenten binden): **Benutzerkonfiguration → Richtlinien → Windows-Einstellungen → Skripts (Anmeldung)** → Skript hinzufügen:
   - Skriptname: `powershell.exe`
   - Skriptparameter:
     ```
     -ExecutionPolicy Bypass -WindowStyle Hidden -File "\\schule.local\SYSVOL\schule.local\scripts\Set-UserFTA.ps1" -ConfigFile "\\schule.local\SYSVOL\schule.local\scripts\associations.conf"
     ```
3. Alternativ (z. B. ohne GPO) per Aufgabenplanung „Bei Anmeldung" im Benutzerkontext mit gleichem Befehl.

Wichtig: Das Skript läuft als **angemeldeter Benutzer** (nicht als SYSTEM/anderer Admin) — der Hash enthält die SID des Benutzers, und das Profil muss bereits geladen sein.

## Konfiguration (`associations.conf`)

Eine Zuordnung pro Zeile, `Name = ProgID`:

```
.pdf  = MSEdgePDF
http   = MSEdgeHTM
.docx = Word.Document.12
```

- Name **mit** führendem Punkt (`.pdf`) = Dateiendung → `HKCU\...\Explorer\FileExts\<ext>\UserChoice`
- Name **ohne** Punkt (`http`, `https`, `ftp`, `mailto`) = URL-Protokoll → `HKCU\...\Shell\Associations\UrlAssociations\<proto>\UserChoice`
- `#` oder `;` = Kommentar

### ProgIDs herausfinden

Am einfachsten an einem Test-PC die Zuordnung einmal manuell in den Einstellungen setzen und dann auslesen:

```powershell
.\Set-UserFTA.ps1 -Get                 # alle aktuellen UserChoice-Zuordnungen
.\Set-UserFTA.ps1 -Get -GetName .pdf   # nur eine Endung
```

Alternativ in der Registry: `HKLM\SOFTWARE\Classes\<ext>\OpenWithProgids`, `HKLM\SOFTWARE\RegisteredApplications`, `HKLM\SOFTWARE\Clients\StartMenuInternet\<Browser>\Capabilities\URLAssociations`. Typische Werte: Edge `MSEdgeHTM`/`MSEdgePDF`, Chrome `ChromeHTML`, Firefox `FirefoxHTML-...`, VLC `Applications\vlc.exe`, Office `Word.Document.12` usw.

## Befehle

```powershell
.\Set-UserFTA.ps1                                   # associations.conf neben dem Skript anwenden
.\Set-UserFTA.ps1 -ConfigFile \\server\share\associations.conf
.\Set-UserFTA.ps1 -Association @{ '.mp4' = 'Applications\vlc.exe' }   # direkt ohne Datei
.\Set-UserFTA.ps1 -Get                             # aktuelle Zuordnungen anzeigen
.\Set-UserFTA.ps1 -Remove                          # konfigurierte UserChoice-Einträge entfernen
.\Set-UserFTA.ps1 -SelfTest                        # Hash-Funktion gegen Testvektor prüfen
```

Log: `%TEMP%\Set-UserFTA.log` (per `-LogFile` änderbar). Exit-Code `0` = alles OK, `1` = Fehler.

## Funktionsweise (kurz)

Pro Zuordnung wird der `UserChoice`-Schlüssel neu angelegt, `ProgId` geschrieben, der Zeitstempel des Schlüssels gelesen und daraus zusammen mit Endung, Benutzer-SID und einem aus `shell32.dll` ausgelesenen konstanten String der `Hash` berechnet (Base64 eines MD5-basierten, von Microsoft verwendeten Mischverfahrens). Danach werden `Hash` und `ProgId` geschrieben sowie ein `ApplicationAssociationToasts`-Eintrag gesetzt (unterdrückt die Meldung „Standardanwendungen wurden zurückgesetzt") und `SHChangeNotify` ausgelöst. Weil der Hash den Schlüssel-Zeitstempel enthält, sollte das Skript bei **jedem Login** laufen.

## Einschränkungen (wichtig!)

- **UCPD.sys (ab Februar-2024-Updates auf Windows 10 22H2+ und Windows 11):** Windows blockiert Schreibzugriffe Dritter auf die UserChoice-Keys von **`http`, `https` und `.pdf`**. Diese drei Zuordnungen können mit diesem Skript auf solchen Systemen **nicht** gesetzt werden. Alternativen:
  - GPO **„Standard-Zuordnungskonfigurationsdatei festlegen"** (maschinenweite XML-Datei, z. B. per `dism /online /export-defaultappassociations`) — das ist der von Microsoft unterstützte Weg, oder
  - UCPD als Admin einmalig deaktivieren (Neustart nötig), oder
  - manuell über Einstellungen → Apps → Standard-Apps.
  - Alle übrigen Endungen/Protokolle (`.docx`, `.mp4`, `.htm`, `ftp`, …) funktionieren normal.
- **Windows 11 24H2+ (Consumer-Editionen Pro/Home):** Microsoft testet/rollt dort `UserChoiceLatest` mit einem **neuen, maschinengebundenen Hash** aus; sobald pro Benutzer `HashVersion=1` gesetzt ist, wird der klassische `UserChoice`-Hash ignoriert. Nach aktuellem Stand betrifft das Consumer-Editionen; **Education/Enterprise** sind davon laut Hersteller nicht betroffen (VDI-Profil-Roaming). Falls eure Clients betroffen sind: aktuelle SetUserFTA-Version oder die GPO-XML-Lösung verwenden.
- Der Hash ist pro Benutzer (SID) und pro Schlüssel-Zeitstempel gebunden — deshalb bei jedem Login ausführen, nicht nur einmalig.
- Windows-Updates können das undokumentierte Hash-Verfahren ändern; `-SelfTest` prüft die Implementierung gegen einen festen Vektor.

## Lizenz & Credits

Der UserChoice-Hash-Code in `Set-UserFTA.ps1` stammt aus **[PS-SFTA](https://github.com/DanysysTeam/PS-SFTA)** (MIT License, Copyright 2022 Danysys — Danyfirex & Dany3j), das auf der Reverse-Engineering-Arbeit von **Christoph Kolbicz** ([SetUserFTA](https://kolbi.cz/blog/2017/10/25/setuserfta-userchoice-hash-defeated-set-file-type-associations-per-user/), kolbi.cz) und **LMongrain** basiert. Eigener Code: MIT.
