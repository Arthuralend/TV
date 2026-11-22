# App Store Connect — тексты и ответы для публикации

Всё ниже копируется в App Store Connect как есть. Лимиты Apple указаны в скобках.

## Основное

| Поле | Значение |
|---|---|
| Name / Название (30) | **TV - IPTV & TV Guide** |
| Название на iPhone | **TV** (CFBundleDisplayName, уже в проекте) |
| Bundle ID | `com.arthuralend.tv` |
| SKU | `tv-iptv-ios` |
| Primary language | Russian (или English) |
| Category / Категория | Entertainment (основная), Utilities (дополнительная) |
| Price / Цена | Free |
| Privacy Policy URL | https://arthuralend.github.io/TV/privacy.html |
| Support URL | https://arthuralend.github.io/TV/ |
| Marketing URL | https://arthuralend.github.io/TV/ |
| Terms (EULA) | стандартное Apple EULA (по умолчанию) |
| Copyright | 2026 Arthuralend |

## Русский (ru)

**Subtitle / Подзаголовок (30):**
Плеер M3U и телепрограмма

**Promotional text (170):**
Смотрите свои IPTV-каналы с удобной телепрограммой: что идёт сейчас, что будет дальше, архив передач, напоминания, «картинка в картинке» и AirPlay.

**Keywords (100, через запятую без пробелов):**
iptv,m3u,m3u8,xtream,телегид,телепрограмма,epg,xmltv,плеер,тв,каналы,онлайн,архив,плейлист,mpv

**Description / Описание (4000):**
```
TV — простой и быстрый плеер для ваших IPTV-плейлистов со встроенной телепрограммой.

ПЛЕЙЛИСТЫ
• Ссылки M3U и M3U8
• Файлы плейлистов из приложения «Файлы» или через «Поделиться»
• Аккаунты Xtream Codes (сервер, логин, пароль)
• Несколько плейлистов и быстрое переключение между ними
• Группы каналов, поиск, избранное и недавно просмотренные

ТЕЛЕПРОГРАММА
• Что идёт сейчас и что будет дальше — прямо в списке каналов
• Экран «Телегид»: что идёт на всех каналах в выбранное время
• Расписание каждого канала по дням с описаниями передач
• Напоминания о начале передачи
• Поддержка XMLTV (.xml и .xml.gz), автоматическое сопоставление каналов

ПРОСМОТР
• Системный плеер для HLS: «картинка в картинке» и AirPlay
• Встроенный плеер MPV: быстрый старт, MPEG-TS и другие форматы
• Архив передач (catch-up), если его поддерживает провайдер
• Переключение каналов свайпом, выбор аудиодорожки, режим «заполнить экран»
• Звук продолжает играть в фоне

КОНФИДЕНЦИАЛЬНОСТЬ
Никакой регистрации, рекламы и слежки. Ваши плейлисты хранятся только на устройстве.

ВАЖНО
TV — это только плеер. Приложение не содержит и не продаёт телеканалы. Для просмотра нужен плейлист от вашего IPTV-провайдера. Используйте только контент, который вы имеете право смотреть.
```

**What's New (4000):**
Первая версия.

## English (en-US)

**Subtitle (30):**
M3U Player with Live TV Guide

**Promotional text (170):**
Watch your own IPTV channels with a clean TV guide: what's on now and next, catch-up, reminders, Picture in Picture and AirPlay.

**Keywords (100):**
iptv,m3u,m3u8,xtream,epg,xmltv,guide,player,live,channels,playlist,catchup,mpv,stream,tv guide

**Description (4000):**
```
TV is a simple, fast player for your own IPTV playlists with a built-in TV guide.

PLAYLISTS
• M3U and M3U8 links
• Playlist files from the Files app or the Share menu
• Xtream Codes accounts (server, username, password)
• Several playlists with quick switching
• Channel groups, search, favorites and recently watched

TV GUIDE
• What's on now and next, right in the channel list
• Guide screen: what's on every channel at the time you choose
• Each channel's schedule by day with programme descriptions
• Reminders before a programme starts
• XMLTV support (.xml and .xml.gz) with automatic channel matching

WATCHING
• System player for HLS with Picture in Picture and AirPlay
• Built-in MPV player: fast start, MPEG-TS and other formats
• Catch-up (archive) when your provider supports it
• Swipe to change channels, audio track selection, fill screen
• Audio keeps playing in the background

PRIVACY
No sign-up, no ads, no tracking. Your playlists stay on your device.

IMPORTANT
TV is a player only. It does not include or sell any TV channels. You need a playlist from your IPTV provider. Only watch content you have the right to view.
```

**What's New:** First release.

## App Privacy (раздел «Конфиденциальность приложения»)

* Do you or your third-party partners collect data from this app? → **No, we do not collect data from this app** («Данные не собираются»).
* Tracking → **No**.

## Age Rating (возрастной рейтинг)

Ответы на анкету:
* Все категории насилия, контента для взрослых, азартных игр и т. п. → **None / Нет**.
* Unrestricted Web Access → **No**.
* User-Generated Content → **No**.
* Messaging and Chat → **No**.
* Parental Controls / Age Assurance → **No**.

Итог обычно **4+** (или 12+ — Apple может завысить для потоковых плееров; это нормально).

## Export Compliance (шифрование)

В Info.plist уже стоит `ITSAppUsesNonExemptEncryption = NO` — вопрос при загрузке сборки не появится. Приложение использует только стандартное HTTPS-шифрование iOS.

## Content Rights (права на контент)

«Does your app contain, show, or access third-party content?» → **Yes** — и подтвердите, что у вас есть права. Приложение лишь воспроизводит то, что добавил пользователь.

## App Review Information — заметки для ревьюера (вставьте в «Notes»)

```
TV is a media player for IPTV playlists that the user already owns (M3U/M3U8 links, files, Xtream Codes logins).
The app does NOT include, sell, or link to any channels or streams, and it does not promote any IPTV service.
No account is required.

How to test:
1. Launch the app, tap "Add Playlist".
2. Choose "Link" and paste this test playlist (Apple's public HLS sample streams):
   https://arthuralend.github.io/TV/demo.m3u
3. Tap Save. Tap any channel to play. Picture in Picture and AirPlay buttons are at the top of the player.
4. The "TV Guide" tab shows programme data when a playlist provides an XMLTV guide (the demo streams have none).

NSAllowsArbitraryLoads is enabled because many IPTV providers and XMLTV guides are only available over plain HTTP, and the user enters these addresses themselves. The app uses the "audio" background mode so the TV sound keeps playing in the background and in Picture in Picture.
Reminders use local notifications only.
```

Контакт для ревьюера: ваше имя, телефон и e-mail (заполняются в App Store Connect, не публикуются).
Демо-аккаунт: **не нужен** (снимите галочку «Sign-in required»).

## Скриншоты

Обязательно: **iPhone 6.9"** (1320×2868 или 1290×2796), от 3 до 10 штук. Приложение только для iPhone, поэтому скриншоты iPad не нужны.
Снимите их в симуляторе iPhone 17 Pro Max (⌘S в Simulator) — см. ios/README.md, раздел «Скриншоты».
Рекомендуемые экраны: список каналов с телепрограммой, экран «Телегид», расписание канала, плеер в горизонтальной ориентации, добавление плейлиста.
Важно: на скриншотах не должно быть чужих логотипов и передач, на которые у вас нет прав — используйте демо-плейлист или свой.
