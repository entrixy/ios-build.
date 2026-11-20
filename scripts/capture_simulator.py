#!/usr/bin/env python3
"""Capture the actual app on fresh disposable iPhone simulators. No network fixtures."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import shutil
import time

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / '.local-checks/DerivedData/Build/Products/Debug-iphonesimulator/Entrixy.app'
OUTPUT = ROOT / '.local-checks/ci/screenshots'
BUNDLE = 'com.entrixy.ios'
TEXT_TOOL = ROOT / '.local-checks/verify-capture-text'


def run(*args, timeout=90, optional=False):
    try:
        result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired:
        if not optional:
            raise
        print("Optional simulator command timed out: " + " ".join(args[:4]), flush=True)
        return ""
    print(result.stdout, end='', flush=True)
    if result.returncode and not optional:
        raise RuntimeError('Simulator command failed: ' + ' '.join(args[:4]))
    return result.stdout.strip()


def cleanup_device(device):
    run('xcrun', 'simctl', 'shutdown', device, timeout=30, optional=True)
    run('xcrun', 'simctl', 'delete', device, timeout=30, optional=True)


def create_booted_device(model, device_type, runtime, *, appearance=None):
    # Recovery is allowed only before any app scenario or command has started.
    # A stuck CoreSimulator service cannot be repaired by creating another device.
    for attempt in range(2):
        device = None
        try:
            created = run('xcrun', 'simctl', 'create', 'Entrixy preview ' + model, device_type, runtime)
            device = created.splitlines()[-1].strip()
            run('xcrun', 'simctl', 'boot', device)
            run('xcrun', 'simctl', 'bootstatus', device, '-b', timeout=300)
            # A terminal "Finished" status also occurs in healthy runs and does
            # not establish UI readiness. Probe the UI service before any app
            # scenario, inside the same bounded cold-boot recovery boundary.
            if appearance is not None:
                run('xcrun', 'simctl', 'ui', device, 'appearance', appearance, timeout=60)
            return device
        except (RuntimeError, subprocess.TimeoutExpired):
            if device:
                cleanup_device(device)
            if attempt == 1:
                raise
            if os.environ.get('GITHUB_ACTIONS') == 'true':
                # The hosted runner is disposable and exclusively owns this job.
                # Never restart a developer's simulator service on their Mac.
                print('Cold boot stalled; restarting hosted CoreSimulator service before scenarios', flush=True)
                run('killall', '-9', 'com.apple.CoreSimulator.CoreSimulatorService', timeout=15, optional=True)
            else:
                print('Cold simulator preparation stalled; preparing one replacement before scenarios', flush=True)


def prepare_device(model, device_type, runtime):
    device = create_booted_device(model, device_type, runtime)
    try:
        run('xcrun', 'simctl', 'install', device, str(APP), timeout=240)
        container = Path(run('xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data', timeout=120))
        # Cosmetic status setup must not run ahead of the app installation.
        run('xcrun', 'simctl', 'status_bar', device, 'override', '--time', '9:41',
            '--dataNetwork', 'wifi', '--wifiMode', 'active', '--wifiBars', '3',
            '--batteryState', 'charged', '--batteryLevel', '100', timeout=15, optional=True)
        return device, container
    except (RuntimeError, subprocess.TimeoutExpired):
        cleanup_device(device)
        raise


def expected_visible_text(screen):
    if screen == 'app-code-setup': return ['Код и вход', 'Новый код Entrixy', 'Повторите новый код']
    if screen == 'app-code-settings': return ['Код и вход', 'Запрашивать код при входе']
    if screen == 'app-entry-lock': return ['Вход в Entrixy', 'Введите код Entrixy']
    if screen == 'app-entry-rejected': return ['Вход в Entrixy', 'Код не принят']
    if screen == 'control': return ['Управление', 'Настройки', 'Гости', 'Журнал']
    if screen == 'code-setup': return ['Создать', 'Новый PIN-код', 'Повторите PIN-код', 'Отмена']
    if screen == 'code-entry': return ['Подтвердить', 'Отмена', '2', '3', '5', '6', '7', '8']
    if screen == 'code-rejected': return ['Подтвердить', 'Код не принят', 'Отмена']
    if screen == 'biometric': return ['Подтвердить биометрией', 'Отмена']
    if screen == 'offline': return ['Управление', 'Контроллер не в сети']
    if screen in ['confirm-open', 'confirm-close', 'code-entry', 'code-rejected', 'biometric', 'ble-guest-confirm']:
        return ['Подтвердить']
    if screen in ['journal', 'owner-journal', 'ble-owner-journal', 'ble-guest-journal']: return ['Журнал', 'Копировать']
    if screen == 'settings': return ['Настройки', 'Мои серверы', 'Гости', 'Журнал']
    if screen in ['guests', 'issued-list', 'delegated-untrusted']: return ['Гости', 'Настройки', 'Журнал']
    if screen == 'key-detail': return ['Полученный ключ']
    if screen in ['add-key', 'delegation-preview', 'delegation-rejected']: return ['Добавить ключ']
    if screen in ['owner-form']: return ['Добавить сервер']
    if screen in ['owner-ready', 'owner-uncertain', 'owner-offline']: return ['Мои серверы']
    if screen == 'object-form': return ['Добавить объект']
    if screen in ['object-edit', 'object-delete-confirm']: return ['Настройка объекта|Удалить объект']
    if screen.startswith('object-') or screen == 'ble-registered': return ['Мои объекты']
    if screen == 'issue-form': return ['Выдать ключ']
    if screen in ['issued-edit-form', 'issued-access-form']: return ['Изменить ключ']
    if screen.startswith('issued-') or screen == 'ble-renewed': return ['Выданный ключ|Отозвать ключ']
    if screen == 'sender-form': return ['Передать доступ']
    if screen == 'sender-edit-form': return ['Объекты получателя']
    if screen.startswith('sender-'): return ['Переданный ключ|Отозвать доступ']
    if screen.startswith('delegated-'): return ['Переданный доступ|Отозвать доступ']
    if screen.startswith('delegation-') or screen == 'additional-parts': return ['Ожидаемые ключи']
    if screen.startswith('backup-'): return ['Резервная копия|Перенести доступы']
    if screen == 'message-compose': return ['Написать сообщение']
    if screen == 'message-read': return ['Сообщение']
    if screen.startswith('message-'): return ['Сообщения', 'Входящие']
    if screen in ['ble-scan', 'ble-uncertain', 'ble-paired']: return ['контроллер']
    if screen.startswith('ble-revoke-'): return ['доступ']
    if screen == 'owner-confirm': return ['Подтвердить действие', 'Отмена']
    if screen == 'ble-owner-confirm': return ['Подтвердить действие', 'Отмена']
    if screen in ['control', 'request-sent', 'result', 'offline', 'owner-sending',
                  'owner-result', 'owner-guest-request', 'ble-owner-result',
                  'ble-owner-unknown', 'ble-guest-result', 'ble-guest-expired', 'ble-guest-unknown']:
        return ['Управление']
    raise RuntimeError('No visible UI expectation for ' + screen)


def capture_visible_screen(device, path, screen):
    # Only retry a read-only screenshot of the same process. Never relaunch the
    # scenario or repeat a command to work around a slow launch animation.
    deadline = time.monotonic() + 60
    pending = ROOT / '.local-checks/pending-capture.png'
    while True:
        run('xcrun', 'simctl', 'io', device, 'screenshot', str(pending))
        result = subprocess.run([str(TEXT_TOOL), str(pending), *expected_visible_text(screen)],
                                capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            pending.replace(path)
            return
        if result.returncode != 1:
            raise RuntimeError('Could not verify visible UI: ' + result.stderr[-500:])
        if time.monotonic() >= deadline:
            # Preserve the actual rejected PNG for inspection; it is never in the
            # accepted manifest, and a failed run cannot replace the gallery.
            shutil.copyfile(pending, OUTPUT / ('failed-' + screen + '.png'))
            raise RuntimeError('Expected app screen never became visible: ' + screen + ' ' + result.stdout[-300:])
        print('Waiting for visible app UI: ' + screen + ' ' + result.stdout.strip(), flush=True)
        time.sleep(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--action-flows', action='store_true', help='Capture labelled, isolated software-controller scenarios')
    parser.add_argument('--all-flows', action='store_true', help='Capture every implemented UI stage with isolated test transports')
    parser.add_argument('--comparison-matrix', action='store_true', help='Optional device/theme comparison for internal QA')
    options = parser.parse_args()
    actions = options.action_flows or options.all_flows
    if not APP.is_dir():
        raise RuntimeError('The simulator app must be built first')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    run('xcrun', 'swiftc', str(ROOT / 'scripts/verify_capture_text.swift'), '-o', str(TEXT_TOOL), timeout=120)
    runtimes = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'runtimes', '--json']))['runtimes']
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
    available = [r for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier']]
    matching = [r for r in available if r['version'] == sdk or r['version'].startswith(sdk + '.')]
    if not matching:
        raise RuntimeError('No installed iOS simulator runtime matching SDK ' + sdk)
    runtime = matching[0]['identifier']
    manifest = []
    devices = [('iphone16', 'com.apple.CoreSimulator.SimDeviceType.iPhone-16')]
    if options.comparison_matrix:
        devices.append(('iphone11', 'com.apple.CoreSimulator.SimDeviceType.iPhone-11'))
    for model, device_type in devices:
        device, container = prepare_device(model, device_type, runtime)
        try:
            bootstrap = Path(os.environ.get('RUNNER_TEMP', '/tmp')) / 'preview-bootstrap.json'
            if bootstrap.is_file() and not actions:
                cache = container / 'Library/Caches'
                cache.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(bootstrap, cache / 'preview-bootstrap.json')
            for appearance in (['light', 'dark'] if options.all_flows and options.comparison_matrix else ['light']):
                run('xcrun', 'simctl', 'ui', device, 'appearance', appearance)
                launched = appearance != "light"
                screens = (['confirm-open', 'confirm-close', 'code-setup', 'code-entry', 'code-rejected',
                            'biometric', 'request-sent', 'result', 'journal', 'offline'] if actions else
                           ['control', 'settings', 'key-detail', 'guests', 'journal', 'add-key'])
                if options.all_flows:
                    screens += ['control', 'settings', 'key-detail', 'add-key', 'guests',
                                'owner-form', 'owner-ready', 'owner-uncertain', 'owner-offline',
                                'object-form', 'object-created', 'object-edit', 'object-renamed',
                                'object-delete-confirm', 'object-deleted', 'object-uncertain',
                                'issue-form', 'issued-key', 'issued-list', 'issued-paused', 'issued-revoked', 'issued-uncertain', 'issued-revoke-confirm',
                                'owner-confirm', 'owner-sending', 'owner-result', 'owner-journal', 'owner-guest-request',
                                'issued-edit-form', 'issued-edit-result', 'issued-access-form',
                                'backup-form', 'backup-export', 'backup-preview', 'backup-restored', 'backup-rejected', 'backup-interrupted',
                                'delegation-preview', 'delegation-waiting', 'delegation-ready', 'delegation-rejected',
                                'delegated-awaiting', 'delegated-ready', 'delegated-uncertain', 'delegated-revoked', 'delegated-untrusted',
                                'sender-form', 'sender-link', 'sender-uncertain', 'sender-vouched', 'sender-revoked', 'sender-edit-form', 'sender-edited',
                                'message-inbox', 'message-read', 'message-corrupt', 'message-compose', 'message-sent', 'additional-parts', 'ble-scan', 'ble-uncertain', 'ble-paired', 'ble-registered', 'ble-owner-confirm', 'ble-owner-result', 'ble-owner-unknown', 'ble-owner-journal', 'ble-guest-confirm', 'ble-guest-result', 'ble-guest-expired', 'ble-guest-unknown', 'ble-guest-journal', 'ble-revoke-pending', 'ble-revoke-applied', 'ble-revoke-stale', 'ble-renewed', 'app-code-setup', 'app-code-settings', 'app-entry-lock', 'app-entry-rejected']
                # Check the complete root navigation before spending time on 85 more states.
                screens = list(dict.fromkeys((['control'] if options.all_flows else []) + screens))
                for screen in screens:
                    if launched:
                        run('xcrun', 'simctl', 'terminate', device, BUNDLE, optional=True)
                    arguments = ['--preview-tab', 'control' if screen == 'add-key' else screen]
                    if screen == 'key-detail':
                        arguments = ['--preview-tab', 'settings', '--preview-key-detail']
                    if screen == 'add-key':
                        arguments.append('--preview-add-key')
                    if actions:
                        arguments = ['--capture-actions', screen]
                    diagnostic_name = 'action-capture-status.json' if actions else 'preview-status.json'
                    diagnostic = container / 'Library/Caches' / diagnostic_name
                    diagnostic.unlink(missing_ok=True)
                    run('xcrun', 'simctl', 'launch', device, BUNDLE, *arguments,
                        '-AppleLanguages', '(ru)', '-AppleLocale', 'ru_RU')
                    launched = True
                    time.sleep(4)
                    container = Path(run('xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data'))
                    diagnostic = container / 'Library/Caches' / diagnostic_name
                    # A fresh Intel simulator can take over a minute between accepting
                    # launch and making the first scene active (see SpringBoard logs).
                    # Wait for this same process; never relaunch an action scenario.
                    startup_deadline = time.monotonic() + 180
                    while not diagnostic.is_file() and time.monotonic() < startup_deadline:
                        time.sleep(0.5)
                    if not diagnostic.is_file():
                        raise RuntimeError('Fresh app startup diagnostic missing; cannot verify running UI')
                    deadline = time.monotonic() + 60
                    while True:
                        state = json.loads(diagnostic.read_text())
                        if actions:
                            if not state.get('ready') or not state.get('software_controller') or state.get('scenario') != screen:
                                raise RuntimeError('Software-controller scenario did not prepare: ' + screen)
                            if screen.startswith('app-'):
                                if state.get('app_locked') != (screen in ['app-entry-lock', 'app-entry-rejected']) or state.get('app_lock_enabled') != (screen != 'app-code-setup') or state.get('local_code_set') != (screen != 'app-code-setup'):
                                    raise RuntimeError('Incorrect application entry protection state: ' + screen)
                            expected_frames = 1 if screen == 'request-sent' else (2 if screen in ['result', 'journal'] else 0)
                            expected_journal = 1 if screen in ['request-sent', 'result', 'journal', 'owner-sending', 'owner-result', 'owner-journal', 'ble-owner-result', 'ble-owner-unknown', 'ble-owner-journal', 'ble-guest-result', 'ble-guest-unknown', 'ble-guest-journal'] else 0
                            if state.get('command_frames') != expected_frames or state.get('journal_count') != expected_journal:
                                raise RuntimeError('Unexpected command/journal count for isolated scenario: ' + screen)
                            if screen in ['owner-confirm', 'owner-sending', 'owner-result', 'owner-journal', 'owner-guest-request']:
                                expected_owner_frames = 1 if screen in ['owner-sending', 'owner-result', 'owner-journal'] else 0
                                if state.get('owner_command_frames') != expected_owner_frames or state.get('owner_phone_requests') != (1 if screen == 'owner-guest-request' else 0):
                                    raise RuntimeError('Incorrect executed owner command/request: ' + screen)
                            if screen == 'issue-form' or screen.startswith('issued-'):
                                expected_keys = 0 if screen == 'issue-form' else 1
                                expected_key_requests = 0 if screen == 'issue-form' else (2 if screen in ['issued-paused', 'issued-revoked', 'issued-edit-result'] else 1)
                                expected_state = {'issue-form': 'none', 'issued-uncertain': 'draft', 'issued-paused': 'paused', 'issued-revoked': 'revoked'}.get(screen, 'active')
                                if state.get('issued_key_count') != expected_keys or state.get('key_mutation_requests') != expected_key_requests or state.get('issued_key_state') != expected_state:
                                    raise RuntimeError('Incorrect executed key lifecycle: ' + screen)
                                if state.get('issued_key_pending') != (screen == 'issued-uncertain'):
                                    raise RuntimeError('Incorrect pending key state: ' + screen)
                            if screen.startswith('ble-') and not screen.startswith('ble-guest-'):
                                expected_phase = {'ble-scan': 'none', 'ble-uncertain': 'sent'}.get(screen, 'confirmed')
                                if state.get('ble_pair_state') != expected_phase or state.get('ble_pair_writes') != (0 if screen == 'ble-scan' else 1):
                                    raise RuntimeError('BLE pairing did not persist/execute exactly once: ' + screen)
                                if state.get('ble_pair_count') != (0 if screen == 'ble-scan' else 1) or state.get('owned_object_count') != (0 if screen in ['ble-scan', 'ble-uncertain', 'ble-paired'] else 1):
                                    raise RuntimeError('Incorrect BLE pairing/registration state: ' + screen)
                                if state.get('ble_fire_writes') != (1 if screen in ['ble-owner-result', 'ble-owner-unknown', 'ble-owner-journal'] else 0):
                                    raise RuntimeError('BLE owner action was not executed exactly once: ' + screen)
                            if screen.startswith('ble-revoke-'):
                                expected_result = {'ble-revoke-pending': 255, 'ble-revoke-applied': 64, 'ble-revoke-stale': 65}[screen]
                                if state.get('ble_revoke_count') != 1 or state.get('ble_revoke_result') != expected_result or state.get('ble_revoke_writes') != (0 if screen == 'ble-revoke-pending' else 1):
                                    raise RuntimeError('BLE revocation application was not confirmed honestly: ' + screen)
                            if screen == 'ble-renewed':
                                if not state.get('ble_renew_link_preserved') or state.get('key_mutation_requests') != 2 or state.get('issued_key_pending'):
                                    raise RuntimeError('BLE renewal changed the key or failed exact acknowledgement')
                            if screen.startswith('ble-guest-'):
                                expected_writes = 1 if screen in ['ble-guest-result', 'ble-guest-unknown', 'ble-guest-journal'] else 0
                                if state.get('ble_fire_writes') != expected_writes or state.get('ble_time_writes') != expected_writes:
                                    raise RuntimeError('Guest BLE did not sync time/fire exactly once: ' + screen)
                                if state.get('received_key_count') != 1 or state.get('live_connections') != 0:
                                    raise RuntimeError('Guest BLE capture must use protected offline access')
                            if screen == 'additional-parts':
                                if state.get('delegation_redeems') != 2 or state.get('received_key_count') != 2 or state.get('delegation_pending') != 0:
                                    raise RuntimeError('Additional part did not retain/install two distinct keys')
                            if screen.startswith('message-'):
                                expected_incoming = 1 if screen in ['message-inbox', 'message-read'] else 0
                                if state.get('incoming_message_count') != expected_incoming or state.get('message_delivered_acks') != expected_incoming:
                                    raise RuntimeError('Message was not authenticated/persisted before acknowledgement: ' + screen)
                                if state.get('message_read_acks') != (1 if screen == 'message-read' else 0):
                                    raise RuntimeError('Read receipt did not come from actual message display: ' + screen)
                                if state.get('outgoing_message_count') != (1 if screen == 'message-sent' else 0) or state.get('message_posts') != (1 if screen == 'message-sent' else 0):
                                    raise RuntimeError('Outgoing message was not persisted/sent exactly once: ' + screen)
                            if screen.startswith('sender-'):
                                expected = {'sender-form': 'none', 'sender-link': 'available', 'sender-uncertain': 'draft', 'sender-vouched': 'awaitingOwner', 'sender-revoked': 'revoked', 'sender-edit-form': 'available', 'sender-edited': 'available'}[screen]
                                if state.get('sender_state') != expected or state.get('sender_groups') != (0 if screen == 'sender-form' else 1):
                                    raise RuntimeError('Sender group was not persisted/executed exactly once: ' + screen)
                                if state.get('sender_vouches') != (1 if screen == 'sender-vouched' else 0) or state.get('sender_revokes') != (1 if screen == 'sender-revoked' else 0):
                                    raise RuntimeError('Incorrect sender proof/revocation state: ' + screen)
                                if screen == 'sender-edited' and state.get('sender_object_count') != 1:
                                    raise RuntimeError('Object edit was not reconciled')
                            if screen.startswith('delegated-'):
                                expected = {'delegated-awaiting': 'awaiting', 'delegated-ready': 'ready', 'delegated-uncertain': 'awaiting', 'delegated-revoked': 'revoked', 'delegated-untrusted': 'none'}[screen]
                                if state.get('owner_delegated_state') != expected or state.get('owner_delegated_sent') != (screen == 'delegated-uncertain'):
                                    raise RuntimeError('Incorrect verified owner delegation state: ' + screen)
                                if state.get('owner_delegation_unverified') != (1 if screen == 'delegated-untrusted' else 0):
                                    raise RuntimeError('Untrusted recipient was not rejected: ' + screen)
                            if screen.startswith('delegation-'):
                                if state.get('delegation_redeems') != (1 if screen in ['delegation-waiting', 'delegation-ready'] else 0):
                                    raise RuntimeError('Delegation acceptance was not executed exactly once: ' + screen)
                                if state.get('delegation_pending') != (1 if screen == 'delegation-waiting' else 0) or state.get('received_key_count') != (1 if screen == 'delegation-ready' else 0):
                                    raise RuntimeError('Incorrect durable delegation result: ' + screen)
                            if screen.startswith('backup-'):
                                if state.get('backup_encrypted') != (screen != 'backup-form') or state.get('backup_pending') != (screen == 'backup-interrupted'):
                                    raise RuntimeError('Incorrect encrypted backup/restore state: ' + screen)
                                if state.get('backup_preview') != (screen in ['backup-preview', 'backup-interrupted']):
                                    raise RuntimeError('Incorrect inspected backup state: ' + screen)
                                if state.get('backup_message') != (screen in ['backup-restored', 'backup-rejected', 'backup-interrupted']):
                                    raise RuntimeError('Incorrect backup result: ' + screen)
                            if screen.startswith('object-'):
                                expected_objects = 0 if screen in ['object-form', 'object-deleted'] else 1
                                expected_mutations = 0 if screen == 'object-form' else (3 if screen in ['object-renamed', 'object-deleted'] else 2)
                                if state.get('owned_object_count') != expected_objects or state.get('mutation_requests') != expected_mutations:
                                    raise RuntimeError('Incorrect executed object lifecycle: ' + screen)
                                if state.get('object_pending') != (screen == 'object-uncertain'):
                                    raise RuntimeError('Incorrect pending object state: ' + screen)
                            if screen.startswith('owner-'):
                                expected_owners = 0 if screen == 'owner-form' else 1
                                if state.get('owner_count') != expected_owners or state.get('registration_requests') != expected_owners:
                                    raise RuntimeError('Owner registration was not executed exactly once: ' + screen)
                                if state.get('owner_pending') != (screen == 'owner-uncertain'):
                                    raise RuntimeError('Incorrect registration state: ' + screen)
                            break
                        if not bootstrap.is_file() or (not state.get('busy') and state.get('objects', 0) > 0 and state.get('live_connections', 0) > 0):
                            break
                        if state.get('failed') or time.monotonic() > deadline:
                            raise RuntimeError('Live object synchronization failed: ' + str(state.get('sync_failure', 'unknown_error')) + '; objects=' + str(state.get('objects')) + '; live=' + str(state.get('live_connections')))
                        time.sleep(1)
                    time.sleep(1)
                    if bootstrap.is_file() and not actions and state.get('journal_count') != 0:
                        raise RuntimeError('Read-only preview must not manufacture action history')
                    if not state.get('ready'):
                        raise RuntimeError('Keychain is not ready, OSStatus=' + str(state.get('status')))
                    path = OUTPUT / (model + ('-' + appearance if options.all_flows else '') + '-' + screen + '.png')
                    capture_visible_screen(device, path, screen)
                    if path.read_bytes()[:8] != b'\x89PNG\r\n\x1a\n':
                        raise RuntimeError('Not a PNG screenshot: ' + path.name)
                    manifest.append({'device': model, 'appearance': appearance, 'screen': screen, 'file': path.name,
                                     'source_sha': os.environ.get('GITHUB_SHA'), 'runtime': runtime,
                                     'software_controller': actions, 'visible_text_verified': True, 'app_locked': state.get('app_locked'), 'app_lock_enabled': state.get('app_lock_enabled'), 'command_frames': state.get('command_frames'),
                                     'objects': state.get('objects'), 'journal_count': state.get('journal_count'),
                                     'live_connections': state.get('live_connections'),
                                     'registration_requests': state.get('registration_requests'),
                                     'sync_requests': state.get('sync_requests'), 'owner_count': state.get('owner_count'),
                                     'owner_pending': state.get('owner_pending'),
                                     'ble_pair_count': state.get('ble_pair_count'), 'ble_pair_state': state.get('ble_pair_state'),
                                     'ble_pair_writes': state.get('ble_pair_writes'), 'ble_fire_writes': state.get('ble_fire_writes'), 'ble_time_writes': state.get('ble_time_writes'),
                                     'ble_revoke_writes': state.get('ble_revoke_writes'), 'ble_revoke_count': state.get('ble_revoke_count'),
                                     'ble_revoke_result': state.get('ble_revoke_result'), 'ble_renew_link_preserved': state.get('ble_renew_link_preserved'),
                                     'owned_object_count': state.get('owned_object_count'), 'mutation_requests': state.get('mutation_requests'),
                                     'object_pending': state.get('object_pending'),
                                     'issued_key_count': state.get('issued_key_count'), 'key_mutation_requests': state.get('key_mutation_requests'),
                                     'issued_key_pending': state.get('issued_key_pending'), 'issued_key_state': state.get('issued_key_state'),
                                     'owner_command_frames': state.get('owner_command_frames'), 'owner_phone_requests': state.get('owner_phone_requests')})
                    # Retain provenance for completed frames even if a later scenario fails.
                    pending_manifest = OUTPUT / 'manifest.json.tmp'
                    pending_manifest.write_text(json.dumps(manifest, indent=2) + '\n')
                    pending_manifest.replace(OUTPUT / 'manifest.json')
        except Exception:
            run('xcrun', 'simctl', 'spawn', device, 'log', 'show', '--last', '1m',
                '--style', 'compact', '--predicate', 'eventMessage CONTAINS "com.entrixy.ios"',
                timeout=30, optional=True)
            raise
        finally:
            cleanup_device(device)
    (OUTPUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Captured', len(manifest), 'real simulator screenshots', flush=True)


if __name__ == '__main__':
    main()
