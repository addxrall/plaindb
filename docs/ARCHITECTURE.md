# Architektura

## Stack

- Objective-C z ARC i AppKit. Całe UI jest w kodzie, bez xib i storyboardów.
- `libpq` z Homebrew (`/opt/homebrew/opt/libpq`), linkowane dynamicznie.
- `/usr/bin/ssh` do tuneli, Security.framework do Keychain.
- Build: `Makefile`, czyli `clang` i ręcznie złożony `.app` z `Info.plist`. Nie ma projektu Xcode.

## Pliki

| Plik | Rola |
|---|---|
| `src/main.m` | `AppDelegate`, menu, otwieranie okien połączeń |
| `src/DBConnection.h/.m` | protokół `DBConnection`, `DBResult`, `DBQuoteIdent`, `DBError` |
| `src/PGConnection.m` | implementacja Postgresa na `libpq`; schemat z `pg_catalog` |
| `src/SSHTunnel.m` | `ssh -N -L` przez `NSTask`, czekanie na port, wznawianie |
| `src/ConnectionStore.m` | plist w `~/Library/Application Support/Tabula/connections.plist` i Keychain (usługa `Tabula`) |
| `src/ConnectWindowController.m` | okno startowe: lista połączeń, formularz, zestawianie połączenia |
| `src/MainWindowController.m` | okno połączenia: lista tabel, zakładki Dane / Struktura / SQL, pasek statusu |
| `src/GridView.m` | siatka dla `DBResult`, używana we wszystkich trzech zakładkach |
| `tests/pg_test.m` | test `PGConnection` na prawdziwym, lokalnym Postgresie |

## Przepływy

**Połączenie.** `ConnectWindowController` na wątku w tle:
1. Opcjonalnie uruchamia `SSHTunnel start`, który czeka, aż `127.0.0.1:<wolny port>` zacznie przyjmować połączenia.
2. Wywołuje `PGConnection open`.
3. Na głównym wątku woła `onConnected`, a `AppDelegate` tworzy `MainWindowController`.

**Zapytania.** Każde połączenie ma własną szeregową kolejkę (`queue`), bo `libpq` nie obsługuje równoległych wywołań na jednym połączeniu. `MainWindowController run:done:failed:` wysyła pracę na tę kolejkę, a wynik oddaje na głównym wątku. Kolejność jest zachowana, więc przy szybkim przeklikiwaniu tabel wygrywa ostatnie kliknięcie.

**Wartości.** Wszystko jest tekstem (`NSString`) albo `NSNull`. Parametry idą przez `PQexecParams` jako tekst bez typów, a Postgres sam dopasowuje typ do kolumny.

**Zerwane połączenie.** Jeśli `ssh` padnie po zestawieniu tunelu, `SSHTunnel` uruchamia go ponownie na tym samym porcie co 2 s. Zapytanie wysłane w trakcie awarii kończy się błędem. Przy następnym `execute` `PGConnection` widzi `CONNECTION_BAD` i robi `PQreset`. Zapytania, które padło, nie ponawia, bo mogło już coś zapisać.

**Produkcja.** Połączenie oznaczone jako produkcyjne otwiera się z `default_transaction_read_only=on`. Szczegóły w DECISIONS.md.
