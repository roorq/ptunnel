# 🚇 ptunnel

🇬🇧 **English** · 🇵🇱 [Polski](README.pl.md)

A PowerShell script for Windows 11 that sets up SSH tunnels with `plink.exe`
(PuTTY). The list of servers, IP addresses and ports lives in a separate file,
`ptunnel.csv`, so you never have to edit the script itself.

```
[>] user@bastion.example.com:22  ->  baza-prod, rdp-serwer, socks
    baza-prod       127.0.0.1:15432  -> 10.0.0.15:5432  [OK]
    rdp-serwer      127.0.0.1:13389  -> 10.0.0.20:3389  [OK]
    socks           127.0.0.1:1080   -> SOCKS proxy  [OK]
```

> **Note:** the script's parameters, configuration keys and messages are in Polish.
> The tables below give an English meaning for each one.

## Quick start

1. Install PuTTY (or drop `plink.exe` next to the script). If plink lives somewhere
   else, set its path in `ptunnel.ini` (`Plink = ...`).
2. Fill in `ptunnel.csv`.
3. Connect once with regular PuTTY to accept the server's host key (or fill in `HostKey`).
4. Run:

```bat
ptunnel.bat start
```

`ptunnel.bat` runs the script with `-ExecutionPolicy Bypass`, so double-clicking it works too.

## Options

| command / parameter | meaning |
|---|---|
| `start` | brings up the tunnels (skips ones already running) |
| `stop` | closes the tunnels started by this script |
| `restart` | `stop` + `start` |
| `status` | connection state and listening ports |
| `-Pilnuj` | *"watch"*: after `start`, stays in a loop and restarts dropped connections |
| `-Interwal N` | *"interval"*: how often (seconds) to check connections in `-Pilnuj` mode (default 30) |
| `-Plik path` | *"file"*: a different tunnel list (default `ptunnel.csv` next to the script) |
| `-Plink path` | path to `plink.exe` (default: script directory, PATH, `Program Files\PuTTY`) |

## Settings (`ptunnel.ini`)

Permanent settings, so you don't have to pass parameters every time:

```ini
Plink = C:\Program Files\PuTTY\plink.exe
Plik =
Interwal = 30
```

| key | meaning |
|---|---|
| `Plink` | path to `plink.exe`; empty = auto-detect |
| `Plik` | tunnel list file; empty = `ptunnel.csv` next to the script |
| `Interwal` | seconds between checks in `-Pilnuj` mode; empty = 30 |

- Precedence: **command-line parameter > `ptunnel.ini` > built-in default**.
- Relative paths are resolved from the script directory; environment variables such as `%ProgramFiles%` are expanded.
- A missing `ptunnel.ini` is not an error, the defaults apply.
- A typo in a key name stops the script with an error instead of being silently ignored.

## Tunnel list (`ptunnel.csv`)

Semicolon-separated; lines starting with `#` are ignored:

```
Nazwa;SshHost;SshPort;Uzytkownik;Klucz;HostKey;Typ;LokalnyPort;ZdalnyHost;ZdalnyPort
baza-prod;bastion.example.com;22;user;C:\klucze\user.ppk;;L;15432;10.0.0.15;5432
socks;bastion.example.com;22;user;C:\klucze\user.ppk;;D;1080;;
```

| column | meaning |
|---|---|
| `Nazwa` | *name*: tunnel label |
| `SshHost` / `SshPort` | SSH server (jump host); empty port = 22 |
| `Uzytkownik` | *user*: SSH login |
| `Klucz` | *key*: `.ppk` file; empty = key from Pageant; relative paths resolve from the script directory |
| `HostKey` | server key fingerprint, e.g. `SHA256:...`; empty = must already be accepted in PuTTY |
| `Typ` | *type*: `L` = local port forward, `D` = dynamic SOCKS proxy |
| `LokalnyPort` | *local port*: port on this machine (listens on `127.0.0.1` only) |
| `ZdalnyHost` / `ZdalnyPort` | *remote host / port*: the target as seen from the SSH server (empty for `D`) |

## What does it do?

- **One plink per SSH server**: rows sharing `SshHost`/`SshPort`/`Uzytkownik`/`Klucz`/`HostKey`
  go through a single connection with several `-L`/`-D` options.
- **Validates the file before starting**: ports 1–65535, required fields, key file exists,
  no local port used twice.
- **Detects busy ports**: if another program already listens on a local port, that
  connection is skipped with a warning instead of failing silently.
- **Hidden window + log**: plink runs without a console window. Its stderr goes to
  `logs\<host>_<port>.log`, and if a connection dies at startup the last log lines are shown.
- **Stops only its own processes**: PIDs and process start times are kept in
  `ptunnel.state.json`, so `stop` never kills an unrelated plink (or a process that reused the PID).

## Notes

- plink runs with `-batch`, so it will not prompt about an unknown host key. Accept it
  once in PuTTY or set `HostKey`.
- Passwords are deliberately not supported (no secrets in the CSV). Use a `.ppk` key or Pageant.
- Remote forwards (`-R`) are not supported.
- Ctrl+C in `-Pilnuj` mode only stops the watching; the tunnels keep running.
- The script has not been tested on Windows yet, so check it carefully on the first run.

## Reverting

```bat
ptunnel.bat stop
```

Then delete the folder. The script changes nothing in the system: apart from `logs\`
and `ptunnel.state.json` in its own directory, it writes nothing anywhere.
