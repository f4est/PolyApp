package cache

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
)

func NewRedisClient(addr, password string, db int) *redis.Client {
	return redis.NewClient(&redis.Options{
		Addr:         addr,
		Password:     password,
		DB:           db,
		DialTimeout:  5 * time.Second,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 5 * time.Second,
	})
}

func Ping(ctx context.Context, client *redis.Client) error {
	return client.Ping(ctx).Err()
}
