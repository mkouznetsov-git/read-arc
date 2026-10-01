# Sprint 49B.1 — продолжение #27 / #28

Работа идёт в PR #14. Merge и release требуют отдельного разрешения.
Ручная приёмка физического Android не заменяется зелёным CI.

## #27: причины и исправление

В коде подтверждены два независимых пути отказа:

- Picker возвращал `null` при отсутствии абсолютного `path`, даже когда
  выбор файла состоялся. Теперь запрашивается `readStream`; поток/bytes
  материализуются во временный файл с сохранением исходного имени.
  Удаление staging выполняется только после `await` полного импорта.
  Если прочитать выбор нельзя, UI показывает ошибку.
- Обычный scanner правильно сохранял tombstone, но явный повторный импорт
  того же SHA не создавал новую metadata revision. Теперь только явный
  пользовательский import снимает deletion и выдаёт следующую Lamport revision,
  очищая acknowledgements старого tombstone. Это работает и при существующем
  физическом файле (deduplication), и после его локального удаления.

Empty view теперь показывает friendly displayName выбранной папки и обе
кнопки. Callback вызывает тот же import → scan → manifest → UI reload.
Проверка по коду не доказывает, какой именно Android provider дал исходный
silent failure: это проверяется повторной физической приёмкой.

## Семантика удаления

| Действие | Метаданные | Физические файлы |
| --- | --- | --- |
| Удалить из библиотеки | Account-wide tombstone, книга скрывается на связанных устройствах | Удаляются локальные sources на инициирующем устройстве; получение tombstone другим устройством само по себе не удаляет его файл |
| Удалить локальную копию | Книга остаётся в account library, локальный source снимается | Удаляется локальная копия |
| Повторно добавить тот же SHA | Явное восстановление записи с новой metadata revision | Имеющийся файл используется повторно, иначе импортируется |
| Обычное сканирование | Не снимает tombstone | Файлы не удаляются |
| Смена папки | Подключается новая LibraryRoot | Старая папка и её файлы сохраняются |

## #28: решение и границы доказательств

Подтверждено пользователем: сбой build 118 после reinstall исчезает после
Clear Storage при том же APK. В приложении отсутствовала backup policy;
secure-storage error также попадала в общий путь manifest corruption.
Исправлено: исключение защищённого хранилища выделено отдельно, валидный
manifest не карантинится и не сбрасывается, UI не показывает Java/plugin детали.
Повторная ошибка после ранее успешной загрузки тоже показывает error view.

Вероятная цепочка: восстановленные encrypted preferences + отсутствующий
Keystore key → ошибка инициализации/дешифрования. Точное соответствие исходной
NPE этой цепочке НЕ доказано: нет dump restored prefs/Keystore aliases с
устройства пользователя. #28 остаётся открыт до физической проверки.

Выбран Option A: app-controlled recovery, `allowBackup=false`.
Дополнительно legacy rules и Android 12+ cloud/device-transfer rules исключают
root/file/database/sharedpref/external app data. Это нужно, поскольку у некоторых
производителей `allowBackup=false` не выключает D2D transfer. User-owned SAF
LibraryRoot не превращается в app backup и не удаляется.
Option B с выборочным backup не выбран: восстановление настроек/manifest без
installation secrets создало бы вторую неявную модель восстановления.

`flutter_secure_storage` закреплён на 10.3.4, patch-линии существующего 10.3.0;
11.x не вводится в стабилизационный scope. Upstream 10.3.1–10.3.4 содержит
Android initialization/migration fixes, но это не доказательство устранения
исходной NPE и не замена backup policy. `resetOnError=false` сохранён;
plaintext fallback и автоматического удаления secrets нет. `migrateWithBackup`
— внутренняя транзакционная копия plugin, а не разрешение Android OS backup.

Источники:
- https://pub.dev/packages/flutter_secure_storage/versions/10.3.4/changelog
- https://pub.dev/packages/flutter_secure_storage/versions/10.3.4
- https://developer.android.com/about/versions/12/behavior-changes-12#backup-restore

## Проверки

- `library_empty_recovery_test.dart`: нажатия обеих кнопок empty view,
  обновление списка без restart, provider failure и retry, PlatformException через
  real secret-store wrapper, безопасный UI и отсутствие сброса состояния.
  UI использует управляемую память; настоящий filesystem проверяется отдельно.
- `storage_service_test.dart`: bytes и stream fallback, cleanup после успеха/ошибки чтения,
  новый SHA при другом tombstone,
  same-SHA после локального удаления и при surviving remote file; смена root без удаления файлов.
- `library_repository_test.dart`: недоступные secrets не карантинят валидный manifest.
- `regression_contract_test.dart`: backup exclusions и fail-closed параметры.
- Существующие portable-state, fresh device keypair/identity, Recovery Key,
  pairing recovery, account boundaries, two-client transfer regressions сохраняются.
- Итоговые CI run/head/artifacts фиксируются в PR #14 и Issues #24/#25/#27/#28.

PR builds используют ephemeral Android certificate и macOS ad-hoc signing.
Успешный upgrade smoke с переподписанными fixtures не доказывает возможность
установки PR APK поверх production APK с другим сертификатом.
Для проверки Android reinstall используйте один и тот же новый APK дважды.

## Ручная приёмка

Перед удалением приложения сохраните Recovery Key либо оставьте доступное
доверенное устройство; книги должны быть в user-owned папке.

A. Удалить приложение, установить новый APK, не делать Clear Storage.
Проверить нормальный старт, выбрать прежнюю папку и восстановить аккаунт ключом.
Проверить progress и новую запись устройства. Затем uninstall/reinstall того
же APK при включённом системном backup, повторить recovery. Для точной
диагностики #28 при повторном сбое нужны безопасные сведения о restore и
наличии aliases (без ключей, ciphertext и содержимого книг).

B. Android + Mac: удалить книгу на Mac из библиотеки; на Android проверить
пустой экран с именем папки. Импортировать новый SHA, повторить сценарий с
тем же SHA. Книга появляется сразу. Проверить смену папки и сохранность старых файлов.

C. Повторить pairing, стабильное число книг, загрузку Android-only книги на Mac,
синхронизацию progress. #20–#23 и physical iOS certification остаются вне scope.

Relay update: NOT REQUIRED. С момента `0639da2` server/protocol не менялись.
