# 🚇 ptunnel

🇬🇧 [English](README.md) · 🇵🇱 **Polski**

Skrypt PowerShell dla Windows 11, który zestawia tunele SSH przez `plink.exe`
(PuTTY). Lista serwerów, adresów IP i portów jest w osobnym pliku
`ptunnel.csv`, więc samego skryptu nie trzeba edytować.

```
[>] user@bastion.example.com:22  ->  baza-prod, rdp-serwer, socks
    baza-prod       127.0.0.1:15432  -> 10.0.0.15:5432  [OK]
    rdp-serwer      127.0.0.1:13389  -> 10.0.0.20:3389  [OK]
    socks           127.0.0.1:1080   -> SOCKS proxy  [OK]
```

## Szybki start

1. Zainstaluj PuTTY (albo wrzuć `plink.exe` obok skryptu). Jeśli plink leży gdzie indziej,
   wpisz ścieżkę w `ptunnel.ini` (`Plink = ...`).
2. Uzupełnij `ptunnel.csv`.
3. Połącz się raz zwykłym PuTTY, żeby zaakceptować klucz hosta (albo wpisz `HostKey`).
4. Uruchom:

```bat
ptunnel.bat start
```

`ptunnel.bat` odpala skrypt z `-ExecutionPolicy Bypass`, więc działa też z dwukliku.

## Opcje

| polecenie / parametr | znaczenie |
|---|---|
| `start` | zestawia tunele (już działające pomija) |
| `stop` | zamyka tunele uruchomione przez ten skrypt |
| `restart` | `stop` + `start` |
| `status` | stan połączeń i nasłuchujących portów |
| `-Pilnuj` | po `start` zostaje w pętli i podnosi zerwane połączenia |
| `-Interwal N` | co ile sekund sprawdzać połączenia w trybie `-Pilnuj` (domyślnie 30) |
| `-Plik ścieżka` | inny plik z tunelami (domyślnie `ptunnel.csv` obok skryptu) |
| `-Plink ścieżka` | ścieżka do `plink.exe` (domyślnie: katalog skryptu, PATH, `Program Files\PuTTY`) |

## Ustawienia (`ptunnel.ini`)

Stałe ustawienia, żeby nie podawać parametrów za każdym razem:

```ini
Plink = C:\Program Files\PuTTY\plink.exe
Plik =
Interwal = 30
```

| ustawienie | znaczenie |
|---|---|
| `Plink` | ścieżka do `plink.exe`; puste = szukaj automatycznie |
| `Plik` | plik z tunelami; puste = `ptunnel.csv` obok skryptu |
| `Interwal` | sekundy między sprawdzeniami w trybie `-Pilnuj`; puste = 30 |

- Kolejność ważności: **parametr z linii poleceń > `ptunnel.ini` > wartość domyślna**.
- Ścieżki względne liczone są od katalogu skryptu, działają zmienne typu `%ProgramFiles%`.
- Brak pliku `ptunnel.ini` nie jest błędem, wtedy obowiązują wartości domyślne.
- Literówka w nazwie ustawienia kończy się błędem, a nie cichym pominięciem.

## Plik z tunelami (`ptunnel.csv`)

Separator to średnik, linie zaczynające się od `#` są pomijane:

```
Nazwa;SshHost;SshPort;Uzytkownik;Klucz;HostKey;Typ;LokalnyPort;ZdalnyHost;ZdalnyPort
baza-prod;bastion.example.com;22;user;C:\klucze\user.ppk;;L;15432;10.0.0.15;5432
socks;bastion.example.com;22;user;C:\klucze\user.ppk;;D;1080;;
```

| kolumna | znaczenie |
|---|---|
| `Nazwa` | etykieta tunelu |
| `SshHost` / `SshPort` | serwer SSH (bramka); pusty port = 22 |
| `Uzytkownik` | login SSH |
| `Klucz` | klucz `.ppk`; puste = klucz z Pageanta; ścieżki względne liczone od katalogu skryptu |
| `HostKey` | odcisk klucza serwera, np. `SHA256:...`; puste = musi być już zaakceptowany w PuTTY |
| `Typ` | `L` = przekierowanie portu lokalnego, `D` = dynamiczny SOCKS proxy |
| `LokalnyPort` | port na tym komputerze (nasłuch tylko na `127.0.0.1`) |
| `ZdalnyHost` / `ZdalnyPort` | cel widziany z serwera SSH (dla `D` puste) |

## Co to robi?

- **Jeden plink na serwer SSH**: wiersze z tym samym `SshHost`/`SshPort`/`Uzytkownik`/`Klucz`/`HostKey`
  idą jednym połączeniem z kilkoma opcjami `-L`/`-D`.
- **Sprawdza plik przed startem**: porty 1–65535, wymagane pola, istnienie klucza,
  brak powtórzonych portów lokalnych.
- **Wykrywa zajęte porty**: jeśli inny program już nasłuchuje na porcie lokalnym,
  to połączenie jest pomijane z ostrzeżeniem, a nie pada po cichu.
- **Ukryte okno + log**: plink działa bez konsoli, jego stderr trafia do
  `logs\<host>_<port>.log`, a gdy połączenie padnie przy starcie, wyświetlane są ostatnie linie logu.
- **Zamyka tylko swoje procesy**: PID-y i czasy startu procesów są zapisywane w
  `ptunnel.state.json`, więc `stop` nie ubije obcego plinka (ani procesu z ponownie użytym PID-em).

## Uwagi

- plink działa z `-batch`, więc nie zapyta o nieznany klucz hosta. Zaakceptuj go
  raz w PuTTY albo ustaw `HostKey`.
- Hasła celowo nie są obsługiwane (żadnych sekretów w CSV). Używaj klucza `.ppk` albo Pageanta.
- Zdalne przekierowania (`-R`) nie są obsługiwane.
- Ctrl+C w trybie `-Pilnuj` kończy tylko pilnowanie, tunele dalej działają.
- Skrypt powstał na Linuksie bez PowerShella do testów, więc sprawdź go przy pierwszym uruchomieniu na Windowsie.

## Wycofanie

```bat
ptunnel.bat stop
```

Potem usuń katalog. Skrypt niczego nie zmienia w systemie: poza `logs\` i
`ptunnel.state.json` we własnym katalogu nigdzie nic nie zapisuje.
