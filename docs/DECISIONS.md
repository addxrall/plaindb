# Decyzje

## 2026-10-15 · Objective-C, AppKit, UI w kodzie, Makefile

**Kontekst:** narzędzie dla jednej osoby, na jednego Maca. Ma być proste i przyjemne w użyciu.
**Decyzja:** natywny AppKit w Objective-C. UI budowane w kodzie, build przez `Makefile` bez `.xcodeproj`.
**Konsekwencje:** każda zmiana to czytelny diff w pliku `.m`, a build to jedna komenda. Nie ma podglądu w Interface Builderze. Debugować można przez `lldb` albo Xcode „Debug Executable”.

## 2026-10-15 · Najpierw Postgres, SQLite później

**Kontekst:** najważniejsze jest połączenie z produkcyjnym Postgresem.
**Decyzja:** v0.1 obsługuje tylko Postgresa. Protokół `DBConnection` zostawia miejsce na `SQLiteConnection`.

## 2026-10-15 · Tunel przez systemowy `ssh`, nie libssh2

**Decyzja:** `NSTask` uruchamia `/usr/bin/ssh -N -L` z `BatchMode=yes`, `ExitOnForwardFailure=yes` i `ServerAliveInterval=30`.
**Konsekwencje:** za darmo działają `~/.ssh/config`, agent, `ProxyJump` i klucze sprzętowe. Hasła SSH nie obsługujemy, bo nie ma terminala. Jeśli aplikacja się wysypie, proces `ssh` może zostać osierocony.

## 2026-10-15 · Ochrona produkcji po stronie bazy

**Kontekst:** chcemy, żeby przypadkowy `UPDATE` na produkcji był niemożliwy bez potwierdzenia.
**Decyzja:** sesja produkcyjna ma `default_transaction_read_only=on`, więc to Postgres odrzuca zapis (SQLSTATE 25006). Aplikacja łapie ten błąd, pokazuje SQL do potwierdzenia (Enter = Anuluj) i wykonuje go w `BEGIN READ WRITE … COMMIT`.
**Odrzucone:** zgadywanie po pierwszym słowie zapytania. Łatwo je obejść, np. `SELECT 1; DELETE …` albo `WITH … DELETE`.

## 2026-10-15 · Schemat z `pg_catalog`, nie `information_schema`

**Powód:** `information_schema.table_constraints` ukrywa ograniczenia przed użytkownikiem, który ma tylko `SELECT`. Na produkcji często łączymy się właśnie takim kontem.

## 2026-10-15 · Wartości jako tekst

**Decyzja:** każdą wartość czytamy i wysyłamy jako tekst albo `NULL`.
**Konsekwencje:** jeden sposób wyświetlania i edycji dla wszystkich typów. `bytea` pokazuje się jako hex.
