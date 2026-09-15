# Тест-план ReadArc

## Unit

- `BookRecord.fromJson/toJson` сохраняет все поля.
- Merge metadata идемпотентен.
- LWW progress не откатывается на старые данные.
- Bookmark tombstone побеждает старое добавление.
- SHA-256 одинаков для одинакового файла.

## Integration

- Import -> restart -> library persists.
- Device A changes progress -> Device B receives metadata -> progress updated.
- Device A adds bookmark offline, Device B adds another bookmark offline -> both bookmarks visible after sync.
- Device B downloads selected book from Device A -> hash verified.

## End-to-end

- Android -> Windows: add book, read 12%, continue on Windows.
- macOS -> iPhone: add bookmark, see bookmark on iPhone.
- Linux -> Android over LAN without relay.
- Windows -> iOS through self-hosted relay.

## Negative/security

- Unknown device cannot join account.
- Tampered envelope rejected.
- Tampered chunk rejected.
- Replay of old progress does not overwrite new progress.
- Relay restart does not lose stored data, because relay stores no data by design.

## Performance

- Library with 10 000 metadata records opens under target time.
- 1 GB PDF import does not block UI.
- Metadata sync under 1 MB for normal library.
- Chunk transfer throttling respects battery/network settings.

## Sprint 2 — проверка metadata sync через интернет

### Тест 2.1: один accountId на двух устройствах

1. Запустить relay на публично доступном адресе.
2. Открыть экран синхронизации на Mac.
3. Скопировать `accountId`.
4. Открыть экран синхронизации на Android.
5. Вставить тот же `accountId` и нажать **Сохранить**.
6. Подключить оба устройства к одному `Relay URL`.

Ожидаемый результат: оба устройства показывают статус `Подключено`.

### Тест 2.2: новая книга

1. Добавить TXT-книгу на Mac.
2. Дождаться отправки snapshot или нажать **Отправить snapshot библиотеки**.

Ожидаемый результат: Android показывает эту книгу как remote-only, без локального пути, со статусом доступности на другом устройстве.

### Тест 2.3: прогресс чтения

1. Открыть TXT-книгу на устройстве, где она скачана.
2. Прокрутить текст.
3. Дождаться auto-save progress.

Ожидаемый результат: второе устройство после получения snapshot показывает обновленный процент чтения.

### Тест 2.4: закладки

1. Добавить закладку на Mac.
2. Добавить другую закладку на Android для той же книги, если файл также импортирован на Android.
3. Отправить snapshot с обоих устройств.

Ожидаемый результат: обе закладки присутствуют на обоих устройствах.

### Тест 2.5: локальный путь не перезаписывается

1. Импортировать одну и ту же книгу на Mac и Android.
2. Синхронизировать snapshot.

Ожидаемый результат: каждый клиент сохраняет свой `localPath`, а `availableOnDeviceIds` содержит оба устройства.

## Sprint 3 — File transfer tests

1. Add a TXT book on macOS while Android is connected to the same account.
2. Verify Android shows the book as remote-only.
3. Tap the cloud download button on Android.
4. Verify transfer progress is shown in the book card.
5. Verify the final state shows the normal downloaded/read action and the temporary download progress disappears.
6. Verify the book can be opened on Android and reading progress still syncs back to macOS.
7. Interrupt relay during a large transfer and verify the book is not marked as downloaded.
8. Retry download and verify SHA-256 validation succeeds.

## Sprint 4.0 checks

### Relay endpoint modes

1. Start relay locally with Docker:

```bash
docker compose up --build relay
```

2. In app select **Local development** on desktop and connect.
3. In app select **Custom relay**, set a reachable URL, and connect.
4. Build with `READARC_DEFAULT_RELAY_URL=https://your-service.koyeb.app` and select **ReadArc relay**.
5. Restart app and verify auto-connect is attempted after a successful connection.
6. Press **Disconnect** and verify auto-connect is disabled.

### CI

GitHub Actions must run:

```text
Flutter tests
Python relay syntax check
Docker relay build smoke check
Android APK build
macOS DMG/PKG build
```


## Sprint 4.2: подключение по коду

Добавлен MVP-pairing: первое устройство создаёт 6-значный код подключения, новое устройство вводит код или вставляет `readarc://pair?...` приглашение и автоматически получает `accountId` и relay endpoint. Ручной ввод `accountId` оставлен только как fallback для разработки. Relay хранит pairing-коды только в памяти и удаляет их после первого использования или истечения срока. Подробности: `docs/sprint_04_2_pairing_codes_ru.md`.

## TXT locator cross-device regression

1. Установить одну и ту же сборку на Mac и Android.
2. Подключить оба устройства к одному account через pairing или одинаковый accountId.
3. Добавить TXT-файл на Mac и скачать его на Android.
4. На Mac открыть TXT, перейти к заметному абзацу, подождать 1–2 секунды.
5. На Android открыть эту же книгу.
6. Ожидаемый результат: Android открывает текст рядом с тем же абзацем, а не только рядом с тем же процентом.
7. Повторить в обратную сторону: Android → Mac.

## Sprint 5 — восстановление позиции и устойчивое скачивание

### TXT position restore

1. Открыть TXT на устройстве A.
2. Пролистать до 30–40%.
3. Подождать 1–2 секунды.
4. Закрыть и снова открыть книгу на устройстве A.
5. Ожидается: книга открыта около того же фрагмента текста.
6. Открыть книгу на устройстве B после sync.
7. Ожидается: книга открыта около того же фрагмента текста.

### Download retry/resume

1. Начать скачивание книги на устройстве B.
2. Оборвать relay/интернет до завершения.
3. Ожидается: книга не помечена как скачанная.
4. Вернуть подключение и нажать скачать снова.
5. Ожидается: скачивание продолжается с partial chunk, затем проходит SHA-256 проверку.

### Download cancel

1. Начать скачивание книги.
2. Нажать отмену.
3. Ожидается: активная передача остановлена, книга остаётся remote-only.
4. Повторное нажатие скачать начинает передачу заново; partial удаляется при ручной отмене.

## Hotfix 05.02 — стабильное восстановление страницы TXT

1. Импортировать TXT размером 300–800 КБ.
2. Открыть книгу на Mac.
3. Перейти на страницу, где индикатор показывает около 5%.
4. Закрыть reader.
5. Открыть эту же книгу снова на Mac.
6. Проверить: открыта та же логическая страница; процент не должен заметно прыгать.
7. Дождаться синхронизации.
8. Открыть книгу на Android.
9. Проверить: открыта та же логическая страница, что и на Mac.
10. Добавить закладку, перейти дальше, вернуться по закладке после перезапуска приложения.

## Sprint 6: library cleanup and sorting

- Добавить 3–5 книг и убедиться, что порядок по названию не меняется после sync/progress update.
- Удалить локальный файл книги с устройства: книга остаётся в библиотеке как remote-only.
- Скачать эту же книгу повторно и проверить SHA-256/открытие.
- Удалить книгу из библиотеки: после sync она скрывается на другом устройстве.
- Удалить старую запись доверенного устройства и проверить, что текущее устройство удалить нельзя.

## Sprint 7: TXT-reader smooth scroll and 100% progress

- macOS: открыть длинный TXT, прокручивать колесом/трекпадом, убедиться что scrollbar не прыгает.
- macOS: перетянуть scrollbar, убедиться что текст не скачет вверх-вниз.
- Android: открыть тот же TXT, убедиться что прокрутка остаётся плавной.
- Долистать книгу до конца, проверить что прогресс становится 100.0%.
- Закрыть и открыть книгу снова, проверить восстановление в конце.
- Пролистать до середины на одном устройстве, дождаться sync, открыть на другом устройстве и проверить, что верхний фрагмент текста примерно совпадает.

## Sprint 10 checks

### Android live reader progress

1. Open a long TXT or FB2 file on Android.
2. Scroll continuously for several seconds.
3. Verify that the bottom progress bar and percentage update while scrolling, before leaving the reader.
4. Leave the reader and verify the same percentage is visible in the library list.

### Remote-only PDF/FB2 download source detection

1. Keep the source device online and connected to the same account/relay.
2. Add a PDF or FB2 on the source device.
3. On another device, wait for metadata sync.
4. Tap the cloud icon.
5. Verify that download starts. The app should show “Хранилище книги не в сети” only if no online source answers the file request timeout.

### FB2 MVP reader

1. Import a plain `.fb2` file.
2. Open it and verify that title/paragraph text is readable.
3. Scroll to a recognizable location, close, reopen, and verify position restore.
4. Sync to another device and verify that the same approximate top line is restored there.

## Sprint 11 Hotfix 02 checks

- Отключить Tailscale/relay при работающем приложении: статус sync должен стать недоступным примерно за 5 секунд.
- Снова включить relay: приложение должно подключиться автоматически без ручной кнопки.
- При выключенном relay на старте приложения статус не должен прыгать между `Подключено` и `Relay недоступен`.
- FB2: при прокрутке прогресс должен монотонно меняться по верхнему видимому блоку.
- TXT/FB2: включить полноэкранный режим, убедиться, что скрыты панели и доступны только книга, scrollbar, закладка и выход из fullscreen.

## Sprint 12 checks

- FB2 progress does not jump randomly while scrolling.
- FB2 progress shown in reader matches the library progress after closing the book.
- FB2 position restores to the same logical unit after reopening.
- FB2 external links open in the default browser/application.
- TXT and FB2 text can be selected/copied.
- FB2 images can be copied as data URI.
- Fullscreen mode is available for TXT, FB2 and PDF.

## Sprint 16 checks

- Импортировать EPUB и проверить открытие на Mac и Android.
- Пролистать EPUB, закрыть, открыть снова и проверить восстановление позиции.
- Проверить синхронизацию EPUB progress между устройствами.
- Проверить копирование видимого фрагмента в TXT, FB2 и EPUB.
- Проверить скачивание книги 5–10 MB и сравнить скорость со Sprint 15.


## Sprint 49B portable/reinstall regression set

The automated suite must cover encrypted snapshot content, fresh nonces,
authenticated header/tag rejection, wrong Recovery Key, corrupt/truncated
current fallback to previous, interrupted publish rollback, two independent
device namespaces, duplicate/stale deterministic merge, bookmark and book
tombstones, remote-only books, new device identity, full sandbox and secure
store loss, SHA-256 rename reconciliation, missing root, incomplete format and
unsupported future schema.

The verified pipeline remains unchanged: formatter, analyzer, relay and Flutter
tests gate Android emulator, macOS smoke, iOS unsigned build, verified packages,
packaged upgrades and reader regressions. Real SAF/iCloud/third-party File
Provider reinstall recovery is recorded as a manual certification gap until it
is executed on physical devices.
