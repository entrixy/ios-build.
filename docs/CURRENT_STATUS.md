# Текущий статус iOS — 19.11.2026

Это краткая текущая сводка. Датированные записи в остальных документах — история.
Задание: полный перенос Android10.90, commit
`56155352b0e9f36ef3685aa071a6aafdb2ef6622`, с утверждённым дизайном, затем App Store.
Порядок работы: [AUTONOMOUS_WORK.md](AUTONOMOUS_WORK.md).

## Активный пакет — 20.11.2026

Пользователь разрешил все10 замечаний после обсуждения. Исходный код и
регрессии подготовлены: [REVIEW_FIXES_20261120.md](REVIEW_FIXES_20261120.md).
Ожидается единый Apple312core/197hosted/29UI/58PNG; новый SDK/runtime/visual пока
не принят. Ниже последний фактически успешный baseline; галерея до успешной
замены остаётся487b2f6. Работа продолжается автономно в разрешённых границах.

## Проверенный baseline

- Native `ec2c81f4b2e4955eeb256f0770520e6cf1114f67` → public
  `487b2f6abedcc36020ed19d54e40381fa1574d62`, branch `ci/review-batch`.
- [Apple CI44521810979](https://github.com/entrixy/ios-build./actions/runs/44521810979),
  job135552057271: **success**. Apple312core,191hosted,27UI — без ошибок.
  Debug/test products, Release/privacy/isolation, APNs environment/семь OS
  локализаций и unsigned physical-iPhone app/widget archive прошли.
- 56из56 уникальных оригинальных XCTest PNG из того же прохода: просмотрены,
  опубликованы в [галерее](https://entrixy.com/ios-design.php). Старые19 сняты
  с сайта с приватной копией. HTTPS-хеши всех56 совпали; desktop/mobile,
  поиск, клавиатура/фокус, zoom и swipe проверены, JS ошибок/overflow не найдено.
- Artifact14532476265 SHA256
  `4c93dbb425a4e96da35466299b499a2d9a82758347feffc63983559bed149177`.
  Device evidence14532926533 SHA256
  `dc77c401ce4c86ddf393fbebb2645452832151d737b9b282f92f091c9449109c`.
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
- Остались legacy строки;939 Product keys в семи языках не означают перевод
  всех пользовательских ветвей. Проверять активные пути, а не число ключей.
- Публичная privacy policy пока Android-oriented. Учесть диагностику,
  promotion install UUID/счётчики, APNs token/retention, location/Maps.
- TeamID/BundleID вопрос ранее задан, ответа нет; provisional IDs не считать
  подтверждёнными. Не переспрашивать на каждом шаге и не придумывать доступы.

## Локальные доказательства

`.local-checks/batch-487-evidence/`: логи, оригинальные screenshots/review.json,
CI verification и private visual-review sheets/report. Website private:
`screenshot-gallery-qa/results.json`, backup `before-native-ui-20261119-132824`.
Public main `069d20b` и private origin не изменялись. Генерируемые файлы,
снимки, конфигурация и секреты в Git не входят.
