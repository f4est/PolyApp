# PolyApp Server

Backend сервис PolyApp на Go. Отвечает за авторизацию, пользователей, журналы, посещаемость, оценки, заявки, новости, расписание, отделения, аналитику и демо-данные.

## Стек
- Go 1.25+
- Gin
- Gorm
- PostgreSQL
- Redis
- JWT авторизация

## Запуск через Docker
Из корня репозитория:
```powershell
docker compose up --build api
```

Контейнер API будет доступен на `http://localhost:8000`. Внутри compose база доступна как `db:5432`, с хоста - `localhost:5433`.

## Локальный запуск
Сначала поднимите инфраструктуру:
```powershell
docker compose up -d db redis
```

Затем запустите API:
```powershell
cd server-go
$env:DATABASE_URL="postgres://polyapp:polyapp@localhost:5433/polyapp?sslmode=disable"
$env:REDIS_ADDR="localhost:6380"
$env:JWT_SECRET="dev-secret"
go run ./cmd/api
```

По умолчанию API слушает порт `8000`.

## Полный сброс и демо-наполнение
Из корня репозитория:
```powershell
./scripts/reset_demo_data.ps1 -DatabaseUrl "postgres://polyapp:polyapp@localhost:5433/polyapp?sslmode=disable"
```

Напрямую из папки сервера:
```powershell
cd server-go
$env:DATABASE_URL="postgres://polyapp:polyapp@localhost:5433/polyapp?sslmode=disable"
go run ./cmd/demo-reset
```

Сброс удаляет текущие данные и заново создает демо-набор: пользователей, отделения, группы, кураторов, студентов, преподавание, заявки, отработки, экзамены, новости, оценки, посещаемость и пресеты журнала.

Пароль всех демо-пользователей: `Demo1234`.

## Конфигурация
Основные переменные окружения:
- `HTTP_PORT` - порт API, по умолчанию `8000`.
- `DATABASE_URL` - строка подключения PostgreSQL.
- `REDIS_ADDR` - адрес Redis.
- `REDIS_PASSWORD` - пароль Redis, если нужен.
- `REDIS_DB` - номер Redis DB.
- `JWT_SECRET` - секрет подписи JWT.
- `CORS_ORIGIN` - разрешенный origin, в dev можно `*`.
- `SESSION_TTL_HOURS` - время жизни сессии.
- `MEDIA_DIR` - каталог медиафайлов, по умолчанию `./data`.
- `SEED_DEMO` - `true` включает демо-сид при старте API.

## Команды
```powershell
go mod download
go run ./cmd/api
go run ./cmd/demo-reset
go test ./...
go test ./... -cover
```

## Важные модули
- `cmd/api` - entrypoint API.
- `cmd/demo-reset` - полное пересоздание демо-данных.
- `internal/app` - bootstrap, миграции, сидер.
- `internal/config` - конфигурация окружения.
- `internal/domain` - доменные сущности.
- `internal/usecase` - бизнес-логика.
- `internal/infrastructure` - PostgreSQL, Redis, security, repositories.
- `internal/interface/http` - HTTP маршруты и handlers.

## Админские права
Поддерживаемые permissions:
- `users_manage`
- `schedule_manage`
- `academic_manage`
- `departments_manage`
- `analytics_view`
- `all`

## Работа с группами
Группа может иметь базовую запись и scoped-записи преподавателей. При полном удалении группы через endpoint отделений/журнала удаляются связанные оценки, посещаемость, заявки, аналитические данные, экзамены, отработки, назначения преподавателей и привязки к отделениям. Студенты остаются в системе, но очищается их `student_group`.

## Проверка API
```powershell
Invoke-RestMethod http://localhost:8000/health
```
