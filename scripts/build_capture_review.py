#!/usr/bin/env python3
"""Build a local review sheet only from complete, exact-source simulator captures."""
import argparse
import hashlib
import html
import json
import re
from pathlib import Path

TITLES = {
    'control': 'Управление', 'settings': 'Настройки', 'key-detail': 'Полученный ключ',
    'add-key': 'Добавить ключ', 'guests': 'Гости',
    'confirm-open': 'Подтверждение открытия', 'confirm-close': 'Подтверждение закрытия',
    'code-setup': 'Создание кода', 'code-entry': 'Ввод кода', 'code-rejected': 'Неверный код',
    'biometric': 'Выбор авторизации', 'request-sent': 'Ожидание ответа', 'result': 'Ответ тестового контроллера',
    'journal': 'Журнал выполненной тестовой попытки', 'offline': 'Контроллер недоступен',
    'owner-form': 'Добавить свой сервер', 'owner-ready': 'Сервер зарегистрирован',
    'owner-uncertain': 'Потерян ответ регистрации', 'owner-offline': 'Ошибка синхронизации',
    'object-form': 'Добавить объект', 'object-created': 'Объект создан', 'object-edit': 'Изменить название',
    'object-renamed': 'Название изменено', 'object-delete-confirm': 'Подтверждение удаления',
    'object-deleted': 'Объект удалён', 'object-uncertain': 'Потерян ответ создания объекта',
    'issue-form': 'Выдать гостевой ключ', 'issued-key': 'Ключ выдан — QR и ссылка', 'issued-list': 'Выданные ключи',
    'issued-paused': 'Доступ приостановлен', 'issued-revoked': 'Ключ отозван', 'issued-uncertain': 'Потерян ответ выдачи',
    'issued-revoke-confirm': 'Подтверждение отзыва ключа',
    'owner-confirm': 'Подтверждение команды владельца', 'owner-sending': 'Владелец ожидает ответ',
    'owner-result': 'Ответ на команду владельца', 'owner-journal': 'Журнал команды владельца',
    'owner-guest-request': 'Подписанный запрос гостя на звонок',
    'ble-revoke-pending': 'Отзыв ждёт доставки контроллеру', 'ble-revoke-applied': 'Контроллер подтвердил отзыв',
    'ble-revoke-stale': 'Точный статус отзыва не подтверждён', 'ble-renewed': 'Bluetooth-пропуск обновлён',
    'ble-guest-confirm': 'Подтверждение гостевого Bluetooth-импульса', 'ble-guest-result': 'Гостевая BLE-команда принята',
    'ble-guest-expired': 'Bluetooth-пропуск истёк', 'ble-guest-unknown': 'Ответ гостевой BLE-команды потерян',
    'ble-guest-journal': 'Журнал гостевого BLE-действия',
    'ble-owner-confirm': 'Подтверждение Bluetooth-импульса', 'ble-owner-result': 'Контроллер принял импульс',
    'ble-owner-unknown': 'Результат импульса неизвестен', 'ble-owner-journal': 'Журнал Bluetooth-попытки',
    'ble-scan': 'Поиск Bluetooth-контроллера', 'ble-uncertain': 'Потеря ответа при привязке',
    'ble-paired': 'Привязка подтверждена подписью', 'ble-registered': 'Bluetooth-объект добавлен',
    'additional-parts': 'Новая часть принятой передачи',
    'message-inbox': 'Расшифрованное входящее сообщение', 'message-read': 'Чтение сообщения',
    'message-corrupt': 'Повреждённое сообщение отклонено', 'message-compose': 'Написать сообщение',
    'message-sent': 'Сообщение принято сервером',
    'sender-form': 'Гость выбирает объекты передачи', 'sender-link': 'Ссылка передачи создана',
    'sender-uncertain': 'Потерян ответ создания ссылки', 'sender-vouched': 'Получатель проверен, ожидает владельца',
    'sender-revoked': 'Гость отозвал переданный доступ', 'sender-edit-form': 'Правка объектов передачи',
    'sender-edited': 'Изменение объектов подтверждено',
    'delegated-awaiting': 'Владелец проверил поручительство', 'delegated-ready': 'Связка получателя подтверждена',
    'delegated-uncertain': 'Потерян ответ передачи связки', 'delegated-revoked': 'Переданный доступ отозван',
    'delegated-untrusted': 'Непроверенное поручительство отклонено',
    'delegation-preview': 'Проверка переданного доступа', 'delegation-waiting': 'Ожидание подтверждения владельца',
    'delegation-ready': 'Переданный ключ сохранён', 'delegation-rejected': 'Ошибка проверки передачи',
    'backup-form': 'Резервная копия', 'backup-export': 'Зашифрованный файл готов',
    'backup-preview': 'Копия проверена до переноса', 'backup-restored': 'Перенос завершён',
    'backup-rejected': 'Неверный пароль копии', 'backup-interrupted': 'Перенос прерван — доступно продолжение',
    'issued-access-form': 'Права передачи по объектам',
    'issued-edit-form': 'Изменить выданный ключ', 'issued-edit-result': 'Изменение ключа подтверждено',
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--source-sha', required=True)
    parser.add_argument('--comparison-matrix', action='store_true')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9a-f]{40}', args.source_sha):
        raise RuntimeError('Expected an exact source SHA')
    rows = json.loads((args.directory / 'manifest.json').read_text())
    phones = ['iphone11', 'iphone16'] if args.comparison_matrix else ['iphone16']
    themes = ['light', 'dark'] if args.comparison_matrix else ['light']
    required = {(screen, phone, theme) for screen in TITLES for phone in phones for theme in themes}
    observed, files, records = set(), set(), []
    for row in rows:
        key = (row['screen'], row['device'], row['appearance'])
        name = row['file']
        if key in observed or key not in required or name in files or Path(name).name != name or not name.endswith('.png'):
            raise RuntimeError('Unexpected or duplicate capture')
        if row.get('source_sha') != args.source_sha or not row.get('software_controller') or not row.get('visible_text_verified'):
            raise RuntimeError('Capture does not belong to this isolated source build')
        data = (args.directory / name).read_bytes()
        if not data.startswith(b'\x89PNG\r\n\x1a\n'):
            raise RuntimeError('Capture PNG is missing or invalid')
        observed.add(key)
        files.add(name)
        records.append({**row, 'sha256': hashlib.sha256(data).hexdigest()})
    if observed != required:
        raise RuntimeError('Incomplete capture matrix: missing ' + str(len(required - observed)) + ' screenshots')
    esc = html.escape
    parts = ['<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">',
             '<title>Entrixy — проверка всех этапов</title>',
             '<style>body{font:16px system-ui;margin:24px;color:#1b1d3b;background:#f6f7fa}section{margin:32px 0}h1{font-size:26px}h2{font-size:20px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:16px}figure{margin:0;padding:12px;background:white;border-radius:16px}img{width:100%;height:auto}figcaption{margin-bottom:8px}code{overflow-wrap:anywhere}</style>',
             '<h1>Entrixy — все реализованные этапы</h1>',
             '<p>Тестовый стенд без оборудования. Визуальная проверка: ожидается. Скриншоты не подтверждают физическое открытие, Face ID или работу в фоне.</p>',
             '<p>Сборка: <code>' + esc(args.source_sha) + '</code>. Кадров: ' + str(len(rows)) + '.</p>']
    for screen, title in TITLES.items():
        parts.append('<section><h2>' + esc(title) + '</h2><div class="grid">')
        for row in sorted((r for r in records if r['screen'] == screen), key=lambda r: (r['device'], r['appearance'])):
            name = esc(row['file'], quote=True)
            label = esc(row['device'] + ' · ' + ('светлая тема' if row['appearance'] == 'light' else 'тёмная тема'))
            parts.append('<figure><figcaption>' + label + '</figcaption><a href="' + name + '"><img loading="lazy" src="' + name + '" alt="' + esc(title, quote=True) + '"></a></figure>')
        parts.append('</div></section>')
    parts.append('</html>')
    (args.directory / 'index.html').write_text('\n'.join(parts))
    (args.directory / 'review.json').write_text(json.dumps({'source_sha': args.source_sha, 'visual_review': 'pending', 'captures': records}, indent=2) + '\n')
    print('Prepared review sheet for', len(records), 'actual screenshots; visual review remains pending')


if __name__ == '__main__':
    main()
