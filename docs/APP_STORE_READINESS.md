# Entrixy: путь к App Store

После ревью настроек объектов извлечена [структура Android](ANDROID_STRUCTURE.md)
и составлена [карта iOS](IOS_STRUCTURE.md) по всем 62 узлам. Реализован общий
каталог с независимыми server/guest/object scope, порядком, раскрытием действий,
локальным именем/скрытием и добавлением Bluetooth через выбор типа.

## Текущее задание — полный перенос, 17.11.2026

Действующее указание пользователя — доделать приложение по рабочему Android,
затем снять и проверить весь набор нативных экранов и обновить галерею. Прежние
ограничения «этап 2» и остановки после отдельной вертикали относятся к истории;
они не ограничивают текущую разрешённую работу. Полный результат ещё не готов.
Актуальные функциональные границы и проверки — [FUNCTIONAL_PORT.md](FUNCTIONAL_PORT.md).

Последний общий Apple-прогон: native `98d4676`, public `3b806d7`,
[CI44477923156](https://github.com/entrixy/ios-build./actions/runs/44477923156):
295core, Debug с motion/native UIKit hosts/WidgetKit/test bundles,
Release/privacy/isolation и179hosted без ошибок. UI25:24прошли, включая новую
очередь сообщений/Close и локальное удаление ключа. Диагностика снова timeout
accessibility query. Отдельный modal host НЕ устранил ошибку. Общий результат —
failure.40/44 оригинальных PNG экспортированы, четыре состояния диагностики не
достигнуты; новая галерея не опубликована/не принята.

Следующий source сохраняет тексты/actions/readiness/тестовые assertions согласия,
но внутри панели использует UIKit labels/buttons и явный порядок доступности;
дизайн, геометрия, размеры/цвет/нажатие кнопок используют общие DesignMetrics.
Также включены стабильный момент снимка, завершение общих fixed footers и
двухрядный footer резервной копии вместо переноса слова в тесном ряду. Apple SDK/
runtime/новые точные пиксели этих followups пока pending. Counts179hosted/25UI/44PNG
не меняются. Галерея отклоняет incomplete/failed report и проверяет source/hash.

Ограниченная фоновая BLE/свои local webhook, обычные entry/manual guards, UIKit
очередь сообщений, frozen GPS/Core Motion и четыре widget lifecycle cases имеют
свою проверочную базу; физическая проверка их поведения остаётся отдельно.
PIN/confirm BLE ручной; коалесцирование рекламы не означает выход. SIM-call,
постоянный WSS/APNs в фоне не заявлены реализованными. Полный App Store результат
ещё не готов.

Для следующего source-пакета добавлен unsigned Release archive с iphoneos SDK
(приложение + виджет). Проверяются не только arm64, но и физическая iOS platform
в Mach-O, privacy manifests, fixture isolation и отсутствие provisioning/signatures.
Это исходник CI, ещё не результат сборки архива. Сам архив/IPA не публикуется;
сохраняются лог и metadata с upload_ready=false. Подпись, устройство, TestFlight
и App Store остаются отдельными неподтверждёнными шагами.

App Group `group.com.entrixy.ios` и окончательные Bundle IDs должны быть настроены
в Apple Developer team перед device signing. Подпись/профили не настроены.
На сайте остаются19 прежних кадров069; новые рабочие PNG будут взяты из UI-прогона.
Полная сверка Android, OS/background/BLE/камера на устройстве, реальный account login,
TestFlight, метаданные и App Store не завершены. Съёмка32 текущих сценариев не равна
покрытию всех62 Android-узлов; незакрытые узлы отмечены в IOS_STRUCTURE.md.

## Историческая проверка объектов — 16.11.2026

App `49fb249`, native checkpoint `2dc2f7c`, public
`069d20b04319cb97c371ba7b91c59f5533db7cd1`.
[Основной CI](https://github.com/entrixy/ios-build./actions/runs/43932876115):
142 core, Debug, Release/isolation, 81 hosted native без ошибок, capture19 прошли.
Общий статус **failure**: UI runner не загрузил Accessibility, семь UI-тестов
в этом запуске не начинались. [Отдельная UI-проверка](https://github.com/entrixy/ios-build./actions/runs/43941617579)
выполняется; код приложения/сборки/тестовых утверждений идентичен.

[Галерея](https://entrixy.com/ios-design.php) заменена на 19 настоящих кадров
SwiftUI, iPhone 16 light. Vision/source/hash и визуальный просмотр выполнены;
проверены публичные HTTPS-хеши всех 19 и управление галереей на desktop/mobile.
Это публикация проверенных изображений со статусом UI-tests-pending, **не**
утверждение об успешном общем CI или завершении функциональной приёмки.

Автонастройки своего/выданного/полученного объекта, полные редакторы типов,
передача/компании, камера/своя картинка и остальные пробелы отмечены в карте.
Существующая защищённая выдача/делегирование не объявлены отсутствующими.
Физический iPhone/BLE/сервер, фон, signing/TestFlight/App Store не подтверждены.
На этом историческом этапе работа ограничивалась каталогом. Теперь действует
полный перенос. Основной образец — полный Android `/home/folder/android/dialer`.

## Предыдущая проверенная точка — этап 2

Public `1eedb9196115ce6d577c834dff9261a9ee9ddc6b`, original app `f87de20`.
[Apple CI 43869510705](https://github.com/entrixy/ios-build./actions/runs/43869510705) прошёл все пять групп:
137 core, Debug, Release/isolation, 77 hosted native + 4 UI, capture13.

Рабочий RootView: постоянная плоская нижняя панель в отдельной области от
NavigationStack, условные Control/Guests, общие кнопки; Settings разделён на
Объекты / Ключи / Звуки / Система. Проверены четыре профиля, черновик объекта,
реальные переключения, push/back, отмена формы. Защита действий и wire protocol
сохранены; incomingDepth — подсказка видимости, не разрешение передачи.

На этом предыдущем checkpoint [галерея](https://entrixy.com/ios-design.php) была заменена на 13 настоящих рабочих
SwiftUI-маршрутов с изолированными профилями, iPhone16 light. Все кадры Vision +
source/hash + визуальный просмотр. Это не полный набор пользовательских сценариев
и не проверка физического iPhone/контроллера. App archive остаётся simulator-only.

Полного приложения для App Store пока нет. ActionConfirmation/PIN ещё в прежнем
sheet; полный редактор объектов/своих картинок, оставшиеся права/миграция,
автоматизация/фон, звуки/языки/справка и release/device проверки продолжаются по
[актуальной карте 50 сценариев](ANDROID_IOS_PARITY.md). Звуки не имитируются.
Это было ограничением прежнего этапа; пользователь затем разрешил полный перенос.

## История проверок до этапа 2

Ниже сохранены прежние отчёты. Их слова «сейчас», номера кадров и источники —
исторические; актуальная публикация и исполнение указаны выше.

## Каталог после уточнения 16.11.2026

Сейчас опубликованы 12 настоящих кадров нативного каталога из public7ff99ed /
run43818443994: одна общая плоская нижняя панель, без надписи утверждения.
Проверено сохранение панели на вложенной странице ключа. Apple core136/native74,
Debug/Release/isolation/capture12 прошли. Предыдущие наборы ниже — история.
Полной готовности приложения к App Store по-прежнему нет.

## Текущее состояние галереи — 15.11.2026

Набор f1d70fd ниже — история: пользователь его отклонил, кадры сняты.
HTML-макет также снят. Сейчас https://entrixy.com/ios-design.php показывает
11 реальных кадров нативного SwiftUI-каталога из e188026 / run43728332897.
Общее направление принято с поправкой нижней навигации; поправка внесена
и проверена на снимке. Рабочие экраны приложения по новому каталогу ещё не
переделаны; это не готовность к App Store.

## Актуальная проверка 15.11.2026

Старые 86 PNG сняты с сайта по просьбе пользователя; ссылки `*-afc6942.png`
возвращают 404, набор сохранён приватно. Сейчас опубликованы новые 90 PNG
из f1d70fd. Описания прежних публикаций ниже сохранены как история.

Проверенный и опубликованный источник — public
`f1d70fd6518bdc08513c6a4736b11a2fba1496b4`,
https://github.com/entrixy/ios-build./actions/runs/43694107747.
Apple core136/native74, Debug, Release/isolation и capture90 прошли.
Получены 90 настоящих кадров iPhone16 light; каждый прошёл macOS Vision.
Просмотрены все восемь обзорных листов и крупные кадры управления, offline,
журнала, настройки объекта, PIN/keyboard, owner confirmation и входа по коду.
17 форм прошли проверку нижней отмены. Карточки без добавленных командных
кнопок, offline без модального отказа, журнал без общей белой подложки.

Набор опубликован в https://entrixy.com/upload.php; имена содержат f1d70fd.
Старые кадры сняты, исходные PNG нового набора не ретушировались.
Длинные страницы сняты в одном viewport, ниже есть прокрутка; это не проверка
всех возможных полей, анимации или оборудования. Face ID, физический BLE,
системная приватность на реальном устройстве и оставшиеся функциональные
пробелы ещё требуют работы. Полной готовности к App Store нет.

Предыдущий e72eaec / run43690203221 прошёл Apple core134/native72,
Debug и Release/isolation. Захват остановился на OCR цифры 0 клавиатуры;
другие требуемые цифры распознаны. Проверка требует шесть отдельных цифр
без нестабильно распознаваемого 0; снимок ошибки теперь сохраняется отдельно.
Набор e72 не опубликован. Все остальные функциональные пробелы остаются
в ANDROID_IOS_PARITY.md.
Исторические записи ниже описывают состояние на дату каждого этапа.
Последний завершённый Apple CI: публичный `b0f1fb3fa61fd8ec65f7c4b2c8bd97b00486d12c`,
https://github.com/entrixy/ios-build./actions/runs/43642946966 — 130 core tests,
68 hosted native tests, Debug и Release/isolation прошли. Получены 86 настоящих
снимков iPhone 16 light; каждый прошёл проверку текста macOS Vision.
Визуальный просмотр всех 86 отверг набор: подпись стенда перекрывает нижние вкладки.
Эти кадры не опубликованы. PIN и нижние кнопки отмены уже читаются правильно.

Исправление рамки тестового стенда: original `ea39cc9`, public
`afc694232f66a241799a6cd14a6a31cc495b5917`;
https://github.com/entrixy/ios-build./actions/runs/43647935127 — все пять проверок
прошли. Просмотрены все 86 кадров, главный экран и добавление ключа также в полном
размере: вкладки видны, подпись отделена от интерфейса, в формах нет логотипа,
кнопки отмены снизу. OCR проверил 15 форм, заголовок PIN и действие на карточке.
Статический PNG не подтверждает анимацию логотипа или работу оборудования.

Все 86 новых кадров опубликованы в https://entrixy.com/upload.php, по одному
светлому iPhone 16 на состояние. Имена содержат `afc6942` для обхода старого кеша;
предыдущий набор сохранён приватно. Проверки галереи: поиск, стрелки, Escape и
возврат фокуса, увеличение, мобильный свайп, отсутствие переполнения и JS ошибок.
HTTPS-хеши главных кадров совпадают с проверенными локальными PNG.

Приложение пока не готово к App Store: остаются функциональные пробелы полного
Android-порта, проверки реальных Bluetooth-контроллеров и устройств, Apple signing,
метаданные и review. Успешные simulator tests не заменяют эти проверки.

## Проверенный baseline

- Реально проверенный manual guest milestone: `2a91220`, macOS CI
  https://github.com/entrixy/ios/actions/runs/41304975510 — 26 core + 9 hosted tests,
  simulator app build, по шесть главных экранов iPhone 11 и 16.
- Текущий код перед этим документом: `412fdab` (исправление позиции тестовой плашки).
  После fetch origin/ci-results содержит report/result.json для `b8289c3`, success,
  https://github.com/entrixy/ios/actions/runs/41315688132 . Это НЕ подтверждение412fdab.
- b8289c3: 20 новых кадров тестовых действий, визуальная проверка отвергла размещение
  плашки. Нельзя снова выдавать их за исправленные/новые снимки. Release build должен
  исключать DEBUG simulator fixture, баннер и bootstrap. Живой ключ не нужен для
  изолированного software controller; не включать старые preview-grant для этих кадров.
- Guest: import/QR/photo, Keychain, bind, signed HTTPS/WSS, decrypted objects/avatar,
  manual signed command, PIN/biometry, actual attempt/result journal. Физическое
  открытие/Face ID НЕ проверены. Unsupported policy blocks remain intentional.

## Продолжение 12.11.2026

- `d4dad2d`: CI больше не запрашивает живой preview/bootstrap или OIDC для
  изолированных action captures. В exact-SHA отчёте отдельно сохраняются outcomes
  core_tests/debug_build/release_build/native_tests/captures; visual_review остаётся
  pending до просмотра изображений. YAML и embedded Python проверены локально.
- `53aea2c`: добавлен `BundleKeySeal` — Android-совместимые P-256 SPKI/PKCS8,
  ECDH/HKDF-SHA256 и AES-GCM для K_guest. Все 29 core tests прошли на Linux,
  Swift6.0.3 + swift-crypto3.15.1. Независимый fixture Python cryptography дополнительно
  расшифрован Java JCA по алгоритму Android Crypto.kt. Это криптографический
  компонент, не готовый сетевой/UI сценарий delegation.
- Матрица исходников и пробелов: `docs/ANDROID_IOS_PARITY.md`; все названные Android
  source paths проверены. Следующая функциональная вертикаль — owner registration,
  сохранение credentials с явной обработкой потерянного ответа, затем host sync.
- Оба коммита отправлены в origin/main. На последней проверке ci-results всё ещё
  относился к b8289c3; macOS сборка/тесты/20 изображений нового SHA не подтверждены.
  GitHub connector отвечает404 для приватного entrixy/ios; SSH Git работает.
  Не выдавать успешный Linux core run за Xcode/native/device проверку.

## Полное приложение и все этапы — уточнение пользователя

12.11.2026 пользователь прямо потребовал полностью готовое приложение для App Store
и скриншоты всех этапов. Это критерий завершения; отдельный core-компонент/матрица
не считается выполнением задачи. Требуются функциональность, Apple-сборка,
проверки на устройствах, подпись, метаданные и сценарий review.

Продолжение исходников: OwnerAccount/OwnerAPI + Keychain migration + OwnerScreens
реализуют добавление сервера и sync, сохранение reservation до регистрации,
запрет повторной регистрации при потерянном ответе и retry сохранения credentials
без повторного network request. Legacy guest state сохраняется.
На Linux прошли35coretests (6 новых); добавлены5native tests, но здесь исполнить
их нельзя. App/native Swift прошли только syntax parse, НЕ Xcode typecheck/build.

CI переведён на явный Xcode26.3/iOS SDK26+; проверка binary/dylib запрещает попадание
capture/bootstrap кода в Release. Требование Apple проверено12ноября:
https://developer.apple.com/news/upcoming-requirements/?id=04282026a .
Review для аппаратного приложения потребует демонстрацию на физическом устройстве:
https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/ .
Это не подтверждено скриншотами симулятора.

`--all-flows` теперь описывает76реальныхсимуляторныхкадров:19этапов×2модели×2темы.
Покрытие и оставшиеся этапы: `docs/SCREENSHOT_COVERAGE.md`.
Новые кадры пока не получены. ci-results всё ещё b8289c3; доступ через текущий
GitHub connector даёт404. Пользователю заданы pending вопросы о membership,
доступности физического тестирования и состоянии Actions. Не считать это
подтверждённым запуском/сбоем CI без нового отчёта.

## Продолжение: объекты владельца

- Добавлены call/server-webhook/device creation, claim заводского контроллера,
  зашифрованные metadata + wrapped K_obj, переименование с optimistic revision,
  удаление с подтверждением. Каждый шаг сохраняется до network request.
- Потерянный create response восстанавливается по точному randomized data_cipher
  в sync; claim с неизвестным исходом автоматически не повторяется. Definite
  HTTP4xx rejection позволяет явно отменить локальное изменение. Form не остаётся
  повторно отправляемой, когда попытка уже сохранена.
- Переименование сохраняет неизвестные поля metadata. Серверу не отправляются
  label/phone/masterKey/wrappedKey. У server-webhook URL/secret намеренно передаются
  для маршрутизации, о чём сообщает форма. У call нет фонового iOS автодозвона.
- Web source aa51c2d добавляет data_cipher_revision (UNIX epoch) в host_sync, чтобы
  не угадывать timezone строковой даты. Только additive field; php-lint/diffcheck
  прошли, реальные registrations/objects/commands при проверках не создавались.
  Сторонние серверы без поля revision блокируют переименование до обновления API.
- 45 core tests прошли на Linux Swift6.0.3. Добавлены 4 native tests для полного
  claim/create/rename/delete и persistence/lostresponse/storagefailure, включая
  сохранение ответа claim после отказа Keychain без повторного расходования кода; macOS
  execution и Xcode compilation новой UI всё ещё не подтверждены.
- All-flows: 26×2телефона×2темы=104 ожидаемых PNG. Новый exact-source review index
  с checksums строится только после полной реальной съёмки. В capture root добавлен
  published ready, чтобы зависимые routes key-detail/object-edit сменили spinner
  после async подготовки. Не считать синтаксическую проверку доказательством UI.
- Осталось: owner actuation и полный key create/share/revoke/delegation lifecycle,
  backup/recovery, BLE, automation/background, release signing/device QA и store
  package. Задача «полностью готовое приложение + все скриншоты» НЕ завершена.

## Продолжение без остановки: выдача ключей

После замечания пользователя «почему остановился» работа продолжается без нового
запроса на продолжение. Выполненный источник ещё не означает App Store готовность.

- Добавлены OwnerIssuedKey/OwnerGuestScreens: локальная генерация приглашения,
  encrypted bundle (obj keys/templates), key_create, QR/share, pause/resume/revoke.
  В wire идут hash/public key/ciphertext; имя гостя/user_key/K_guest остаются на
  телефоне. Ссылка показывается после sync, проверившего cipher, public key и object set.
- Потерянный create response восстанавливается без regeneration/replay. Ack при
  storage failure хранится в памяти для retry только сохранения. Revoke необратим
  локально даже если позже придёт старый snapshot. История действий не фабрикуется.
- Исправлена ошибка первоначального OwnerObject: phone/webhook secret нельзя класть
  в общий K_obj metadata. Теперь phone owner-only в Keychain, webhook routing secret
  отдельно; новые blobs содержат только общие label/avatar. Выдача K_obj legacy blob
  с приватными полями блокируется до миграции, чтобы гость не получил прямой секрет.
- Socket grants соответствуют Android HMAC/HKDF; независимый Python vector + proof
  проходят. Контроллер без реально provisioned ownerSecret не получает выдуманный
  доступ. Native-only выдача блокируется до правильной iOS attestation; shared app
  secret не встраивался. Server-webhook transport отмечается owner-encrypted template,
  поэтому его гостевая команда не зависит от телефона владельца в сети.
- Все52coretests прошли Linux. Добавлены3native tests issue/share/pause/resume/revoke,
  lost reply/relaunch и failed ack save. Native UI только syntax parse; macOS CI и
  132 ожидаемых PNG (33×2×2) по-прежнему требуют реального нового Apple run.
- После этого этапа следующий блок — прямые owner actions/foreground WSS,
  затем key edit/delegation/rotation/backup, BLE, iOS automation и signed release.

## Продолжение: прямое управление владельца

- OwnerLiveSession/OwnerControlModel дают foreground host_hello connection, bounded
  buffering/heartbeat/reconnect. Reconnect передаёт только hello, никогда команду.
  Wire сверялся с реально используемым `private/ws-go`, не с устаревшим PHP w/server.
- На главном экране свои объекты открываются прямо с карточки с подтверждением.
  Server-webhook отправляется host_self_webhook; device — host_self_call + nonce/HMAC
  owner proof, только при реально сохранённом ownerSecret. Unprovisioned device
  не открывается через незащищённый fallback. Направление frozen при нажатии.
- Attempt записывается до wire, результат — только совпавший call_id/number_id.
  Быстрый ответ до device_sent буферизуется и применяется после correlation;
  unsolicited/silent/guest события не подменяют результат владельца. Timeout,
  background и disconnect не переотправляют actuation. Очистка журнала не рождает
  строку заново. Ошибки без correlation не выдаются за физический результат.
- Локальный звонок передаётся системному tel: только после явного нажатия.
  Journal «Передано приложению Телефон» означает только успешный OS handoff,
  не завершённый звонок/открытие. Подписанные гостевые do_call/confirm_request
  проверяются по invitation key/объекту/серверу/возрасту и текущему scope ключа;
  nonce сохраняется в Keychain до показа UI. Требуется ручное согласие владельца.
- Новые4core tests дают56всего (Linux pass); новые4native tests описывают persistence,
  early response/correlation, background no-replay, durable guest press replay,
  explicit phone handoff. Native выполнение/Xcode build здесь ещё не подтверждены.
- Capture38×2×2=152PNG ожидаются,5новыхowneraction/request этапов. Новых реальных
  кадров по-прежнему нет. Фоновый APNs request delivery, BLE provisioning,
  backup/migration/keyediting/delegation и signed release остаются в работе.

## Продолжение: правка гостевого ключа

- Правка имени/объектов/приветствия сохраняет user_key, K_guest и guest DID;
  ссылка после подтверждения не меняется. Bundle rebuild сохраняет неизвестные
  поля и существующие auth/combined/network условия; подтверждение меняется только
  по отдельному явному выбору. При удалении объекта отфильтровываются его key,
  templates, streams/cams. Существующие per-object access depth/pool не сбрасываются.
- Pending narrowing хранит прежний effective scope до подтверждения exact cipher
  и нового набора в snapshot. Lost reply сверяется без повторного key_edit.
- 59 core tests прошли Linux; добавлен native edit/lost-reply test (не исполнен
  на Apple toolchain). Два новых этапа дают40×2×2=160 ожидаемых PNG, не реальные кадры.
- Auxiliary ci-inspect b7f69ec отправлен с TARGET_SHA dc29c43; проверить свежую
  ci-diagnostics вместо домыслов о причине отсутствия Apple отчёта.

## Продолжение: зашифрованная копия и перенос iPhone → iPhone

- `BackupEnvelope`: контейнер ENTRIXY1 v1, PBKDF2-SHA256/600000, AES-GCM,
  аутентифицированный заголовок и ограничение размера/работы KDF. Независимый
  Python fixture проверяет кириллический пароль. Схема содержимого iOS имеет
  отдельный marker `entrixy-ios` и расширение `.eib`: импорт Android payload пока
  не реализован; совместимость контейнера не равна совместимости всей копии.
- Native export/import/preview/confirmation и durable restore plan в Keychain.
  Identity целевого iPhone сохраняется; source identity нужна только для подписи
  guest move. Все owner dry-run проверяются до первого claim; после каждого
  успешного переноса доступ и checkpoint записываются вместе. Ошибка записи или
  сети оставляет план для явного продолжения после перезапуска.
- Guest move сначала проверяет подпись нового устройства для восстановления
  после потерянного ответа; fallback на старую/base подпись только при bad_key,
  без обхода cooldown. Owner controls/guest sessions при переносе остановлены.
  Импортированные object cards заблокированы до свежего owner sync.
- 64 core tests прошли Linux Swift6.0.3, 0 failures. Добавлены пять native backup
  tests (preflight отказ, storage failure до сети/после claim, частичный перенос
  и relaunch, конфликт master key); они ещё НЕ исполнены на Apple toolchain.
  App/native source проходит только syntax parse, не Xcode/typecheck.
- Capture matrix46×2×2=184 ожидаемых PNG: шесть backup этапов используют реальное
  шифрование и обычный restore flow с изолированным `.invalid` transport. Системный
  Files picker этим не проверяется. Новых реальных PNG по-прежнему не получено.
- На повторной проверке ci-results/ci-diagnostics всё ещё относятся к старому
  b8289c3 от1ноября. Причина отсутствия свежего macOS отчёта не установлена.

## Продолжение: приём переданного ключа

- `DelegationLink`/`DelegationProof` переносят Android pass MAC и подпись поручительства
  (parent invitation key, а не device key), strict HTTPS/group/secret/P-256 validation.
  Независимый Python Ed25519/HMAC fixture. `DelegationTransport` подписывает точные
  bytes и canonical `key_delegate` endpoint при `?a=...`, не отправляет WK/private key.
- `DelegationRedemption`, `DelegationInbox`, нативный импорт paste/QR/photo и экран
  «Ожидаемые ключи»: recipient private keys сохраняются ДО redeem; sent flag ДО
  передачи. Lost reply/relaunch не вызывает новый redeem/новые ключи. Проверка
  привязывает те же сохранённые ключи и открывает key_cipher только своим P-256.
  Чужой key_cipher/подмена bundle отвергаются; activate+checkpoint атомарны.
- Приём совместим с передачами существующих Android клиентов. Создание передачи
  гостем, vouch polling и owner fulfilment на iOS ещё НЕ подключены к UI/жизни
  приложения. Наличие криптографических примитивов не означает полного delegation.
- Ожидающие приватные recipient данные сохраняются в Keychain, но в backup пока
  не включены: экспорт явно блокируется до завершения/явного удаления ожидания.
  Удаление требует подтверждения о возможной невосстановимости, сервер не отзывает.
- 71 core tests / 0 failures на Linux. Три native tests добавлены: durable intent
  до redeem/lostreply+relaunch/no second redeem, savefailure beforewire, activation
  writefailure retaining recipient. Native/Xcode исполнение НЕ подтверждено.
- 50 capture stages ×2phones ×2themes =200 ОЖИДАЕМЫХ PNG. Четыре новых сценария
  используют обычные import/inbox screens с .invalid recording transport. Ни новых
  PNG, ни визуального review текущего исходника ещё нет.

## Продолжение: права передачи по объектам

- `KeyObjectAccess`: explicit owner depth0...5/pool1...50, default0/3, strict
  snapshot types. Create/edit UI позволяет менять каждый выбранный объект;
  правка прав включается отдельно, иначе server settings сохраняются.
- Pending requestedAccess сохраняется до запроса. Exact bundle+object set без
  совпавших settings не подтверждает правку. grantedAccess хранит локальное
  решение владельца: серверный snapshot не расширяет эту authority. Link/DID
  не меняются; tightening предупреждает об отзыве доступа ниже по цепочке.
- 73 core tests прошли Linux; native persistence/lost edit reply test добавлен,
  Apple execution ожидается. Это не реализация owner delegated bundle fulfilment.
- Добавлен issued-access-form:51×2×2=204 ожидаемых PNG; реальных новых кадров нет.

## Продолжение: подтверждение связки владельцем и проверка цепочки

- `OwnerDelegatedKey`/`OwnerAuthorizedGuest`: цепочка до пяти уровней проверяется
  от locally issued root, независимо от порядка snapshot. Vouch накрывает server,
  child ID и обе public keys. Чужие objects, превышение local depth/pool, app-only
  downgrade, cycle и неподписанная подмена recipient не выпускают связку.
- Wrapped K_guest/socket DID/prepared bundle/key_cipher сохраняются до upload.
  После lost reply/relaunch exact cipher+key_cipher+scope подтверждают результат
  без новой выдачи. Upload запускается владельцем с нативного экрана; повтор
  той же metadata после неопределённого ответа требует отдельного действия.
  Объекты при этом не открываются, journal не заполняется служебными событиями.
- Вкладка Гости показывает проверенные передачи, ожидающие/действующие/отозванные
  состояния и непроверенные запросы. Отзыв намерения блокирует leaf/descendants
  локально до wire; подтверждение отзыва не зависит от доступности root.
- Owner phone requests теперь принимают leaf public key только из проверенной
  цепочки и повторно проверяют root/ancestors/scope перед явным tel: handoff.
  Replay nonce ledger и запрет автоматических звонков сохранены.
- 78 core tests проходят Linux Swift6.0.3 (новые пять delegation tests). Добавлен
  native lifecycle/lost reply/relaunch/revoke test, исполнение на Apple ожидается.
  App/native source прошёл только syntax parse, не Xcode/typecheck.
-56 capture stages ×2phones ×2themes =224 ожидаемых PNG; добавлены awaiting/ready/
  lost upload reply/revoked/forged vouch. Реальных свежих PNG и Apple report нет.
- Создание и сопровождение передачи на iOS у гостя (sender create/vouch) ещё
  предстоит; приём и owner fulfilment теперь реализованы в исходниках.

## Продолжение: передача доступа гостем и сохранение получателя

- `PassSnapshot`/`PassedAccess`/`PassManager`: одна ссылка с частями от1...16
  исходных ключей одного сервера; выбор только разрешённых network objects,
  depth/pool в пределах allowance. WK и ciphertext приветствия сохраняются до
  первого create. Lost reply восстанавливается только по единственному новому
  matching invite вне сохранённого baseline; ambiguous ответ не создаёт новую ссылку.
- Нативные список/форма/QR/share/правка объектов/отзыв. Неподтверждённый create
  не повторяется; ack write failure сначала повторяет сохранение. Добавление/
  удаление объектов сохраняет прежние settings существующих объектов. Pending edit
  блокирует share и vouch до exact scope. Отзыв блокирует vouch/link до первого wire.
- Recipient MAC проверяется до parent vouch. Foreground `pass_vouch` и resume
  обновляют состояние; owner `key_delegated`/`bundle_request` запускают read sync.
  Wire сверялся с production Go timers.go, без вызова production endpoints.
- `ReceivedDelegation` сохраняет P-256 recipient pair и code→guestID после
  установки, не хранит вторые копии signing secrets. Дополнительные части не
  регенерируют уже установленные ключи; используется прежний recipient pair.
  Удаление последнего локального ключа очищает эту запись атомарно.
- Sender WK/management records и received encryption pairs включены в защищённую
  backup-схему; конфликты проверяются до moves. После переноса target installation
  identity остаётся своей. Незавершённый recipient redeem пока блокирует export.
- 86 core tests прошли Linux, включая полный sender→recipient→owner→decode путь
  и проверку отсутствия private material в wire. Пять native sender tests и
  расширение receiver lifecycle добавлены, Apple execution по-прежнему не было.
- 63 capture stages ×2phones ×2themes =252 ожидаемых PNG. CI timeout поднят до60
  минут для полной матрицы. Скрипты/Swift syntax проверены; реальных новых PNG нет.
- Peer messaging/foreground receipt UI, автоматическое получение новых частей,
  BLE, automation/background/APNs, Android backup payload и App Store release
  ещё требуют работы. Не выдавать эти исходники за готовую iPhone сборку.

## Продолжение: личные сообщения по ключам

- Root messages используют AES-GCM под K_guest; passed messages — Android
  `sealKey(recipientPub, random32)|AES-GCM(text)` с P-256. Независимый Python
  fixture проверяет оба ciphertext и SHA256prefix24 для message_ack.
- `MessageManager`/нативные inbox/read/compose: ciphertext сначала проверяется и
  сохраняется в Keychain, затем delivered; readAt фиксируется при открытии экрана
  ДО read acknowledgement. Lost ack повторяет только ту же metadata/hash, без
  action journal. Неверный ключ/повреждение/save failure не отправляют ack.
- Outgoing intent/cipher сохраняются до wire. Owner использует message_send,
  передающий — key_delegate?a=message после свежей проверки recipient MAC.
  Ответ ok означает только «Принято сервером». Legacy message_read/delivered events
  не содержат cipher hash: их не приписываем новой отправке без correlation.
- Messages входят в encrypted backup; merge не выбрасывает непрочитанные записи
  молча и проверяется до moves. Удаление guest атомарно убирает его incoming
  ciphertext и recipient reference. Служебные сообщения не становятся журналом
  действий и не запускают открытие/звонок.
- 90 core tests прошли Linux Swift6.0.3. Шесть native message tests добавлены:
  durability/read display, invalidcipher/savefailure/noack, lost ack/relaunch,
  passed recipient proof, backup и owner outgoing uncertainty. Apple execution
  не было; все App/native файлы прошли только syntax parse.
- 68 capture stages ×2phones ×2themes =272 ожидаемых PNG. Пять новых message
  stages: inbox/read task/corrupt/compose/server accepted; read-ack исходит от
  обычного ReadMessageScreen.task. Реальных новых кадров/visual review нет.
- Доставка в фоне через APNs и cipher-correlated sender receipts ещё не готовы.
  Нельзя выдавать HTTP ok или FCM result за доставку на iPhone.

## Продолжение: дополнительные части уже принятой ссылки

- `DelegationRedemption.availableCodes` строго проверяет group/состояния/уникальность
  до генерации новых signing keys. Installed codes исключаются, P-256 recipient
  pair сохраняется; новая часть не переиздаёт существующие guest keys.
- `DelegationInbox` foreground worker: известные принятые ссылки проверяются
  порциями до8 раз в60секунд, pending группы/части проверяются round-robin
  порциями по15секунд. На background и во время migration задача отменяется.
  Unknown redeem не повторяется, storagefailure не отправляет новую выдачу.
- Новый установленный guest получает отдельный read watcher. Existing control
  sessions/attempts не сбрасываются; подтверждённая bind не дублируется при старте
  watcher. Чтение/подключение не создаёт actuation и не пишет journal.
- Inbox показывает принятые передачи с числом частей и ручной проверкой новых.
  Initial redeem теперь пробует получить готовую связку сразу после ответа;
  автоматические проверки повторяют только bind/read того же сохранённого ключа.
- 91 core tests прошли Linux, 2 native additional-parts/storage/background tests
  добавлены (Apple execution нет). App/native syntax parse, Python69titles passed.
-69 stages×2phones×2themes=276 ожидаемых PNG. Новый additional-parts scenario
  проверяет две guest entries, прежний invite и тот же recipient pair. Настоящих
  новых screenshots/Xcode report по-прежнему нет.

## Продолжение: BLE протокол в ядре

- `BLECrypto`/`BLEGuestGrant`/`BLECommandSession` переносят actual Android/ESP32
  X25519/HKDF/HMAC, advertise v1/v2/v3/state, owner/guest FIRE/TIME и signed revoke.
  Пакеты сверены с независимым Python fixture. Owner DID32bit, pairpacket36B.
- Single consume до write, expiry/deadline повторно проверяются; TIME/WIFI/REVOKE
  receipt не становится FIRE result, GATT acknowledgement не считается открытием.
  BLE wire — импульс/переключение, не отдельные open/close команды.
- 98 core tests проходят Linux; CoreBluetooth/native UI и физический контроллер
  этим ещё НЕ проверены и не являются реализованным BLE end-to-end сценарием.

## Что завершить, по порядку

1. Восстановить macOS CI для точного текущего SHA; результат хранить в ci-results,
   отделять build/core/native/captures. Не принимать старый success за новый. Проверить
   всю текущую матрицу276кадра на iPhone11/16; публиковать только просмотренные кадры.
2. Матрица исходников теперь в `docs/ANDROID_IOS_PARITY.md`; обновлять её по мере переноса. Проверить полную Android функциональность: owner setup,
   controller registration, object/key editing, guests/delegation/revocation, sharing,
   backup/migration, multi-server, BLE, Wi-Fi/time/GEO/combined rules. Для каждой строки
   указать Android source → iOS implementation → tests → physical verification.
   Не заполнять пробелы фиктивными UI, успешными ответами или отключёнными проверками.
3. Реализовывать законченными вертикальными сценариями: owner/key lifecycle и
   encrypted metadata; затем sharing/delegation/rotation/revoke и backup/recovery;
   затем CoreBluetooth pairing/command/expiry/revocation с реальным ESP. Сохранить
   wire vectors и запрет повторения неоднозначного физического открытия.
4. Автоматика: отдельно спроектировать CoreLocation/CoreBluetooth/background/APNs.
   Android background SIM calls и непрерывный сервис не копируются буквально.
   Отсутствие iOS API нельзя маскировать разрешением правила по умолчанию. GEO
   matcher переносить только после чтения истории GEO и воспроизведения успешных,
   стационарных, выездных и неудачных проходов; текущий Android10.90 НЕ содержит
   исправления пропущенных подъездов, только убран старый UI countdown.
5. Подписанная device-сборка и TestFlight: получить подтверждённые Team ID и Bundle
   ID, проверить membership/доступ App Store Connect. В старом контексте membership
   отсутствовала — актуальное состояние неизвестно. Не запрашивать Apple пароль/2FA.
   CI secrets: signing identity/profile и scoped App Store Connect API key. Симулятор
   и ad-hoc local simulator signature не являются устанавливаемой IPA.
6. Устройство: iPhone11/16, реальное открытие по согласованному тесту, PIN/FaceID,
   отозванный/истёкший ключ, ротация, фон, offline, поворот экрана/клавиатура,
   процесс умер во время команды, восстановление состояния без новой identity.
7. App Store package: актуальные SDK requirements, version/build, production
   entitlements, permission usage strings, privacy manifest/required-reason APIs
   и SDK manifests по фактическому использованию, privacy policy/support URL,
   точные privacy labels и export-compliance для crypto, screenshot metadata,
   age rating и reviewer scenario. Не ставить encryption exemption наугад.
   Удаление аккаунта реализовать если приложение позволяет его создавать;
   удаление локального гостевого ключа не выдавать за удаление серверного аккаунта.
   Review setup должен проверяемо демонстрировать функции без чужого шлагбаума.

## Готовность к публикации

Для каждого пункта сохранить commit, exact SHA build report, тесты, фактические
ограничения. Подготовка не требует физического Mac у пользователя: macOS CI подходит
для сборок. Для TestFlight/App Store всё равно нужны developer membership и подпись.
Не покупать услуги и не отправлять приложение на review без явного поручения.

## Источники (перепроверять перед отправкой)

- https://developer.apple.com/app-store/review/guidelines/
- https://developer.apple.com/app-store/app-privacy-details/
- https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/
- https://developer.apple.com/news/upcoming-requirements/
- https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background

## Передача опыта «Доброй Тёте»

Пользователь поручил оставить местному Codex подробную инструкцию для iOS.
Проект на ЭТОМ сервере: /home/tyotya/web/bot.tyotya.ru/public_html; не путать с
production87.242.87.150. Handoff: docs/IOS_CODEX_HANDOFF.md в том репозитории.
Flutter приложения — /home/tyotya/projects/dobra_tetya и dobra_tetya_play.
Entrixy SwiftUI не основа для переписывания такси; передаются CI/QA/Keychain lessons,
а бизнес-логика, бренд и bridge берутся из существующей «Доброй Тёти».

## BLE owner source: foreground pair и один импульс

- CoreBluetoothTransport запрашивает Bluetooth только при явном scan/connect.
  Фильтр Entrixy service, ограниченный scan, serial GATT с тайм-аутами, notify через
  setNotifyValue; одна полная withResponse-запись с проверкой maximumWriteValueLength.
  Нет auto-connect/reconnect/retry physical command; закрытое соединение удерживается
  до didDisconnect, чтобы поздний callback не попал в следующую попытку.
- BLEPairingRecord хранит master-wrapped secret и неизменный 36-byte packet ДО write.
  Sent сохраняется перед записью; lostreply допускает только поиск с HMAC и DID,
  не новый pair. Prepared восстанавливается тем же packet только после сравнения
  сохранённого peer public key. Confirmed secret можно добавить на сервер отдельным
  нажатием, обычный exact-cipher recovery исключает повтор number_add.
- BLE-secret отделён от K_obj/shared metadata и серверного request. Pair record
  сохраняется в encrypted iOS backup вместе с owner. Удаление серверного объекта
  не стирает физический pair; confirmed record допускает новое явное добавление.
- BLEOwnerControlModel: действие прямо с карточки, честный pulse/toggle wire intent,
  проверка owner HMAC advertisement+DID, fresh NONCE read, единый atomic protected
  save recent proof ledger (64, больше firmware nonce window16) + journal до FIRE.
  Первый FIRE RESULT принят, TIME/WIFI/REVOKE проигнорированы. GATT ack без RESULT
  остаётся unconfirmed. Background/migration cancel не вызывает повтор.
- Linux Swift6.0.3: **102 core tests /0failures**, включая independent BLE vectors,
  durable pair/lostreply, wrong-DID/signature/secret refusal и secret separation.
  Добавлены 7 native tests для pair/control persistence/refusal/relaunch/cancellation;
  они НЕ исполнены на Apple. App/native Swift прошёл только syntax parse.
- 8 новых capture stages: 77×4=308 ожидаемых PNG. Actual new PNG отсутствуют;
  ci-results всё ещё b8289c3. Exact-source Apple build, hosted tests и физические
  Bluetooth проверки остаются обязательными. Guest BLE/tokens/renew/revoke ещё
  не подключены; выбор BLE при выдаче ключа пока явно заблокирован.

Apple CoreBluetooth references (просмотрены12.11.2026):
https://developer.apple.com/documentation/corebluetooth/cbcentralmanager
https://developer.apple.com/documentation/corebluetooth/cbperipheral/setnotifyvalue(_:for:)
https://developer.apple.com/documentation/corebluetooth/cbperipheral/maximumwritevaluelength(for:)
https://developer.apple.com/documentation/bundleresources/information-property-list/nsbluetoothalwaysusagedescription

## Guest BLE source: offline cache, authentication и expiry

- BLEBundle выпускает Android/ESP32 token7/sig16/gkey32/kstate16; owner secret и
  K_obj в BLE grant не передаются. Обычный edit сохраняет expiry; descendant получает
  свой DID/key/signature с expiry родителя, поэтому owner polling не продлевает TTL.
  Host sync split number_ids/ble_ids проверяется как одно множество доступа.
- GuestBLECache хранит bundle+snapshot в AES-GCM под K_guest внутри Keychain и iOS
  backup. Revision сохраняется при неизменном содержимом, policy-change сбрасывает
  допуск; recent proof ledger и maximum observed epoch не исчезают при refresh.
  Терминальный отказ очищает cache, известная пауза/удаление/background останавливают
  pending BLE. Временный offline допускает работу до подписанного expiry.
- Гостевая карточка использует тот же confirmation/PIN/biometric flow; AppModel
  выдаёт capability только после авторизации. Coordinator напрямую её не обходит.
  Перед единственным FIRE — повторная policy/expiry/cache revision проверка и atomic
  cache proof+journal save. TIME отдельный, fresh nonce после него; TIME отказ не
  создаёт action history и не вызывает FIRE/retry. Legacy ack остаётся unknown.
- GuestObjects устраняет двойную n:/b: карточку для одного BLE row/grant.
- Linux **107 core tests /0failures** (.local-checks/ble-guest-tests.log), включая
  grant edit/renew/descendant expiry, split-ID sync, cache auth/replay/relaunch/bounds,
  expiry/auth/combined restriction gates. Четыре native guest BLE tests добавлены,
  НЕ исполнены на Apple; весь App/native source только syntax parse.
- Ещё5capture stages:82×4=328ожидаемыхPNG, actual new screenshots отсутствуют.
  Owner BLE выдача в UI пока заблокирована до подключения renew/revoke delivery.
  Существующий Android BLE guest grant имеет iOS source path, но совместимость с
  железом нельзя утверждать до физической проверки.

## BLE renewal/revocation source и отличимые подтверждения

- BLERevocation: signed23B, Android signed-Int32 DID на relay wire, возрастающая
  версия, отказ rollback/contradictorysameversion, owner-only publish vs guest request
  в реальном WebSocket validator. Подписанные решения повторно публикуются после
  reconnect (это idempotent maintenance, не opening). Нет claim о server-storage ack.
- Pause/revoke/narrow/delete готовят запреты для известных descendant DIDs в том же
  protected save до API. Fresh sync также ограничивает paused/revoked/unavailable
  leaves. Resume/re-add готовит разрешение только после exact acknowledged scope;
  scoped restore не разрешает другие BLE-объекты. Owner-секрет удалённого объекта
  остаётся в защищённом archive для доставки уже выпущенных отзывов.
- Owner/guest foreground carry до16 решений/connection, bounded deadline, проверка
  latestversion доwrite и durable receipt. 0x40=applied;0x41=equalORnewer, точное
  решение не подтверждает. GATTwriteack/timeout не помечают applied. При отказе
  сохранить receipt физическая команда не отправляется. Maintenance не входит
  в action journal. BLEPermissionsScreen показывает pending/applied/unknown и
  отдельную явную подготовку новой версии после свежей проверки authority.
- Root BLE выдача доступна в source UI; expiry виден; явное продление24h сохраняет
  user_key/K_guest/DID/link/policy. Новый exactcipher+pending сохраняется до upload,
  lostreply восстанавливается readback без ещё одного продления. Offline отзыв
  вступает в силу после доставки контроллеру или истечения токена; UI это сообщает.
- Linux **115 core tests /0failures** (.local-checks/ble-lifecycle-tests.log): signed
  decision/antirollback/receipt semantics, scoped freshack restoration, deletedsecret
  archive, stable renewal, BLE descendant expiry/subtree pause-resume, real WS role
  validators. Дополнительно4native cases про owner/guest carry, receipt-savefailure
  и полный pause/resume/renew-lostreply/revoke/delete добавлены, НЕ исполненыApple.
  App/native source только syntax parse, НЕ Xcode build/typecheck/hardware test.
- Ещё4capture stages:86×4=344ожидаемыхPNG. ActualnewPNG/build всё ещё отсутствуют.
  ДальшеAndroidbackuppayload, полнаяправкаусловий/аватаров, rotation, controller
  provisioning/Wi-Fi, automation/location/APNs и Apple signing/device/review checks.

## Начало Android payload adapter (ещё не native import)

AndroidBackupDocument разбирает typed SharedPreferences export app=entrixy/ver1,
проверяет count/types/size/owner credentials/guest identities/source seed/aliases и
unwrap оригинального K_guest/P256recipient. Original payload bytes сохраняются
целиком; неизвестные preference names не исчезают. Codable сохраняет один original,
а при чтении снова валидирует его, без второй копии всех entries.

GuestSigningIdentity отделяет подпись от ещё не полученного K_guest. GuestAPI
move/recover работает без фиктивного decryption key; new-device recovery →old→base
только bad_key, cooldown/неоднозначный отказ не обходятся. Полученный sealed key
проверяется сохранённым recipient + AES bundle, чужой recipient не вызывает fallback
к старому K_guest. Это основа адаптера; BackupScreen/owner payload translation и
полный Android→iOS migration ещё НЕ подключены.

Linux **120 core tests /0failures** (.local-checks/android-backup-tests.log), включая
typed input/original retention/alias conflict/wrapped recipient, signing-only move,
awaiting-owner recovery/wrongrecipient/cooldown. Новых native runs/PNG нет.

## Android owner material: local translation, native migration pending

AndroidOwnerAdapter сохраняет original master/credentials, host-local aliases,
K_obj/data_cipher, локальный телефон, device socket secret и BLE owner secret/DID.
Два одинаковых server object ID на разных hosts не смешиваются. Существующий
повреждённый ключ не заменяется; новый metadata key допускается только для legacy
записи, где key/cipher никогда не было. Owner key slots (user_key/K_guest/pinned
public/DID) остаются в androidKeys до сверки со свежим owner snapshot. Signed
Android BLE decisions проверяются owner secret; старый GATT-written marker не
выдаётся за controller-applied. Всё это пока local source translation, не готовый
Android import в BackupScreen.

Owner local policies сохраняются отдельно от guest templates. Auth/combined rules
не теряются при переводе; до подключения owner auth UI защищённая owner-команда
блокируется. Парный owner BLE не зависит от server metadata acknowledgement:
секрет/DID позволяют ручной импульс и до number_add ack, без повтора регистрации
или server mutation. Delete intent скрывает такой control.

Linux **123 core tests /0failures** (.local-checks/android-owner-tests.log), включая
multi-server aliases, original secrets/decision retention, damaged-key refusal и
owner policy parsing. Два native refusal/offline-owner tests добавлены; Apple
execution отсутствует. App/native source прошёл только syntax parse.

CI clarification from user: runs#28…#49 действительно FAILED, последний#49=f983daa.
Триггеры работают; свежий ci-results report не публикуется. Ошибка job/Annotations
запрошена; причина пока неизвестна. actionlint1.7.12 не находит ошибок workflow;
первый failed412fdab вообще не менял workflow относительно successfulb8289c3.
До получения ошибки конфигурация CI вслепую не меняется.

## Existing-owner backup merge: data-loss correction

При восстановлении в уже существующую идентичную owner account прежний код пропускал
всю запись владельца, теряя отсутствующие на target объекты/ключи после завершения
плана. OwnerBackupMerge теперь добавляет недостающий protected material и заранее
отказывает при несовместимых ключах, scope, public identities и pending mutations.
Preflight вычисляет merge до любых host_claim. Удалённые объекты и терминально
отозванные ключи не оживают; sent metadata/pairing не становятся unsent; newer BLE
revocations нельзя перекрыть старым pending allow. Source/target master и credentials
не заменяются. In-flight owner snapshots игнорируются при зарезервированном плане,
а owner actions остаются заблокированы до завершения переноса.

Linux127coretests0failures (.local-checks/owner-backup-merge-tests.log),4 новых core
merge cases. Native restore-into-existing-owner case добавлен, Apple execution нет.
App/native syntax parse passed. CI configuration пока не менялась: ждём Annotations
failedrun#49. Изменения послеf983daa сохранены локальными коммитами до диагностики CI.

## Required-reason API manifests — source, device archive pending

App/Resources/PrivacyInfo.xcprivacy declares actual app-local defaults(CA92.1),
monotonic elapsed-time/nonce/entry/wake timers(35F9.1), metadata of private cache/
App Group files(C617.1) and user-selected document/audio/backup files(3B52.1).
Widget/PrivacyInfo.xcprivacy separately declares App Group file metadata(C617.1).
The Release isolation check now requires those manifests in the BUILT app and
embedded widget. XML/plist validation passed locally; Apple packaging is pending.
These are required-API reasons only, not a completed data-collection questionnaire,
a claim of No Data Collected, tracking/privacy-label approval, or export classification.

References checked against current Apple documentation:
https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest
https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
