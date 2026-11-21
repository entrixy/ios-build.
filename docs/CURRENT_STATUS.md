# Полный объём iOS — 22.11.2026

Позднее требование пользователя: внести ВСЁ доступное без физического iPhone,
затем один итоговый Apple-прогон и полная галерея. Последний пакет не заменяет
весь объём. Результат source-аудита: [NO_IPHONE_AUDIT.md](NO_IPHONE_AUDIT.md).

Текущие дополнения ещё НЕ прошли Apple SDK/runtime: RTSP/DASH/WebM/MKV через
прикреплённый официальный VLCKit с защищёнными loopback-мостами; запрос alert
permission для гостя с сообщениями; настоящий Go native_only contract и корректный
текст отказа; инициирование удаления серверных данных с защищённой квитанцией,
подтверждением DELETE и новым входом для всего аккаунта. По всем7языкам1441ключ.

Локально322core PASS, включая3 новых deletion и6 camera/contract;14проверок
pipeline PASS; Swift syntax (НЕ SDK), YAML/Python и7-language parity PASS.
План общего набора:223hosted/34UI/66оригинальныхPNG +4StoreJPEG, Debug/Release/
privacy/isolation и unsigned physical-iPhone archive с динамической camera library.
Это ожидаемое покрытие, не выполненная Apple-проверка и не процент готовности.

Backend website ea599ec:16изолированных deletion checks/PHP-l PASS. ПубличныйAPI
реально возвращает503deletion_unavailable, CLI URL404. Migration не применялась,
реальных заявок/удалений нет. Активация требует согласованного оператора, срока и
инвентаря удаления/законного хранения: install/DATA_DELETION.md сайта. Не выдавать
ручную обработку заявки за автоматическую очистку или действующий сервис.

Предыдущий полезный CI44943637451/public9167004 не отменён:313core/Debug и2реальные
UI-регрессии PASS; общий212hosted PASS, UI32из33/63из64PNG, failure. Единственная
ошибка — жест XCTest не переместил ползунок TTL (rawAXvalue5 вместо процентов).
Артефакт14726745908/SHAce95d05d проверен, отказ неполной публикации сохранён.
Теперь тест двигает видимый thumb по actualframe/rawvalue и требует «1 час»,
не ослабляя проверку. Четыре адресных случая (slider/новыйdeletionUI/дваdecoder)
идут перед целым223hosted/34UI; прежние reset/English уже прошли и отдельно не
повторяются. Release/archive предшествующего source ещё исполняются. Его исходник НЕ
содержит текущие дополнения; изображения не публиковать как финальные. Галерея
остаётся62кадра принятогоd4915bb, пользовательская загрузка файлов остаётся сверху.

Ниже — история пакета21.11; её pending/количества не заменяют сводку выше.

# Текущий статус iOS — 21.11.2026

Это краткая текущая сводка. Датированные записи в остальных документах — история.
Задание: полный перенос Android10.90, commit
`56155352b0e9f36ef3685aa071a6aafdb2ef6622`, с утверждённым дизайном, затем App Store.
Порядок работы: [AUTONOMOUS_WORK.md](AUTONOMOUS_WORK.md).

## Новый пакет без физического iPhone — два UI исправления ожидают проверки

Исправленный source00573f0/publicfa6f665, run44941648937:313core, Debug,
Release/privacy/isolation и unsigned arm64 iPhone app/widget archive прошли.
Но UI вообще не запускался: начальный `simctl list runtimes --json` превысил60с.
Общий run неуспешен по обязательному simulator-health gate;2 UI-исправления
этим запуском НЕ проверены. Нельзя выводить готовность из REST conclusion шага
с continue-on-error: нужны prepared-device evidence и действительный UI result.

Вместо слепого полного повтора выполнен отдельный run44942724439/source3445040:
Intel и ARM оба прошли. Оба SHA-verified artifacts содержат source-owned iOS26.2
prepared-device reports и1179×2556 native health frames; это НЕ снимки приложения.
Добавлено ограниченное восстановление только обнаруженного metadata timeout:
один restart CoreSimulator на disposable GHA host ДО создания устройства/сценариев,
затем один повтор того же запроса. На Mac разработчика, при иных ошибках или
повторном timeout восстановление не выполняется/ошибка не скрывается. Проверено
тремя новыми boundary cases (всего14pipeline). Reuse/cleanup после UI службу
не перезапускает. Полный preparation log сохраняется сразу, до компиляции.

Source `de3e44d` / public `dbd5e1d`, run44931604741: Apple313core, Debug app/widget/
test bundles,212hosted и9focused прошли. Общий UI:31из33 прошли; два новых сценария
не прошли. Получены62из64PNG, complete=false/tests_succeeded=false; не опубликованы.
Store capture после ошибки пропущен; Release/privacy/isolation и unsigned
iPhone app/widget archive прошли, upload_ready=false.

Причины и следующий цельный fix:
- Reset sheet был прикреплён к Group из нескольких List Sections и не открывался.
  Владение sheet перенесено в стабильный SettingsScreen/AppEntryLockSettings;
  Section вызывает переданный callback. Та же форма/дизайн/защита сброса сохранены.
- DEBUG SettingsScreen.task повторно применял начальный capture route при возврате
  из Messages и переключал System на Objects. Настройка fixture теперь выполняется
  один раз на экземпляр; обычный settingsRequest обрабатывается по-прежнему.
  Английский тест дополнительно проверяет сохранение выбранной System.
- В следующем Apple batch сначала исполняются именно эти2 регрессии, затем весь
  набор212hosted/33UI/64PNG. Прежние9 focused уже прошли; соответствующие сценарии
  остаются в общем наборе, без отдельного повторения. Assertions не ослаблены.
- После завершения UI/Store-фазы job-owned симулятор освобождается до Release/
  archive, включая ошибочный UI. Эти SDK-only сборки не требуют запущенного
  симулятора. Это освобождение ресурсов, не доказанный диагноз медленной сборки.

Состав пакета: явный атомарный local reset/PIN recovery с durable cleanup marker,
запрет старых записей/очистки новых данных;9 reset contracts прошли. Native-only
refusal прекращает одинаковый reconnect и сохраняет ключи/BLE; рабочий Go-контракт client=app подтверждён по source22.11.1423 Product keys во всех7 языках, активный UI и известные
системные результаты переводятся при отображении; raw protocol и пользовательские
данные сохраняются. Три localization hosted cases прошли; английские import/messages
положительные проверки прошли до описанной ошибки возврата в fixture.
Есть прямой privacy link System/Help и даты выбранного языка.

App/Widget IDs/App Group параметризованы, генератор release inputs не принимает
неподтверждённые значения. Privacy flow inventory/manifests, RU/EN metadata и
review handoff подготовлены. RU keywords исправлены до94 UTF8bytes/EN55; Support/
marketing/privacy URLs добавлены отдельным metadata/docs-only `9d86cef` (в bundle
не входят). Публичный guide на всех7языках уточняет recovery/Keychain/ограничения
и содержит contact email; политика дополнена фактическими iOS flows/retention.
Production APNs schema создана пустой, provider отключён.

Первый `cc5f616` / public `dd51a32`, run44924160939 остановился на simulator UI
service до Debug. Новый fresh host эту ошибку не воспроизвёл. Это отдельный
инфраструктурный сбой, не причина двух UI failures выше.

Локально для исправлений: Swift syntax parse PASS (не SDK typecheck),14 pipeline
contracts/Python AST/YAML/diff PASS. Новый Apple runtime ещё не исполнен. Ожидаемый итог:
313core/212hosted/33UI +2focused,64nativePNG +4originalJPEG на том же симуляторе.
До complete CI и просмотра всех новых кадров галерея сохраняет62 d4915bb.
Материалы: [RELEASE_HANDOFF.md](RELEASE_HANDOFF.md),
[PRIVACY_DATA_FLOWS.md](PRIVACY_DATA_FLOWS.md), `release/metadata/`.

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

- Проверка22.11: рабочий `/ws` обслуживает Go-сервер (private/ws-go), а не
  legacy w/server.php. Его native_only проверяет client=app; iOS уже посылает
  этот признак вместе с подписью hello. Go сохраняет press при relay/подтверждении.
  Прежний вывод о необходимости HMAC/App Attest относился к неработающему PHP.
  Не добавлять новый протокол и не менять рабочую проверку подлинности.
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
