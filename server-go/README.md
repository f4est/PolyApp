# PolyApp Server (Go)

Backend сервиса PolyApp.

## Стек

- Go 1.24+
- Gin (HTTP API)
- Gorm (ORM)
- PostgreSQL
- Redis
- JWT auth

## Структура

- `cmd/api/main.go` — запуск HTTP сервера
- `internal/app` — bootstrap/wiring зависимостей
- `internal/config` — env-конфигурация
- `internal/domain` — domain entities/interfaces/errors
- `internal/usecase` — бизнес-логика
- `internal/infrastructure` — persistence/cache/security
- `internal/interface/http` — handlers/routes/middleware
- `internal/models` — вспомогательные модели
- `data/` — локальные media-файлы (если запуск без docker volume)

## Конфигурация

Переменные окружения:

- `HTTP_PORT` (default `8000`)
- `DATABASE_URL` (пример: `postgres://polyapp:polyapp@localhost:5432/polyapp?sslmode=disable`)
- `REDIS_ADDR` (пример: `localhost:6379`)
- `REDIS_PASSWORD`
- `REDIS_DB` (default `0`)
- `JWT_SECRET`
- `CORS_ORIGIN` (default `*`)
- `SESSION_TTL_HOURS` (default `168`)
- `MEDIA_DIR` (default `./data`)
- `SEED_DEMO` (`true/false`)

## Запуск

### Локально

```bash
cd server-go
go mod download
go run ./cmd/api
```

### Через Docker

Из корня репозитория:

```bash
docker compose up --build api
```

## API

Базовые endpoint'ы:
- `GET /health`
- `GET /time-sync`
- `POST /auth/login`
- `POST /auth/register`
- `GET /auth/me`

Также доступны модули:
- news/notifications
- schedule
- journal (v1 + v2 preset engine)
- attendance/grades/exams
- makeups
- requests
- admin/departments/assignments

## Тесты

```bash
cd server-go
go test ./...
go test ./... -cover
```

Текущее состояние покрытия:
- usecase: основной unit-coverage (~61.6%)
- interface/http: базовые тесты маршрутов/парсеров (~4.9%)

## Миграции/модели

Проект использует `AutoMigrate` через Gorm при bootstrap.
При изменении моделей перезапустите API (или контейнер), чтобы схема подтянулась.

## Примечания

- Для мобильных клиентов используйте доступный с устройства `API_BASE_URL` (не `localhost`).
- При CORS-проблемах проверьте `CORS_ORIGIN` и разрешённые заголовки в middleware.
