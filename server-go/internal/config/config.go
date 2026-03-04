package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

type Config struct {
	HTTPPort        string
	DatabaseURL     string
	RedisAddr       string
	RedisPassword   string
	RedisDB         int
	JWTSecret       string
	CORSOrigin      string
	SessionTTL      time.Duration
	MediaDir        string
	SeedDemoOnStart bool
}

func Load() Config {
	cfg := Config{
		HTTPPort:      getEnv("HTTP_PORT", "8000"),
		DatabaseURL:   getEnv("DATABASE_URL", "postgres://polyapp:polyapp@localhost:5432/polyapp?sslmode=disable"),
		RedisAddr:     getEnv("REDIS_ADDR", "localhost:6379"),
		RedisPassword: getEnv("REDIS_PASSWORD", ""),
		JWTSecret:     getEnv("JWT_SECRET", "dev-secret-change"),
		CORSOrigin:    getEnv("CORS_ORIGIN", "*"),
		MediaDir:      getEnv("MEDIA_DIR", "./data"),
	}
	cfg.RedisDB = getEnvInt("REDIS_DB", 0)
	cfg.SessionTTL = time.Duration(getEnvInt("SESSION_TTL_HOURS", 24*7)) * time.Hour
	cfg.SeedDemoOnStart = getEnv("SEED_DEMO", "false") == "true"
	return cfg
}

func (c Config) Address() string {
	return fmt.Sprintf(":%s", c.HTTPPort)
}

func getEnv(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	value := getEnv(key, "")
	if value == "" {
		return fallback
	}
	number, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return number
}
