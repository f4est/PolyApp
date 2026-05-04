package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"polyapp/server-go/internal/app"
	"polyapp/server-go/internal/config"
	"polyapp/server-go/internal/infrastructure/persistence"
	"polyapp/server-go/internal/infrastructure/security"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()

	cfg := config.Load()
	db, err := persistence.OpenPostgres(cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("connect postgres: %v", err)
	}
	if err := persistence.AutoMigrate(db); err != nil {
		log.Fatalf("migrate database: %v", err)
	}

	if err := app.ResetAndSeedDemo(ctx, db, security.BcryptPasswordService{}, cfg.MediaDir); err != nil {
		log.Fatalf("reset and seed failed: %v", err)
	}
	fmt.Println("demo reset complete")
}
