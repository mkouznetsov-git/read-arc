# Sprint 49B — manual certification

Автоматизация проверяет crypto, generations, reinstall, merge и builds.
Перед merge на реальных устройствах нужно подтвердить File Provider behavior.

## Android

1. Выбрать SAF root, добавить книгу, progress и bookmarks.
2. Создать Recovery Key и сохранить вне LibraryRoot.
3. Полностью удалить ReadArc и убедиться, что app data/secure storage удалены.
4. Установить PR artifact, выбрать прежний SAF root, восстановить Recovery Key.
5. Проверить новый deviceId, книги, progress, bookmark tombstone и sync.
6. Повторить recovery через 6-digit pairing с другого устройства.
7. Проверить read-only provider, временно offline provider и interrupted upload.

## macOS

1. Повторить сценарий на security-scoped root в iCloud Drive/Dropbox.
2. Удалить sandbox и Keychain entries, но оставить root.
3. Проверить recovery, новый device key, rename/move книги и relay merge.
4. Запустить packaged ad-hoc app на другом Mac/user profile.
5. Проверить отсутствие Keychain Sharing/Data Protection Keychain regression.

## iOS

1. Повторить в Files/iCloud Drive и стороннем File Provider.
2. Проверить materialization placeholders и coordinated generations.
3. Удалить приложение, установить unsigned/development build, выбрать root.
4. Проверить оба recovery flow и background flush.

## Shared-root concurrency

1. A и B выбирают один root.
2. A меняет progress, B добавляет и удаляет bookmark.
3. Убедиться, что namespaces A/B существуют одновременно.
4. C выполняет recovery и получает deterministic merged state.
5. Повредить current A: C использует previous A и current B.
6. Подмешать stale snapshot и затем relay state: newer revisions не откатываются.

## Security inspection

- выполнить recursive strings/search в .readarc;
- accountEncryptionKey, private device key и Recovery Key отсутствуют;
- изменить authenticated header, ciphertext и tag — recovery отвергается;
- проверить, что diagnostics/logs не содержат ключей;
- проверить rotation с отключением storage между staging и publish.
