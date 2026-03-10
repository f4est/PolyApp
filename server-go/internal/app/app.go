package app

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"polyapp/server-go/internal/config"
	"polyapp/server-go/internal/infrastructure/cache"
	"polyapp/server-go/internal/infrastructure/persistence"
	"polyapp/server-go/internal/infrastructure/security"
	httpapi "polyapp/server-go/internal/interface/http"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"
	"polyapp/server-go/internal/usecase"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type Runtime struct {
	Config config.Config
	DB     *gorm.DB
	Redis  *redis.Client
	Router *gin.Engine
}

func Bootstrap(ctx context.Context) (*Runtime, error) {
	cfg := config.Load()

	if err := os.MkdirAll(filepath.Join(cfg.MediaDir, "news"), 0o755); err != nil {
		return nil, fmt.Errorf("create media/news dir: %w", err)
	}
	if err := os.MkdirAll(filepath.Join(cfg.MediaDir, "schedule"), 0o755); err != nil {
		return nil, fmt.Errorf("create media/schedule dir: %w", err)
	}

	db, err := persistence.OpenPostgres(cfg.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("connect postgres: %w", err)
	}
	if err := persistence.AutoMigrate(db); err != nil {
		return nil, fmt.Errorf("migrate database: %w", err)
	}
	if err := persistence.CleanupLegacyLabs(ctx, db); err != nil {
		return nil, fmt.Errorf("cleanup legacy labs: %w", err)
	}

	redisClient := cache.NewRedisClient(cfg.RedisAddr, cfg.RedisPassword, cfg.RedisDB)
	if err := cache.Ping(ctx, redisClient); err != nil {
		return nil, fmt.Errorf("connect redis: %w", err)
	}

	userRepo := persistence.NewUserRepo(db)
	sessionRepo := persistence.NewSessionRepo(db)
	newsRepo := persistence.NewNewsRepo(db)
	gradingRepo := persistence.NewGradingRepo(db)

	passwordService := security.BcryptPasswordService{}
	tokenService := security.NewJWTService(cfg.JWTSecret)
	sessionCache := cache.NewRedisSessionCache(redisClient, cfg.SessionTTL)
	formulaEngine := usecase.NewFormulaEngineUseCase()

	authUC := usecase.NewAuthUseCase(userRepo, sessionRepo, sessionCache, passwordService, tokenService)
	newsUC := usecase.NewNewsUseCase(newsRepo)
	presetUC := usecase.NewPresetUseCase(gradingRepo, formulaEngine)
	journalUC := usecase.NewJournalUseCase(gradingRepo, gradingRepo, formulaEngine)

	handler := httpapi.NewHandler(cfg, db, redisClient, authUC, newsUC, presetUC, journalUC, userRepo, newsRepo)
	authMiddleware := httpMiddleware.NewAuthMiddleware(tokenService, authUC)
	router := httpapi.NewRouter(handler, authMiddleware)

	if cfg.SeedDemoOnStart {
		if err := SeedDemo(ctx, db, passwordService); err != nil {
			return nil, fmt.Errorf("seed demo: %w", err)
		}
	}

	return &Runtime{
		Config: cfg,
		DB:     db,
		Redis:  redisClient,
		Router: router,
	}, nil
}
