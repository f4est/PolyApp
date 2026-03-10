# PolyApp Migration (Go + PostgreSQL + Redis)

Проект переведён с Python backend на Go backend.

## Что изменено

- Новый backend: `server-go` (Gin + Gorm + JWT + Redis sessions).
- База данных: `PostgreSQL` вместо `SQLite`.
- Кэш/сессии: `Redis`.
- Контейнеризация: `docker-compose.yml` (api + db + redis).
- Flutter UI: адаптивный каркас с отдельными layout-паттернами для:
  - web
  - desktop (Windows/macOS/Linux)
  - mobile

## Быстрый запуск через Docker

```bash
docker compose up --build
```

API будет доступен на:

- `http://localhost:8000`
- health-check: `GET /health`

## Запуск тестов backend (TDD слой)

```bash
cd server-go
go test ./...
```

## Frontend

Flutter использует:

```dart
const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000',
);
```

Пример запуска Flutter Web с явным API URL:

```bash
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000
```

## Важно

Старый Python-код перенесён в `legacy-files/server-legacy` как legacy-референс, но новый runtime — это `server-go`.
