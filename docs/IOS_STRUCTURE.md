# Структура iOS по карте Android

Основание: [62 узла Android](ANDROID_STRUCTURE.md), Android 5615535. Это карта
реального подключения и пробелов, а не объявление полного переноса.

## Актуальная сверка — 17.11.2026

Таблица ниже обновлена по source `6b42489`. Последний полный функциональный
Apple-прогон относится к `fe9e8e1`: core240/native140, Debug/Release/isolation
без ошибок. Более новые компактные диалоги и автотриггеры с подтверждением/PIN
имеют только syntax/source проверки и ожидают Apple. Более поздний ARM UI-прогон
`d1f89b7` прошёл все16 UI-кейсов, включая аватар/compact confirm/PIN/factory claim;
Core245 Apple/Debug также прошли. Новый BLE Info и код в редакторе ждут UI17.
Текущий core248 прошёл Linux; полная новая native146 проверка ещё ожидается.
Строка с подключённым маршрутом не означает визуальную или аппаратную приёмку.
Полные исходники и доказательства: [FUNCTIONAL_PORT.md](FUNCTIONAL_PORT.md).
Ниже таблицы сохранены исторические результаты каталога от 16 ноября.

## Слои и владение данными

- App shell: RootView + AppNavigationState, единая нижняя панель и отдельные задачи.
- Каталог: ObjectReference (owner server + UUID либо received guest identity + object ID),
  CatalogObject, ObjectCatalogModel. Настройки и Управление используют один список,
  порядок и visibility. Числовой server ID никогда не является UI identity сам по себе.
- Локальное представление: ObjectCatalogPreferences в SavedState/Keychain. Received
  label/hidden не меняют GuestObject metadata, ключ, bundle, grant или полномочия.
  Save происходит до публикации изменения; отказ записи сохраняет прежний интерфейс.
- Экраны задач: ObjectSettingsRows раскрывает действия; ObjectSettingsTask несёт
  точный target. OwnerObjectEditor изменяет owner object, ReceivedObjectNameScreen —
  локальное имя. AddCatalogObjectScreen использует выбранный в Системе сервер; AddOwnerObjectScreen — тип,
  BLEPairingScreen продолжает создание нового BLE-объекта. BLE никогда не приписывается
  к соседней карточке существующих ворот.
- Защита/исполнение: AppModel создаёт замороженный ActionIntent/OwnerActionIntent,
  повторно проверяет после auth/confirm; GuestActionPolicy/OwnerManualPolicy,
  owner/guest WS, BLE models исполняют существующие команды. Каталог не даёт authority.
- Состояния: connection/availability, position и actual outcome раздельны.
  CatalogStatusAvatar показывает availability кругом на аватаре. Текст результата,
  причины отказа, pause и сообщения сохраняются в своих блоках. BLE observation
  имеет срок по sleep interval; без наблюдения доступность неизвестна. Нового
  foreground passive scanner подключён; фон и физическое радио ещё не проверены.
- Выдача/передача: OwnerIssuedKey/KeyObjectAccess и PassedAccess остаются владельцами
  персистентного scope. IncomingDepth даёт только видимость вкладки. Per-object
  templates владельца, выданного гостя и incoming должны оставаться разными областями.
- Восстановление: IOSBackupPayload несёт optional preferences, старые state/backup
  читаются без них. Merge сохраняет текущий локальный выбор при конфликте; rollback
  до успешного save. Ключи/identity не пересоздаются ради изменений UI.

## Полная раскладка узлов

Маршруты указаны по рабочему коду; оставшиеся границы отделены от наличия UI.
Фон, оборудование, live E2E и App Store требуют самостоятельной проверки.

| Android ID | Узел | iOS feature / маршрут | Подключение и границы |
| --- | --- | --- | --- |
| C01 | Общий список карточек | ObjectCatalogModel → ControlScreen | Подключён общий порядок и visibility. |
| C02 | Карточка действия | GuestCatalogControlCard / OwnerCatalogControlCard | Прямой тап, индикатор на аватаре, scoped policy; компактный ActionPrompt ожидает свежей Apple/UI-проверки. |
| C03 | Ручной запуск | AppModel.actionIntent/ownerActionIntent → execute | Существующие guards/PIN/биометрия/one-shot сохраняются. |
| C04 | Состояние контроллера | CatalogStatusAvatar / BLEPassiveObserver / BLEProximityRuntime | Свежие подписанные BLE observations и RSSI debounce в foreground; фон/реальное радио не подтверждены. |
| C05 | Положение объекта | OwnerControlModel.positions / ActionLink.positions | Исходные4 уголка OPEN поверх аватара,64/56pt и статус-точка как Android; BLE только при свежем reachable observation. Данные/выбор направления сохраняются; новая source/UI-проверка ожидается. |
| C06 | Камера в карточке | ObjectControlCard / ObjectCameraStream / CameraVideoProxy | Поток в той же карточке, showWhen, scoped camera entitlement; JPEG/MJPEG/native HLS/MP4, auth bridge проверен транспортными тестами. Декодирование камеры/другие форматы не приняты. |
| C07 | Готовность автоматизации | AutomationEditor / AutomationCoordinator / AutomationRuntime | Geo route/zone, Wi-Fi/time/BLE, latch/rearm. Source ограниченного background BLE/owner-local-webhook подключён; iOS Wi-Fi scan/постоянный WSS не имитируются. Новый Apple/device прогон ожидается. |
| C08 | Подсказки/баннер | HomeLocationWarning / HomeWidgetHint / PhoneReadinessCard | Source: классический плохой GPS по Android80m/240s/90s; widget hint только без виджета и при полностью помещающемся списке. Права в Settings. Promo cache/события и frozen-GPS/motion остаются отдельно. |
| O01 | Общий список | ObjectSettingsRows + ObjectCatalogPreferences | Один смешанный список; onMove сохраняет порядок; стандартный режим изменения порядка iOS. |
| O02 | Свой обычный объект, раскрытие | ObjectSettingsRows → OwnerObjectEditor / AutomationEditor | Редактор типа, автонастройки, удаление; новая UI-проверка переходов ещё ожидается. |
| O03 | Входящий обычный объект, раскрытие | ReceivedObjectNameScreen / AutomationEditor / hideReceivedObject | Локальное имя/скрытие и scoped incoming three-way overrides, force bounds; ключ/соседние объекты сохраняются. |
| O04 | Свой BLE, раскрытие | OwnerObjectEditor / AutomationEditor / BLEPermissionsScreen | Автонастройки, durable перенос сервера и отдельная owner Info после AutoMode подключены; новый Info-source ожидает Apple/UI. |
| O05 | Входящий BLE, раскрытие | ReceivedObjectNameScreen / AutomationEditor / hideReceivedObject | Scoped incoming BLE overrides и локальное представление; signed grant/expiry/revocation guards сохраняются. |
| O06 | Добавить объект | AddCatalogObjectScreen → AddOwnerObjectScreen | Четыре типа в порядке Android; используется выбранный сервер, регистрация только при Save. Pending registration не отправляется заново вслепую. |
| O07 | Создать call | AddOwnerObjectScreen / ObjectPhoneContactPicker | Телефон и системный выбор контакта; iOS handoff просит системное подтверждение, автоматический сброс звонка недоступен. |
| O08 | Создать webhook | WebhookConfigurationFields / PhoneWebhookTransport | URL/secret, phone/server mode и toggle; HMAC, журнал до POST и отсутствие повтора после потерянного ответа проверены. |
| O09 | Создать device | createOwnerObject(device) / deviceRegister / DeviceCredentialsSheet / DeviceClaimLink | Durable device registration и credentials; reply recovery без второй identity. Factory claim deep link подставляет код и исходный host (новый source, Apple/UI ещё pending). |
| O10 | Создать BLE | AddOwnerObjectScreen(Bluetooth) → BLEPairingScreen → BLEPairingModel | Подключён реальный существующий pair executor; новые secrets/физические команды не симулируются. |
| O11 | Редактор обычного объекта | OwnerObjectEditor / OwnerObject | Call/webhook/device поля и policy; защищённые параметры сохраняют исходный объект и ожидающие изменения. |
| O12 | Поделиться устройством | DeviceCredentialsSheet / ownerDeviceCredentials | ENTX-DEV, QR/copy/share сохранённых credentials; явное missing-credentials состояние. |
| O13 | Привязать приложение к device | OwnerObjectEditor.deviceFields / ownerSocketBindingCode | ENTX-BIND создаётся и сохраняется перед показом, копирование без пересоздания объекта; физический конфигуратор не проверен. |
| O14 | Редактор своего BLE | OwnerObjectEditor / OwnerBLEMove / moveBLEObject | Durable create-target/delete-source/local merge; исходные UUID/secret/pairing и порядок сохраняются, неоднозначный ответ не дублирует создание. |
| O15 | Информация BLE | BLEInformationDialog / BLEDeviceInformation / owner observer | Authenticated owner v3/v4 battery/status/fw/hw/sleep/age; явное no-data для legacy/без наблюдения. Core248 Linux прошёл; новая UI17/Apple проверка pending. |
| O16 | Удаление своего объекта | ObjectSettingsRows → deleteOwnerObject | Существующий durable delete/reconcile и BLE revocations сохраняются. |
| O17 | Аватар объекта | ObjectAvatarPicker / ObjectAvatarImage / saveObjectAvatar | 8 исходных пресетов и PhotosPicker/crop/JPEG; owner encrypted upload и incoming local override. Открытие, 8 пресетов и кнопка загрузки прошли UI17; физическая загрузка фото ещё не принята. |
| O18 | Камера: настройки | ObjectCameraFields / ObjectCameraConfiguration | Stream/snapshot/auth/showWhen, частные параметры и per-key entitlement; real camera/device acceptance остаётся. |
| K01 | Полученные ключи | SettingsScreen.keys → KeyDetailScreen | Отдельная подвкладка; connection здесь остаётся информативным текстом. |
| K02 | Добавить ключ | KeyImportScreen → AppModel.add | Paste/QR/photo + bind; повторный импорт возвращает hidden без замены identity. |
| K03 | Удалить входящий ключ | AppModel.removeKey | Очищает и catalog overrides/order только этого guest scope. |
| S01 | Звуки | SoundSettingsRows / AppSoundCenter / EventSoundBackup | 9 исходных событий, оригинальные MP3, volume/mute/custom/reset/preview, actual audio bytes в backup; звук физического iPhone не принят. |
| Y01 | Согласие на отчёты | AppDiagnostics / DiagnosticSettingsSection / DiagnosticConsentDialog | Persist-before-upload, opt-out purge, sanitized MetricKit, trusted guarded endpoint; native/UI execution pending. Геокоординаты не собираются. |
| Y02 | Тема | SettingsScreen.system / appearance | Существующий выбор темы. |
| Y03 | Код Entrixy | AppCodeSettingsSection / AppCodeDialog / AppEntryLockScreen / ActionConfirmation | Защищённые изменения entry lock и отдельная авторизация intent; Compact action confirm/PIN прошли native и UI17; полный набор настроек ещё ждёт визуальной приёмки. |
| Y04 | Резервная копия | BackupSettingsSection / BackupPresentation / BackupManager | Native/Android inspect, preview, encrypted export, claims/checkpoints, merge и напоминание; real cross-device migration не принят. |
| Y05 | Серверы | ServerSettingsSection / ServerSettingsDialog / OwnerServerSettings | Inline список, selected host, access code/account link/unlink/local forget и owner-loss guards. Клиентские fixtures прошли; live pwa_login.php восстановлен (site875d2b6), negative HTTP contract проверен без cookies; успешный реальный login/link ещё не принят. |
| Y06 | Сети приватности | ServerPrivacyRouter / NetworkPrivacySettingsSection / scoped backup / encrypted bundles | Proxy153 green; live startup и home UI подключены в source, актуальные native/UI19 ещё проверяются. iOS17 — только cellular при правилах, iOS16 — запрет серверных подключений; hardware acceptance остаётся. |
| Y07 | Подсказки ОС | PhoneReadinessCard / PhoneReadiness / PhoneRequirements | Conditional geo/precision/BLE/notify requirements, явные запросы и Settings; базовый native168 прошёл. Source Always теперь связан с работающим callback runtime; BLE без geo его не требует. Новый Apple/device прогон ожидается. |
| Y08 | Разработчик | HelpScreen 7 taps / DeveloperSettingsSection | Manual technical send/off as Android; UI pending. Android FCM/geo debug tools не объявлены перенесёнными; DEBUG capture routes остаются отдельно от Release. |
| G01 | Свои выданные доступы | GuestsHub.OwnerGuestsScreen | Android People/Companies/Presets, conditional tabs, scoped cards и передаваемые доступы подключены; полная UI/E2E-приёмка остаётся. |
| G02 | Карточка гостя | GuestPersonCard / IssueOwnerKeyScreen / OwnerDelegatedKeyScreen | Раскрытие, редактирование/clone/QR/share/message/pause/delete; общая визуальная проверка всех состояний остаётся. |
| G03 | Выдать гостю | IssueOwnerKeyScreen / GuestKeyDraft / OwnerIssuedKey | Черновик без server identity до Save; checkbox объектов, per-object invocations/templates/access/TTL/video. |
| G04 | Править существующий ключ | IssueOwnerKeyScreen / editOwnerKey | Та же signing/bundle identity при редактировании; pending snapshot не затирает более новые локальные изменения. |
| G05 | Доступ к одному объекту | GuestAccessFields / KeyObjectAccess / OwnerDelegatedKey | Depth/pool/native-only и точное наследование native flag; серверный app-only запрещает браузер, не native passing. |
| G06 | Автонастройки конкретного гостя | GuestObjectSettings / AutomationEditor(.issued) / saveAutomation | Отдельные шаблоны host/key/object, root bounds и force; не смешиваются с owner/incoming настройками. |
| G07 | Реакция владельца на запрос | GuestInvocationEditor / OwnerCallPreference / OwnerPhoneNotifications | Auto/confirm/notify/off и serveDuringCall; проверенные foreground guards, реальная доставка/звонок в фоне не приняты. |
| G08 | Срок BLE-пропуска | BLETokenLifetimes / GuestObjectSettings / renewOwnerBLEKey | 11 TTL от1ч до30д; выбор не продлевает текущий токен, explicit renew сохраняет identity. |
| G09 | Pause/resume/revoke | GuestPersonCard / GuestRemovalDialog / BLEPermissionsScreen | Pause/resume/revoke, durable signed BLE decisions; corporate keys тоже имеют scope, hardware delivery не принята. |
| G10 | QR/share | InviteQRCode / системный ShareLink | Существующий QR/share ссылки-ключа. |
| G11 | Сообщение | MessageScreens / MessageManager / SavedMessage | Существующие защищённые сообщения; единая Android message presentation ещё неполная. |
| G12 | Компании | CompanyPresentation / KnownCompany / VerifiedCompanyPress | host/id + verified signing pin, profile/claim/grant UI; real server E2E и полная визуальная приёмка остаются. |
| G13 | Преднастройки | GuestPresets / OwnerGuestDefaults | Defaults для новых ключей и scoped explicit clone; старые ключи не меняются при сохранении defaults. |
| G14 | Передать ключ | PassedGuestsSection / PassAccessForm / PassManager | Полученный источник и свежий verified allowance, native-only наследуется; protected group/secret/identity сохраняются. |
| G15 | Создать/править передаваемый ключ | PassAccessForm / PassedAccess / PassManager | Android name/welcome/grouped checkbox/access rows, один host, per-object ACL; дополнительные части сохраняются до wire, reply reconciliation без дубликата. |
| G16 | Подтверждение цепочки | DelegationInbox / OwnerDelegatedKey / automatic bundle fulfilment | Подписи/vouch/full parent chain/scope до публикации сохранённой связки; live cross-platform E2E ещё не принят. |
| J01 | Журнал действий | JournalScreen / JournalEntry / DelegatedJournalLedger | Action history и локальное отображаемое имя; не записывать UI sync. |
| H01 | Помощь | AppHeaderActions / HelpScreen / ProductText | Общая помощь и язык с исходными флагами, native lower navigation; оставшаяся L10n/полная проверка ссылок отдельно. |
| E01 | Общие окна сети | RootView.errorMessage + inline action rejection | Общие ошибки отдельно от inline outcome; полный event coordinator ещё не реализован. |
| E02 | Запрос гостя владельцу | OwnerPhoneRequestDialog / OwnerControlModel / OwnerPhoneNotifications | Компактный foreground approve/decline и 5sec cancelable notify; background/APNs/device-проверка остаётся. |
| E03 | Автотриггер | AutomationCoordinator / ActionPrompt / executeActionPrompt | Единый foreground manual/automatic confirm/PIN/biometry, одно согласие на frozen intent, cancel consumes arrival; latest source6b42489 ещё не Apple-исполнен. |
| E04 | Ключ принят/отклонён | KeyImportScreen / DelegationInboxScreen | KeyAcceptanceDialog: welcome только из authenticated bundle, readiness по правилам именно этого ключа, только OK; сохранённый неподтверждённый ключ не считается принятым. Новый source/UI тест ожидают Apple. |
| E05 | Восстановление | BackupPresentation / BackupRestorePlan / backup reminder | Preview/restore/preflight/checkpoints/reminder подключены, системный файл sharing; реальный перенос между устройствами не принят. |
| W01 | Виджет | WidgetKit/AppIntent iOS17, source; Apple/device pending | Общий каталог представления, исходные аватары; action в приложении через текущую policy/entry/PIN/confirm. Базовый Apple168 прошёл; device pending. TTL60с, consume-before-dispatch, нет fire URL/ключей в extension. Android service в фоне этим не перенесён. |

## Приёмка этого изменения

Core: независимые identities серверов/ключей/BLE, смешанный стабильный порядок,
rename/hide/reimport/remove scope, backward-compatible Codable и backup merge.
Native: запись до публикации, отказ Keychain write, restart, сохранение prefs после
owner update; отсутствие изменения исходного ключа/metadata и выдуманного журнала.
UI: раскрытие объекта, локальное имя в обоих разделах, скрытие одного объекта с
сохранением ключа; добавление BLE только через выбор типа, без физического scan/fire
в тесте. Реальные simulator screenshots по изменённым состояниям, exact SHA/hash.
Результаты запусков записываются после их завершения, не предполагаются заранее.


## Проверяемая реализация 16.11.2026

Исходный код `49fb249`, точная build-копия public
`069d20b04319cb97c371ba7b91c59f5533db7cd1`:
[Apple CI 43932876115](https://github.com/entrixy/ios-build./actions/runs/43932876115).
Все 194 исходных/build-файла двух checkout побайтово совпадают.
Core142, Debug, Release с изоляцией DEBUG-фикстур, native81 и capture19 прошли.
Общий CI failure: UI runner не инициализировал Accessibility, UI-assertions не
запускались. Изолированная проверка семи UI-cases ещё ожидается. Галерея 19 кадров
опубликована с явным незавершённым UI-статусом. Состав и процедура просмотра — в
[SCREENSHOT_COVERAGE](SCREENSHOT_COVERAGE.md).

Проверяемые UI-пути: смешанный порядок в Настройках и Управлении; раскрытие,
локальное переименование/скрытие с сохранением ключа; Bluetooth через добавление;
первый объект без предварительного перехода в регистрацию сервера; четыре типа
профиля, push/back и нижняя панель. Открытие формы первого объекта не регистрирует
владельца: существующая безопасная регистрация вызывается только при Save.
Реальная привязка/команда BLE и сетевое создание этим UI-прогоном не выполняются.

Это общий каталог и первые подключения существующих исполнителей. Полные
автонастройки своего/выданного/входящего объекта, их редакторы и runtime, камера,
полные поля типов, компании, foreground/background BLE scanner и виджет остаются
пробелами соответствующих узлов. Наличие строки в карте не означает готовую функцию.
