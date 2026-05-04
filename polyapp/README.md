# PolyApp Client

Flutter клиент PolyApp для web, Android, iOS, Windows, Linux и macOS. Основной сценарий разработки сейчас - web через Chrome.

## Требования
- Flutter SDK stable
- Dart SDK из Flutter
- Запущенный backend API

Проверка окружения:
```powershell
flutter doctor -v
```

## Установка зависимостей
```powershell
cd polyapp
flutter pub get
```

## Конфигурация API
Клиент получает адрес backend через `--dart-define=API_BASE_URL=...`.

Типовые значения:
- Web/Desktop на том же ПК: `http://localhost:8000`
- Android эмулятор: `http://10.0.2.2:8000`
- Физическое устройство в LAN: `http://<LAN_IP_ПК>:8000`

Опционально:
- `WEB_VAPID_KEY` - ключ web push-уведомлений.

## Запуск web
```powershell
cd polyapp
flutter run -d chrome --web-port 5050 --dart-define=API_BASE_URL=http://localhost:8000
```

PowerShell helper:
```powershell
cd polyapp
./run_web.ps1 -Port 5050 -Device chrome --dart-define=API_BASE_URL=http://localhost:8000
```

## Сборка
Web:
```powershell
flutter build web --release --dart-define=API_BASE_URL=https://api.example.com
```

Android APK:
```powershell
flutter build apk --release --dart-define=API_BASE_URL=https://api.example.com
```

## Проверки
```powershell
flutter analyze
```

Если в проект добавлены тесты:
```powershell
flutter test
```

## Основные разделы приложения
- Авторизация и профиль пользователя.
- Новости и категории новостей.
- Заявки на документы и преподавание группы.
- Отработки.
- Журнал оценок с пресетами.
- Журнал посещаемости.
- Экзамены.
- Аналитика.
- Админ-панель: пользователи, отделения, группы, расписание, новости, заявки, академические данные.

## Производительность
Админ-панель и журналы используют ленивую загрузку вкладок и ограниченные списки для тяжелых сущностей. Если после массовых изменений демо-данных страницы начинают грузиться медленно, пересоздайте демо-базу актуальной командой из корня репозитория:
```powershell
./scripts/reset_demo_data.ps1 -DatabaseUrl "postgres://polyapp:polyapp@localhost:5433/polyapp?sslmode=disable"
```

## Структура
- `lib/api/` - API клиент и DTO.
- `lib/journal/` - журналы оценок и посещаемости.
- `lib/makeup/` - отработки и админские страницы.
- `lib/analytics/` - аналитика.
- `assets/` - статические ресурсы.
- `web/`, `android/`, `ios/`, `windows/`, `linux/`, `macos/` - платформенные проекты.
