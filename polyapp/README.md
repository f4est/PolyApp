# PolyApp Client (Flutter)

Flutter-клиент PolyApp для:
- Web (Chrome)
- Android
- iOS
- Windows
- macOS
- Linux

## Требования

- Flutter SDK (stable)
- Dart SDK (идёт с Flutter)
- Android Studio/Xcode (для мобильных платформ)
- Visual Studio Build Tools (для Windows)

Проверка окружения:

```bash
flutter doctor -v
```

## Параметры запуска

Ключевые `--dart-define`:
- `API_BASE_URL` — адрес backend API
- `WEB_VAPID_KEY` — ключ web-push (опционально)

Примеры:
- локально на ПК (web): `http://localhost:8000`
- Android эмулятор: `http://10.0.2.2:8000`
- физический телефон в Wi-Fi: `http://<LAN_IP_ПК>:8000`

## Режимы: demo vs release

В текущем проекте нет flavor'ов (`demo/release`), поэтому используем:

- demo: `debug` (или `profile`) с демо backend (`SEED_DEMO=true`)
- release: `--release` + production API URL

### Demo (debug)

```bash
flutter run -d <device> \
  --dart-define=API_BASE_URL=http://localhost:8000
```

### Release run

```bash
flutter run -d <device> --release \
  --dart-define=API_BASE_URL=https://api.example.com
```

## Запуск по устройствам

### 1) Web (Chrome)

```bash
cd polyapp
flutter pub get
flutter run -d chrome --web-port 5050 \
  --dart-define=API_BASE_URL=http://localhost:8000
```

PowerShell-скрипт:

```powershell
./run_web.ps1 -Port 5050 -Device chrome --dart-define=API_BASE_URL=http://localhost:8000
```

### 2) Android эмулятор

```bash
flutter run -d emulator-5554 \
  --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

### 3) Android физическое устройство

```bash
flutter run -d <android_device_id> \
  --dart-define=API_BASE_URL=http://192.168.0.150:8000
```

Где `192.168.0.150` — LAN IP вашего ПК.

### 4) iOS (Mac only)

```bash
flutter run -d ios \
  --dart-define=API_BASE_URL=http://<LAN_IP_ПК>:8000
```

### 5) Windows

```bash
flutter run -d windows \
  --dart-define=API_BASE_URL=http://localhost:8000
```

### 6) macOS

```bash
flutter run -d macos \
  --dart-define=API_BASE_URL=http://localhost:8000
```

### 7) Linux

```bash
flutter run -d linux \
  --dart-define=API_BASE_URL=http://localhost:8000
```

## Сборка приложений (demo/release)

## Web

### Demo build

```bash
flutter build web \
  --dart-define=API_BASE_URL=http://localhost:8000
```

### Release build

```bash
flutter build web --release \
  --dart-define=API_BASE_URL=https://api.example.com
```

Артефакт: `build/web/`

## Android

### Demo APK (debug)

```bash
flutter build apk --debug \
  --dart-define=API_BASE_URL=http://192.168.0.150:8000
```

### Release APK

```bash
flutter build apk --release \
  --dart-define=API_BASE_URL=https://api.example.com
```

### Release App Bundle (Play Store)

```bash
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://api.example.com
```

Артефакты:
- APK: `build/app/outputs/flutter-apk/`
- AAB: `build/app/outputs/bundle/release/`

## iOS (Mac only)

### Demo build

```bash
flutter build ios --debug --no-codesign \
  --dart-define=API_BASE_URL=http://<LAN_IP_ПК>:8000
```

### Release build

```bash
flutter build ios --release \
  --dart-define=API_BASE_URL=https://api.example.com
```

Для публикации настройте signing в Xcode.

## Windows

### Demo build

```bash
flutter build windows --debug \
  --dart-define=API_BASE_URL=http://localhost:8000
```

### Release build

```bash
flutter build windows --release \
  --dart-define=API_BASE_URL=https://api.example.com
```

Артефакт: `build/windows/x64/runner/Release/`

## macOS

### Demo build

```bash
flutter build macos --debug \
  --dart-define=API_BASE_URL=http://localhost:8000
```

### Release build

```bash
flutter build macos --release \
  --dart-define=API_BASE_URL=https://api.example.com
```

## Linux

### Demo build

```bash
flutter build linux --debug \
  --dart-define=API_BASE_URL=http://localhost:8000
```

### Release build

```bash
flutter build linux --release \
  --dart-define=API_BASE_URL=https://api.example.com
```

## Firebase/Push

Проект подключён к Firebase (`firebase_options.dart`).
Для web push укажите:

```bash
--dart-define=WEB_VAPID_KEY=<your_vapid_key>
```

## Проверки качества

```bash
flutter analyze
flutter test
```

Примечание: сейчас директория `test/` отсутствует, поэтому `flutter test` вернёт ошибку про отсутствие тестов.

## Частые проблемы

1. `Failed to fetch` на телефоне:
- проверьте `API_BASE_URL` (должен быть IP ПК, не `localhost`)
- backend должен быть доступен по сети и слушать порт `8000`

2. Android build требует desugaring:
- уже включено в `android/app/build.gradle.kts` (`isCoreLibraryDesugaringEnabled = true`)

3. CORS ошибки в web:
- проверьте `CORS_ORIGIN` на backend

4. После изменения API/моделей:
- перезапустите backend и клиент
