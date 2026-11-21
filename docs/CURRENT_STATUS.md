# Текущий статус iOS — 21.11.2026

Это краткая текущая сводка. Датированные записи в остальных документах — история.
Задание: полный перенос Android10.90, commit
`56155352b0e9f36ef3685aa071a6aafdb2ef6622`, с утверждённым дизайном, затем App Store.
Порядок работы: [AUTONOMOUS_WORK.md](AUTONOMOUS_WORK.md).

## Новый пакет без физического iPhone — source подготовлен

Добавлены явный безопасный local reset/PIN recovery с durable cleanup marker,
защита от старых записей после reset, остановка отклонённого native-only hello
без удаления ключей, параметризуемые App/Widget IDs и App Group, декларации
фактических privacy flows и оригинальные JPEG Store candidates в CI.
«Нарисовать маршрут» центрируется;33 legacy UI подписи используют существующие
переводы,20 новых ключей есть во всех7 языках (984 Product keys).
Материалы: [RELEASE_HANDOFF.md](RELEASE_HANDOFF.md),
[PRIVACY_DATA_FLOWS.md](PRIVACY_DATA_FLOWS.md), `release/metadata/`.

Локально: Swift syntax parse PASS (не Apple SDK typecheck),6 GuestEvent core
cases PASS,11 pipeline/6 process/4 release-preparation contracts PASS,
984×7 key/placeholder consistency PASS. Новый Apple runtime ещё НЕ выполнен.
Ожидаются313core/207hosted/32UI,64 отдельных native PNG и4 original JPEG.
До actual complete CI/visual review галерея сохраняет прежние62 d4915bb.
Production APNs tables подготовлены пустыми, provider оставлен отключённым;
публичная политика дополнена фактическими iOS processing/retention/reset.

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
  контрактов прошли. Provider config, production migration/worker и реальная
  APNs доставка не настроены/не проверены. Существующий Android FCM сохранён.

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
- Предупреждение о забытом PIN копирует Android reinstall recovery; iOS Keychain
  может пережить удаление. Проверить реальный recovery path без молчаливой
  потери identity/ключей и исправить сообщение/поведение согласованно.
- Остались legacy строки;964 Product keys в семи языках не означают перевод
  всех пользовательских ветвей. Проверять активные пути, а не число ключей.
- Публичная privacy policy пока Android-oriented. Учесть диагностику,
  promotion install UUID/счётчики, APNs token/retention, location/Maps.
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
