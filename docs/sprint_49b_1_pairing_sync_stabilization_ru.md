# Sprint 49B.1 — Pairing / Sync Stabilization

## #15 и #16: общая цепочка отказа

При claim существующий Mac менял `accountId` и ключ, но сохранял книги, tombstones,
Lamport clock, applied operation ids и trust records прежнего локального аккаунта.
Первый snapshot такого устройства выглядел как корректный snapshot уже целевого
аккаунта. Старый tombstone с высокой revision выигрывал merge и скрывал физически
существующую книгу на обоих устройствах.

Pairing code при этом создавался обычным HTTP-запросом. Владелец кода не обязан был
иметь готовое WebSocket-соединение с relay. Поэтому `pairing_claimed` мог пройти,
когда Android отсутствовал в relay: Android не добавлял новый device id в trusted
devices, а запрос файла с Mac не находил отвечающий доверенный источник.

Исправление сохраняет существующую архитектуру:

- authenticated pairing claim теперь является явной account boundary;
- сохраняется только installation-specific device id/keypair;
- книги, tombstones, clock, applied ids и trust старого аккаунта не переносятся;
- физические файлы выбранного LibraryRoot заново индексируются обычным scanner;
- глобальная Lamport/tombstone-семантика scanner и merge не ослаблена;
- владелец завершает WebSocket handshake с relay, публикует актуальный snapshot и
  только затем показывает шестизначный код;
- новый device id после reinstall регистрируется через существующий
  `pairing_claimed`/trusted-device flow; transfer остаётся Sprint 47/47B protocol.

Если выбранный LibraryRoot содержит portable state другого аккаунта, pairing не
перезаписывает его. Физические книги индексируются, но portable writes остаются
заблокированными до явного выбора/восстановления подходящего root.

## #17: race-sensitive пути и диагностика

Исходный единичный сбой без текста ошибки воспроизвести детерминированно нельзя.
При расследовании найдены и закрыты проверяемые race-sensitive места:

- повторные нажатия создания кода объединяются в одну client transaction;
- relay атомарно резервирует code внутри одного lock;
- retry после потерянного HTTP response использует не-секретный `requestId` и
  получает тот же активный code;
- code остаётся single-use;
- UI получает безопасный stage (`library_scan`, `relay_ready`, `invite_create`);
- code, Recovery Key и account encryption key не пишутся в diagnostic log.

## #18: macOS Keychain

Secure storage остаётся в зашифрованном macOS Keychain с
`first_unlock_this_device`; секреты не вынесены в LibraryRoot и не переводятся в
plaintext. Для текущих PR artifacts используется legacy Keychain backend без
Keychain Sharing entitlement — это совместимый путь для sandboxed ad-hoc build.

Повторяющиеся диалоги относятся к нестабильной code identity ad-hoc artifacts:
новая сборка получает другую подпись, а ACL уже существующих Keychain records не
может автоматически признать её тем же приложением. Один prompt может приходиться
на каждый защищённый record/access. Удалять записи или ослаблять ACL нельзя.

Packaging теперь:

- явно маркирует PR/internal artifact как `ad-hoc` в `MACOS_SIGNING.txt`;
- поддерживает стабильную Developer ID identity из protected CI secrets;
- fail-closed запрещает production publish без стабильной подписи;
- проверяет sandbox/file-bookmark entitlements после re-sign;
- не добавляет новый keychain access group и не удаляет существующие secrets.

До подключения protected Developer ID certificate ручная приёмка PR build должна
учитывать: при переходе между ad-hoc builds старые Keychain ACL могут запросить
разрешение снова. Чистая production identity обязана оставаться стабильной.

## #19: build identity

Product version Sprint 49B.1: `0.49.1`. Каждый verified workflow использует
`github.run_number` как общий пользовательский build id, например `0.49.1 (115)`.

- Android: `versionName=0.49.1`; package `versionCode=run_number+10000`, чтобы не
  ломать upgrade с прежних split APK; UI показывает исходный общий run number.
- macOS/iOS: `CFBundleShortVersionString=0.49.1`,
  `CFBundleVersion=run_number`.
- Android `versionCode` проверяется на диапазон `1..2100000000`.
- release tag может задать product version, но CI build id остаётся отдельным.

Точная версия видна на экране «Синхронизация» в карточке устройства.

## Regression coverage

- old-account high-revision tombstone не пересекает pairing boundary;
- физическая Android-книга остаётся видимой на Android и Mac;
- отсутствие local-only книги в remote snapshot не создаёт tombstone;
- owner relay readiness предшествует показу pairing code;
- fresh installation device id получает trust;
- Android → macOS file request находит источник и завершается проверенными bytes;
- concurrent code generation и HTTP retry идемпотентны, claim single-use;
- существующий Recovery Key reinstall suite продолжает проверять восстановление
  account identity/progress при свежем device id;
- build/signing configuration защищена contract tests и package verification.
