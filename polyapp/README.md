# PolyApp Client (Flutter)

Flutter-клиент PolyApp для Web, Desktop и Mobile.

## Поддерживаемые платформы
- Web (Chrome)
- Android
- iOS
- Windows
- macOS
- Linux

## Требования
- Flutter SDK (stable)
- Dart SDK
- Android Studio / Xcode (для мобильных)
- Visual Studio Build Tools (для Windows)

Проверка окружения:
```bash
flutter doctor -v
```

## Конфигурация
Ключи `--dart-define`:
- `API_BASE_URL` — адрес API
- `WEB_VAPID_KEY` — web push (опционально)

Примеры `API_BASE_URL`:
- Web/desktop локально: `http://localhost:8000`
- Android эмулятор: `http://10.0.2.2:8000`
- Физический телефон в Wi‑Fi: `http://<LAN_IP_ПК>:8000`

## Запуск
### Web
```bash
cd polyapp
flutter pub get
flutter run -d chrome --web-port 5050 --dart-define=API_BASE_URL=http://localhost:8000
```

PowerShell helper:
```powershell
./run_web.ps1 -Port 5050 -Device chrome --dart-define=API_BASE_URL=http://localhost:8000
```

### Android эмулятор
```bash
flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

### Android устройство
```bash
flutter run -d <device_id> --dart-define=API_BASE_URL=http://192.168.0.150:8000
```

### iOS
```bash
flutter run -d ios --dart-define=API_BASE_URL=http://<LAN_IP_ПК>:8000
```

### Desktop
```bash
flutter run -d windows --dart-define=API_BASE_URL=http://localhost:8000
flutter run -d macos --dart-define=API_BASE_URL=http://localhost:8000
flutter run -d linux --dart-define=API_BASE_URL=http://localhost:8000
```

## Сборка
### Web
```bash
flutter build web --release --dart-define=API_BASE_URL=https://api.example.com
```

### Android
```bash
flutter build apk --release --dart-define=API_BASE_URL=https://api.example.com
flutter build appbundle --release --dart-define=API_BASE_URL=https://api.example.com
```

### iOS
```bash
flutter build ios --release --dart-define=API_BASE_URL=https://api.example.com
```

### Desktop
```bash
flutter build windows --release --dart-define=API_BASE_URL=https://api.example.com
flutter build macos --release --dart-define=API_BASE_URL=https://api.example.com
flutter build linux --release --dart-define=API_BASE_URL=https://api.example.com
```

## Что важно знать в текущей версии
- Для учителя журнал теперь изолирован по связке `Группа + Преподаватель`.
- Админ в выборе журнала видит полный каталог с подписями `Группа - Преподаватель`.
- В аналитике добавлен расширенный (wide) режим на web.
- Для экзаменов есть шаблоны загрузки (`csv/xlsx`) через UI.

## Проверки качества
```bash
flutter analyze
flutter test
```

Примечание: если `test/` отсутствует, `flutter test` вернёт ошибку об отсутствии тестов.
