<#
.SYNOPSIS
    Zestawia tunele SSH przez plink.exe (PuTTY) na podstawie pliku ptunnel.csv.

.DESCRIPTION
    Akcje:
      start    - uruchamia tunele (pomija już działające)
      stop     - zamyka tunele uruchomione przez ten skrypt
      restart  - stop + start
      status   - pokazuje stan połączeń i nasłuchujących portów

    Tunele idące przez ten sam serwer SSH są łączone w jeden proces plink.

    Ustawienia (ścieżka do plink.exe, plik z tunelami, interwał) są w ptunnel.ini.
    Kolejność ważności: parametr z linii poleceń > ptunnel.ini > wartość domyślna.

.EXAMPLE
    .\ptunnel.ps1 start
    .\ptunnel.ps1 start -Pilnuj          # dodatkowo pilnuje i podnosi zerwane połączenia
    .\ptunnel.ps1 status
    .\ptunnel.ps1 stop
    .\ptunnel.ps1 start -Plik D:\inne.csv -Plink "C:\Program Files\PuTTY\plink.exe"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status')]
    [string]$Akcja = 'start',

    # Plik z listą tuneli
    [string]$Plik = (Join-Path $PSScriptRoot 'ptunnel.csv'),

    # Ścieżka do plink.exe (domyślnie: katalog skryptu, PATH, Program Files)
    [string]$Plink,

    # Po starcie zostań w pętli i podnoś zerwane połączenia
    [switch]$Pilnuj,

    # Co ile sekund sprawdzać połączenia w trybie -Pilnuj
    [int]$Interwal = 30
)

$ErrorActionPreference = 'Stop'
$StanPlik       = Join-Path $PSScriptRoot 'ptunnel.state.json'
$LogDir         = Join-Path $PSScriptRoot 'logs'
$UstawieniaPlik = Join-Path $PSScriptRoot 'ptunnel.ini'
$ParametryCLI   = $PSBoundParameters

# ---------------------------------------------------------------- pomocnicze

function Write-Info([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }

# Ścieżka względna -> względem katalogu skryptu; rozwija też %ZMIENNE% środowiskowe
function Resolve-ScriptPath([string]$p) {
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $PSScriptRoot $p }
    return $p
}

# Wczytuje ptunnel.ini (format: Nazwa = wartość) i nadpisuje nim domyślne wartości parametrów.
# Parametr podany jawnie w linii poleceń zawsze wygrywa z plikiem.
function Import-Settings {
    if (-not (Test-Path $UstawieniaPlik)) { return }

    $dozwolone = 'Plink', 'Plik', 'Interwal'
    $nr = 0
    foreach ($linia in Get-Content -Path $UstawieniaPlik -Encoding UTF8) {
        $nr++
        $l = $linia.Trim()
        if (-not $l -or $l[0] -in '#', ';', '[') { continue }

        $i = $l.IndexOf('=')
        if ($i -lt 1) { throw "ptunnel.ini, wiersz ${nr}: oczekiwano 'Nazwa = wartość', jest '$l'." }
        $klucz   = $l.Substring(0, $i).Trim()
        $wartosc = $l.Substring($i + 1).Trim().Trim('"')

        $pasuje = $dozwolone | Where-Object { $_ -eq $klucz }
        if (-not $pasuje) { throw "ptunnel.ini, wiersz ${nr}: nieznane ustawienie '$klucz' (dozwolone: $($dozwolone -join ', '))." }
        if (-not $wartosc -or $ParametryCLI.ContainsKey($pasuje)) { continue }

        switch ($pasuje) {
            'Plink'    { $script:Plink = Resolve-ScriptPath $wartosc }
            'Plik'     { $script:Plik  = Resolve-ScriptPath $wartosc }
            'Interwal' {
                $n = 0
                if (-not [int]::TryParse($wartosc, [ref]$n) -or $n -lt 1) {
                    throw "ptunnel.ini, wiersz ${nr}: Interwal musi być liczbą sekund większą od 0, jest '$wartosc'."
                }
                $script:Interwal = $n
            }
        }
    }
}

function Get-PlinkPath {
    if ($Plink) {
        if (Test-Path $Plink) { return (Resolve-Path $Plink).Path }
        throw "Nie znaleziono plink.exe pod wskazaną ścieżką: $Plink (sprawdź Plink w ptunnel.ini lub parametr -Plink)"
    }
    $kandydaci = @(
        (Join-Path $PSScriptRoot 'plink.exe'),
        (Get-Command plink.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
        (Join-Path $env:ProgramFiles 'PuTTY\plink.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'PuTTY\plink.exe')
    ) | Where-Object { $_ }
    foreach ($k in $kandydaci) { if (Test-Path $k) { return $k } }
    throw "Nie znaleziono plink.exe. Zainstaluj PuTTY albo ustaw Plink w ptunnel.ini."
}

function Test-Port([string]$value, [string]$what, [int]$line) {
    $n = 0
    if (-not [int]::TryParse($value, [ref]$n) -or $n -lt 1 -or $n -gt 65535) {
        throw "Wiersz ${line}: niepoprawny $what '$value' (dozwolone 1-65535)."
    }
    return $n
}

# Cytowanie argumentu dla linii poleceń Windows (spacje w ścieżce do klucza itp.)
function ConvertTo-Arg([string]$s) {
    if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
    return $s
}

function Read-Tunnels([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Nie znaleziono pliku konfiguracyjnego: $Path" }

    $linie = Get-Content -Path $Path -Encoding UTF8 |
             Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') }
    if (-not $linie) { throw "Plik $Path nie zawiera żadnych tuneli." }

    $wiersze = @($linie | ConvertFrom-Csv -Delimiter ';')
    $wynik = @()
    $nr = 1  # nr wiersza danych (bez nagłówka i komentarzy)

    foreach ($w in $wiersze) {
        $nr++
        $get = { param($name) if ($w.$name) { "$($w.$name)".Trim() } else { '' } }

        $t = [ordered]@{
            Nazwa       = & $get 'Nazwa'
            SshHost     = & $get 'SshHost'
            SshPort     = & $get 'SshPort'
            Uzytkownik  = & $get 'Uzytkownik'
            Klucz       = & $get 'Klucz'
            HostKey     = & $get 'HostKey'
            Typ         = (& $get 'Typ').ToUpper()
            LokalnyPort = & $get 'LokalnyPort'
            ZdalnyHost  = & $get 'ZdalnyHost'
            ZdalnyPort  = & $get 'ZdalnyPort'
        }

        if (-not $t.Nazwa)   { $t.Nazwa = "tunel$nr" }
        if (-not $t.SshHost) { throw "Wiersz ${nr} ($($t.Nazwa)): brak SshHost." }
        if (-not $t.SshPort) { $t.SshPort = '22' }
        if (-not $t.Typ)     { $t.Typ = 'L' }
        if ($t.Typ -notin 'L', 'D') { throw "Wiersz ${nr} ($($t.Nazwa)): Typ musi być L albo D, jest '$($t.Typ)'." }

        $t.SshPort     = Test-Port $t.SshPort 'SshPort' $nr
        $t.LokalnyPort = Test-Port $t.LokalnyPort 'LokalnyPort' $nr

        if ($t.Typ -eq 'L') {
            if (-not $t.ZdalnyHost) { throw "Wiersz ${nr} ($($t.Nazwa)): brak ZdalnyHost." }
            $t.ZdalnyPort = Test-Port $t.ZdalnyPort 'ZdalnyPort' $nr
        }

        if ($t.Klucz) {
            $k = $t.Klucz
            if (-not [IO.Path]::IsPathRooted($k)) { $k = Join-Path $PSScriptRoot $k }
            if (-not (Test-Path $k)) { throw "Wiersz ${nr} ($($t.Nazwa)): nie znaleziono klucza '$($t.Klucz)'." }
            $t.Klucz = (Resolve-Path $k).Path
        }

        $t.Grupa = '{0}@{1}:{2}|{3}|{4}' -f $t.Uzytkownik, $t.SshHost, $t.SshPort, $t.Klucz, $t.HostKey
        $wynik += [pscustomobject]$t
    }

    # Ten sam port lokalny nie może być użyty dwa razy
    $dup = $wynik | Group-Object LokalnyPort | Where-Object Count -gt 1
    if ($dup) { throw "Port lokalny użyty wielokrotnie: $(($dup.Name) -join ', ')" }

    return $wynik
}

# ---------------------------------------------------------------- stan (PID-y)

function Get-State {
    $stan = @{}
    if (Test-Path $StanPlik) {
        $dane = Get-Content $StanPlik -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($e in $dane) { $stan[$e.Grupa] = $e }
    }
    return $stan
}

function Save-State($stan) {
    $lista = @($stan.Values)
    if ($lista.Count -eq 0) { Remove-Item $StanPlik -ErrorAction SilentlyContinue; return }
    ConvertTo-Json -InputObject $lista | Set-Content $StanPlik -Encoding UTF8
}

# Zwraca proces plink, jeśli wpis w stanie nadal wskazuje na żywy proces (ochrona przed ponownym użyciem PID)
function Get-LiveProcess($wpis) {
    if (-not $wpis) { return $null }
    $p = Get-Process -Id $wpis.Pid -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -eq 'plink' -and $p.StartTime.Ticks -eq [long]$wpis.StartTicks) { return $p }
    return $null
}

function Test-Listening([int]$port) {
    [bool](Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------- akcje

function Start-Group($grupa, $tunele, $stan, $plinkExe) {
    $t0 = $tunele[0]
    $opis = "$($t0.Uzytkownik)@$($t0.SshHost):$($t0.SshPort)"

    if (Get-LiveProcess $stan[$grupa]) {
        Write-Info "[=] $opis już działa (PID $($stan[$grupa].Pid))" 'DarkGray'
        return
    }

    foreach ($t in $tunele) {
        if (Test-Listening $t.LokalnyPort) {
            Write-Info "[!] $opis - port $($t.LokalnyPort) ($($t.Nazwa)) jest zajęty przez inny program, pomijam to połączenie." 'Yellow'
            return
        }
    }

    $a = @('-ssh', '-N', '-batch', '-P', $t0.SshPort)
    if ($t0.Uzytkownik) { $a += '-l', $t0.Uzytkownik }
    if ($t0.Klucz)      { $a += '-i', $t0.Klucz }
    if ($t0.HostKey)    { $a += '-hostkey', $t0.HostKey }
    foreach ($t in $tunele) {
        if ($t.Typ -eq 'D') { $a += '-D', "127.0.0.1:$($t.LokalnyPort)" }
        else                { $a += '-L', "127.0.0.1:$($t.LokalnyPort):$($t.ZdalnyHost):$($t.ZdalnyPort)" }
    }
    $a += $t0.SshHost
    $argStr = ($a | ForEach-Object { ConvertTo-Arg "$_" }) -join ' '

    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $log = Join-Path $LogDir (($t0.SshHost -replace '[^\w\.-]', '_') + "_$($t0.SshPort).log")

    Write-Info "[>] $opis  ->  $(($tunele | ForEach-Object Nazwa) -join ', ')" 'Cyan'
    $p = Start-Process -FilePath $plinkExe -ArgumentList $argStr -WindowStyle Hidden -PassThru `
                       -RedirectStandardError $log

    Start-Sleep -Seconds 3
    $p.Refresh()
    if ($p.HasExited) {
        Write-Info "[X] $opis - plink zakończył się (kod $($p.ExitCode)). Log: $log" 'Red'
        Get-Content $log -ErrorAction SilentlyContinue | Select-Object -Last 5 | ForEach-Object { Write-Info "    $_" 'Red' }
        Write-Info "    Wskazówka: przy pierwszym połączeniu zaakceptuj klucz hosta w PuTTY albo wpisz HostKey w CSV." 'DarkYellow'
        return
    }

    $stan[$grupa] = [pscustomobject]@{
        Grupa      = $grupa
        Pid        = $p.Id
        StartTicks = $p.StartTime.Ticks
        Opis       = $opis
    }
    Save-State $stan

    foreach ($t in $tunele) {
        $cel = if ($t.Typ -eq 'D') { 'SOCKS proxy' } else { "$($t.ZdalnyHost):$($t.ZdalnyPort)" }
        $ok  = Test-Listening $t.LokalnyPort
        $c   = if ($ok) { 'Green' } else { 'Yellow' }
        $s   = if ($ok) { 'OK' } else { 'jeszcze nie nasłuchuje' }
        Write-Info ("    {0,-15} 127.0.0.1:{1,-6} -> {2}  [{3}]" -f $t.Nazwa, $t.LokalnyPort, $cel, $s) $c
    }
}

function Invoke-Start {
    $plinkExe = Get-PlinkPath
    $tunele   = Read-Tunnels $Plik
    $grupy    = $tunele | Group-Object Grupa
    Write-Info "plink: $plinkExe"

    do {
        $stan = Get-State
        foreach ($g in $grupy) { Start-Group $g.Name @($g.Group) $stan $plinkExe }
        if ($Pilnuj) {
            Write-Info "--- $(Get-Date -Format 'HH:mm:ss') pilnuję połączeń co $Interwal s (Ctrl+C kończy pilnowanie, tunele zostają) ---" 'DarkGray'
            Start-Sleep -Seconds $Interwal
        }
    } while ($Pilnuj)
}

function Invoke-Stop {
    $stan = Get-State
    if ($stan.Count -eq 0) { Write-Info 'Brak uruchomionych tuneli.'; return }
    foreach ($e in @($stan.Values)) {
        $p = Get-LiveProcess $e
        if ($p) {
            Stop-Process -Id $p.Id -Force
            Write-Info "[-] Zamknięto $($e.Opis) (PID $($e.Pid))" 'Yellow'
        } else {
            Write-Info "[ ] $($e.Opis) już nie działał" 'DarkGray'
        }
    }
    Remove-Item $StanPlik -ErrorAction SilentlyContinue
}

function Invoke-Status {
    $tunele = Read-Tunnels $Plik
    $stan   = Get-State
    foreach ($g in ($tunele | Group-Object Grupa)) {
        $t0 = $g.Group[0]
        $p  = Get-LiveProcess $stan[$g.Name]
        $opis = "$($t0.Uzytkownik)@$($t0.SshHost):$($t0.SshPort)"
        if ($p) { Write-Info "[+] $opis  PID $($p.Id), od $($p.StartTime)" 'Green' }
        else    { Write-Info "[-] $opis  nie działa" 'Red' }
        foreach ($t in $g.Group) {
            $cel = if ($t.Typ -eq 'D') { 'SOCKS proxy' } else { "$($t.ZdalnyHost):$($t.ZdalnyPort)" }
            $ok  = Test-Listening $t.LokalnyPort
            $s   = if ($ok) { 'nasłuchuje' } else { '-' }
            Write-Info ("    {0,-15} 127.0.0.1:{1,-6} -> {2}  [{3}]" -f $t.Nazwa, $t.LokalnyPort, $cel, $s)
        }
    }
}

# ---------------------------------------------------------------- main

try {
    Import-Settings
    switch ($Akcja) {
        'start'   { Invoke-Start }
        'stop'    { Invoke-Stop }
        'restart' { Invoke-Stop; Invoke-Start }
        'status'  { Invoke-Status }
    }
} catch {
    Write-Info "BŁĄD: $($_.Exception.Message)" 'Red'
    exit 1
}
