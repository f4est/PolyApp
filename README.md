# PolyApp (Go + Flutter)

PolyApp — учебная платформа с backend на Go и клиентом на Flutter.

## Стек
- Backend: Go, Gin, Gorm, PostgreSQL, Redis
- Frontend: Flutter (Web/Desktop/Mobile)
- Infra: Docker Compose

## Структура репозитория
- `server-go/` — API, бизнес-логика, модели/репозитории, middleware
- `polyapp/` — Flutter приложение
- `docker-compose.yml` — локальный запуск сервисов
- `logos-source/` — служебные скрипты и материалы

## Ключевые особенности текущей версии
- Preset Journal (v2): пресеты, вычисляемые колонки, пересчёт на сервере.
- Отдельный журнал на связку `Группа + Преподаватель`.
- Заявки на преподавание группы:
- дубликаты одной и той же заявки блокируются;
- после одобрения создаётся связь преподаватель-группа.
- Каталог журналов для админа: вывод всех журналов с подписью `Группа - Преподаватель`.
- Аналитика: добавлен расширенный (wide) режим.

## Быстрый старт (Docker)
```bash
docker compose up --build
```

Доступность:
- API: `http://localhost:8000`
- Health: `GET /health`

## Локальный запуск
### Backend
```bash
cd server-go
go run ./cmd/api
```

### Frontend (Web)
```bash
cd polyapp
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

## Тесты
### Backend
```bash
cd server-go
go test ./...
go test ./... -cover
```

### Frontend
```bash
cd polyapp
flutter analyze
flutter test
```

Примечание: если папки `test/` нет, `flutter test` вернёт ошибку об отсутствии тестов.

## Конфигурация
### Backend env
- `HTTP_PORT` (default `8000`)
- `DATABASE_URL`
- `REDIS_ADDR`, `REDIS_PASSWORD`, `REDIS_DB`
- `JWT_SECRET`
- `CORS_ORIGIN`
- `SESSION_TTL_HOURS`
- `MEDIA_DIR`
- `SEED_DEMO`

### Frontend `--dart-define`
- `API_BASE_URL`
- `WEB_VAPID_KEY` (опционально)

## Документация по подпроектам
- Backend: [server-go/README.md](server-go/README.md)
- Flutter app: [polyapp/README.md](polyapp/README.md)
