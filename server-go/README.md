# PolyApp Go Backend

Новый backend для PolyApp на `Go + PostgreSQL + Redis`.

## Архитектура

Слои (Clean Architecture):

- `internal/domain/*`: сущности, ошибки, интерфейсы репозиториев и сервисов.
- `internal/usecase/*`: бизнес-логика (auth/news) через интерфейсы.
- `internal/infrastructure/*`: адаптеры Postgres/Redis/JWT/bcrypt.
- `internal/interface/http/*`: Gin handlers, middleware, DTO, роутинг.
- `internal/app/*`: bootstrap и wiring зависимостей.
- `cmd/api/main.go`: точка входа API.

## TDD

Usecase-слой покрыт unit-тестами:

- `internal/usecase/auth_usecase_test.go`
- `internal/usecase/news_usecase_test.go`

Запуск:

```bash
go test ./...
```

## Запуск локально

```bash
go run ./cmd/api
```

Переменные окружения:

- `HTTP_PORT` (default `8000`)
- `DATABASE_URL`
- `REDIS_ADDR`
- `REDIS_PASSWORD`
- `REDIS_DB`
- `JWT_SECRET`
- `CORS_ORIGIN`
- `SESSION_TTL_HOURS`
- `MEDIA_DIR`
- `SEED_DEMO` (`true/false`)

