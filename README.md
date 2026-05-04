# PolyApp

PolyApp - монорепозиторий учебной платформы для колледжа. В проекте есть Go backend, Flutter клиент, Docker-инфраструктура и отдельная команда для пересоздания демо-данных.

## Состав репозитория
- `server-go/` - REST API, авторизация, журналы, заявки, новости, аналитика, сидер демо-данных.
- `polyapp/` - Flutter приложение для web/mobile/desktop.
- `scripts/` - вспомогательные PowerShell-команды.
- `docker-compose.yml` - локальный PostgreSQL, Redis и API.
- `logos-source/` - исходники бренд-материалов.

## Быстрый старт через Docker
```powershell
docker compose up --build
```

После запуска:
- API: `http://localhost:8000`
- Healthcheck: `http://localhost:8000/health`
- PostgreSQL с хоста: `localhost:5433`
- Redis с хоста: `localhost:6380`

Docker compose автоматически включает `SEED_DEMO=true`, поэтому при первом запуске API создаст демо-данные, если база пустая.

## Локальная разработка
Поднять только инфраструктуру:
```powershell
docker compose up -d db redis
```

Запустить backend локально:
```powershell
cd server-go
$env:DATABASE_URL="postgres://polyapp:polyapp@localhost:5433/polyapp?sslmode=disable"
$env:REDIS_ADDR="localhost:6380"
go run ./cmd/api
```

Запустить Flutter web:
```powershell
cd polyapp
flutter pub get
flutter run -d chrome --web-port 5050 --dart-define=API_BASE_URL=http://localhost:8000
```

## Демо-данные
Для полного сброса базы и пересоздания демо-данных используйте команду из корня репозитория:
```powershell
./scripts/reset_demo_data.ps1 -DatabaseUrl "postgres://polyapp:polyapp@localhost:5433/polyapp?sslmode=disable"
```

Команда очищает существующие данные и заново создает отделения, группы, студентов, преподавателей, новости, заявки, экзамены, отработки, оценки, посещаемость и журнальные пресеты.

Пароль для демо-пользователей: `Demo1234`.

## Основные возможности
- Авторизация и роли: admin, teacher, student, parent, SMM, обработчик заявок.
- Админ-панель с управлением пользователями, отделениями, группами, заявками, новостями, расписанием и аналитикой.
- Журнал оценок с пресетами и синхронизацией с посещаемостью.
- Журнал посещений.
- Назначения преподавателей на группы и заявки на преподавание.
- Документные заявки студентов.
- Отработки и сообщения по отработкам.
- Лента новостей с категориями и медиа.
- Аналитика по группам, оценкам и посещаемости.

## Проверки перед пушем
Backend:
```powershell
cd server-go
go test ./...
```

Flutter:
```powershell
cd polyapp
flutter analyze
```

## Документация подпроектов
- Backend: [server-go/README.md](server-go/README.md)
- Flutter клиент: [polyapp/README.md](polyapp/README.md)
