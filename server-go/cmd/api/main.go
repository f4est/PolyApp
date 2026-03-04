package main

import (
	"context"
	"log"

	"polyapp/server-go/internal/app"
)

func main() {
	ctx := context.Background()
	runtime, err := app.Bootstrap(ctx)
	if err != nil {
		log.Fatalf("bootstrap failed: %v", err)
	}
	log.Printf("polyapp-go api started on %s", runtime.Config.Address())
	if err := runtime.Router.Run(runtime.Config.Address()); err != nil {
		log.Fatalf("server stopped: %v", err)
	}
}
