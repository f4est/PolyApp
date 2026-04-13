# PolyApp Server (Go)

Backend для PolyApp.

## Стек
- Go 1.24+
- Gin
- Gorm
- PostgreSQL
- Redis
- JWT auth

## Архитектура
- `cmd/api` — entrypoint
- `internal/app` — bootstrap
- `internal/config` — env-конфиг
- `internal/domain` — сущности/контракты/ошибки
- `internal/usecase` — бизнес-логика
- `internal/infrastructure` — persistence/cache/security
- `internal/interface/http` — маршруты/handlers/middleware

## Ключевые изменения текущей версии
- Журнал оценок v2 (preset engine) с серверным пересчётом.
- Изоляция журнала по связке `группа+преподаватель` (teacher scope).
- Блокировка дублирующихся заявок на преподавание одной группы от одного преподавателя.
- Новый endpoint каталога журналов v2 для admin/teacher:
- `GET /journal/v2/groups/catalog`
- Для админа метки журналов формируются как `Группа - Преподаватель`.

## Запуск
### Локально
```bash
cd server-go
go mod download
go run ./cmd/api
```

### Через Docker
```bash
docker compose up --build api
```

## Конфигурация
- `HTTP_PORT` (default `8000`)
- `DATABASE_URL` (`postgres://polyapp:polyapp@localhost:5432/polyapp?sslmode=disable`)
- `REDIS_ADDR`
- `REDIS_PASSWORD`
- `REDIS_DB`
- `JWT_SECRET`
- `CORS_ORIGIN`
- `SESSION_TTL_HOURS`
- `MEDIA_DIR`
- `SEED_DEMO`

## Основные API модули
- Auth/Users/Roles
- News/Notifications
- Schedule (DOCX upload + parsing)
- Journal v1 + Journal v2 Presets
- Attendance/Grades/Exams
- Makeups
- Requests
- Departments/Admin panel
- Analytics

## Тесты
```bash
cd server-go
go test ./...
go test ./... -cover
```

## Примечания
- Модели мигрируются через `AutoMigrate` на старте.
- Для мобильных клиентов не используйте `localhost` в `API_BASE_URL`, используйте LAN IP сервера.
