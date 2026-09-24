# Sprint 49B — Portable Library State & Reinstall Recovery

## Результат

Sprint продолжает архитектуру 49A: книги остаются в пользовательском
LibraryRoot, а .readarc хранит только encrypted portable metadata.
Параллельной модели библиотеки и нового conflict-resolution протокола нет.

Реализованы:

- versioned immutable .readarc/format.json;
- per-installation state/deviceId/current|previous;
- per-installation recovery/deviceId/current|previous;
- AES-256-GCM, fresh nonce, authenticated headers и HKDF-SHA256 domains;
- account-key-authenticated rotationAuth отклоняет forged high-revision recovery envelopes;
- до успешного recovery или явного нового аккаунта portable writes новой installation подавлены;
- 256-bit Base32 Recovery Key с checksum;
- encrypted account-key envelope;
- recovery через Recovery Key и существующий 6-digit pairing;
- сохранение account identity при обязательной новой device identity;
- merge через Lamport/revision/tombstone semantics Sprint 47;
- SHA-256 reconciliation после rename/move;
- remote-only preservation;
- snapshot checkpoints после durable manifest mutation, sync merge,
  reader exit, lifecycle background и controlled shutdown;
- SAF service I/O на Android и coordinated security-scoped I/O на Apple;
- Recovery Key create/show/copy/confirm/verify и двухфазный rotate UX, который
  отзывает прежний key во всех device namespaces только после подтверждения;
- явные unsupported/incomplete/corrupt/wrong-key paths.

## Snapshot policy

Mutation не пишет snapshot на каждый scroll callback. StorageService coalesce-ит
изменения на 750 ms. ReaderExitCheckpoint дожидается durable progress mutation,
а background/shutdown принудительно flush-ят portable state. Sync
replaceManifest и physical scan используют тот же scheduler.

## Recovery order

    LibraryRoot portable state
            +
    fresh installation manifest/device keys
            ↓ existing deterministic merge
    physical LibraryScanner reconciliation by SHA-256
            +
    ordinary relay merge

Portable snapshot не является абсолютной истиной. Более новая revision
побеждает, tombstone не воскресает, duplicate operation остаётся idempotent,
wall clock не участвует в v3 ordering.

## Failure policy

- corrupt current → authenticated previous;
- обе generations corrupt → явная ошибка, не empty library;
- interrupted publish → rollback verified current;
- wrong Recovery Key → local manifest/secure storage не изменяются;
- missing/unavailable/read-only root → ошибка доступа, root не создаётся заново;
- future format → отказ без перезаписи;
- concurrent format bootstrap → принимается только валидный immutable winner;
- отсутствие recovery authority → можно создать новый account для физических
  книг, старый .readarc сохраняется.

## Scope

Не реализованы Sprint 50 Ed25519 sync-envelope migration, collections, FTS,
reader themes, CHM, EPUB/FB2 fixes, installers и auto-update.

