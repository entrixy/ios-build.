# Фактические потоки данных iOS

Аудит 21.11.2026; публичная политика `https://entrixy.com/privacy` дополнена iOS.
Итоговые ответы App Store Connect сверяются с реально включённым production
сервисом, а не только с наличием manifest в архиве.

| Данные | Путь и получатель | Хранение / declaration |
| --- | --- | --- |
| Email и account ID | OwnerAPI.accountLogin → pwa_login; host_account link/unlink | Существующий подтверждённый аккаунт; пароль/token на iPhone не сохраняются. Email/User ID, app functionality, linked. |
| Owner/guest device binding, APNs token | register_host, signed guest bind; native_push | Device ID/User ID, functionality; привязка может быть связана с аккаунтом. Push не является разрешением управления. |
| Зашифрованные объекты, сообщения, делегирование | OwnerObject/GuestMessageCrypto/PassCrypto; access server | Шифротекст и читаемые routing/status/scope identifiers. В manifest консервативно указаны Other User Content и Emails or Text Messages, functionality/linked; не объявлять всё приложение «No data collected». |
| Server-side webhook | Явно выбранный режим, access server | URL/secret необходимы серверу для выполнения; исключение из утверждения о нечитаемых настройках. Local webhook и камера идут выбранному endpoint. |
| Координаты/Wi-Fi/маршруты/BLE/motion | AutomationSensors/AutomationEditor/NetRoute | Условия проверяются на устройстве; настройки передаются внутри защищённых пакетов. Карта использует Apple MapKit. On-device use не следует автоматически обозначать как upload developer-серверу. |
| Контакт/QR/фото/свой звук | Системный CNContactPicker, камера, PhotosPicker/fileImporter | Получаются явно выбранные номер/имя или файл; полного чтения адресной книги нет. Контакт становится данными объекта; своя картинка может передаваться внутри encrypted object package. |
| Face ID/Touch ID/PIN | LocalActionCode/ActionBiometrics/KeychainStore | Biometric template остаётся у iOS. Device-only credentials; забытый PIN не восстанавливается. Явный локальный reset удаляет доступы и не отзывает remote guests. |
| Crash/manual diagnostics | AppDiagnostics/DiagnosticReport → entrixy.com/api/crash_report.php | Crash требует opt-in, manual — запроса. Allowlist stack/facts/events, без owner credentials/имён/координат/SSID. Crash/Other Diagnostic Data, functionality; payload не содержит account/device ID, но сервер видит IP соединения. |
| Promo install UUID, views/clicks | AppPromotions/PromotionAPI → promo/promo_view/go | UUID отделён от access identity; сервер хранит per-install/date view counts. Tags/lang/version/age выбирают карточку. Device ID/Product Interaction/Advertising Data, first-party marketing/analytics. UUID не считать автоматически анонимным. |
| Сетевой IP/security logs | Hosting/access server | Сетевые сервисы видят адрес; rate limits и operational logs нужно учитывать отдельно. Домашние сетевые ограничения fail closed при неподдерживаемом маршруте. |
| Widget catalog | WidgetPresentationPublisher → собственный App Group | Только presentation data; нет key/phone/webhook/identity/команды. Widget не загружает эти данные на сервер, manifest collection array пуст. |

`NSPrivacyTracking=false`: в native source нет IDFA, third-party ad/analytics SDK
или объединения с чужими наборами для рекламы. First-party promo views остаются
объявленной обработкой; не называть их отсутствием сбора данных.
Email/device identifiers и action metadata обозначены linked. Diagnostic payload
не содержит идентификатора установки; не соединять его с аккаунтами через
серверные наборы без повторного пересмотра declaration.

## Фактическое удаление и retention

- `cron/cleanup_logs.php`: call_log/audit_log и обычные crashes старше30дней;
  offline pending host hints старше7дней. Запущенность cron нужно подтвердить
  операционно, не только наличием source.
- Android manual-logs/hostlogs могут архивироваться без удаления по возрасту.
  iOS diagnostic versions — `ios-crash` / `ios-manual`; они попадают в обычные
  crash records, не в Android auto-hostlog исключение.
- APNs worker: inactive/mismatched/revoked device bindings, inactivity30дней;
  outbox7дней. Provider пока выключен; реальные tokens не регистрировались.
- Promo view endpoint не содержит age-delete; срок автоматического удаления не
  обещан. Hosting logs/backups требуют отдельной операционной сверки.
- LocalStateReset заменяет весь защищённый state одним update, отзывает запись
  у старого model, затем чистит app-only caches/settings/notifications. Durable
  marker требует закончить cleanup после crash; до этого доступ закрыт.
  Ошибка чтения/записи не создаёт новую рабочую identity. Внешние backup-файлы
  не удаляются; удаление приложения само по себе не гарантирует очистку Keychain.

## Перед отправкой

Сверить production processors/retention с этой таблицей, итоговый Xcode privacy
report с manifests и ответы Store с фактически включёнными функциями. Указать
контакт оператора, способы запроса удаления и применимые территории. Публичная
политика описывает и находящийся в разработке iOS; это не знак готовности релиза.

Основание классификации: [Apple privacy details](https://developer.apple.com/app-store/app-privacy-details/)
и [формат manifest](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest).

## Дополнительный исходный код22.11 — активация отдельно

VLCKit декодирует только loopback camera capabilities. HTTP/RTSP-мосты приложения
держат авторизацию на выбранном camera origin; remote URL, password/token не
передаются проигрывателю. Это third-party decoder, не analytics/advertising SDK;
license/source-access notice включён. Реальная камера/сетевая приёмка pending.

Server deletion initiation добавляет подтверждённый запрос scope=device/account,
request ID, host/user ID, время и статус; вDB только hash случайной квитанции.
Пароль/JWT используются временно для нового входа, не пишутся в state/queue.
Локальная квитанция защищена вместе с owner state и может попасть в выбранный
пользователем зашифрованный backup; после local RESET она пропадает, серверная
заявка не отменяется. Receipt-status API не возвращает email, host ID или bearer.
Это app functionality, не tracking. Service disabled: оператор/срок/retention ещё
не утверждены, migration не применялась, реальных заявок/удалений нет. Перед
активацией сверить фактический retention с install/DATA_DELETION.md сайта; нельзя
считать pending удалением или заменить удаление shared account локальным RESET.
