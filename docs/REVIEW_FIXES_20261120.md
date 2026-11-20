# Пакет замечаний к487b2f6 — 20.11.2026

Пользователь разрешил реализацию всех десяти пунктов после обсуждения.

| № | Изменение |
| --- | --- |
| 1 | Исходный анимированный круглый логотип открывает язык/помощь/сайт; root-дубли убраны. |
| 2 | Общий EqualActionRow измеряет однострочную ширину и переводит всю группу в полный столбец при нехватке места. UIKit consent использует то же правило. |
| 3 | Две широкие GEO-кнопки имеют фиксированные колонки иконки/текста и левое выравнивание переносов. |
| 4 | Owner/guest иконки объектов получили общую светло-серую рамку. Исходные изображения сохранены. |
| 5 | CatalogObject использует локализованный source_mine «Мой», как Android. |
| 6 | У каждого объекта сразу виден drag handle. Перестановка через собственный NSItemProvider только внутри процесса сохраняется в существующем порядке и применяется к обоим корням. Добавлены VoiceOver move-up/down. EditButton убран. |
| 7 | Исходный AutoMode заменяет похожие на refresh SF Symbols; заголовок редактора и действие снова одной строкой, без системного круглого toolbar-оформления. Обе Android точки входа сохранены. |
| 8 | Действия выданного ключа — отдельные48pt квадратные кнопки со светлой подложкой; адаптивная сетка сохраняет читаемый размер. |
| 9 | Собственный звук выбирается кнопкой с исходным Android UploadFile. |
| 10 | Все guest phone requests, включая сохранённые auto/notify, требуют явного «Позвонить». Нет таймера автопередачи в Phone. Deadline60s, отмена/сбой связи/фон/актуальные права/занятость/проверка после await; повторный tap не повторяет handoff. Уведомление только сообщает о запросе и ведёт в приложение. |

## Проверки этого source

Локально: frontend parse App/Widget/hosted/UI, diff check, шесть capture-pipeline
контрактов прошли. Ядро не менялось: повторный Linux core-прогон не нужен.
Следующий общий Apple пакет ожидает312core/197hosted/29UI/58оригинальныхPNG.
Две новые контрольные точки — меню логотипа и production-диалог запроса гостя
после проверки подписанного offline fixture frame. Стенд не вызывает реальные
API/телефонию. Source есть; SDK/runtime/визуальная приёмка пока ожидаются.
Новый набор публикуется только после полного успеха и просмотра оригиналов.

Телефонные тесты подменяют dialer: они проверяют правильность допуска и статусов,
а не сотовый вызов. Signed archive, реальный iPhone, SIM, фон/permissions, live
Android/server interoperability и Store acceptance всё ещё требуют своих проверок.
Действия серверных/локальных webhook и BLE не превращены в ручные телефонные.
Android call preferences сохраняются в совместимом формате; это не обещание
Android автодозвона на iOS. Открытие tel: требует подтверждения пользователя:
[Apple Phone Links](https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/PhoneLinks/PhoneLinks.html).

## Происхождение двух значков

AutoMode и UploadFile взяты из exact Android build dependency
androidx.compose.material.icons.outlined. Их PathBuilder commands извлечены из
AndroidX classpath и записаны как SVG без изменения геометрии. Это Material
Design icons под Apache2.0; лицензия уже сохранена в ThirdParty/material-design-icons/LICENSE
и App/Resources/MaterialIcons-LICENSE.txt. Архив зависимости не коммитится.
Dependency classes.jar SHA256: 2baa76b246bef86b8c8f2f754fe3f08280222edfe16e1534fc21e0654a443c39
