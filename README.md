# Tabula

Prosty, natywny klient Postgresa na macOS, napisany w Objective-C i AppKit. Służy do szybkiego podejrzenia, jak wygląda baza, i poprawienia jakiejś wartości. Działa lokalnie, bez kont i bez chmury.

## Co umie (v0.1)

- Zapisane połączenia. Hasła trzyma w Keychain.
- **Tunel SSH** przez systemowy `ssh`, więc działają `~/.ssh/config`, klucze, agent i `ProxyJump`. Tunel trzyma połączenie i sam je wznawia, gdy padnie.
- Lista tabel i widoków z filtrem.
- **Dane**: siatka po 200 wierszy, sortowanie kliknięciem w nagłówek, stronicowanie.
- **Struktura**: kolumny, typy, `NOT NULL`, wartości domyślne, klucz główny i indeksy.
- **SQL**: edytor z ⌘R. Jeśli zaznaczysz fragment, uruchomi się tylko on.
- **Tryb produkcyjny**: czerwony pasek w oknie i sesja `READ ONLY`. Zapis wymaga potwierdzenia, a potem wykonuje się w `BEGIN READ WRITE … COMMIT`.

W planach: edycja komórek, dodawanie i usuwanie wierszy, SQLite.

## Wymagania

- macOS z Xcode albo Command Line Tools
- `libpq` z Homebrew: `brew install libpq`

## Budowanie

```sh
make          # buduje build/Tabula.app
make run      # buduje i otwiera
make test     # test warstwy Postgresa na lokalnej bazie (TABULA_TEST_DB, domyślnie postgres)
```

Jeśli chcesz mieć aplikację w Launchpadzie, skopiuj `build/Tabula.app` do `/Applications`.

## Tunel SSH

W polu **Tunel SSH** wpisz `user@serwer` albo alias z `~/.ssh/config`. Pole **Host bazy** oznacza wtedy adres widziany z serwera, zwykle `localhost`.

Tabula uruchamia `ssh` w trybie `BatchMode`, więc nie zapyta o hasło do serwera. Potrzebny jest klucz (najlepiej w agencie), a serwer musi być już w `known_hosts`. Jeśli jeszcze nie jest, połącz się z nim raz ręcznie z terminala.

## Znane ograniczenia

- Po każdym przebudowaniu macOS może zapytać o dostęp do hasła w Keychain, bo zmienia się podpis aplikacji. Wybierz „Zawsze pozwalaj”.
- Zakładka SQL ładuje cały wynik do pamięci. Przy ogromnych tabelach dopisz `LIMIT`.
- Nie da się przerwać długiego zapytania.

Szczegóły techniczne: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), decyzje projektowe: [docs/DECISIONS.md](docs/DECISIONS.md).
