# Структура iOS по карте Android

Основание: [62 узла Android](ANDROID_STRUCTURE.md), Android 5615535. Это карта
реального подключения и пробелов, а не объявление полного переноса.

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
  локальное имя. AddCatalogObjectScreen выбирает сервер; AddOwnerObjectScreen — тип,
  BLEPairingScreen продолжает создание нового BLE-объекта. BLE никогда не приписывается
  к соседней карточке существующих ворот.
- Защита/исполнение: AppModel создаёт замороженный ActionIntent/OwnerActionIntent,
  повторно проверяет после auth/confirm; GuestActionPolicy/OwnerManualPolicy,
  owner/guest WS, BLE models исполняют существующие команды. Каталог не даёт authority.
- Состояния: connection/availability, position и actual outcome раздельны.
  CatalogStatusAvatar показывает availability кругом на аватаре. Текст результата,
  причины отказа, pause и сообщения сохраняются в своих блоках. BLE observation
  имеет срок по sleep interval; без наблюдения доступность неизвестна. Нового
  passive/background scanner этот этап не добавляет.
- Выдача/передача: OwnerIssuedKey/KeyObjectAccess и PassedAccess остаются владельцами
  персистентного scope. IncomingDepth даёт только видимость вкладки. Per-object
  templates владельца, выданного гостя и incoming должны оставаться разными областями.
- Восстановление: IOSBackupPayload несёт optional preferences, старые state/backup
  читаются без них. Merge сохраняет текущий локальный выбор при конфликте; rollback
  до успешного save. Ключи/identity не пересоздаются ради изменений UI.

## Полная раскладка узлов

«Нет route/editor» означает реальный пробел; интерфейс не показывает работающую
на вид кнопку вместо отсутствующего исполнителя. Этот этап подключает общий
каталог и существующие операции. Полные автонастройки/компании/фон не объявляются
реализованными из-за наличия этого документа или типов маршрутов.

| Android ID | Узел | iOS feature / маршрут | Подключение и границы |
| --- | --- | --- | --- |
| C01 | Общий список карточек | ObjectCatalogModel → ControlScreen | Подключён общий порядок и visibility. |
| C02 | Карточка действия | GuestCatalogControlCard / OwnerCatalogControlCard | Прямое действие; новые индикаторы. Полная готовность правил ещё не перенесена. |
| C03 | Ручной запуск | AppModel.actionIntent/ownerActionIntent → execute | Существующие guards/PIN/биометрия/one-shot сохраняются. |
| C04 | Состояние контроллера | AppModel.objectAvailability → CatalogStatusAvatar | Сеть и свежие BLE observations раздельны; passive/background BLE scanner ещё отсутствует. |
| C05 | Положение объекта | OwnerControlModel.positions / ActionLink.positions | Данные и выбор направления есть; углы-индикаторы ещё не перенесены. |
| C06 | Камера в карточке | Нет production route | Нужны camera settings, guest stream entitlement, поток и состояния. |
| C07 | Готовность автоматизации | GuestActionPolicy / OwnerManualPolicy | Неподдержанные условия блокируются; engine/editor/rearm не объявлены готовыми. |
| C08 | Подсказки/баннер | Нет полного production route | Разделить readiness ОС и promo cache/события. |
| O01 | Общий список | ObjectSettingsRows + ObjectCatalogPreferences | Один смешанный список; onMove сохраняет порядок; стандартный режим изменения порядка iOS. |
| O02 | Свой обычный объект, раскрытие | ObjectSettingsRows → OwnerObjectEditor | Раскрытие на месте, отдельные настройки/удаление. Полный набор типов и автонастройки — пробел. |
| O03 | Входящий обычный объект, раскрытие | ObjectSettingsRows → ReceivedObjectNameScreen / hideReceivedObject | Локальное имя/скрытие реализованы; входящий редактор автонастроек отсутствует. |
| O04 | Свой BLE, раскрытие | ObjectSettingsRows → OwnerObjectEditor / BLEPermissionsScreen | BLE различается типом; Info/move/automation ещё не подключены. |
| O05 | Входящий BLE, раскрытие | ObjectSettingsRows → ReceivedObjectNameScreen / hideReceivedObject | Тот же local scope; не удаляет ключ. BLE incoming automation отсутствует. |
| O06 | Добавить объект | AddCatalogObjectScreen → AddOwnerObjectScreen | Выбор owner server; четыре типа, BLE только через добавление. Первый объект открывает форму сразу, owner регистрируется при Save; pending registration не отправляется повторно. |
| O07 | Создать call | AddOwnerObjectScreen → createOwnerObject(call) | Телефон есть; Contacts/hangup поля ещё не перенесены. |
| O08 | Создать webhook | AddOwnerObjectScreen → createOwnerObject(webhook) | Есть server HTTPS; phone/webhook mode/toggle редакторы ещё не полные. |
| O09 | Создать device | AddOwnerObjectScreen → createOwnerObject(device) | Claim есть; полный новый deviceRegister/credentials flow отсутствует. |
| O10 | Создать BLE | AddOwnerObjectScreen(Bluetooth) → BLEPairingScreen → BLEPairingModel | Подключён реальный существующий pair executor; новые secrets/физические команды не симулируются. |
| O11 | Редактор обычного объекта | OwnerObjectEditor → renameOwnerObject | Сейчас имя/пресеты/local manual policy; полных type-specific полей нет. |
| O12 | Поделиться устройством | Нет production route | Нужны device credential QR/share и missing-credentials состояние. |
| O13 | Привязать приложение к device | Нет production route | Нужны ENTX-BIND/configurator и публикация socket shares без пересоздания объекта. |
| O14 | Редактор своего BLE | OwnerObjectEditor + OwnerObject(kind=ble) | Имя есть; move требует отдельной durable transaction и проверки контракта. |
| O15 | Информация BLE | Нет production route | Нужны полученные advertisement info и возраст; не заполнять выдуманными данными. |
| O16 | Удаление своего объекта | ObjectSettingsRows → deleteOwnerObject | Существующий durable delete/reconcile и BLE revocations сохраняются. |
| O17 | Аватар объекта | OwnerObjectEditor / ObjectAvatar / OwnerObjectAvatar | 8 оригинальных пресетов; production upload своей картинки ещё отсутствует. |
| O18 | Камера: настройки | Нет production route | Хранение/редактор камеры, auth и выдача права требуют общего контракта с C06/G04. |
| K01 | Полученные ключи | SettingsScreen.keys → KeyDetailScreen | Отдельная подвкладка; connection здесь остаётся информативным текстом. |
| K02 | Добавить ключ | KeyImportScreen → AppModel.add | Paste/QR/photo + bind; повторный импорт возвращает hidden без замены identity. |
| K03 | Удалить входящий ключ | AppModel.removeKey | Очищает и catalog overrides/order только этого guest scope. |
| S01 | Звуки | Нет production route | Event sound settings/volume/picker/player — самостоятельная подсистема. |
| Y01 | Согласие на отчёты | Нет полного production route | Разделить crash consent и диагностические координаты. |
| Y02 | Тема | SettingsScreen.system / appearance | Существующий выбор темы. |
| Y03 | Код Entrixy | AppEntryLockSettings / AppEntryLockScreen / ActionConfirmation | Существующие код/биометрия/lock; не объединять entry unlock и authority одного intent. |
| Y04 | Резервная копия | BackupScreen → BackupManager / BackupRestorePlan | Catalog preferences входят в export/merge; Android parser ещё не полностью подключён к restore UI. |
| Y05 | Серверы | SettingsScreen.system → OwnerServersScreen / AddOwnerServerScreen | Owner registration/sync есть; account link/unlink/access code edit/forget остаются неполными. |
| Y06 | Сети приватности | Нет production route; GuestActionPolicy guards | Не ослаблять неподдержанную network policy. |
| Y07 | Подсказки ОС | Нет полного production route | Платформенные разрешения/готовность iPhone отдельно от Android OEM. |
| Y08 | Разработчик | DEBUG captures/catalogues; production dev flow отсутствует | DEBUG routes изолированы от Release, не являются продуктовой dev вкладкой. |
| G01 | Свои выданные доступы | OwnerGuestsScreen | Issued/delegated/forwarded пути есть; вкладки Люди/Компании/Преднастройки ещё неполны. |
| G02 | Карточка гостя | OwnerKeyScreen / OwnerDelegatedKeyScreen | Существующие операции; полное раскрытие Android ещё не перенесено. |
| G03 | Выдать гостю | IssueOwnerKeyScreen → OwnerIssuedKey / AppModel | Durable выдача; full per-object templates/type fields — пробел. |
| G04 | Править существующий ключ | OwnerKeyScreen → editOwnerKey | Существующий edit с сохранением K_guest; камера и templates требуют дополнения. |
| G05 | Доступ к одному объекту | KeyObjectAccess / IssueOwnerKeyScreen | Per-object depth/pool подключены. Native-only true пока отклоняется текущим iOS guard; не выдавать модель поля за готовый переключатель. Authority проверяется в Core/API. |
| G06 | Автонастройки конкретного гостя | Нет production editor; GuestActionPolicy сохраняет guards | Отдельные (host,key,object) templates, owner/incoming разделены по контракту. |
| G07 | Реакция владельца на запрос | OwnerControlModel.phoneRequests / dial / decline | Foreground запросы есть; редактор реакции per guest/object ещё отсутствует. |
| G08 | Срок BLE-пропуска | OwnerKeyScreen / AppModel.renewOwnerBLEKey | Продление существует; отдельный per-guest TTL редактор Android ещё не перенесён. |
| G09 | Pause/resume/revoke | AppModel key mode/revoke + BLEPermissionsScreen | Существующие signed revocations/reconcile; корпоративная ветвь отсутствует. |
| G10 | QR/share | InviteQRCode / системный ShareLink | Существующий QR/share ссылки-ключа. |
| G11 | Сообщение | MessageScreens / MessageManager / SavedMessage | Существующие защищённые сообщения; единая Android message presentation ещё неполная. |
| G12 | Компании | Нет production route | Company identity(host,id), trust/profile/claim и UI требуют отдельной feature. |
| G13 | Преднастройки | Нет полного production route | Существующие ключи не менять при сохранении defaults для новых выдач. |
| G14 | Передать ключ | PassedAccessScreen → PassManager | Существующий делегирующий путь, live allowance обязателен. |
| G15 | Создать/править передаваемый ключ | PassedAccessScreen / PassManager / PassedAccess | Существующие группы/части/per-object allowance, требуются полный UX и E2E. |
| G16 | Подтверждение цепочки | DelegationInbox / DelegationInboxScreen / OwnerDelegatedKey | Существующие подписи/vouch/fulfil/revocation checks. |
| J01 | Журнал действий | JournalScreen / JournalEntry / DelegatedJournalLedger | Action history и локальное отображаемое имя; не записывать UI sync. |
| H01 | Помощь | LicenseScreen отдельно; Help route отсутствует | Нужно руководство/язык/версия/dev вход, не подменять лицензиями. |
| E01 | Общие окна сети | RootView.errorMessage + inline action rejection | Общие ошибки отдельно от inline outcome; полный event coordinator ещё не реализован. |
| E02 | Запрос гостя владельцу | OwnerPhoneRequestRows / OwnerControlModel | Существующий foreground approve/decline; notification/background пути отдельно. |
| E03 | Автотриггер | Нет production route | Требуется automation runtime/event с target, countdown/auth/cancel, без повторной команды. |
| E04 | Ключ принят/отклонён | KeyImportScreen / DelegationInboxScreen | Есть bind/errors/pending; полный readiness/welcome ещё не перенесён. |
| E05 | Восстановление | BackupScreen / BackupManager | Существующий restore status; ServerRestore offer/reminder отдельные пробелы. |
| W01 | Виджет | Нет widget extension | Внешний intent должен проходить ту же policy/lock/target validation. |

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
