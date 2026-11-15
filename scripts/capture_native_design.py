#!/usr/bin/env python3
"""Capture compiled SwiftUI component catalog on a disposable Apple simulator."""
import hashlib,json,os,subprocess,time
from pathlib import Path
from capture_simulator import ROOT,APP,OUTPUT,BUNDLE,TEXT_TOOL,run,prepare_device,cleanup_device
PAGES={
 'buttons': ['Кнопки','Добавить сервер','Отказать'],
 'fields': ['Поля и переключатели','Название объекта','Подтверждать нажатие'],
 'rows': ['Списки и разделители','Полученный ключ','Обновить данные'],
 'objects': ['Карточки объектов','Контроллер не в сети'],
 'journal': ['Журнал','Копировать','Очистить','Контроллер принял команду'],
 'navigation': ['Навигация','Настройки','Ключи','Главные разделы'],
 'confirm': ['Подтвердите открытие','Отмена','Открыть'],
 'delete': ['Удалить объект','Гости потеряют доступ','Отмена'],
 'code': ['Код Entrixy','Повторите код','Сохранить'],
 'avatar': ['Картинка объекта','Загрузить свою картинку','готовый значок'],
 'selectors': ['Выбор и сроки','Действует до','Радиус'],
}
TITLES={'buttons':'Кнопки и состояния','fields':'Поля и переключатели','rows':'Списки и разделители','objects':'Карточки объектов','journal':'Журнал','navigation':'Навигация и разделы','confirm':'Диалог подтверждения','delete':'Диалог удаления','code':'Создание кода Entrixy','avatar':'Своя картинка и пресеты','selectors':'Выбор и сроки'}
def main():
 OUTPUT.mkdir(parents=True,exist_ok=True)
 run('xcrun','swiftc',str(ROOT/'scripts/verify_capture_text.swift'),'-o',str(TEXT_TOOL),timeout=120)
 sdk=run('xcrun','--sdk','iphonesimulator','--show-sdk-version').strip().splitlines()[-1]
 runtimes=json.loads(subprocess.check_output(['xcrun','simctl','list','runtimes','--json']))['runtimes']
 runtime=next(r['identifier'] for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier'] and (r['version']==sdk or r['version'].startswith(sdk+'.')))
 device,container=prepare_device('native-design','com.apple.CoreSimulator.SimDeviceType.iPhone-16',runtime)
 captures=[]
 try:
  run('xcrun','simctl','ui',device,'appearance','light')
  for index,(page,expected) in enumerate(PAGES.items()):
   if index:run('xcrun','simctl','terminate',device,BUNDLE,optional=True)
   status=container/'Library/Caches/native-design-status.json';status.unlink(missing_ok=True)
   run('xcrun','simctl','launch',device,BUNDLE,'--native-design',page,timeout=180)
   deadline=time.monotonic()+180
   while not status.exists():
    if time.monotonic()>deadline:raise RuntimeError('Catalog did not become ready: '+page)
    time.sleep(.5)
   state=json.loads(status.read_text());assert state=={'ready':True,'page':page,'native_design':True,'network_requests':0,'command_frames':0}
   path=OUTPUT/('iphone16-light-design-'+page+'.png');deadline=time.monotonic()+240
   while True:
    run('xcrun','simctl','io',device,'screenshot',str(path))
    check=subprocess.run([str(TEXT_TOOL),str(path),*expected],capture_output=True,text=True,timeout=180)
    if check.returncode==0:break
    if check.returncode!=1 or time.monotonic()>deadline:raise RuntimeError(page+': '+check.stdout+check.stderr)
    time.sleep(1)
   captures.append({'screen':page,'title':TITLES[page],'file':path.name,'device':'iphone16','appearance':'light','source_sha':os.environ['GITHUB_SHA'],'native_design':True,'visible_text_verified':True,'runtime':runtime,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
   (OUTPUT/'review.json').write_text(json.dumps({'kind':'native-design-review','source_sha':os.environ['GITHUB_SHA'],'captures':captures},ensure_ascii=False,indent=2))
   print('Native SwiftUI design captured:',page,flush=True)
  assert len(captures)==len(PAGES)
 finally:cleanup_device(device)
if __name__=='__main__':main()
