# Sprint 49A — manual certification checklist

Автоматический pipeline проверяет business logic, platform compilation и packaged upgrade, но не эмулирует полностью реальные SAF/security-scope/File Provider permissions. Эти пункты необходимо пройти перед production release; невыполненный пункт нельзя отмечать как проверенный.

## Android physical device

- Выбрать tree через системный picker, закрыть процесс ReadArc, перезагрузить устройство и убедиться, что библиотека открывается без повторного выбора.
- Через файловый менеджер добавить EPUB/FB2/PDF в корень и подпапку; проверить discovery, rename, case-only rename и move.
- Импортировать файл, уже находящийся в tree, и тот же SHA из другого места; лишняя физическая копия не должна появиться.
- Отозвать SAF permission: книги не исчезают и не создаются tombstone/массовые availability updates. Повторно выдать доступ и проверить восстановление.
- Во время relay- и Direct/LAN-download проверить, что итоговый файл появляется в tree, а `sandbox/incoming/*.part` удаляется после SHA verification.
- Повторить download после kill процесса и проверить resume, duplicate/reordered chunks и revoke peer во время передачи.
- Проверить cloud-backed DocumentsProvider с `FLAG_PARTIAL`, если доступен: entry остаётся логическим, чтение вызывает materialization.

## macOS packaged sandbox build

- Выбрать обычный каталог и каталог на внешнем диске; выполнить quit/relaunch и перезагрузку macOS без повторного picker.
- Проверить persisted app-scoped bookmark, затем stale/reselect flow после перемещения каталога или изменения volume availability.
- Добавить, переименовать и переместить книгу через Finder; временно отключить root и убедиться, что manifest/index не очищаются.
- Создать symlink на файл и каталог за пределами root: они не должны появиться в библиотеке или читаться через relative location.
- Проверить import и relay/Direct download: canonical файл находится в root, materialized/processed copies остаются удаляемым cache.
- Повторить upgrade установленного ad-hoc package и проверить совместимость manifest, Keychain и bookmark entitlement.

## iOS physical device

- Выбрать каталог через Files directory picker, завершить процесс и снова запустить приложение; bookmark должен восстановить доступ.
- Проверить локальный Files-каталог и iCloud/сторонний File Provider, включая entry, bytes которого ещё не загружены.
- Убедиться, что `requiresMaterialization` не выглядит как гарантированно offline-readable, а reader/transfer инициирует coordinated download.
- Добавить/rename/move файл через Files и проверить scan после relaunch.
- Отозвать или потерять provider access: библиотека не становится пустой; после reselect reading state остаётся привязан к SHA.
- Проверить import и download с другого ReadArc device; итоговый оригинал должен находиться в выбранном Files root, не только в app container.

На момент Sprint 49A iOS имеет функциональные picker/bookmark/traversal/materialization wiring и unsigned build gate. Полная device certification, provider-specific поведение и UX progress/cancel materialization остаются ручными release gates.
