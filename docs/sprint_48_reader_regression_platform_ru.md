# Sprint 48 — Reader regression platform

## Цель

Зафиксировать текущее поведение reader-ов ReadArc до дальнейшего изменения форматных движков и
не допускать незаметных регрессий структуры документа, текста, навигации и восстановления позиции.

## Архитектура

- `lib/main.dart` оставлен только точкой входа; приложение перенесено в
  `lib/app/readarc_app.dart`.
- Публичный `ReaderRegressionPlatform` и форматные adapters находятся в `lib/reader/`.
- Characterization API использует те же FB2/EPUB/DOCX/PDF/DJVU parsing functions, что и приложение,
  и возвращает детерминированный `ReaderDocumentSnapshot`.
- Тяжёлый TXT/FB2/EPUB/DOCX parsing вынесен из UI-isolate. Операция reader-а отменяется при закрытии
  экрана и принудительно завершается по timeout.
- `ReaderDocumentCache` материализует документ лениво и ограничен одновременно по числу документов
  и приблизительному объёму текста.
- PDF render cache остаётся ограниченным двумя страницами на Android и тремя на desktop.

## Защита ресурсов

До распаковки EPUB/DOCX читается central directory ZIP и проверяются:

- размер исходного файла;
- количество entries;
- размер одного entry и суммарный распакованный размер;
- compression ratio;
- ZIP64, дубли имён и traversal/absolute paths.

Повреждение или превышение лимита возвращает диагностируемый `ReaderParseException`, а не пустой
успешный документ.

## Fixtures и тесты

В `test/fixtures/` добавлены TXT, FB2, EPUB, PDF, DOCX и DJVU fixtures. Поведенческие тесты проверяют:

- blocks, semantic text и таблицы;
- число страниц PDF/DOCX/DJVU;
- EPUB href/anchors;
- сохранение и восстановление block/page locator;
- повреждение каждого поддерживаемого fixture-формата;
- oversized input, ZIP bomb declarations и path traversal;
- большой TXT, отмену фоновой обработки, lazy materialization и LRU eviction.

Fixture с исправленной регрессией считается частью контракта и не должен заменяться упрощённым
файлом без изменения тестовых ожиданий и объяснения в PR.

## Неизменённый scope

Новые пользовательские функции и форматы не добавлены. Sync protocol, manifest schema, pairing,
relay и production signing не изменялись. Публикация release остаётся возможной только после всех
обязательных jobs verified pipeline.
