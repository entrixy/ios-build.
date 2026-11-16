# Android → iOS: актуальная карта сценариев и приёмки

Карта этапа 1 с уточнениями этапа 2, 16.11.2026. Прежняя противоречивая таблица заменена; история остаётся в Git. Результаты проверки этапа 2 записываются ниже отдельно.

После пользовательского ревью порядок исправлен: сначала полная
[структура Android](ANDROID_STRUCTURE.md), затем архитектура iOS, затем реализация.
Предыдущий перенос вкладок не завершил структуру настроек объектов: раскрываемые
карточки, типовые редакторы, автонастройки и передача доступа связаны между собой.
Таблица 50 сценариев ниже остаётся сводкой наличия функций; для иерархии и
действующих входов используется новая структурная карта с индексом исходников.

## Основание и границы

- Эталон Android: `56155352b0e9f36ef3685aa071a6aafdb2ef6622` (10.90).
- Рабочий iOS source этапа 2: original `f87de20`, public `1eedb9196115ce6d577c834dff9261a9ee9ddc6b`.
- [Apple CI 43869510705](https://github.com/entrixy/ios-build./actions/runs/43869510705): Debug, Release/isolation, **137 core + 77 hosted native + 4 UI-теста**, capture13 прошли. Все четыре UI-сценария выполнены с проверкой доступности кнопок и реальных переходов; это не аппаратная приёмка.
- [Опубликованы 13 рабочих маршрутов](https://entrixy.com/ios-design.php), iPhone 16 light, DEBUG simulator stored profiles. `scripts/capture_stage_two.py` использует настоящий RootView/AppModel; прежний каталог 12 PNG заменён. Все 13 кадров прошли Vision/проверку source/hash и визуальный просмотр.
- Просмотрены текущие точки входа, UI, вызванные модели/основные guards, конфигурация проекта, существующие тесты и Android/серверный контракт native_only. Это source-аудит, а не построчное доказательство всей криптографии и не live server/radio испытание.
- Физический iPhone, контроллер, боевые доступы, телефонные звонки и миграция реальных данных на этом этапе не использовались.

## Как читать карту

**Р** — рабочий путь подключён в указанных пределах, есть тестовая база; это не отметка полной приёмки Android/iOS. **Ч** — путь есть частично, недостают ветви/настройки/интеграция. **Н** — пользовательского пути нет. Ни одна строка пока не объявлена полностью принятой для выпуска.

UI проверяется отдельно. Этап 2 переносит общую нижнюю навигацию и стили кнопок из каталога в рабочие экраны; это не завершение всех форм и сценариев.
P1–P9 — платформенные вопросы ниже. Наличие API не доказывает допустимую задержку,
надёжность или соответствие конкретной прошивке. Критерий в последнем столбце —
запланированная приёмка, **не заявление о выполненном тесте**.

Источники Android относительны `app/src/main/java/com/entrixy/app/`; имена функций
в старой карте сохранены как точки входа. Swift App/ и Sources/EntrixyCore/ — текущие исходники.

Общий каталог объектов уже подключён к обоим корням; области данных и оставшиеся
пути описаны в [структуре iOS](IOS_STRUCTURE.md). Итоговая проверка нового checkpoint
выполняется отдельно от прежнего этапа 2.

## 50 пользовательских сценариев

| ID | Сценарий / Android источник | Статус и текущее состояние iOS | Проверочная база / ограничения | Критерий приёмки |
| --- | --- | --- | --- | --- |
| 01 | Четыре основные вкладки, бренд; `MainActivity.DialerApp`, `HomeScreen`, `ui/theme/Theme` | **Р** — RootView использует общий NavigationStack и AppBottomNavigation; AppNavigationState задаёт условные Control/Guests. Четыре подраздела SettingsScreen подключены к существующим данным. Полный состав настроек Android ещё не перенесён. | N2; — | Пустой профиль, гость, владелец: нужные вкладки, единая панель на вложенных страницах, правильный возврат; один заголовок без «Навигации». |
| 02 | Тап гостевого объекта; `ActionCard.Card(onClick)`, `HomeScreen.onCall` | **Р** — App/GuestScreens.swift → AppModel.actionIntent/execute: тап всей карточки, gate по policy; лишняя надпись «Полученные объекты» удалена на этапе 2. | T1; — | Один тап вызывает ровно нужное действие; подтверждение только по policy; внешний вид по принятому образцу. |
| 03 | Тап своего объекта; `HomeScreen.onCall`, `HostService.callOwnNumber/fireOwnWebhook` | **Р** — App/OwnerControlSection.swift → ownerActionIntent/execute: прямой тап уже есть, направление фиксируется и перепроверяется. Обязательный chooser устранён. | T2; — | Владелец открывает/закрывает по актуальному состоянию; изменение направления во время PIN отменяет старый intent. |
| 04 | Недоступный объект, отказ по условиям; `ActionCard.unreachable/tapRejected/tapBlocked` | **Р** — AppModel.actionRejections/rejectOwnerAction: отказ управления в карточке, отдельный transient feedback; не все остальные ошибки приложения имеют единый UX. | T1 T2; — | Offline/нет прав/истёк срок: понятный отказ, ноль команд и записей выполнения; повторное подключение не повторяет тап. |
| 05 | Состояние открыто/закрыто/движение; `OpenPositionCorners`, `BleEvents`, `HostService.obj_state_update`, `GuestConn` | **Ч** — App/OwnerControlModel.swift и GuestScreens.swift учитывают направление и онлайн устройств; Android OpenPositionCorners/свежесть/полная индикация не перенесены. | T1 T2; P3 | Открыт, закрыт, движется, устарел, offline различимы; устаревшее положение не выдаётся за текущее. |
| 06 | Повторный тап, потеря связи, неоднозначный исход; `HostService`, `BleFire`, `GuestConn` | **Р** — GuestActionSession, OwnerCommand и BLE sessions: одна попытка, результат/неопределённость; есть регрессии потери связи. | T1 T2 T3; P3 P5 | Двойной тап, разрыв до/после send, перезапуск: нет двойной команды и выдуманного успеха. |
| 07 | Телефонный объект владельца; `Calls`, `HostService.placeCall`, настройки hangup | **Ч** — App/OwnerControlModel.swift.dial передаёт tel: системному телефону. Автоотбой и Android фоновый дозвон не реализованы. | T2; P1 | Системное подтверждение, отмена и передача вызова корректны; журнал не считает handoff состоявшимся звонком. Отдельно согласовать автосброс. |
| 08 | Гостевой запрос звонка владельцу; `HostService.do_call/confirm_request`, `ConfirmReceiver` | **Ч** — OwnerControlModel принимает подписанные запросы звонка в foreground, предлагает согласие/отказ; фонового уведомления владельца нет. | T2; P1 P5 | Гостевой запрос приходит правильному владельцу, нельзя повторить подпись; отмена/занятость/нет владельца/фон определены. |
| 09 | Локальный/серверный webhook, toggle; `GuestUrlEditor`, `HostService.fireOwnWebhook`, `Prefs.getWhToggle` | **Ч** — OwnerObject/OwnerCommand: серверный webhook и toggle есть; полного локального режима и редактора URL/секрета/режима нет. | T2 T7; P5 | По каждому Android режиму: создать, изменить, вызвать, проверить целевой получатель и подпись; тайм-аут не превращается в повтор. |
| 10 | Подтверждение действия; `ActionCard.tapAuthLevel/confirmOpen` | **Р** — App/ActionConfirmation.swift используется и гостем, и владельцем по policy. Рабочее представление ещё sheet, каталог отдельно. | T1 T2; — | Confirmation off: прямой тап; on: компактный диалог; отмена ничего не отправляет, защита после изменения объекта перепроверяется. |
| 11 | PIN/биометрия отдельного действия; `AppCode`, `CodeGate`, `ActionCard.runAuthThenCall` | **Ч** — App/ActionAuthentication.swift, AppModel: общий PIN/lockout и current-set biometrics, owner auth уже подключён. Face ID на устройстве не проверен. | T1 T2 T6; P7 | Верный/неверный PIN, блокировка, перезапуск, отмена биометрии, изменение набора биометрии; разрешение только на одно связанное действие. |
| 12 | Блокировка входа/возврата; `AppLock`, `MainActivity`, `CodeLockScreen` | **Р** — App/AppEntryLockScreen.swift и AppEntryLockPolicy: холодный старт, >60 секунд в фоне, изменение кода с проверкой старого; защита входа не авторизует объект. | T6; P7 | Холодный запуск/короткий фон/долгий фон/ссылка при блокировке; отключение только после проверки; ошибка хранилища не снимает защиту. |
| 13 | GEO зона и направление захода; `GuestAutomationEditor`, `GeoTracker`, `AutoCombine` | **Н** — Нет рабочего GEO редактора/исполнителя; GuestActionPolicy читает часть настроек, но это не движок. | S; P2 | Сохранить зону; вход/выход и направление; отказ разрешений; одно срабатывание и повторное взведение; фон/перезапуск проверены. |
| 14 | Маршрут/коридор и карта; `CorridorMapScreen`, `GeoCorridorMatcher`, `ActivityManager` | **Н** — Нет экрана карты/коридора и GeoCorridorMatcher аналога. | S; P2 | Редактировать маршрут, проехать в обоих направлениях; GPS шум/параллельная дорога/повторный въезд не дают ложного открытия. |
| 15 | Wi-Fi/BSSID/пороги; `WifiChecker`, `GuestAutomationEditor.WifiInlineEditor` | **Н** — Нет Wi-Fi редактора/исполнителя; сетевые запреты частично консервативно блокируют команды. | S; P4 | Проверить, какие поля реально использует Android; текущая сеть/нет сети/нет разрешения/смена BSSID; не подменять сканирование знанием текущего SSID. |
| 16 | Расписание/дни/ночные интервалы; `TimeInlineEditor`, `AutoCombine.secondsLeftInWindow`, `GeoTracker` | **Н** — Нет редактора расписания и планировщика; GuestActionPolicy блокирует неподдержанные серверные time_from/time_to. | T7 S; P5 | Дни, ночной интервал, границы, часовой пояс/перевод часов; отсутствие фонового события не ослабляет срок доступа. |
| 17 | И/ИЛИ, readiness, rearm, countdown; `ActionCard`, `AutoCombine` | **Ч** — GuestActionPolicy/OwnerManualPolicy разбирают any/all и блокируют неподдержанное AND; полноценного readiness/arming/rearm нет. | T7; P2 P3 P4 P5 | Таблица истинности совпадает с Android; все включённые условия, выход/возврат, таймеры; одиночное правило all не превращать в новый запрет. |
| 18 | Импорт ключа: вставка/камера/фото; `MainActivity`, `QrScan`, `ShareIn`, `SettingsScreen` | **Ч** — App/KeyImportScreen.swift, QRScannerScreen, GuestInvite: вставка/QR/фото есть; реальная камера и полный UX не проверены. | T0 T7; P7 | Принять все поддержанные Android форматы; неверный QR/отмена/повтор/невыданные разрешения не создают лишнюю identity. |
| 19 | HTTPS Universal Links и custom scheme; `AndroidManifest`, `MainActivity.handleIntent` | **Ч** — Custom scheme в project.yml есть; associated-domains entitlement отсутствует; наличие HTTPS parser не равно Universal Links. | T7 S; P6 | Ссылка из браузера, QR и другого приложения ведёт в нужную ветку; после разблокировки продолжается один intent. |
| 20 | Производственный claim QR; `MainActivity` `/claim`, `SettingsScreen.AddObjectSheet` | **Ч** — AddOwnerObjectScreen принимает claim-код вручную; обработки производственной /claim ссылки нет. | T2 S; P6 | Сканировать реальную claim-ссылку, проверить сервер и цель; ошибочный/чужой/уже использованный код не создаёт объект повторно. |
| 21 | Компании/профиль/подлинность; `OrgVerify`, `OrgLogo`, `MainActivity`, `Api.orgInvite/orgClaim` | **Н** — Нет корпоративного UI и цепочки orgInvite/orgClaim/проверенного профиля. | S; P6 | Приглашение компании → проверка подлинности → запрос/получение доступа; просроченная ссылка и отказ не обходятся. |
| 22 | Список полученных ключей, обновление/удаление; `SettingsScreen` key tab | **Ч** — Отдельная подвкладка Ключи уже есть; KeyDetailScreen даёт refresh/remove. Локальное имя и скрытие отдельного объекта подключены через ObjectSettingsRows; это другой scope, не удаление ключа. Полное соответствие представления Keys ещё не принято. | T0; — | Статус ключа, обновление, удаление и повторный импорт; скрытие одного объекта сохраняет ключ и соседние объекты, повторный импорт возвращает скрытые без замены identity. |
| 23 | Создание/синхронизация владельца, несколько серверов; `Api.registerHost/hostSync`, `Prefs` | **Р** — OwnerAPI/OwnerAccount/AppModel: несколько серверов, регистрация/sync, сохранённое неопределённое состояние; UI ограничен. | T2; — | Два сервера, недоступный сервер, потерянный ответ регистрации и ошибка записи: один owner, повтор только проверки/сохранения. |
| 24 | Серверный аккаунт/тариф; `SettingsScreen.serverDialog`, `Api.accountLogin/hostAccount` | **Н** — Нет accountLogin/hostAccount пользовательского пути; owner credentials не являются серверным аккаунтом. | S; — | Login/link/unlink на нужном сервере, неверный пароль/отмена; отвязка аккаунта не удаляет локальные доступы молча. |
| 25 | Добавление device/call/webhook/BLE; `AddObjectSheet`, `BlePair`, `Api.deviceRegister/deviceClaimEx` | **Ч** — App/OwnerScreens.swift и BLEPairingScreen: четыре типа в Добавить объект, call/server webhook, claim и BLE pair; первый owner регистрируется при Save. Нет полного deviceRegister → ENTX-DEV → конфигуратор. | T2 T3; P3 P6 | Пройти каждый тип отдельно; для нового контроллера получить данные/код и продолжить штатную настройку, как Android. |
| 26 | Изменение объекта; `EditObjectSheet`, `GuestCallEditor`, `EditBleObjectSheet` (GuestUrlEditor не вызывается) | **Ч** — Общий ObjectSettingsRows: раскрываемые свои/входящие/BLE, общий порядок, локальное имя/скрытие полученного объекта. OwnerObjectEditor сохраняет название, 8 пресетов, local confirm/auth и BLE права. Полных phone/webhook/автоматизации полей нет. | T2 T7; — | Изменить каждое Android поле и повторно открыть; неизменяемые секреты/права сохраняются, сбой записи откатывает изменение. |
| 27 | Перенос объекта на другой сервер; `ObjectMove`, `EditBleObjectSheet` | **Н** — Нет пользовательского переноса отдельного объекта между серверами; BackupManager решает другой сценарий. | S; — | Переезд одного объекта с зависимыми правами/секретами; прерывание на каждом шаге, продолжение без дубликата и потери старого доступа. |
| 28 | Ротация объектных ключей; `Vault.rotateObjectKey`, `HostService` | **Ч** — Guest поддерживает текущий/предыдущий object key; owner rotate/re-encrypt/reissue workflow отсутствует. | T7; — | Смена ключа владельцем, обновление получателей, отключённый гость, возобновление после ошибки; старый ключ не остаётся бессрочным обходом. |
| 29 | Аватары/пресеты/локальный override; `AvatarPreset`, `AvatarPickerDialog`, `Prefs.setOverride` | **Ч** — App/AvatarCache.swift и ObjectViews.swift: decrypt/cache, owner читает preset metadata. Реальная загрузка своей картинки/графические overrides не подключены; PhotosPicker есть только в каталоге. | T2 T7 C; P7 | Своя картинка и пресет: выбрать/отменить/сохранить/удалить, перезапуск, локальное и серверное изменение; проверить обновление у гостя. |
| 30 | Живая картинка/поток; `StreamView`, `SnapshotCard`, `ActionCard.streamOpen` | **Н** — Нет рабочего renderer/редактора Android stream/snapshot и условий его показа. | S; P5 | Задать поток/снимок, проверить showWhen/call/nearby, закрытие/ошибку сети и прекращение загрузки при уходе. |
| 31 | Выдача ключа/QR/share; `GuestsScreen`, `Vault`, `Api.keyCreate` | **Ч** — OwnerIssuedKey/IssueOwnerKeyScreen: issue, QR/share, encrypted bundle есть; набор Android шаблонов/параметров урезан. | T2 T7; P8 | Выдать реальному получателю, QR/ссылка декодируются Android и iOS; выбранный scope/защита/срок точно соблюдаются. |
| 32 | Правка/пауза/возобновление/отзыв ключа; `GuestsScreen`, `Api.keyEdit/keySetMode/keyRevoke` | **Р** — AppModel editOwnerKey/setOwnerKeyMode/revokeOwnerKey: stable identity, label/scope/welcome, pause/revoke и сохранение неопределённого исхода. | T2; — | Редактирование не меняет ссылку; пауза/возврат/отзыв и потерянный ответ проверены; дочерние права обновляются корректно. |
| 33 | Права на объект, depth/pool, native-only; `ObjectAccessSheet`, `GuestsScreen` | **Ч** — KeyObjectAccess: depth/pool есть. OwnerIssuedKey явно запрещает nativeOnly, UI отправляет false. Причину нельзя объяснять неподтверждённой аттестацией. | T2 T7 S; P8 | Сверить контракт native_only/client_type с сервером; разрешённый клиент работает, браузер запрещён; лимиты по объекту/цепочке не расширяются. |
| 34 | Сроки, сетевые правила, реакция занятости; `GuestsScreen`, `GuestCallEditor`, `GuestAutomationEditor` | **Ч** — Нет полного редактора auth/условий/сроков/занятости; OwnerIssuedKey фиксирует force_when_busy=false. | T2 T7; P1 P4 P5 | Каждое право/срок/реакция занятости сохраняются и действуют у получателя; смена политики не оставляет прежнего разрешения. |
| 35 | Приём передачи/ожидание/новые части; `ShareIn`, `PassOnSection`, `Api.keyInvite*` | **Р** — DelegationInbox/ReceivedDelegation: durable info/redeem/resolve и дополнительные части; в foreground. | T4; P5 P6 | Приём до/после owner подтверждения; новые части добавляются без замены identity; прерывание/повтор не теряют уже принятый доступ. |
| 36 | Передача дальше/create/edit/vouch/revoke; `PassOnSection`, `PassVouch`, `Api.keyDelegate*` | **Р** — PassedAccess/PassManager/OwnerDelegatedKey: create/edit/vouch/revoke и owner fulfilment; полного live E2E доказательства нет. | T4 T7; P5 | A выдаёт B, B передаёт C, A подтверждает/сужает/отзывает; обе платформы проверяют цепочку, повтор и прерывание. |
| 37 | Личные сообщения и delivered/read; `GuestsScreen.MessageSheet`, `GuestConn`, `FcmService` | **Ч** — MessageManager/GuestMessages/MessageScreens: encrypted send/receive, durable delivered/read ack. Нет APNs; полный UI correlation статусов не доказан. | T4; P5 | Сообщение между Android/iOS, повторы/перезапуск/фон; «прочитано» только по соответствующему подтверждению. |
| 38 | Локальный журнал и экспорт; `Journal`, `JournalScreen` | **Р** — App/GuestScreens.swift.JournalScreen, AppModel: реальные attempts/results, share/copy/toast/direct clear; историческое описание старых alert в аудите устарело. UI каталога отдельно. | T1 T2 T0; — | Точное время/кто/объект/исход, экспорт, copy, clear и перезапуск; sync/передача ключа не становятся открытием. |
| 39 | Журнал действий переданных ключей; `PassJournal`, `JournalScreen.LaunchedEffect` | **Р** — App/PassManager.swift.sync вызывает AppModel.importDelegatedJournal; есть dedup и durable ledger. Старое утверждение «не импортируется» неверно. | T4; — | Одна серверная запись появляется один раз, не возвращается после clear, переживает restore; requested без результата не называется открытием. |
| 40 | BLE pairing и защищённая команда; `BlePair`, `BleCrypto`, `BleFire` | **Ч** — CoreBluetooth + pair/fire sessions: защищённые foreground owner/guest команды есть; на физическом iPhone/контроллере не проверены. | T3 T7; P3 P7 | Pair → перезапуск → один FIRE → верный receipt; неверный ключ/nonce/подпись отвергаются; испытание на реальном контроллере. |
| 41 | BLE passive/background scan, дальность/сон; `BleScanReceiver`, `BleScanRegistrar`, `BleActiveScanner`, watchdog | **Н** — Нет Android passive/background readiness/watchdog/auto-trigger аналога. Foreground scan не покрывает этот путь. | T3 S; P3 P5 | Спящий контроллер, фон, экран выключен, Bluetooth выкл/вкл, выход/возврат и восстановление состояния без ложной команды. |
| 42 | BLE сроки/продление/отзывы; `BleTokenTtlSheet`, `BleFire`, `Vault`, `GuestConn` | **Ч** — Signed BLE renew/revocation/carry/receipt есть; UI продлевает на 24 часа, Android даёт выбор TTL. | T3 T7; P3 | Проверить все допустимые сроки, expiry без интернета, перенос отзыва на контроллер, подтверждённое применение и повтор доставки. |
| 43 | Native iOS backup/migration; `Backup`, `ServerRestore`, `FpMove`, `hostClaim/keyMove` | **Р** — App/BackupManager.swift, BackupEnvelope/OwnerBackupMerge: iOS export/inspect/preflight/restore с checkpoint/merge есть; живой перенос не проверен. | T5 T7; P7 | Верный/неверный пароль, конфликт, прерывание owner/guest claim, повторный запуск; исходный доступ и identity не теряются молча. |
| 44 | Android backup → iOS; `Backup.export/import`, `Prefs/Vault` | **Ч** — AndroidBackupDocument/AndroidOwnerAdapter/AndroidKeyRecovery есть в Core, но BackupManager.inspect декодирует только IOSBackupPayload. | T5 T7 S; P7 | Реальная копия Android → просмотр состава → preflight → перенос с продолжением после сбоя; совместимость ключей проверяется на сервере/контроллере. |
| 45 | Foreground/background/restart, push; `HostService`, `BootReceiver`, `FcmService`, `FcmTopics` | **Ч** — Foreground WSS/reconnect есть, LiveAppRoot уходит в suspend; нет APNs/background engine/BootReceiver эквивалента. | T1 T2 S; P2 P3 P5 | Раздельно проверить active/background/locked/system termination/force-quit/reboot; свежесть ключей, сообщений и отзывов и политика восстановления. |
| 46 | Звуки и громкость по событиям; `SoundPlayer`, `BleSound`, `SoundEventCard`, Settings sounds | **Н** — Нет Android звуковых профилей/загрузки/громкости по событиям. Haptic отказа — лишь отдельный feedback. | S; P5 P7 | Загрузить/выбрать/предпрослушать, громкость/mute; разные события и системные режимы, уведомления проверить на iPhone. |
| 47 | Тема/язык/справка/витрина; `Theme`, `MainActivity.languageList`, `HelpScreen`, `PromoCard` | **Ч** — Тема system/light/dark уже работает через AppStorage. Нет полного language/help/promo/company UI; декларация только ru. | S C; — | Тема/язык сохраняются; все строки/справка/ссылки и бренд корректны; Help сохраняет общую нижнюю навигацию, как Android. |
| 48 | Диагностика/отправка лога/обновление; `Diagnostics`, `LogSafe`, Settings system, `Api.crashReport/versionCheck` | **Н** — Нет пользовательского Diagnostics/LogSafe/crashReport/versionCheck workflow; CI лог не заменяет его. | S; — | Собрать/просмотреть/отправить диагностику с удалением секретов; отмена/сбой отправки, информация о версии и штатный переход обновления. |
| 49 | Виджеты/внешние действия; `KeyWidgetProvider/ConfigActivity/ActionReceiver` | **Н** — Нет WidgetKit target/конфигурации виджета/внешнего действия. | S; P9 | Выбрать объект, виджет показывает актуальный доступ; действие соблюдает PIN/права/срок, отзыв и потерю связи; решение API после прототипа. |
| 50 | Сеть/локальные ограничения/маршрут; `NetRoute`, `Net`, `WifiChecker`, `net_block` | **Ч** — Подписанный HTTPS и запрет redirect есть; нет Android NetRoute/cellular selection и SSID/BSSID runtime policy. | T7 S; P4 P5 | При Wi-Fi без интернета и доступной сотовой сети не отправлять неавторизованный повтор; сетевые условия проверять до команды, недоступность обозначать явно. |

Итого по наличию рабочих путей: **Р — 14, Ч — 24, Н — 12**. Это не процент готовности: объём и риск строк различаются.

## Проверочная база: что уже есть, что ещё требуется

Тесты ниже найдены в исходниках. Сводный CI подтверждает исполнение существующего
набора, но не аппаратную приёмку и не точное совпадение всех UI сценариев.

| Код | Существующие файлы доказательств |
| --- | --- |
| T0 | Tests/EntrixyAppTests/AppStateTests.swift — persistence/journal/QR photo import. |
| T1 | Tests/EntrixyAppTests/ActionFlowTests.swift — challenge/result, отказ без send, PIN/lockout, relaunch/no replay. |
| T2 | Tests/EntrixyAppTests/OwnerAccountTests.swift — регистрация/объекты/ключи, frozen direction, owner PIN, policy rollback, неоднозначные ответы, phone handoff, owner messages/delegation. |
| T3 | Tests/EntrixyAppTests/BLEPairingTests.swift, BLEOwnerControlTests.swift, BLEGuestControlTests.swift — симулированные transports. Это не испытание радио. |
| T4 | Tests/EntrixyAppTests/DelegationInboxTests.swift, PassManagerTests.swift, MessageManagerTests.swift — durable delegation/messages/journal. Core DelegationEndToEndTests также не live серверный E2E. |
| T5 | Tests/EntrixyAppTests/BackupTests.swift — preflight, checkpoint, lost reply, merge. |
| T6 | Tests/EntrixyAppTests/AppEntryLockTests.swift и core AppEntryLockPolicyTests.swift — cold/background/code/rollback. |
| T7 | Tests/EntrixyCoreTests/ — протоколы, криптография, owner/object/key policies, Android backup adapters, BLE lifecycle, delegated journal. Сопоставить конкретные cases перед изменением каждой строки. |
| N2 | Tests/EntrixyAppTests/AppNavigationTests.swift: роли, legacy hint, черновик/готовая карточка. Tests/EntrixyUITests/NavigationUITests.swift: 4 UI-сценария — отмена, push/back, смена root, роли, фактический Control → Guests. Capture13 — выбранные рабочие маршруты. |
| C | App/NativeDesignCatalog.swift — исторический каталог компонентов. PhotosPicker в нём не равен загрузке owner avatar в продукте. |
| S | Только просмотр source/отсутствующей интеграции. Приёмочных тестов пользовательского пути пока нет. |

Обязательные условия для всех изменяемых сценариев: нормальный исход, отмена,
пустые данные/ошибка, offline, недостаточные права/истёкший срок; для операций —
двойной тап, потеря ответа и ошибка записи. Для durable операций дополнительно
перезапуск и продолжение. Проверять отсутствие лишнего физического действия,
сохранность identity/секретов и правдивый журнал. Новые тесты нужны для логики и
значимых рисков, а не для зеркального пересказа простого UI кода.

## Рабочий UI: конкретный объём этапа 2

| Область | Текущий рабочий код | Требуемый результат |
| --- | --- | --- |
| Основная навигация | RootView использует общую production AppBottomNavigation в отдельной области рядом с NavigationStack; каталог использует тот же компонент. | Один общий компонент в реальном приложении; сохранение на обычных вложенных страницах; модальные окна поверх; Android условия видимости Control/Guests. |
| Настройки | SettingsScreen: Объекты / Ключи / Звуки / Система. OwnerObjectRows переиспользуются из рабочего редактора; гостевые объекты пока без полного редактора. Звуки явно не реализованы. | Внутренние вкладки Объекты / Ключи / Звуки / Система; каждый элемент на своём Android месте. Нереализованные функции не имитируются кнопками. |
| Карточки | Надпись «Полученные объекты» удалена; действия карточек и guards сохранены. Сортировка/скрытие остаются пробелами. | Убрать придуманную группировку; порядок, локальные названия/скрытие и состояния сверять с Android. |
| Подтверждение/PIN | App/ActionConfirmation.swift остаётся sheet со Spacer и нижней отменой. | Подключить компактные компоненты к реальным intent/auth без изменения guards и без двойной команды. |
| Кнопки/разделители/журнал | Общие production PrimaryActionStyle/SecondaryActionStyle, 48 pt, нейтральная и красная заливки. KeyDetail — без per-action белых плашек, с полными разделителями. Журнал использует те же залитые кнопки. Остальные сложные формы проверяются по своим сценариям. | Общие production-компоненты; одинаковые роли, размеры, заливки, разделители и состояния. |
| Картинки | Рабочий редактор выбирает пресет; загрузка своей картинки есть только в каталоге. | Полная цепочка выбрать → проверить → зашифровать/сохранить → передать → обновить у получателя. |
| Заголовки | Лишняя «Навигация» удалена из каталога и capture expectations. Рабочие roots имеют смысловые заголовки; вложенные страницы — inline title. | Один смысловой заголовок; логотип только в нужном месте; без служебных подписей поверх native frames. |
| CI снимки | scripts/capture_stage_two.py снимает 13 реальных production routes через RootView с DEBUG-only сохранёнными профилями. Apple CI 43869510705 прошёл, кадры просмотрены и опубликованы. | Выборочные реальные product flows из рабочих компонентов и моделей; полный набор на границе этапа, без светлых/тёмных дублей. |

## Платформенная карта: решение до реализации спорного поведения

Проверено по официальной документации Apple 16.11.2026. Документальные ограничения
отделены от нашего проектного вывода. Ничего ниже не отменяет права/условия ключа.
Неподдержанное ограничение нельзя молча пропустить ради срабатывания.

| Код | Что известно | Решение / необходимая проверка |
| --- | --- | --- |
| P1 — сотовые звонки | Apple Phone Links: tel: требует подтверждения пользователя. Android Calls.place использует TelecomManager и таймер endCall. | Сохраняем явный handoff и правдивый статус. Автоматический звонок/автоотбой не обещаем: публичный допустимый эквивалент Android в этом аудите не подтверждён. Принять продуктовый вариант отдельно; owner-request в фоне проверить на iPhone. |
| P2 — GEO/коридор | Core Location поддерживает мониторинг регионов/пробуждение; документация ограничивает одновременно наблюдаемые условия числом 20. | GEO не объявляется невозможным. Нужны выбор API с учётом deployment iOS16, разрешения, стратегия при >20 зонах и пробы въезда/направления/шума/фон/reboot. CLMonitor нельзя молча сделать зависимостью iOS16. Коридор не равен одной геозоне. |
| P3 — BLE | CoreBluetooth имеет background central и восстановление состояния; повторные discoveries в фоне объединяются, интервал поиска может увеличиваться. | Проверить service UUID/advertising текущей прошивки, сон, RSSI/дальность, locked/background/relaunch. Не обещать одинаковую скорость и continuous readiness с Android по наличию background mode. Сам foreground FIRE требует отдельного hardware proof. |
| P4 — Wi-Fi/сети | NEHotspotNetwork.fetchCurrent даёт текущие SSID/BSSID при выполнении условий Apple и наличии entitlement. Универсального API сканирования Wi-Fi нет. | Сначала извлечь точный Android контракт: текущая сеть, список видимых сетей или RSSI. Для каждой части — сохранить/адаптировать/не поддержать с причиной. HotspotHelper не обход для произвольного сканирования. Маршрутизацию проверить отдельно. |
| P5 — фон/сроки/push | BGTask выполняется по решению системы; silent push не гарантирован. Текущий проект при уходе в фон приостанавливает sessions; APNs и background capabilities не настроены. | Не эмулировать Android Service вечным WSS/таймером. Разнести серверную актуальность, пользовательские push, background refresh, GEO/BLE события. Критичные запреты/expiry проверять и при исполнении. Пробы active/locked/background/system termination/force-quit/reboot и offline restore. |
| P6 — HTTPS links | Universal Links требуют associated domains entitlement и AASA на сайте; parser HTTPS и custom scheme этого не заменяют. | Это недоделанная интеграция, а не запрет iOS. Сверить /key, /i, /claim, /c и legacy /o; аппаратная проверка домена, установки, заблокированного входа и отложенного intent. |
| P7 — разрешения/безопасность | Keychain/LocalAuthentication/камера/PhotosPicker требуют проверки соответствующих пользовательских состояний на устройстве. Текущий catalog не проверяет production photo upload. | Отказ/отзыв разрешения, новое лицо/отпечаток, блокировка телефона, перезапуск, память/хранилище. Не заменять action authentication успешной разблокировкой входа. |
| P8 — тип клиента/native_only | Android Api и lib/key_objects.php описывают native_only как «приложение, не браузер». Swift OwnerIssuedKey запрещает true и per-object true. | Сверить актуальный серверный handshake/client_type для всех типов объектов и legacy. Не объявлять отсутствие Apple attestation причиной без доказательства; не подписываться Android-клиентом и не снимать native-only запрет. До контрактной проверки — статус частичный. |
| P9 — виджеты | WidgetKit target в проекте отсутствует. Допустимый способ действия и передачи защиты в приложение ещё не выбран. | Прототип реального действия/перехода и свежести UI с правами/expiry. Нельзя превращать виджет в обход PIN/Face ID. Это отдельный ограниченный сценарий, не обещание Android widget 1:1. |

Официальные источники (без перепечатки текстов):

- [Apple: Phone Links](https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/PhoneLinks/PhoneLinks.html)
- [Apple: Core Location region monitoring](https://developer.apple.com/documentation/corelocation/monitoring-the-user-s-proximity-to-geographic-regions)
- [Apple: Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [Apple: current Wi-Fi network](https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:))
- [Apple: TN3111 Wi-Fi overview](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview)
- [Apple: choosing background strategies](https://developer.apple.com/documentation/backgroundtasks/choosing-background-strategies-for-your-app)
- [Apple: background push delivery](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
- [Apple: associated domains](https://developer.apple.com/documentation/xcode/supporting-associated-domains)

Аппаратные пробы на этом этапе НЕ выполнялись. Их результат — отдельное доказательство,
которое нужно получить до обещания соответствующих фоновых/радио сценариев.

## Очерёдность и остановки

1. **Этап 2: рабочая структура — выполнен в описанных границах.** Обычный пользователь без объектов, гость, владелец, делегирующий гость: навигация и состав разделов → настоящие рабочие маршруты. Сначала перенос общих компонентов из каталога в production, затем подключение экранов; не создавать вторую независимую библиотеку стилей. Четыре внутренних раздела настроек; неперенесённые функции остаются в реестре, а не изображают работу. Удалить лишнее «Навигация». На выходе реальная native сборка, компактный набор изменённых экранов и проверка возвратов/видимости панели. Остановиться и доложить.
2. **Этап 3: управление/объекты.** Пункты 02–12, 25–30, 40: отдельные законченные вертикали device, call, webhook, BLE; не ждать конца проекта, чтобы проверить один настоящий BLE FIRE на iPhone. Ротацию и move не смешивать с rename. Остановка после каждой вертикали.
3. **Этап 4: права/гости.** 31–39, 42: scope/сроки/auth/native-only/занятость, выдача/пауза/отзыв, A→B→C и сообщения. Зависимые фоновые статусы не объявлять готовыми раньше P5.
4. **Этап 5: перенос/сервисы.** 19–24, 27–28, 43–44: Android/iOS копии и identity, server/account/company/claim/configurator, move/rotation с checkpoint.
5. **Этап 6: условия и фон.** 13–17, 41, 45, 50. Платформенные прототипы P1–P6 выполняются до соответствующей вертикали, а не откладываются до App Store. Любая необходимая адаптация с видимым изменением поведения отдельно согласуется.
6. **Этап 7: остальное.** 29–30, 46–49: avatars/stream, звуки, языки/справка, диагностика, widgets; часть функций может закрываться раньше вместе со своей вертикалью. Дублировать работу не нужно.
7. **Этап 8: выпуск.** Сквозная Android↔iOS приёмка на сервере/контроллере, устройствах, TestFlight, signing/privacy/review. Сборка симулятора не является сборкой для публикации.

Каждый отчёт: изменённые ID → что реально работает → выполненные проверки и кадры →
оставшиеся ограничения → следующий ограниченный шаг. После отчёта **остановка**,
следующий этап только после продолжения пользователем. Даты/процент готовности пока
не оцениваются: физические сценарии и объём адаптаций ещё не измерены.

## Граница завершённого этапа 2

Проверены пустой профиль, обычный гость, владелец, делегирующий гость; нижняя
панель, отмена импорта, push/back и смена корневого раздела. Черновик владельца
не включает Control до появления доступной карточки. UIKit содержимое и панель
разделены соседними областями: прежний внешний safeAreaInset позволял списку
перекрывать область кнопок, что выявили UI-тесты. Кнопки List/Form используют
общий actionListRow против обрезки системой до капсулы.

Навигация подразделов настроек, общий стиль кнопок и выбранные страницы перенесены; полный состав настроек не перенесён. Компактное
представление ActionConfirmation/PIN, полный редактор объектов/картинок и все
остальные пользовательские маршруты не объявлены готовыми. Звуки остаются Н.
Это историческая граница этапа 2. Пользователь затем разрешил продолжение после
извлечения полной структуры; рабочая раскладка и пробелы описаны в [IOS_STRUCTURE.md](IOS_STRUCTURE.md).


## Дополнение: общий каталог объектов, 16.11.2026

По карте всех 62 узлов реализованы scoped ObjectReference, общий смешанный каталог
и постоянные локальные настройки представления. Пункты 01, 21, 22, 25, 26, 29, 40
получили более точную структуру/интеграцию; это не завершает каждый такой сценарий.
Разные server/guest/object identities не объединяются по числовому ID. Скрытие
входящего объекта не отзывает ключ и не удаляет соседей; повторный импорт показывает
объекты снова. Ошибка записи не публикует новое имя, порядок или скрытие.

Bluetooth создаётся через Добавить объект → тип Bluetooth; отдельная строка рядом
с существующими воротами удалена. В карточке управления доступность — круг на аватаре,
тип/источник — отдельная подпись. Webhook нейтрален, неизвестный BLE не зелёный.
Серверы находятся в Системе. Удаление/скрытие использует компактный общий диалог;
полный PIN/ActionConfirmation ещё не перенесён.

Источник приложения `49fb249`, public `069d20b04319cb97c371ba7b91c59f5533db7cd1`,
[CI 43932876115](https://github.com/entrixy/ios-build./actions/runs/43932876115).
Core142/Debug/Release-isolation/native81/capture19 прошли; общий CI failure из-за
инициализации Accessibility до UI-assertions. Изолированная проверка UI7 ещё
ожидается. Все 19 кадров опубликованы с явным статусом ui-tests-pending.
Статусы 50 сценариев оставлены
Р14 / Ч24 / Н12: это категории наличия путей, не процент готовности приложения.
Полные автонастройки/передача/физические проверки не считаются завершёнными.
