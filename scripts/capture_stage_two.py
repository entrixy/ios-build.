#!/usr/bin/env python3
"""Capture production SwiftUI routes with isolated, simulator-only stored profiles."""
import hashlib, json, os, subprocess, time
from capture_simulator import ROOT, OUTPUT, BUNDLE, TEXT_TOOL, run, prepare_device, cleanup_device
PAGES = {
 'empty': ['Настройки', 'Объекты', 'Пока нет объектов', 'Добавить объект'],
 'guest-control': ['Управление', 'Ворота во двор'],
 'owner-control': ['Управление', 'Ворота во двор', 'Свой'],
 'mixed-objects': ['Настройки', 'Дверь Bluetooth', 'Ворота во двор', 'Гостевой въезд'],
 'guest-keys': ['Настройки', 'Ключи', 'controller.invalid', 'Добавить ключ'],
 'key-detail': ['Полученный ключ', 'Обновить данные', 'Удалить ключ с iPhone'],
 'owner-objects': ['Настройки', 'Объекты', 'Ворота во двор', 'Добавить объект'],
 'owner-expanded': ['Настройки', 'Ворота во двор', 'Свой', 'Добавить объект'],
 'guest-expanded': ['Настройки', 'Ворота во двор', 'Гостевой', 'Добавить объект'],
 'add-object': ['Новый объект', 'Тип подключения', 'BLE', 'Bluetooth-реле', 'Отмена'],
 'object-delete': ['Удалить объект?', 'Гости потеряют доступ', 'Отмена'],
 'owner-guests': ['Гости', 'Люди', 'Компании', 'Пресеты', 'Добавить гостя'],
 'delegating-guests': ['Гости', 'Передать ключ'],
 'system': ['Настройки', 'Система', 'Код Entrixy', 'Задать код'],
 'code-settings': ['Код Entrixy', 'Задать код', 'Спрашивать код при входе'],
 'sounds': ['Настройки', 'Звуки', 'Громкость звуков приложения', 'Нажатие на карточку', 'По умолчанию'],
 'add-key': ['Добавить ключ', 'Вставить ссылку', 'Сканировать QR-код', 'Отмена'],
 'add-server': ['Добавить сервер', 'Адрес сервера', 'Код доступа, если он есть', 'Аккаунт на сервере', 'Отмена'],
 'journal': ['Журнал', 'Копировать', 'Очистить', 'Журнал пуст'],
}
TITLES = {
 'owner-control': 'Управление своим объектом',
 'mixed-objects': 'Общий список: свои, гостевые и Bluetooth',
 'owner-expanded': 'Свой объект: раскрытые действия',
 'guest-expanded': 'Полученный объект: локальные действия',
 'add-object': 'Добавление объекта: тип Bluetooth',
 'object-delete': 'Удаление объекта: подтверждение',
 'empty': 'Пустой профиль: доступные разделы',
 'guest-control': 'Гость: управление объектом',
 'guest-keys': 'Настройки: полученные ключи',
 'key-detail': 'Полученный ключ: вложенная страница',
 'owner-objects': 'Владелец: объекты в настройках',
 'owner-guests': 'Владелец: раздел гостей',
 'delegating-guests': 'Гость с правом передачи: раздел гостей',
 'system': 'Настройки: система',
 'code-settings': 'Код Entrixy: настройки входа',
 'sounds': 'Настройки: звуки событий',
 'add-key': 'Добавление ключа',
 'add-server': 'Добавление сервера',
 'journal': 'Пустой журнал действий',
}
def main():
 OUTPUT.mkdir(parents=True, exist_ok=True)
 run('xcrun', 'swiftc', str(ROOT/'scripts/verify_capture_text.swift'), '-o', str(TEXT_TOOL), timeout=120)
 sdk=run('xcrun','--sdk','iphonesimulator','--show-sdk-version').strip().splitlines()[-1]
 runtimes=json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','--json']))['runtimes']
 runtime=next(r['identifier'] for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier'] and (r['version']==sdk or r['version'].startswith(sdk+'.')))
 device,container=prepare_device('stage-two-product-routes','com.apple.CoreSimulator.SimDeviceType.iPhone-16',runtime)
 captures=[]
 try:
  run('xcrun','simctl','ui',device,'appearance','light')
  for index,(page,expected) in enumerate(PAGES.items()):
   if index: run('xcrun','simctl','terminate',device,BUNDLE,optional=True)
   status=container/'Library/Caches/stage-two-status.json';status.unlink(missing_ok=True)
   run('xcrun','simctl','launch',device,BUNDLE,'--stage-two',page,timeout=180)
   deadline=time.monotonic()+180
   while not status.exists():
    if time.monotonic()>deadline:raise RuntimeError('Product route did not become ready: '+page)
    time.sleep(.5)
   state=json.loads(status.read_text())
   assert state['ready'] and state['route']==page and state['product_routes'] and state['journal']==0, state
   owner=page in ['owner-objects','owner-guests','add-server','owner-expanded','add-object','object-delete','owner-control','mixed-objects'];empty=page in ['empty','add-key']
   tabs=(['control'] if not empty else [])+['settings']+(['guests'] if owner or page=='delegating-guests' else [])+['journal']
   assert state['tabs']==tabs and state['owners']==int(owner) and state['guests']==int((not owner and not empty) or page=='mixed-objects'),state
   visible_tabs=[] if page in ['add-key','add-server','add-object','object-delete'] else [{'control':'Управление','settings':'Настройки','guests':'Гости','journal':'Журнал'}[x] for x in tabs]
   path=OUTPUT/('iphone16-light-stage2-'+page+'.png');deadline=time.monotonic()+240
   while True:
    run('xcrun','simctl','io',device,'screenshot',str(path))
    check=subprocess.run([str(TEXT_TOOL),str(path),*expected,*visible_tabs],capture_output=True,text=True,timeout=180)
    if check.returncode==0:break
    if check.returncode!=1 or time.monotonic()>deadline:raise RuntimeError(page+': '+check.stdout+check.stderr)
    print('Waiting for product route:',page,check.stdout.strip(),flush=True);time.sleep(1)
   captures.append({'screen':page,'title':TITLES[page],'file':path.name,'device':'iphone16','appearance':'light','source_sha':os.environ['GITHUB_SHA'],'product_routes':True,'profile':state,'visible_text_verified':True,'runtime':runtime,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
   (OUTPUT/'review.json').write_text(json.dumps({'kind':'stage-two-product-review','source_sha':os.environ['GITHUB_SHA'],'captures':captures},ensure_ascii=False,indent=2))
   print('Production SwiftUI route captured:',page,flush=True)
  assert len(captures)==len(PAGES)
 finally:cleanup_device(device)
if __name__=='__main__':main()
