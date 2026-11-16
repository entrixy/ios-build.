# Структура полного Android-клиента — основание переноса на iOS

Срез от 16.11.2026: Android **10.90**, commit
`56155352b0e9f36ef3685aa071a6aafdb2ef6622`, `/home/folder/android/dialer`.
Все ссылки вида `src:ui/SettingsScreen.kt:475` отсчитываются от
`app/src/main/java/com/entrixy/app/` этого среза.

Это карта существующих экранов, действий, данных и исполнителей Android.
Она предшествует изменению архитектуры и интерфейса iOS. Успешные проверки
предыдущего этапа iOS подтверждают выбранные маршруты навигации и компоненты,
**не полноту переноса настроек объектов**. Объектные редакторы, автоматизация
и передача доступа не были перенесены как единая структура.

Механический индекс [ANDROID_SOURCE_INDEX.json](ANDROID_SOURCE_INDEX.json)
фиксирует все **83 Kotlin-файла / 37 381 строку**, объявления, места создания
диалогов, **13 manifest-компонентов**, входящие ссылки и хеш исходного дерева
(207 отслеживаемых файлов). Это лексический индекс, а не доказательство
исполнения каждой ветки. Карта ниже дополнена чтением вызовов, условий,
редакторов и обработчиков; аппаратная работа здесь не проверялась.

## 1. Корень приложения и внешние входы

```text
App: хранилище → локальные данные/миграции → сетевые наблюдатели → HostService
MainActivity
├─ блокировка приложения: CodeLockScreen
└─ DialerApp
   ├─ обязательное обновление / начальная загрузка / согласие на crash reports
   ├─ общий верх: название, состояние связи с сервером, помощь, язык
   ├─ текущая вкладка или HelpScreen
   ├─ общая нижняя панель: Управление | Настройки | Гости | Журнал
   └─ общие события: подтверждения, сообщения, приглашения, восстановление
```

Основание: `src:App.kt:13`, `src:MainActivity.kt:84`, `src:MainActivity.kt:597`.
Блокировка оборачивает приложение; в `DialerApp` force-update проверяется до
загрузки и основных вкладок. Начальная вкладка — сохранённая, иначе Управление
при наличии действий, иначе Настройки. Управление появляется при непустом
`computeActions()`. Гости доступны при своих обычных/BLE-объектах либо разрешённой
дальнейшей передаче входящего ключа. Настройки и Журнал постоянны.
Помощь заменяет тело текущей вкладки, нижняя панель остаётся.

| Вход | Разбор и продолжение |
| --- | --- |
| Иконка приложения / возврат / новый Intent | `MainActivity.onCreate/onResume/onNewIntent`: блокировка, восстановление локальных данных, продолжение отложенного действия. |
| `entrixy:`; HTTPS `/key` | `handleInviteIntent` → `Vault.parseKeyInput` → проверка сервера/своего ключа → validate/bind → сохранение, ingest bundle, runtime гостя. QR/ручной ввод имеют свой вызов bind в Settings; их надо сверять как отдельные входы. |
| HTTPS `/claim?c=…`, `entrixy://claim` | `pendingClaimHost/pendingClaimCode` → Настройки → добавление объекта в режиме device claim. Сервер ссылки сохраняется. |
| HTTPS `/c/…`, `/o/…`; custom org/company | `orgInvite` → известная компания/ключ профиля → при наличии owner credentials `orgClaim` → общий диалог запроса доступа → Гости/Компании или Добавить объект. |
| HTTPS `/i/…`; custom invite | `ShareIn.accept`: составное приглашение, ключ записи получателя, redeem/vouch; возможно ожидание владельца. Позже подтягиваются новые части той же ссылки. |
| Буфер обмена | Проверяется в `handleClipboardKey`, проходит тот же обработчик разобранного ключа; это отдельный канал обнаружения ссылки. |
| Тап виджета | `KeyWidgetActionReceiver` → разрешённое действие через службу либо MainActivity с одноразовым nonce/отложенным fire для unlock/auth/confirm. Устаревший intent не исполняется заново. |
| Уведомление подтверждения | `ConfirmReceiver` → `HostService.sendConfirmResponse`; принятие/отказ связаны с конкретным call ID. |
| FCM | `FcmService`: message/share_message/share_part → расшифровка/дедупликация/сохранение → сообщение или обновление частей ключа. |
| Геозона / активность / BLE advertisement / загрузка ОС | Receivers → служба/трекеры, а не отдельные экраны; см. раздел 8. |

Источники: `src:MainActivity.kt:138`, `src:MainActivity.kt:252`,
`src:MainActivity.kt:365`, `src:MainActivity.kt:416`, `src:MainActivity.kt:531`;
`AndroidManifest.xml`. Manifest экспортирует MainActivity, конфигуратор виджета,
провайдер виджета и BootReceiver; FileProvider выдаёт доступ к файлу копии.
Остальные прикладные службы/приёмники внутренние.

## 2. Иерархия разделов и действий

Идентификаторы ниже — стабильные ссылки для будущей карты iOS. Строка может
описывать раскрываемую карточку или вложенное действие, а не отдельный экран.

### Управление

| ID | Узел / действие | Данные, условия, результат | Android |
| --- | --- | --- | --- |
| C01 | Общий список карточек | Свои call/webhook/device, свои BLE, входящие обычные и BLE; один сохранённый порядок, скрытые входящие исключаются. | `src:data/AppState.kt:596`, `src:ui/HomeScreen.kt:47` |
| C02 | Карточка действия | Аватар + круглый индикатор, название, значок типа и источник свой/гостевой, состояние/индикаторы правил, камера при разрешении. Тап выполняет/ограничивает действие; перехода в выдуманную страницу подробностей нет. | `src:ui/components/ActionCard.kt:80` |
| C03 | Ручной запуск | Политика доступности/И-условий → код/биометрия или confirm при требовании → исполнитель по типу/владению → inline-результат и журнал. Без требования нет дополнительного confirm. | `src:ui/components/ActionCard.kt:381`, `src:ui/HomeScreen.kt:304` |
| C04 | Состояние контроллера | Индикатор 10 dp на аватаре: READY зелёный, OFFLINE/AUTH_FAIL красный, CONNECTING янтарный; webhook нейтральный primary, BLE по доступности радио/advertisement/сроку токена. Это не текстовый подзаголовок «Нет соединения». | `src:ui/components/ActionCard.kt:220`, `src:ui/components/ActionCard.kt:602` |
| C05 | Положение объекта | OPEN/CLOSED/OPENING/CLOSING/UNKNOWN отдельно от доступности; события WS/BLE, углы-индикаторы, состояние bistable/toggle. Отправленный запрос не равен подтверждённому открытию. | `src:data/AppState.kt:177`, `src:ui/components/OpenPositionCorners.kt:27` |
| C06 | Камера в карточке | Ручное раскрытие и auto-show always/call/nearby, JPEG refresh или видео, auth headers, ошибки/загрузка/закрытие. В гостевом bundle только при выданном праве. | `src:ui/components/ActionCard.kt:117`, `src:ui/components/ActionCard.kt:850`, `src:ui/components/StreamView.kt:74` |
| C07 | Готовность автоматизации | Дистанция, Wi-Fi совпадения, время/обратный отсчёт, armed/rearm, геокоридор, цвет карточки. Часть состояния поступает из фоновых исполнителей. | `src:ui/components/ActionCard.kt:246`, `src:host/AutoCombine.kt:21` |
| C08 | Подсказки/баннер | Неточное GEO/фоновые разрешения/батарея, переход в настройки ОС, подсказка виджета; promo из кеша/сервера с учётом режима показа и клика. | `src:ui/HomeScreen.kt:79`, `src:ui/HomeScreen.kt:260` |

### Настройки → Объекты

Это **общий переупорядочиваемый список**, не секции объектов по серверу.
Строка раскрывает действия на месте; редактор открывается своей кнопкой.
BLE pairing расположен **в Добавить объект → Bluetooth**, не под существующими воротами.

| ID | Узел / действие | Что находится внутри и что меняется | Android |
| --- | --- | --- | --- |
| O01 | Общий список | Drag handle, аватар, имя/локальная замена, тип, относящиеся к типу подписи и значки правил. Порядок общий с Управлением и списком выбора объектов для выдачи ключа. | `src:ui/SettingsScreen.kt:409` |
| O02 | Свой обычный объект, раскрытие | Настройки; Автоматизация; Удалить. Список не открывает редактор напрямую. | `src:ui/SettingsScreen.kt:475` |
| O03 | Входящий обычный объект, раскрытие | Локальное переименование; входящие автонастройки; скрыть объект. Скрытие оставляет ключ и другие объекты, повторный импорт ключа возвращает скрытые. | `src:ui/SettingsScreen.kt:631` |
| O04 | Свой BLE, раскрытие | Настройки; Автоматизация; Информация; Удалить. Расстояние/далеко вместо сетевых полей. | `src:ui/SettingsScreen.kt:829` |
| O05 | Входящий BLE, раскрытие | Локальное имя; входящие BLE-автонастройки; скрыть только этот замок. | `src:ui/SettingsScreen.kt:964` |
| O06 | Добавить объект | Имя + четыре типа: call, webhook, device, BLE. Разрешения/лимиты/регистрация относятся к выбранному типу. | `src:ui/SettingsScreen.kt:3041` |
| O07 | Создать call | Номер вручную или из контакта; включение/секунды отбоя; разрешение на звонок; локальные параметры и шифрованная запись объекта. | `src:ui/SettingsScreen.kt:3173`, `src:ui/SettingsScreen.kt:3442` |
| O08 | Создать webhook | URL, секрет, исполнение phone/server, импульсный/toggle вариант. Phone URL/secret локальные; server данные идут предусмотренным протоколом. | `src:ui/SettingsScreen.kt:3231`, `src:ui/SettingsScreen.kt:3505` |
| O09 | Создать device | Новый контроллер или claim по коду; deviceRegister/deviceClaimEx → объект/секреты → код устройства для настройки; отдельные ошибки claim/auth/conflict. | `src:ui/SettingsScreen.kt:3261`, `src:ui/SettingsScreen.kt:3454` |
| O10 | Создать BLE | Разрешения и включение Bluetooth → поиск → pairing/handshake → запись собственного BLE-объекта и его ключей → синхронизация. Фазы поиска/соединения/handshake/готовности показываются внутри добавления. | `src:ui/SettingsScreen.kt:3321`, `src:ble/BlePair.kt:80` |
| O11 | Редактор обычного объекта | Имя; сервер показан при нескольких owner accounts; по типу phone/hangup или webhook URL/secret/mode/toggle, либо device credentials/bind. Камера в том же редакторе; кнопка автонастроек в заголовке. Сохранение обновляет шифрованную запись и guest bundles. | `src:ui/SettingsScreen.kt:3655` |
| O12 | Поделиться устройством | Из device-редактора → ENTX-DEV код с key+secret и адресом сервера, QR/копирование/системный share; при отсутствии credentials отдельное объяснение. Это данные контроллера, не приглашение гостю. | `src:ui/SettingsScreen.kt:2538`, `src:ui/SettingsScreen.kt:3808` |
| O13 | Привязать приложение к device | Получить/показать ownerSecret и ENTX-BIND, копирование и ссылка на конфигуратор; пересобрать bundles. Не BLE pairing и не новый объект. | `src:ui/SettingsScreen.kt:3821` |
| O14 | Редактор своего BLE | Имя; при нескольких owner accounts выбор сервера. Другой сервер → отдельное подтверждение переноса, а не обычное сохранение имени. Стабильный локальный ID и ключ объекта сохраняются; shares старого сервера удаляются из bundles. | `src:ui/SettingsScreen.kt:4603`, `src:store/ObjectMove.kt:28` |
| O15 | Информация BLE | Последние battery/hardware/firmware/sleep/flags/возраст данных; нет свежих данных — соответствующее состояние. | `src:ui/SettingsScreen.kt:2620` |
| O16 | Удаление своего объекта | Подтверждение, оптимистичное удаление карточки, API; object key удаляется после принятого удаления. При ошибке запрашивается авторитетное состояние. BLE имеет свою ветку и удаляет локальный template ещё до ответа — это не полный откат настроек при отказе. | `src:ui/SettingsScreen.kt:2677`, `src:ui/SettingsScreen.kt:2996` |
| O17 | Аватар объекта | Нажать аватар в настройках → оригинальные пресеты либо выбрать свою картинку; обработка/сохранение, для своего объекта E2EE-передача и rebuild bundles. У входящего обычного объекта аватар в списке read-only; у входящего BLE вызов picker присутствует — не выравнивать их по предположению. | `src:ui/SettingsScreen.kt:4048`, `src:ui/SettingsScreen.kt:4266` |
| O18 | Камера: настройки | URL, распознанный тип картинки/видео; none/basic/bearer/custom header auth; интервал; always/call/nearby. Право гостя видеть поток задаётся при редактировании выданного ключа. | `src:ui/SettingsScreen.kt:4445`, `src:ui/GuestsScreen.kt:1453` |

### Настройки → Ключи / Звуки / Система

| ID | Узел | Состав и действия | Android |
| --- | --- | --- | --- |
| K01 | Полученные ключи | Самостоятельная подвкладка **Ключи внутри Настроек**, не блок в Системе и не список объектов. Карточка источника/подключения, состояние и удаление ключа с предупреждением. | `src:ui/SettingsScreen.kt:1190` |
| K02 | Добавить ключ | Вставка или QR; распознать install-link отдельно, чужой сервер/неполный ключ, свой ключ, duplicate, binding/already-bound/needs-new-key. Успешный QR обрабатывается сразу; повторный импорт снимает hidden-флаги объектов. | `src:ui/SettingsScreen.kt:2748` |
| K03 | Удалить входящий ключ | Удаляются runtime, сохранённый ключ и его зависимые входящие объекты/локальные данные; это шире скрытия одного объекта O03/O05. | `src:ui/SettingsScreen.kt:1282`, `src:store/Prefs.kt:2784` |
| S01 | Звуки | Общая громкость; для tap/confirm/incall/geo/biometric/message/success/error/widget_fire — прослушать, свой файл, сброс, выключение. Системный picker и SoundPlayer участвуют в сценарии. | `src:ui/SettingsScreen.kt:1331`, `src:ui/SettingsScreen.kt:4332` |
| Y01 | Согласие на отчёты | Согласие на crash reports отдельно от отправки host.log с координатами в dev mode. | `src:ui/SettingsScreen.kt:1389` |
| Y02 | Тема | System/light/dark; сохранение выбора. | `src:ui/SettingsScreen.kt:1418`, `src:ui/theme/Theme.kt:166` |
| Y03 | Код Entrixy | Создать/сменить/удалить код; входной lock, биометрия, проверка старого кода, отдельный кодовый гейт подтверждения действия. Один механизм кода, разные назначения. | `src:ui/SettingsScreen.kt:1459`, `src:ui/CodeGate.kt:57` |
| Y04 | Резервная копия | Export: пароль/повтор, сохранить файл или share. Import: выбор файла, проверка формата/пароля, предупреждение о замене и возможность сначала сохранить текущее, серверный перенос, применение/ошибки/повтор незавершённых переносов. | `src:ui/SettingsScreen.kt:1545`, `src:store/Backup.kt:24` |
| Y05 | Серверы | Несколько owner accounts: выбрать текущий, добавить/редактировать host+access code, согласовать suite, регистрация, account email/password/link/unlink, забыть сервер с предупреждением, перезапуск. Не путать owner device credentials и аккаунт сайта. | `src:ui/SettingsScreen.kt:1921`, `src:ui/SettingsScreen.kt:2086` |
| Y06 | Сети приватности | Добавить текущую Wi-Fi сеть в запрет с подтверждением; список/удаление; серверный трафик через сотовую либо BANNED. Входящие ограничения могут приходить в bundle. | `src:ui/SettingsScreen.kt:1992`, `src:net/NetRoute.kt:208` |
| Y07 | Подсказки ОС | Права location/background location, батарея/autostart/OEM, скрыть подсказку. Android-механизмы выделяются для платформенной адаптации, сценарий готовности сохраняется. | `src:ui/SettingsScreen.kt:207`, `src:util/Oem.kt:22` |
| Y08 | Разработчик | Открывается 7 тапами по версии в Помощи; отправка host logs, каталоги иконок/контролов, диагностика, отключить dev mode. Это не обычная продуктовая вкладка. | `src:ui/SettingsScreen.kt:2336`, `src:ui/HelpScreen.kt:76` |

### Гости → Люди / Компании / Преднастройки и Передать ключ

| ID | Узел | Состав, ограничения и последствия | Android |
| --- | --- | --- | --- |
| G01 | Свои выданные доступы | Три подвкладки Люди/Компании/Преднастройки. Если есть и свои, и передаваемые входящие доступы, разделы получают заголовки. Делегированные дочерние ключи не дублируются отдельными карточками владельца: отображается число переданных. | `src:ui/GuestsScreen.kt:148` |
| G02 | Карточка гостя | Сводка объектов/состояния/pending/awaiting bundle/количества переданных; раскрыть → править, клонировать, QR/share, сообщение, pause/resume, удалить. У незавершённой выдачи повтор/восстановление. | `src:ui/GuestsScreen.kt:345` |
| G03 | Выдать гостю | Имя/welcome, обычные+BLE объекты в общем порядке, серверные группы/ограничение выбора сервера, per-object доступ/автонастройки/типовые параметры; durable draft до завершения выдачи. Код ссылки и K_guest сохраняются, пустая/неподтверждённая выдача не маскируется готовым ключом. | `src:ui/GuestsScreen.kt:790` |
| G04 | Править существующий ключ | Имя/welcome, набор обычных/BLE, разрешение видео, per-object поля; rebuild существующим K_guest, серверное сохранение и удаление старых object keys из доступа/ротация. Идентичность получателя не заменяется из-за редактирования. | `src:ui/GuestsScreen.kt:1327` |
| G05 | Доступ к одному объекту | Native-only; разрешить дальнейшую передачу и глубина до 5; pool до 50. Доступ хранится по объекту, не одна общая настройка всего ключа. | `src:ui/GuestsScreen.kt:2274`, `src:data/AppState.kt:106` |
| G06 | Автонастройки конкретного гостя | Пара `(host, keyId, objectId)`; тот же редактор правил, но с уровнями own/suggest/force. Для BLE свой target и TTL. | `src:ui/GuestsScreen.kt:1656`, `src:ui/GuestsScreen.kt:1685` |
| G07 | Реакция владельца на запрос | Для call: react off/confirm/notify/auto и обслуживать во время звонка. Для webhook: phone/server с предупреждением о переключении; это действующий GuestCallEditor. | `src:ui/GuestsScreen.kt:1714`, `src:ui/GuestCallEditor.kt:34` |
| G08 | Срок BLE-пропуска | Отдельный TTL по гостю и замку, запись настройки и обновление bundle; срок офлайн-токена не равен расписанию автооткрытия. | `src:ui/GuestsScreen.kt:2185` |
| G09 | Pause/resume/revoke | Сохраняется прежний mode; signed revocations BLE/socket, bundles/ротации, eventual доставка. Удаление компании имеет свою ветку отзыва выданных ей доступов. | `src:ui/GuestsScreen.kt:592`, `src:ui/GuestsScreen.kt:1742`, `src:ui/GuestsScreen.kt:1798` |
| G10 | QR/share | QR ссылки-ключа и полный экран QR; системная отправка. Секреты ключа и публичная install-ссылка имеют разное назначение. | `src:ui/GuestsScreen.kt:720` |
| G11 | Сообщение | MessageSheet: текст/ссылки/emoji, защищённая отправка, delivered/read/expired; адресат свой гость или получатель переданного ключа. Получение — общий диалог, а не запись в журнал действий. | `src:ui/GuestsScreen.kt:1931`, `src:ui/GuestsScreen.kt:1960` |
| G12 | Компании | Сканирование приглашения, профиль/домен/проверенный ключ/логотип, выдача либо правка доступа существующей компании, отозвать/забыть; host входит в identity компании. | `src:ui/GuestsScreen.kt:165`, `src:ui/GuestsScreen.kt:834`, `src:store/OrgVerify.kt:16` |
| G13 | Преднастройки | Имя владельца, defaults per-object nativeOnly/depth/pool для новых выдач. Не выдать за уже изменённые права существующих ключей. | `src:ui/GuestsScreen.kt:283` |
| G14 | Передать ключ | Полученные объекты с реальным разрешением владельца. Список переданных ссылок: раскрыть → правка, share, сообщение, отзыв. Право передачи проверяется через API, наличие вкладки — лишь UI-подсказка. | `src:ui/PassOnSection.kt:77` |
| G15 | Создать/править передаваемый ключ | Выбор разрешённых обычных/BLE объектов, имя/welcome, per-object depth/pool не шире родителя; выбор ограничен host. Одна ссылка может содержать несколько исходных частей/ключей; последующие части дополняют получателя. | `src:ui/PassOnSection.kt:376`, `src:ui/PassOnSection.kt:573` |
| G16 | Подтверждение цепочки | Родитель vouch → владелец проверяет подписи/цепочку → выдаёт bundle конкретному recipient. Отозванный parent, invalid/bound invite, ожидание владельца — разные результаты. | `src:store/PassVouch.kt:12`, `src:store/ShareIn.kt:29`, `src:store/Vault.kt:379` |

### Журнал / Помощь / общие события

| ID | Узел | Поведение | Android |
| --- | --- | --- | --- |
| J01 | Журнал действий | Новые сверху, время/дата/кто/объект/фактический результат и уровень; экспорт share/copy, очистка. Техническая синхронизация/управление ключами сюда не попадают. Импорт истории переданных действий дедуплицируется. | `src:ui/JournalScreen.kt:42`, `src:data/Journal.kt:14`, `src:data/PassJournal.kt:15` |
| H01 | Помощь | Разделы управление/объекты/автоматика/гости/безопасность/разрешения, ссылка на полное руководство нужного языка, версия и dev unlock. | `src:ui/HelpScreen.kt:28` |
| E01 | Общие окна сети | Broken proxy с раскрываемыми подробностями, offline notice по запросу, запрет сети/переход в настройки, достигнутый лимит. Не каждое offline-состояние открывает модалку. | `src:MainActivity.kt:918`, `src:MainActivity.kt:954`, `src:MainActivity.kt:1030` |
| E02 | Запрос гостя владельцу | PendingConfirm / истечение / принять-отказать, отдельные notification/buzzer пути, привязка к call ID. | `src:MainActivity.kt:1068`, `src:host/HostService.kt:2662` |
| E03 | Автотриггер | PendingGeoCall auto/confirm/auth, отсчёт/отмена/код; исходный object target сохраняется. | `src:MainActivity.kt:1144`, `src:MainActivity.kt:1585` |
| E04 | Ключ принят/отклонён | Readiness Wi-Fi/location/permissions, welcome владельца; binding rejection, ожидание делегированного bundle отдельны. | `src:MainActivity.kt:1326`, `src:MainActivity.kt:1341`, `src:MainActivity.kt:1354` |
| E05 | Восстановление | Restore offer/report; reminder о копии; отчёт о ключах, чей перенос ещё не завершён. | `src:MainActivity.kt:972`, `src:MainActivity.kt:1288` |
| W01 | Виджет | Выбрать объект → persist binding → аватар/состояние → тап; unlock/auth/confirm открывают приложение, разрешённый прямой путь идёт через службу. Удалённый объект не заменяется другим. | `src:widget/KeyWidgetConfigActivity.kt:75`, `src:widget/KeyWidgetProvider.kt:68`, `src:widget/KeyWidgetActionReceiver.kt:17` |

## 3. Автонастройки: единая модель, разные области применения

Входы в `GuestAutomationEditor` нельзя объединить в один локальный switch:

| Область | Ключ хранилища/вход | Сохранение и продолжение |
| --- | --- | --- |
| Собственный обычный объект | `keyId=0`, object ID → guest_templates | Локальные правила владельца; GEO может затем наследоваться per-guest шаблоном; обновление связанных bundles и трекеров. |
| Собственный BLE | `keyId=0`, bleId → ble_templates | Правила BLE-автооткрытия; изменение редактора само по себе не перевооружает уже сработавший замок. |
| Выданный гостю обычный/BLE | `(host,keyId,objectId)` → guest_templates | Полный выбор уровней own/suggest/force, публикация в bundle именно этому гостю. |
| Полученный обычный/BLE | `isIncoming=true`, `(localKeyId,objectId)` → incoming_templates | Только разрешённые изменения с owner bounds; merge новых owner rules не стирает допустимый локальный выбор. |

Основание: `src:ui/GuestAutomationEditor.kt:90`, `src:ui/SettingsScreen.kt:1141`,
`src:ui/SettingsScreen.kt:2959`, `src:store/Prefs.kt:3272`, `src:store/Vault.kt:532`.

Состав правил: включение и уровень; объединение any/all; BLE-радиус только для BLE;
GEO точка/текущая позиция/радиус либо до шести подходных полилиний с зоной ворот;
для гостевого шаблона «как в настройках объекта»; Wi-Fi connected SSID/BSSID либо
снимок BSSID/SSID и порог совпадений; время/дни, моменты для any и интервалы для all;
код/биометрия и подтверждение перед действием. Выбор точки/маршрута открывает
`CorridorMapScreen`, время — time picker, Wi-Fi — системные разрешения/скан.
Incoming force фиксирует геометрию/ограничения; combine selector скрывается только
при `combineLevel=force`. Уровни own/suggest/force имеют отдельную логику упаковки
и merge; их нельзя трактовать только как оформление.

Исполнители: `GeoTracker` для обычных объектов; `BleScanReceiver` для BLE;
`AutoCombine` для общей готовности; `GeoCorridorMatcher` для направленного прохода;
`WifiChecker`, geofencing/activity/sensor входы. `armedAuto`, `rearmAt`,
`awaitNewEntry`, вход снаружи и manual-open latch предотвращают повторное
срабатывание. UI-индикация и фоновое исполнение обязаны использовать согласованные
данные, но не являются одним и тем же вычислением.

## 4. Четыре разных понятия, которые раньше смешивались

1. **Добавить BLE-объект**: O06 → O10, pairing новой платы и создание объекта.
2. **Настроить существующий объект**: O02/O04 → O11/O14, свои типовые поля и
   автонастройки. Привязка приложения к socket device — O13, а не BLE.
3. **Передать доступ к объектам**: G03/G04/G05/G14/G15; per-object права,
   получатель, цепочка, depth/pool, bundle и подписи. Это не перенос записи сервера.
4. **Перенести BLE на другой свой сервер**: O14 → ObjectMove: новая запись с тем
   же cipher, проверка записи/удаления с откатом, rebind локального ID,
   исключение старых shares из bundles. Это не передача владения другому человеку;
   момент удаления bundle не следует выдавать за доказанную немедленную отмену
   уже выданного офлайн-токена на железе.

## 5. Данные и identity, на которые должна опираться структура iOS

| Сущность | Identity / связи | Хранилище и исполнители |
| --- | --- | --- |
| Владелец на сервере | Host + device credentials; отдельно account email/access code и per-host fingerprint | Prefs.OwnerAccount; Api/registerHost/hostClaim; HostService |
| Обычный собственный объект | Стабильный local ID ↔ `(host, serverObjectId)`, type; ObjectKey/cipher; phone/webhook/device secrets | Prefs alias map, HostNumberInfo, Vault, Api |
| Собственный BLE | Local ID + ownerDeviceId + ownerSecret + ObjectKey; сервер хранит зашифрованную запись | BleObject, Prefs, BlePair/BleFire, ObjectMove |
| Входящий ключ | LocalKeyId + user key + host, fingerprint/signing binding, K_guest, bundle; hidden и overrides отдельно | Prefs.GuestKey, GuestConn, Vault, GuestSign |
| Входящий объект | LocalKeyId + objectId + тип; socket credentials или BLE token/secret/expiry/revocations | GuestNumberInfo / GuestBleObject / GuestSocketCred |
| Выданный ключ | `(host,keyId)`, user key/K_guest, label/welcome/mode; object IDs, ObjAccess, templates, stream/TTL; durable pending ID | HostKeyInfo, PendingHostKey, Vault, HostService |
| Передаваемая ссылка | Group + запись получателя + несколько частей, parent/child/vouch, host каждой части | ShareIn, PassVouch, Prefs, PassOnSection |
| Компания | `(host,orgId)` + профиль/domain/pubkey, проверенный logo; связь с выданным ключом | KnownOrg, OrgVerify, OrgLogoStore |
| Автоматизация | Scope + object target; template/owner template/local changes; runtime readiness/arming отдельно | Prefs.GuestTemplate, Vault.mergeIncomingTemplate, trackers |
| Действие/состояние | ActionKey `h…`, `b…`, `g…n…`, `gb…b…`; доступность, положение и inline outcome — разные поля | Action/AppState, owner/guest WS, BLE |
| Журнал / сообщения | Фактическая запись действия отдельно от message cipher hash и delivered/read acknowledgements | Journal/PassJournal; incoming pending message/seenMessage |

Запрещено использовать один голый server ID для разных серверов или смешивать
локальное имя с шифрованной owner metadata. Ошибка чтения/записи identity не даёт
права создать новую. Durable drafts, revocations, token renewals и pending moves
живут дольше одного экрана/процесса.

## 6. Команды и обратный путь результата

| Тип и роль | Путь исполнения | Обратный путь |
| --- | --- | --- |
| Свой call | C03 → Calls / HostService.triggerHostCall, hangup | Факт начала попытки/ошибка разрешений, звонковое состояние; не придумывать sensor-confirmed открытие. |
| Гостевой call | C03 → GuestConn.sendCall с подписью → owner HostService → reaction/confirm/busy policy → Calls | call_status и журнал владельца/гостя; отказ/истечение/занято различаются. |
| Свой/гостевой webhook | Phone/server route по настройке; signed request для гостя; payload action open/close/toggle в соответствующем режиме | Ответ/позиция/close timer, inline feedback и журнал. |
| Свой/гостевой socket device | Owner/guest WS → challenge → device credential подпись команды → контроллер | device_status / obj_state_update / ошибки rate-limit/offline и реальный outcome. |
| Свой BLE | BleFire.run → scan/cache → GATT nonce/подпись → result notification | OK, unconfirmed, unavailable/permission/signature/rejected и положение bistable; maintenance отдельно. |
| Гостевой BLE | BleFire.runGuest с токеном/expiry/guest identity/revocations → GATT | Результат локально и pending fire event → sync/ack владельцу; requestBleTokenRenew без подмены identity. |

Основание: `src:ui/HomeScreen.kt:304`, `src:host/GuestConn.kt:145`,
`src:host/HostService.kt:813`, `src:host/HostService.kt:1037`,
`src:host/HostService.kt:2351`, `src:ble/BleFire.kt:143`, `src:ble/BleFire.kt:292`.
Повтор maintenance/sync не означает разрешение автоматически повторить
неоднозначную физическую команду.

## 7. Резервирование, переезд и восстановление

Android-копия `ENTRIXY1` v1: PBKDF2, salt/nonce и AES-GCM, сохранённые настройки,
owner/object/guest key material и файлы. Device fingerprint/installation seed,
FCM token и widget bindings не становятся identity нового телефона. Источник
отпечатка передаётся отдельно для подписанного переноса.

Реальный путь: выбрать файл → parse/decrypt без применения → предупредить о
замене, при необходимости экспортировать текущее → hostClaim на всех владельческих
серверах с обработкой отказов → перенос incoming keys → apply → перезапуск
соединений/трекеров/рескан → отчёт и retry pending moves. Эта цепочка не заменяется
кнопкой «импорт JSON». Отдельные ветви: legacy fingerprint migration до запуска
соединений, eviction старого телефона с очисткой, ServerRestore после потери
серверных записей с отчётом о том, что нужно перепривязать.

Источники: `src:store/Backup.kt:24`, `src:ui/SettingsScreen.kt:1826`,
`src:host/FpMove.kt:17`, `src:host/ServerRestore.kt:25`, `src:host/HostService.kt:2380`.

## 8. Полное распределение исходников по подсистемам

Все 83 файла перечислены ниже; сигнатуры и номера строк — в JSON-индексе.
Перечень означает структурный учёт файла, не построчное доказательство алгоритма.

| Подсистема | Файлы относительно исходного корня | Ответственность |
| --- | --- | --- |
| Запуск | `App.kt`, `MainActivity.kt` | Инициализация, восстановление, crash consent/handler, версия, Intent/lifecycle, корень и глобальные окна. |
| Данные | `data/Action.kt`, `data/AppState.kt`, `data/BleObject.kt`, `data/GuestBleObject.kt`, `data/Journal.kt`, `data/PassJournal.kt` | Модели, реактивное runtime состояние, общий список действий, журналы/импорт. |
| Основные экраны | `ui/HomeScreen.kt`, `ui/SettingsScreen.kt`, `ui/GuestsScreen.kt`, `ui/JournalScreen.kt`, `ui/HelpScreen.kt` | Основные продуктовые деревья C/O/K/S/Y/G/J/H. |
| Редакторы | `ui/GuestAutomationEditor.kt`, `ui/CorridorMapScreen.kt`, `ui/GuestCallEditor.kt`, `ui/GuestUrlEditor.kt`, `ui/PassOnSection.kt`, `ui/CodeGate.kt` | Правила/карта, reaction, передача ключа, код; GuestUrlEditor отдельно помечен недостижимым ниже. |
| Вспомогательный UI | `ui/QrCode.kt`, `ui/IconsDebugSheet.kt`, `ui/ControlsDebugSheet.kt`, `ui/theme/Theme.kt` | QR, dev каталоги и тема. |
| Компоненты | `ui/components/ActionCard.kt`, `ui/components/AvatarPreset.kt`, `ui/components/Modifiers.kt`, `ui/components/NumberWheel.kt`, `ui/components/LinkifiedText.kt`, `ui/components/Paragraphs.kt`, `ui/components/QrScan.kt`, `ui/components/OpenPositionCorners.kt`, `ui/components/OrgLogo.kt`, `ui/components/StreamView.kt`, `ui/components/StatusBadge.kt` | Общие product controls, original artwork, picker, ссылки, поток, состояние. |
| Хранение | `store/Prefs.kt`, `store/Vault.kt`, `store/Crypto.kt`, `store/GuestSign.kt`, `store/AppCode.kt` | Secure/plain prefs разделены; master/object/guest keys, E2EE data/bundles/merge/rotation, подписи, локальный код. |
| Перенос/делегирование | `store/Backup.kt`, `store/ObjectMove.kt`, `store/ShareIn.kt`, `store/PassVouch.kt`, `store/OrgVerify.kt` | Backup/move, BLE server move, составные приглашения, vouch, проверка компании. |
| Сеть | `net/Api.kt`, `net/Net.kt`, `net/NetRoute.kt`, `net/WsClient.kt` | Контракты endpoints/suite/signatures, HTTP clients, выбор допустимой сети/запрет, WS и reconnect. |
| Центральная служба | `host/HostService.kt`, `host/GuestConn.kt`, `host/Calls.kt`, `host/FpMove.kt`, `host/ServerRestore.kt` | Owner WS по серверам, guest connections, sync/durable pending, challenge/commands/results/revokes/renew, телефон, переезды/восстановление. |
| Автоматика | `host/GeoTracker.kt`, `host/GeoCorridorMatcher.kt`, `host/AutoCombine.kt`, `host/WifiChecker.kt` | Фоновые датчики/время/зона/маршрут, readiness, latch/rearm, Wi-Fi. |
| Lifecycle/confirm | `host/BootReceiver.kt`, `host/ConfirmReceiver.kt`, `host/BleScanWatchdogReceiver.kt` | Перезапуск после boot/update, ответ уведомлению, восстановление BLE scanner при staleness. |
| BLE | `ble/BlePair.kt`, `ble/BleFire.kt`, `ble/BleCrypto.kt`, `ble/BleEvents.kt`, `ble/BleScanReceiver.kt`, `ble/BleScanRegistrar.kt`, `ble/BleActiveScanner.kt`, `ble/BleSound.kt`, `ble/BleTexts.kt` | Pair криптография/протокол, fire/result/time/revoke maintenance, пассивный/активный scan, автоfire, события/звуки/тексты. |
| GEO/активность ОС | `geo/GeofenceManager.kt`, `geo/GeofenceReceiver.kt`, `geo/ActivityManager.kt`, `geo/ActivityReceiver.kt` | Регистрация зон/активности, события-побудители для службы/трекера. |
| Push | `fcm/FcmService.kt`, `fcm/FcmTopics.kt` | Topics по ключам, resubscribe, message/shared parts, дедуп и acknowledgements. |
| Виджеты | `widget/KeyWidgetProvider.kt`, `widget/KeyWidgetConfigActivity.kt`, `widget/KeyWidgetActionReceiver.kt` | Конфигурирование, отрисовка/обновление, защищённый tap routing. |
| Утилиты | `util/AppLock.kt`, `util/Diagnostics.kt`, `util/Oem.kt`, `util/LogSafe.kt`, `util/SoundPlayer.kt` | Lock lifecycle, единый состав диагностики, настройки OEM, сокрытие чувствительных логов, sound events. |

Ресурсы среза: 63 PNG, 11 MP3, 44 XML, bundled notices HTML/TXT и dependency JSON.
`values` и переводы de/es/fr/pt/ru/zh; семь resource value directories — не семь
разных интерфейсов. Gradle: Compose/Material3, reorderable, Coil, ML Kit/ZXing,
location/activity/geofence, biometric, security-crypto, OkHttp, osmdroid,
Media3 и FCM; BLE X25519 через BouncyCastle. Android minSdk 26, target/compile 35.
Нативные зависимости Android не задают автоматически соответствующие iOS API.

## 9. Неактивный код и расхождения внутри эталона

- `GuestUrlEditor` объявлен, вызовов в текущем Kotlin-дереве нет. Рабочая
  webhook-настройка проходит через EditObjectSheet/GuestCallEditor.
- `GeoHowToDialog`, `ActionRowButton`, `AvatarButton` в ActionCard,
  отдельный `PromoCard` в HomeScreen и `ObjectAccessIcon` в GuestsScreen имеют
  только определения. Не создавать дополнительные страницы iOS по этим именам.
- `computeActions` использует простое окно BLE lastSeen 10 секунд, а ActionCard
  учитывает sleep advertisement window/состояние Bluetooth/expiry. Одна общая
  строка «не в сети» стирает эти разные значения; при проектировании iOS нужны
  раздельные доступность, возможность команды и видимый индикатор.
- В widget tap guard есть отдельная упрощённая ветка time/AND; комментарий и
  присвоенное `timeMatched = !timeActive` не следует считать эквивалентом
  AutoCombine. Перед переносом widget поведения нужен явный контракт с теми же
  ограничениями команд, а не копирование комментария.
- Наличие строки в strings.xml/комментария или старого документа не подтверждает
  действующий экран. В частности, legacy текст «Передача гостю» не доказывает
  текущий вход в настройку передачи; действующие входы приведены в G05/G15.

## 10. Как эта карта применяется к iOS

Следующий отдельный этап — заложить по этой карте структуру iOS: связать каждый
ID с feature/domain target, состоянием, действием, persistence и существующим
Swift executor либо явным пробелом. Сначала четыре корня и полное дерево
Настройки/Гости, затем общая модель объекта/редакторов/правил/прав доступа,
затем служебные события и восстановление. Сохранять проверенные CryptoKit,
Keychain, protocol и one-shot command implementations, не переписывать их ради
смены организации UI.

До структурного сопоставления запрещено объявлять «настройки как на Android»
на основании наличия четырёх tabs, добавлять BLE под существующий объект,
смешивать owner/guest/incoming настройки или заменять действующий сценарий
заглушкой. Имена будущих Swift экранов не являются реализованным функционалом.
Ограничения iOS фиксируются по конкретной ветке и проверяются отдельно по
[карте платформенных вопросов](ANDROID_IOS_PARITY.md), не угадываются из Android.

Это checkpoint **извлечения структуры**, не завершение приложения, не изменение
production UI и не новые screenshots. После отчёта — остановка по требованию
пользователя; реализация следующего этапа начинается отдельно.

Воспроизведение индекса без сборки:

```sh
python3 scripts/extract_android_structure.py /home/folder/android/dialer --check
```
