# ADR-010: переносимое состояние библиотеки и восстановление

Статус: принято для Sprint 49B.

## Контекст

После Sprint 49A оригиналы книг принадлежат пользователю и находятся в
выбранном LibraryRoot. Sandbox ReadArc содержит индекс, кэш, processed
artifacts, transfer journal и секреты. Полное удаление приложения уничтожает
sandbox и secure storage, но не должно лишать пользователя метаданных чтения,
если он сохранил Recovery Key либо имеет другое доверенное устройство.

LibraryRoot может быть общей папкой File Provider, iCloud Drive, Dropbox или
сетевого хранилища. Один глобальный mutable JSON привёл бы к lost update при
одновременной работе нескольких установок.

## Решение

Структура .readarc:

    .readarc/
    ├── format.json
    ├── state/<originating-device-id>/
    │   ├── current
    │   └── previous
    └── recovery/<originating-device-id>/
        ├── current
        └── previous

format.json — маленький неизменяемый маркер схемы. Каждая installation пишет
только в namespace своего deviceId. Чужие generations только читаются.
current публикуется через staging, flush, byte verification и rename; прежний
валидный current становится previous. Повреждение current не считается
пустой библиотекой: сначала проверяется previous, затем выдаётся явная ошибка.

Snapshot содержит LibraryManifest.toSyncJson(): logical books, SHA-256,
metadata, locators, progress, bookmarks, revisions, Lamport clock, operation
ids, tombstones, public trusted-device records, roles, capabilities и
revocations. Абсолютные пути, LibraryRoot locator, security-scoped bookmark,
SAF URI и platform-local availability location не сериализуются. После recovery
snapshot объединяется существующим mergeManifests, затем результат
reconcile-ится с LibraryScanner по SHA-256. Отсутствующая физически книга не
становится tombstone и сохраняет remote-only semantics.

## Криптография

Snapshot и recovery envelope используют AES-256-GCM из cryptography.
Для каждого объекта генерируется новый 96-bit nonce. Ключ AES выводится
HKDF-SHA256 с отдельными domains:

- readarc-portable-state-v1;
- readarc-recovery-envelope-v1.

AAD аутентифицирует format version, kind, crypto suite, accountId,
originating deviceId, generation, revision/keyId, activation,
rotationRevision и creation timestamp. Ciphertext или header нельзя
незаметно изменить.

Recovery Key — случайные 256 bit, Base32 без неоднозначных символов, с
32-bit checksum и префиксом версии RA1. Это не пароль, password KDF не
используется. Ключ показывается только после authenticated read-after-publish
pending envelope, не логируется, не отправляется relay и не сохраняется
plaintext.

Ротация двухфазная. Pending envelope не отзывает прежний active key. После
подтверждения пользователем новый envelope дважды публикуется как active, чтобы
current и previous содержали уже подтверждённый ключ. Только тогда старый ключ
перестаёт подходить. Между device namespaces побеждает наибольший
Lamport rotationRevision с детерминированным deviceId tie-break; wall clock не
участвует. Поэтому crash до подтверждения оставляет старый ключ рабочим, а
успешная ротация действительно отзывает его во всех namespaces.

Recovery envelope содержит зашифрованный accountEncryptionKey; plaintext
header содержит только versioned non-secret routing metadata, включая
accountId и keyId. accountEncryptionKey, Recovery Key и device private key
никогда не находятся plaintext в .readarc.

## Identity

При recovery сохраняются:

- accountId;
- accountEncryptionKey.

Всегда сохраняется новая installation identity, уже созданная новым sandbox:

- новый deviceId;
- новая Ed25519 signing keypair;
- новый trusted-device record.

Portable snapshot не может заменить эти поля. Repository имеет отдельную
authenticated-recovery transaction, которая проверяет совпадение нового
deviceId и обоих ключевых полей с текущей installation перед commit. Старые
trusted-device public records остаются видимыми и могут быть отозваны.

## Recovery flows

1. Trusted device: новая installation выбирает root, использует существующий
   шестизначный pairing flow, получает account identity, затем decrypt/merge
   portable snapshots и выполняет обычный relay merge.
2. Recovery Key: envelope восстанавливает account identity локально, после чего
   создаётся recovery-authorized owner record новой installation, portable
   snapshots merge-ятся и выполняется physical scan.
3. Нет trusted device и Recovery Key: зашифрованное состояние математически
   невосстановимо. UI предлагает новый account для найденных книг и не удаляет
   старый .readarc.

## Threat model

Защищаемся от чтения LibraryRoot третьей стороной, случайной/злонамеренной
модификации ciphertext/header, truncated/interrupted write, stale generation,
nonce reuse, lost update общей папки и восстановления украденной device
identity. Не скрываем факт существования ReadArc account, accountId, deviceId,
generation и приблизительный размер/время snapshot. Компрометация Recovery Key
даёт доступ к account key и требует ротации.

## Совместимость и отложенные решения

49A root без .readarc безопасно bootstrap-ится после обычного открытия и не
блокирует чтение. Platform layer реализует только service-file I/O: Android —
SAF, macOS/iOS — security-scoped URL и NSFileCoordinator.

Sprint 49B не меняет sync envelopes на per-device Ed25519 signatures.
Подпись и trust hardening остаются Sprint 50. Формат сохраняет public keys и
revocation records, необходимые для будущей миграции.
