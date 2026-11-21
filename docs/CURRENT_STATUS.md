# Текущий статус iOS — 21.11.2026

Это краткая текущая сводка. Датированные записи в остальных документах — история.
Задание: полный перенос Android10.90, commit
`56155352b0e9f36ef3685aa071a6aafdb2ef6622`, с утверждённым дизайном, затем App Store.
Порядок работы: [AUTONOMOUS_WORK.md](AUTONOMOUS_WORK.md).

## Выполненный пакет замечаний — 21.11.2026

Все10 согласованных замечаний реализованы; подробности в
[REVIEW_FIXES_20261120.md](REVIEW_FIXES_20261120.md).
58 настоящих кадров просмотрены и опубликованы вместо56 прежних в
[галерее](https://entrixy.com/ios-design.php). Один светлый iPhone16 на состояние.

## Проверенная версия

- Native `e2defc3` → public `de13dad311be3a18b21e2c6f15f174049c7c901b`,
  branch `ci/review-batch`; public tree тот же, что2b95a82 (повтор после preflight).
- [Apple CI44877317284](https://github.com/entrixy/ios-build./actions/runs/44877317284),
  job136764768820: **success**. Apple312core,197hosted,29UI — без ошибок.
  Дополнительно оба проблемных switch-сценария прошли по3 раза (6/6).
  Debug, Release/privacy/isolation и unsigned physical-iPhone app/widget archive прошли.
- Все58 оригинальных XCTest PNG из того же полного прохода: source и SHA256
  сверены, кадры просмотрены, без ретуши/обрезки/дубликатов вариантов.
  Прежние56 сняты с сайта с приватной копией. HTTPS-хеши всех58 совпали;
  desktop/mobile, поиск, клавиатура/фокус/Escape, zoom/swipe проверены;
  JS ошибок и горизонтального overflow нет.
- Artifact14698233796 SHA256
  `8616c44c56851aeea95b064d13f9cbe4aea64b019753eb2f65ee4ed917e66e92`.
  Device evidence14698123615 SHA256
  `ee5282d6ead39e042296f4ceaf5f322b3e894d38ca98fceedd2045a6e104255d`.
- Прежние intermittent input failures XCTest сохранены в истории. Новый
  DEBUG-only пассивный наблюдатель показал реальные попадания в UISwitch и
  единственное сохранение согласия на каждое включение. Точная причина старых
  сбоев не доказана; успешный симулятор не заменяет устройство/Release input acceptance.
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
- Остались legacy строки;950 Product keys в семи языках не означают перевод
  всех пользовательских ветвей. Проверять активные пути, а не число ключей.
- Публичная privacy policy пока Android-oriented. Учесть диагностику,
  promotion install UUID/счётчики, APNs token/retention, location/Maps.
- TeamID/BundleID вопрос ранее задан, ответа нет; provisional IDs не считать
  подтверждёнными. Не переспрашивать на каждом шаге и не придумывать доступы.

## Локальные доказательства

`.local-checks/batch-de-full-evidence/`: логи и58 оригинальных screenshots/review.json.
`.local-checks/batch-de-device-evidence/`: arm64 iphoneos, min iOS16 app/17 widget,
unsigned, privacy manifests и fixture isolation passed; upload_ready=false.
`.local-checks/batch-de-focused-evidence/`:6/6 focused cases и неперсональная
запись касаний/Bool-переходов. Website private: `native-de-full-visual/` (58-state
visual record/CI verification), `screenshot-gallery-qa/results.json`, backup
`before-native-ui-20261121-080133`. Старые неуспешные пакеты не публиковались.
Public main `069d20b` и private origin не изменялись. Генерируемые файлы,
снимки, конфигурация и секреты в Git не входят.
