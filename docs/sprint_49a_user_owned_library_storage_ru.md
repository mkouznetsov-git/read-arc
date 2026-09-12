# Sprint 49A — User-owned library storage

## Результат

Архитектурный принцип спринта: **ReadArc не хранит ваши книги. ReadArc работает с вашей библиотекой.**

Приватный sandbox содержит manifest/index, secrets, transfer journal, processed artifacts и materialization cache. Canonical EPUB/FB2/PDF/DOC/DOCX/DJVU и другие поддерживаемые файлы находятся в выбранном пользователем root.

## Реализация

- `LibraryRoot` скрывает desktop path, SAF tree URI и Apple bookmark.
- `LibraryStorageProvider` не пропускает platform locator в scanner/repository/UI.
- `LibraryScanner` рекурсивно сохраняет relative location, использует size + modified timestamp для reuse SHA и повторно hash-ит только новые/изменённые entries.
- SHA-256 остаётся `BookRecord.id`; rename/move и duplicate locations не создают новую logical book.
- Source existence и offline byte availability разделены.
- `BookImportService` копирует внешний файл в root; файл уже внутри root не копируется.
- Старт/возврат в библиотеку запускает scan, поэтому ручные add/delete/rename/move обнаруживаются без UI папок.
- Reader adapters и оба file-transfer пути используют `materializeBook`, а завершённая загрузка записывается в user root.
- Недоступный root не считается пустым: сохранённый manifest/index остаётся, UI показывает причину и reselect.

## Миграция

`library_migration.json` хранит target, source, expected SHA, relative destination и verified flag. Root записывается как canonical только после полной проверки. Journal и root descriptor имеют previous generation для восстановления после crash. Повторный запуск продолжает migration; уже скопированный контент определяется по SHA. Legacy originals не удаляются автоматически.

## Тесты Sprint 49A

Покрыты empty/recursive/supported, fingerprint reuse, add/delete/content change, rename/move, same SHA, duplicate content, unavailable/permission lost, File Provider materialization state, manual add, cache independence, root persistence/import destination, interrupted migration/restart и SHA verification. Platform contract test проверяет opaque root и отсутствие local locators в sync JSON.

Существующие relay, E2E, bookmarks, locators, reader regression и durable file-transfer suites не ослаблены.

## Известные ограничения

- UI папок/коллекций не входит в 49A; relative tree уже сохранён в index.
- `.readarc`, portable progress/bookmarks/settings, Recovery Key, account/trust recovery — Sprint 49B.
- Ed25519 envelope signing, full-text search, themes/fonts и reader-format fixes не входят.
- File Provider download UX пока минимален: materialization выполняется при открытии/передаче, а сложный progress/cancel UI отложен.
