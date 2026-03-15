# PolyApp (Go + Flutter)

PolyApp — учебная платформа с модульной архитектурой:
- backend: Go (Gin, Gorm, PostgreSQL, Redis)
- frontend: Flutter (web/desktop/mobile)
- infra: Docker Compose

## Репозиторий

- `server-go/` — API, бизнес-логика, миграции/модели, интеграция с БД/Redis
- `polyapp/` — клиентское приложение Flutter
- `docker-compose.yml` — локальный запуск всего стека (api + db + redis)
- `logos-source/` — исходники/материалы по логотипам и служебные скрипты

## Архитектура

### Backend (Clean Architecture)

- `server-go/internal/domain` — сущности, контракты репозиториев, доменные ошибки
- `server-go/internal/usecase` — бизнес-сценарии
- `server-go/internal/infrastructure` — адаптеры Postgres/Redis/security
- `server-go/internal/interface/http` — Gin-роуты, DTO, middleware, handlers
- `server-go/internal/app` — bootstrap приложения
- `server-go/cmd/api` — точка входа

### Frontend

- `polyapp/lib/api` — API-клиент и DTO
- `polyapp/lib/journal` — журналы оценок/посещаемости
- `polyapp/lib/makeup` — отработки
- `polyapp/lib/analytics` — аналитика
- `polyapp/lib/widgets` — UI-компоненты
- `polyapp/lib/main.dart` — app shell, маршрутизация по ролям, auth

## Быстрый старт (Docker)

```bash
docker compose up --build
```

Доступность:
- API: `http://localhost:8000`
- Health: `GET http://localhost:8000/health`

## Локальный запуск без Docker

### Backend

```bash
cd server-go
go run ./cmd/api
```

### Frontend (пример web)

```bash
cd polyapp
flutter pub get
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

## Тесты и качество

### Backend

```bash
cd server-go
go test ./...
go test ./... -cover
```

Текущее покрытие (по `go test ./... -cover`):
- `internal/usecase`: ~61.6%
- `internal/interface/http`: ~4.9%
- остальные пакеты: без/минимум тестов

### Frontend

```bash
cd polyapp
flutter analyze
flutter test
```

Примечание: в текущем состоянии директория `polyapp/test` отсутствует, поэтому `flutter test` вернёт `Test directory "test" not found`.

## Основные переменные

### Backend env

- `HTTP_PORT` (default `8000`)
- `DATABASE_URL`
- `REDIS_ADDR`
- `REDIS_PASSWORD`
- `REDIS_DB`
- `JWT_SECRET`
- `CORS_ORIGIN`
- `SESSION_TTL_HOURS`
- `MEDIA_DIR`
- `SEED_DEMO`

### Frontend dart-define

- `API_BASE_URL` — адрес API
- `WEB_VAPID_KEY` — для web push (если используется)

## Документация по модулям

- Server guide: [server-go/README.md](server-go/README.md)
- App guide: [polyapp/README.md](polyapp/README.md)
