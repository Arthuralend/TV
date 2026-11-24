# TV — приложение для iPhone

* В App Store: **TV - IPTV & TV Guide**
* На экране iPhone: **TV**
* Bundle ID: `com.arthuralend.tv` · iOS 16+ · только iPhone · русский и английский

## Возможности

* Плейлисты: ссылка M3U/M3U8, файл (в том числе «Открыть в TV» из «Файлов»), Xtream Codes; несколько плейлистов.
* Каналы: группы, поиск, избранное, недавние, логотипы (из плейлиста, телегида или базы iptv-org).
* Телегид XMLTV (.xml / .xml.gz): «сейчас / далее» в списке, вкладка «Телегид» по времени, расписание канала по дням, напоминания (локальные уведомления).
* Архив (catch-up) в форматах flussonic / shift / append / шаблоны `catchup-source`.
* Плеер: VLC (MobileVLCKit) — играет HLS, MPEG-TS и другие форматы; новый плеер на каждый поток и остановка в фоне, поэтому переключение и закрытие без подвисаний. Свайп по видео справа налево — список каналов, слева направо — список групп. Выбор аудиодорожки, «заполнить экран», пульт на экране блокировки.
* Без аккаунтов, рекламы, аналитики. Манифест приватности `PrivacyInfo.xcprivacy` включён.

> Скрытого встроенного плейлиста и промокода (как в версиях для Mac/Android) в iOS-версии **нет намеренно**: Apple отклоняет приложения со скрытыми функциями (правило 2.3.1) и IPTV-приложения, которые сами раздают каналы (5.2.3).

## Структура

```
ios/
  project.yml            — описание проекта для XcodeGen
  Podfile                — MobileVLCKit (плеер VLC)
  ExportOptions.plist    — выгрузка в App Store Connect
  TV/Sources/            — код SwiftUI
  TV/Resources/          — иконка, локализация, PrivacyInfo.xcprivacy
  AppStore/metadata.md   — все тексты и ответы для App Store Connect
  AppStore/AppIcon-1024.png
docs/                    — сайт: поддержка, политика конфиденциальности, условия, демо-плейлист
```

## 1. Включить сайт с политикой конфиденциальности (один раз)

GitHub → репозиторий **Arthuralend/TV** → Settings → Pages → Source: *Deploy from a branch*, Branch: `main`, папка `/docs` → Save.
Через пару минут откроются:

* https://arthuralend.github.io/TV/ — поддержка (Support URL)
* https://arthuralend.github.io/TV/privacy.html — политика конфиденциальности
* https://arthuralend.github.io/TV/terms.html — условия использования
* https://arthuralend.github.io/TV/demo.m3u — тестовый плейлист для ревьюера Apple

(Страницы появятся после слияния этой ветки в `main`.)

## 2. Создать приложение в App Store Connect

1. developer.apple.com → Certificates, IDs & Profiles → Identifiers → «+» → App IDs → App → Bundle ID `com.arthuralend.tv` (Explicit). Можно не делать — Xcode создаст сам при первой подписи.
2. appstoreconnect.apple.com → Apps → «+» → New App: платформа iOS, имя **TV - IPTV & TV Guide**, язык, Bundle ID `com.arthuralend.tv`, SKU `tv-iptv-ios`.
3. Заполните страницу по файлу [`AppStore/metadata.md`](AppStore/metadata.md): описание, ключевые слова, URL, «Конфиденциальность приложения → данные не собираются», возрастной рейтинг, заметки для ревьюера.

Если имя «TV - IPTV & TV Guide» окажется занято, App Store Connect не даст его сохранить — подойдут варианты «TV: IPTV & TV Guide» или «TV — IPTV Player & TV Guide». Название на iPhone («TV») от этого не зависит.

## 3а. Сборка, скриншоты и страница в App Store без Mac — через GitHub Actions

Используется тот же ключ App Store Connect API, что и в репозитории Documents-Tabes.

1. GitHub → **Arthuralend/TV** → Settings → Secrets and variables → Actions → New repository secret:
   * `APPSTORE_API_KEY_ID` — Key ID
   * `APPSTORE_API_ISSUER` — Issuer ID
   * `APPSTORE_API_KEY_P8` — текст файла `AuthKey_….p8` целиком (вместе со строками BEGIN/END)
   * `APPLE_TEAM_ID` — необязательно: если его нет, Team ID берётся из Bundle ID
2. Actions → **iOS** → **Run workflow**. Он:
   * собирает, подписывает и загружает приложение в App Store Connect (номер сборки = номер запуска);
   * делает скриншоты в симуляторе iPhone 6.9" (русский и английский);
   * заполняет страницу: названия, описания, ключевые слова, ссылки, категории, возрастной рейтинг, заметки для ревьюера, скриншоты (`ios/AppStore/listing`).
3. Вручную в App Store Connect остаётся: **App Privacy** → «Data Not Collected», контакт для ревьюера, выбор сборки в версии и кнопка **Submit for Review**.

Для автоматической подписи ключ должен иметь роль **Admin**.

## 3б. Сборка на Mac в Xcode

```bash
brew install xcodegen cocoapods
```

```bash
cd ios && xcodegen generate && pod install && open TV.xcworkspace
```

В Xcode: таргет **TV** → Signing & Capabilities → выберите свою команду (Team). Затем Product → Archive → Distribute App → App Store Connect → Upload.
Открывайте именно `TV.xcworkspace` (не `.xcodeproj`), иначе не подключится VLC.

## Скриншоты

Нужны скриншоты iPhone 6.9" (1320×2868). В Xcode запустите приложение на симуляторе **iPhone 17 Pro Max** (или 16 Pro Max), добавьте демо-плейлист `https://arthuralend.github.io/TV/demo.m3u` или свой, и сделайте снимки ⌘S в Simulator. 3–5 экранов достаточно.

## Версии

* Версия для App Store — `MARKETING_VERSION` в `project.yml` (сейчас 1.0.0). Для обновления увеличьте её и запустите workflow снова.
* Номер сборки ставится автоматически (номер запуска GitHub Actions).

## Лицензии

Плеер — MobileVLCKit (LGPL 2.1, VideoLAN), подключается через CocoaPods. Логотипы каналов — открытая база iptv-org.
