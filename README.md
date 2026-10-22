# GTokGlass

Liquid Glass для TikTok (iOS 26/27) поверх мода **GTok 2.4**.

## Что делает

TikTok 46.x собран с iOS 26 SDK и уже содержит **собственную реализацию Liquid Glass**
(`TUXLiquidGlassView`, `TUXLiquidGlassEffectManager`, `TUXLiquidGlassContainerView`),
но каждый компонент выключен экспериментом. Твик переключает геттеры
`_TtC12TUXSwiftBase14TUXExperiments` в `YES`, и TikTok сам рисует стекло:

- кнопки, диалоги, шторки/шиты, меню, поповеры, модалки
- тосты (обычные, нижние, центральные), floating notices, in-app push
- intro-панели

Плюс опционально:
- `abGlass` — AB-флаги ленты (карточки, кнопки, фикс таббара под iOS 26)
- `tabBarGlass` — собственный `UIGlassEffect`-фон для кастомного `TTKTabBar`
  (таббар TikTok не входит в TUX-систему стекла)

## Конфиг и лог

Лежат в песочнице приложения: `Документы/GTokGlass/`
(видно в приложении «Файлы» → «На iPhone» → TikTok — твик включает file sharing).

`config.json`:

```json
{
  "enabled": true,
  "nativeGlass": true,
  "abGlass": true,
  "tabBarGlass": false,
  "log": true,
  "showStatus": true
}
```

- `enabled: false` — полностью выключить твик (если что-то ломается)
- `showStatus` — капсула «Liquid Glass: ON» на 3 секунды при запуске

После правки конфига — перезапуск TikTok.

`log.txt` — что нашлось и что включилось.

## Сборка

Dylib собирается на macOS-раннере GitHub Actions (нужен iOS SDK, на Windows его нет).

1. Создать репозиторий на GitHub (можно приватный).
2. Загрузить туда **содержимое** этой папки (`Tweak.m`, `Makefile`, `control`, `.github/`).
3. Actions → **build** → *Run workflow*.
4. Дождаться артефакта `GTokGlass-dylib`, скачать, распаковать — внутри `GTokGlass.dylib`.

## Вшивание в IPA

```powershell
python tools/inject.py --ipa "gtok 2.4.ipa" --dylib GTokGlass.dylib --out gtok-glass.ipa
```

Скрипт:

- кладёт dylib в `Payload/TikTok.app/Frameworks/`
- добавляет `LC_LOAD_DYLIB @executable_path/Frameworks/GTokGlass.dylib`
  в главный бинарь (там есть 25 КБ свободного места в заголовке)
- включает `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
- удаляет `_CodeSignature` / `SC_Info` / `embedded.mobileprovision`
- пакует обратно с правильными правами (`0755` для Mach-O, `0644` для данных)

Результат **неподписанный** — подписать своим сертификатом (ESign / Feather).

## Откат

Поставить оригинальный `gtok 2.4.ipa` заново. Либо `"enabled": false` в конфиге.
