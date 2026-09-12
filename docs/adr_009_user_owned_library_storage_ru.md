# ADR-009: пользователь владеет файлами библиотеки

Статус: принято в Sprint 49A.

## Решение

ReadArc не считает оригиналы книг частью приватного sandbox приложения. Пользователь выбирает корневой каталог библиотеки, а ReadArc рекурсивно индексирует обычные файлы в этом каталоге и читает их через `LibraryStorageProvider`.

Контентная идентичность книги остаётся SHA-256. Абсолютный путь, Android `content://` URI и Apple security-scoped bookmark не являются идентичностью книги и не входят в синхронизируемый snapshot.

## Границы

- `LibraryRoot` — непрозрачный локальный дескриптор корня: desktop path, Android SAF tree URI или Apple security-scoped bookmark.
- `LibraryStorageProvider` — platform boundary для scan, hash, import, delete и materialization.
- `LibraryScanner` — независимый от UI incremental scanner.
- `LibraryIndex` — воспроизводимый локальный индекс fingerprint: relative location, size, надёжный modified timestamp, SHA-256 и доступность bytes.
- `BookRecord` — синхронизируемая идентичность/reading state плюс локальные `relativeLocation` и `sourceAvailability`, которые удаляются из sync JSON.
- Reader и file transfer получают `File` только через `StorageService.materializeBook`; для SAF/File Provider это техническая cache-копия, а не canonical source.

## Состояния доступа

`available`, `temporarilyUnavailable`, `permissionLost` и `missing` различаются явно. Неуспешный probe не запускает scan и не очищает manifest/index. Для File Provider отдельно хранится `requiresMaterialization`: запись существует, но bytes могут отсутствовать offline.

## Platform mapping

- Android: `ACTION_OPEN_DOCUMENT_TREE`, persisted read/write URI grant, traversal через `DocumentsContract`.
- macOS: `NSOpenPanel`, security-scoped bookmark и повторный `startAccessingSecurityScopedResource` при каждой операции.
- iOS: Files directory picker, bookmark descriptor и security-scoped access. UI минимален, но contract совпадает с macOS и не предполагает filesystem path.
- Windows/Linux: пользовательский desktop path за тем же интерфейсом.

## Миграция

До фиксации canonical root старые приватные книги копируются в выбранный каталог и проверяются по SHA-256. Durable journal записывается после каждого шага атомарными поколениями; повторный запуск продолжает миграцию и сначала ищет уже скопированный SHA. Старые sources не удаляются в Sprint 49A.

## Последствия

Переименование и перемещение сохраняют progress, bookmarks, locator и sync history, поскольку они привязаны к SHA-256. Дубликаты одного контента могут иметь несколько index locations, но остаются одной logical book. Удаление cache/index не затрагивает пользовательские originals.

Portable `.readarc` metadata и account recovery остаются Sprint 49B.
