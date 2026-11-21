# Текущий статус iOS — 21.11.2026

Это краткая текущая сводка. Датированные записи в остальных документах — история.
Задание: полный перенос Android10.90, commit
`56155352b0e9f36ef3685aa071a6aafdb2ef6622`, с утверждённым дизайном, затем App Store.
Порядок работы: [AUTONOMOUS_WORK.md](AUTONOMOUS_WORK.md).

## Новый пакет без физического iPhone — ожидает Apple SDK/runtime

Первый source `cc5f616` / public `dd51a32`, run44924160939 завершился
неуспешно21.11 в16:37UTC: Apple core прошёл, но два холодных запуска Intel
симулятора остановились на timeout UI appearance service. Сборка приложения,
hosted/UI, Release и новые снимки в этом run не запускались. Это инфраструктурный
сбой, а не подтверждённая ошибка приложения. GitHub connector показывал устаревший
статус; актуальное завершение проверено через REST без кэша.

Следующий цельный source включает:
- Явный local reset/PIN recovery: атомарный пустой state с durable cleanup marker,
  отказ старым моделям в записи и повторной очистке новых данных,9 hosted contracts.
- Остановка отклонённого native-only hello без удаления ключей и BLE grants;
  причина переводится при отображении. Сам контракт аттестации ещё не решён.
- Параметризуемые App/Widget IDs и App Group, проверка собранной конфигурации,
  безопасный генератор release inputs, фактические privacy declarations.
- Общий privacy link в System/Help;1423 Product keys во всех7 языках. Переведены
  активные UI literals и известные системные результаты при отображении, сохраняя
  исходные значения для протокола/логики и пользовательский текст без изменения.
  Даты следуют выбранному языку. Добавлен английский UI-сценарий.
- Центрирование «Нарисовать маршрут», два новых native reset checkpoints.
- Четыре оригинальных Store JPEG после полного native/UI прохода на том же
  проверенном симуляторе; независимые Debug/Release/archive при сбое UI service.
  Ошибка подготовки всё равно делает общий review неуспешным.

Локально: Swift syntax parse PASS (не SDK typecheck); Linux Foundation исполнил
ProductText с реальными1423×7 resources; структура ключей/placeholder одинакова.
11 pipeline /6 process /4 release-preparation checks прошли в подготовке.
Ожидаемый Apple набор:313core/212hosted/33UI +9focused,64nativePNG +4originalJPEG.
Это ожидаемые количества, новые runtime assertions ещё не приняты.
До complete CI и просмотра всех новых кадров галерея сохраняет62 d4915bb.

Материалы: [RELEASE_HANDOFF.md](RELEASE_HANDOFF.md),
[PRIVACY_DATA_FLOWS.md](PRIVACY_DATA_FLOWS.md), `release/metadata/`.
Публичная privacy policy дополнена фактическими iOS flows/retention/reset;
все7 языковых destinations отвечают HTTPS200. Production APNs schema создана
пустой, provider отключён. Реальная доставка и signing остаются внешними gates.

## Выполненный пакет замечаний — 21.11.2026

Вторая серия: все9 замечаний и дополнительный показ глубины/количества ключей
реализованы. Подробности: [REVIEW_FIXES_20261121.md](REVIEW_FIXES_20261121.md).
62 настоящих кадра просмотрены и опубликованы вместо58 прежних в
[галерее](https://entrixy.com/ios-design.php). Один светлый iPhone16 на состояние.
Передача владельцем и дальнейшая передача гостем показаны с глубиной3 и пулом7.

## Проверенная версия

- Native app/source `b18d37f` → public `d4915bb27e3ef1a436d8f8c270e6488e96fd1c07`,
  branch `ci/review-batch`.
- [Apple CI44909437420](https://github.com/entrixy/ios-build./actions/runs/44909437420),
  job136861889924: **success**. Apple312core,198hosted,31UI — без ошибок.
  Перед полным проходом6 switch-focused и3 адресных сценария также прошли.
  Debug, Release/privacy/isolation, unsigned physical-iPhone app/widget archive прошли.
- Все62 оригинальных XCTest PNG получены из того же успешного полного прохода;
  source и SHA256 сверены, просмотрены все кадры и дополнительно6 оригиналов.
  Без ретуши/обрезки/дубликатов вариантов. Прежние58 сняты с сайта с приватной копией.
  HTTPS-хеши всех62 совпали; desktop/mobile, поиск, next/previous, клавиатура/фокус/
  Escape, zoom/swipe проверены; JS ошибок и горизонтального overflow нет.
- Full artifact14711262844 SHA256
  `e39ab5585b31c08321ef37811cc619bf47c2981fe2287186a2385bb951cc47a7`.
  Device evidence14711489262 SHA256
  `606536e982e8b31c3113ff57fec14d4609a30a9359f8fb9c3891f14aafeef83d`.
- Ранние неуспешные прогоны и промежуточные визуальные отклонения сохранены
  в истории и не публиковались. Native Stepper проверяется реальным нажатием
  на пределе, поскольку AX может сообщать isEnabled=true для серой кнопки.
  Прежняя точная причина intermittent input failures не доказана;
  успешный симулятор не заменяет устройство/Release input acceptance.
- Backend native push: website `d9ec3b6`,23provider/22изолированных DB+HTTP
  контрактов прошли. Production migration выполнена21.11 с пустыми таблицами и отключённым provider;
  credentials/worker и реальная APNs доставка не настроены/не проверены. Существующий Android FCM сохранён.

Успешный baseline не означает полный перенос или готовность к App Store.
Снимки показывают viewports тестовых профилей; hardware/реальные аккаунты ими
не проверяются. Архив unsigned; PNG1178×2556 пока не приняты как Store assets.

## Остаток: связанные пакеты и критерии

| Пакет | Работа и критерий завершения |
| --- | --- |
| A. Оставшиеся программные расхождения | Пройти незакрытые ветви 62-узловой структуры/50 сценариев с Android source. Закрыть доступные программные пробелы: оставшиеся UI/локализация/справка, iOS recovery/PIN и контракты. По каждому пункту записать источник, реализацию и проверку. Не переписывать уже зелёные функции. |
| B. Подготовка выпуска | Свести фактические data flows/retention в iOS privacy policy и Store answers; завершить ru/en metadata, reviewer checklist и оригинальные Store assets правильного размера. Подготовить signing/APNs/AASA/worker инструкции с подтверждёнными идентификаторами. Секреты и итоговые ответы не выдумывать. |
| C. Живая совместимость и устройства | Успешный account link; Android↔iOS выдача/передача/отзыв/ротация/backup; реальный BLE pair/fire/revocation; камера, cellular, permissions, background/locked/force-quit/reboot, Widget/App Group, APNs и deep links. Исправить выявленные дефекты одним пакетом. Симулятор не заменяет эту приёмку. |
| D. Кандидат и выпуск | Точный финальный source проходит общий Apple набор и визуальную проверку; signed archive/IPA, установка/TestFlight, privacy/review metadata, submission после требуемой приёмки/доступов. |

Начать пакет A с адресного аудита оставшихся пунктов; пакет B можно готовить
пока ожидается необходимый доступ к C. Нового тестового прогона ради этой
документации не нужно. Детали: ANDROID_IOS_PARITY.md и APP_STORE_PACKAGE.md.

## Конкретные незакрытые вопросы

- Whole-key `native_only`: server требует attest/attest_ts, ни текущий Android,
  ни iOS hello их не посылают. Это общий source contract gap; не обходить
  проверку и не встраивать server secret. Нужна совместимость обеих платформ.
- Новый reset/recovery и локализация ожидают Apple hosted/UI acceptance. Исходные
  пользовательские имена и сообщения не переводятся; количество Product keys
  само по себе не подтверждает полноту всех сценариев.
- Публичная privacy policy обновлена; final Store answers, account/deletion
  classification, export compliance и reviewer access ещё не подтверждены.
- TeamID/BundleID вопрос ранее задан, ответа нет; provisional IDs не считать
  подтверждёнными. Не переспрашивать на каждом шаге и не придумывать доступы.

## Локальные доказательства

`.local-checks/batch-d4-full-evidence/`: логи и62 оригинальных screenshots/review.json,
включая6+3 focused,198hosted/31UI. `.local-checks/batch-d4-device-evidence/`:
arm64 iphoneos SDK26.2, min iOS16 app/17 widget, unsigned; privacy manifests и
fixture isolation passed, upload_ready=false. Website private:
`native-d4-full-visual/` (62-state visual record/CI verification),
`screenshot-gallery-qa/results.json`, backup `before-native-ui-20261121-145830`.
Старые неуспешные пакеты не публиковались. Public main `069d20b` и private origin
не изменялись. Генерируемые файлы, снимки, конфигурация и секреты в Git не входят.
