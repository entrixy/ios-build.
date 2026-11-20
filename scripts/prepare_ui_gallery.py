#!/usr/bin/env python3
"""Prepare the existing site's gallery manifest from a complete native UI batch.

This never uploads, edits images or declares visual/full-product acceptance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct

SCREENS = {
    'header-menu': ('Меню Entrixy', 'Система'),
    'guest-call-request': ('Запрос гостя на звонок', 'Гости'),
    'control': ('Управление', 'Объекты'),
    'control-promotion': ('Карточка Entrixy в управлении', 'Объекты'),
    'settings-objects': ('Настройки объектов', 'Объекты'),
    'settings-empty': ('Настройки без объектов', 'Объекты'),
    'add-object-call': ('Добавить объект', 'Объекты'),
    'object-webhook-edit': ('Редактировать вебхук', 'Объекты'),
    'object-rename': ('Название объекта', 'Объекты'),
    'object-hide': ('Скрытие объекта', 'Объекты'),
    'object-avatar': ('Выбор значка', 'Объекты'),
    'automation-owner': ('Автоматика своего объекта', 'Автоматика'),
    'automation-guest': ('Автоматика гостевого объекта', 'Автоматика'),
    'automation-geo': ('Геолокация и радиус', 'Автоматика'),
    'automation-route-map': ('Рисование маршрута', 'Автоматика'),
    'automation-wifi-connect': ('Условие подключения Wi-Fi', 'Автоматика'),
    'automation-wifi-fingerprint': ('Настройки Wi-Fi отпечатка', 'Автоматика'),
    'automation-time-point': ('Время срабатывания', 'Автоматика'),
    'automation-time-interval': ('Интервал расписания', 'Автоматика'),
    'object-camera-settings': ('Параметры камеры', 'Объекты'),
    'object-device-settings': ('Параметры контроллера', 'Объекты'),
    'device-access-parameters': ('Доступ к конфигуратору', 'Объекты'),
    'guest-call-preferences': ('Реакция на запрос гостя', 'Гости'),
    'guest-ble-lifetime': ('Срок Bluetooth-пропуска', 'Гости'),
    'ble-pairing': ('Добавление Bluetooth', 'Объекты'),
    'ble-information': ('Информация Bluetooth', 'Объекты'),
    'device-claim': ('Добавление устройства по QR', 'Объекты'),
    'received-key-delete-confirmation': ('Удаление полученного ключа', 'Ключи'),
    'received-key-detail': ('Полученный ключ', 'Ключи'),
    'add-key': ('Добавление ключа', 'Ключи'),
    'key-accepted': ('Приветствие владельца', 'Ключи'),
    'guests-owner': ('Гости', 'Гости'),
    'guest-issue-object': ('Объекты гостевого ключа', 'Гости'),
    'guest-access-limits': ('Права гостя', 'Гости'),
    'guest-issued-actions': ('Действия с выданным ключом', 'Гости'),
    'guest-issued-edit': ('Изменение выданного ключа', 'Гости'),
    'guest-issued-qr': ('QR выданного ключа', 'Гости'),
    'guest-revoke-confirmation': ('Подтверждение отзыва ключа', 'Гости'),
    'guest-presets': ('Пресеты прав', 'Гости'),
    'guest-companies': ('Компании', 'Гости'),
    'guests-delegating': ('Переданные доступы', 'Передача'),
    'access-pass': ('Передача доступа', 'Передача'),
    'passed-access-limits': ('Права при передаче', 'Передача'),
    'message-incoming': ('Входящее сообщение владельца', 'Гости'),
    'message-compose': ('Сообщение гостю', 'Гости'),
    'action-confirmation': ('Подтверждение действия', 'Защита'),
    'action-code-setup': ('Код подтверждения', 'Защита'),
    'entry-code-rejected': ('Проверка кода входа', 'Защита'),
    'journal': ('Журнал', 'Система'),
    'system': ('Настройки системы', 'Система'),
    'sounds': ('Звуки', 'Система'),
    'backup-password': ('Пароль резервной копии', 'Система'),
    'home-network': ('Домашняя сеть', 'Система'),
    'server-account': ('Учётная запись сервера', 'Система'),
    'crash-consent': ('Разрешение диагностики', 'Система'),
    'diagnostic-settings': ('Настройки диагностики', 'Система'),
    'developer-report': ('Технический журнал', 'Система'),
    'help': ('Помощь', 'Система'),
}


def prepare(directory, *, source_sha):
    directory = Path(directory)
    report = json.loads((directory / 'review.json').read_text())
    if not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('An exact source SHA is required')
    if (report.get('kind') != 'native-ui-checkpoints' or report.get('source_sha') != source_sha
            or report.get('tests_succeeded') is not True or report.get('complete') is not True
            or report.get('missing_states')):
        raise ValueError('Only a complete successful exact-source UI batch can enter the gallery')
    captures = report.get('captures', [])
    if len(captures) != len(SCREENS) or {row.get('screen') for row in captures} != set(SCREENS):
        raise ValueError('The gallery needs one frame for every named state, without duplicates')
    records = []
    for screen, (title, group) in SCREENS.items():
        row = next(row for row in captures if row['screen'] == screen)
        name = row['file']
        if (name != f'iphone16-light-{screen}-{source_sha[:7]}.png'
                or row.get('source_sha') != source_sha or row.get('native_xctest') is not True
                or row.get('device') != 'iphone16' or row.get('appearance') != 'light'
                or not row.get('test_identifier')):
            raise ValueError('Unexpected native screenshot provenance')
        data = (directory / name).read_bytes()
        if (data[:8] != b'\x89PNG\r\n\x1a\n' or data[12:16] != b'IHDR'
                or hashlib.sha256(data).hexdigest() != row.get('sha256')
                or struct.unpack('>II', data[16:24]) != (row['width'], row['height'])):
            raise ValueError('Screenshot changed after native export')
        records.append({**row, 'title': title, 'group': group, 'theme': row['appearance']})
    manifest = {**report, 'kind': 'native-ui-review', 'review_scope': 'functional-ui-checkpoints',
                'functional_verification': 'ui-tests-passed', 'visual_review': 'pending',
                'full_android_parity': 'pending', 'captures': records}
    (directory / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--source-sha', required=True)
    args = parser.parse_args()
    manifest = prepare(args.directory, source_sha=args.source_sha)
    print(f"Prepared {len(manifest['captures'])} original frames; visual review is pending; nothing uploaded")
