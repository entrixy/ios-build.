# Выпуск: подготовленные материалы и внешние зависимости

Рабочий пакет 21.11.2026. Это подготовка, не подтверждение публикации.
Исполненный baseline и новые результаты указываются в CURRENT_STATUS.md.

## Идентификаторы и подпись

`release/identifiers.example.json` содержит только пустые поля. Подтверждённые
значения из Apple Developer сохранить вне Git, затем выполнить:

```sh
python3 scripts/prepare_app_store_release.py \
  --inputs /private/path/registered-identifiers.json
```

Генератор требует `confirmed: true`, Team ID, application identifier prefix,
Bundle ID и App Group; отклоняет лишние поля, управляющие символы и перезапись
существующего результата. Prefix не подменяется Team ID: у старых аккаунтов
они могут различаться. Сертификаты, пароли, p8/p12 и profiles сюда не передавать.

Полученный `.local-checks/AppStore/registered-release/Signing.xcconfig`
подставляется в Xcode build/archive через `-xcconfig`. Один параметр
`ENTRIXY_APP_BUNDLE_ID` задаёт app и вложенный `.widget`; `ENTRIXY_APP_GROUP`
попадает в entitlements и Info.plist обоих продуктов. WidgetCatalog читает
значение из собранного bundle, без запасной жёстко заданной группы.

Зарегистрировать app/widget и общую группу, проверить Push Notifications,
Associated Domains, Access Wi-Fi Information; права подписи должны соответствовать
реальным профилям. CI продолжает использовать provisional IDs и unsigned archive.
Наличие `.xcconfig` не подтверждает регистрацию или выдачу профилей Apple.

После подписания проверить app/widget identifiers, team/prefix, App Group,
aps-environment, associated domains и вложенные profiles в настоящем архиве.
Подготовленный AASA публикуется на entrixy.com только для совпадающей подписанной
версии. Затем проверяются HTTPS без redirect, Apple CDN и реальные ссылки на iPhone.

## Тексты и скриншоты

`release/metadata/ru.json` и `en-US.json`: название, подзаголовок, описание,
promotional text в пределах символьных лимитов. Keywords проверяются по UTF-8:
RU94байта, EN55байт при лимите100. Support URL ведёт прямо к iOS-разделу
руководства с настоящим contact email; marketing/privacy URLs также подготовлены.
Руководство на всех7языках уточняет Keychain/reset и ограничения iOS.
Перед загрузкой указать
фактические версию/build, категорию, владельца/copyright, возрастной рейтинг,
страны и контакт App Review. Не обещать автоматический звонок/отбой в iOS.

В System и Help добавлен прямой общий privacy link; destinations всех7 языков
отвечают HTTPS200. Новый английский UI-case проверяет реальный импорт/отмену,
messages и доступность policy без внешнего browser handoff.

CI `capture_store_assets.py` после успешного полного UI-прохода на том же проверенном симуляторе снимает четыре
оригинальных JPEG непосредственно `simctl`, отдельно от галереи. Проверяются
1179×2556, отсутствие alpha, видимый текст и SHA256. Изображения не обрабатываются.
Это кандидаты с изолированными данными: нужны фактическое завершение CI и
визуальный просмотр. PNG1178×2556 из XCTest не выдавать за Store-format assets.
При загрузке сверить текущую размерную таблицу App Store Connect.

## App Review

Нужны поддерживаемый работающий сервер, безопасный проверочный доступ и
контроллер/видео реальной работы. Нельзя отправлять reviewer произвольный
неработающий ключ или ставить DEBUG-профили в Release. Подготовить приватную
инструкцию: получение ключа → ручное действие/подтверждение → журнал → выдача и
делегирование → пауза/отзыв → backup. Отдельно объяснить системное подтверждение
звонка и ограничения фона, Wi-Fi и Bluetooth. Не использовать реальные ворота
пользователя как открытый публичный демонстрационный объект.

Указание контактов/доступа и видео требует владельца аккаунта и оборудования.
В приложении выполняется вход в уже существующий подтверждённый email-аккаунт
через `pwa_login`; регистрация нового email-аккаунта в iOS отсутствует.
`register_host` создаёт привязку owner-устройства, а не email-аккаунт.
Локальный сброс и unlink не являются удалением сайта/аккаунта. Классификацию
учётной записи и обязательность удаления требуется подтвердить при final App Review:
отсутствие signup в iOS само по себе не доказывает исключение из правил Apple.

## APNs: что уже можно подготовить

Production схема двух новых таблиц `native_push_devices` / `native_push_outbox`
создана 21.11; обе пусты. Provider оставлен отключённым. Никакие существующие
ключи, FCM, очереди и WSS-процессы не менялись. HTTP/2 на сервере доступен.

Далее нужны Apple Team ID/Key ID, разрешённый для APNs private key и точный app
topic. Они хранятся вне docroot/Git; production/sandbox выбираются по токену
подписанной версии. Existing `lib/native_push.php` и отдельно блокируемый
`scripts/native-push-worker.php` не передают Apple ключи или ciphertext сообщений.

После настройки проверить schema и права, один запуск CLI worker, затем
периодический запуск с отдельным lock/log. До credentials не включать provider
и не заявлять реальную доставку. Нужны настоящая регистрация токена, foreground/
background/locked доставка, отозванный ключ, invalid token и повторная регистрация.
Изолированные provider/DB tests не направлять в production DB.

## Оставшиеся программные и аппаратные границы

- Whole-key `native_only`: `w/server.php` проверяет HMAC attest/attest_ts, текущие
  Android GuestConn/GuestSign и iOS GuestCrypto.hello их не передают. iOS теперь
  прекращает одинаковые отклонённые подключения и сохраняет ключи; это не замена
  проверки подлинности. Нельзя встраивать серверный HMAC-secret в приложение
  или считать `client: app` доказательством. App Attest требует зарегистрированного
  App ID и проверки устройства; нужен также совместимый Android-контракт.
-1423 Product keys во всех семи языках: активный UI и известные системные
  результаты переводятся при отображении; протокольные статусы и пользовательские
  имена/сообщения сохраняются. ОС-диалоги зависят от системного языка. Новый
  английский UI-case и три hosted localization cases ожидают Apple runtime.
- Физические BLE pairing/pulse/revocation, камера, звонки/cellular, фон/locked/
  force-quit/reboot, Widget/App Group и Android↔iOS live lifecycle ещё не приняты.
- Используются криптографические алгоритмы и защищённые собственные протоколы.
  Export compliance и возможное исключение определить по реальному выпуску;
  `ITSAppUsesNonExemptEncryption=false` без основания не подставлять.

## Официальные источники

Проверены 21.11.2026:
[privacy details](https://developer.apple.com/app-store/app-privacy-details/),
[privacy manifests](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest),
[App Attest](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity),
[App Review](https://developer.apple.com/app-store/review/guidelines/),
[screenshots](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications),
[metadata limits and Support URL](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information).
