package cache

import (
	"context"
	"fmt"
	"strconv"
	"time"

	domainErrors "polyapp/server-go/internal/domain/errors"

	"github.com/redis/go-redis/v9"
)

type RedisSessionCache struct {
	client *redis.Client
	ttl    time.Duration
}

func NewRedisSessionCache(client *redis.Client, ttl time.Duration) *RedisSessionCache {
	return &RedisSessionCache{
		client: client,
		ttl:    ttl,
	}
}

func (c *RedisSessionCache) key(sessionID string) string {
	return fmt.Sprintf("session:%s", sessionID)
}

func (c *RedisSessionCache) Set(ctx context.Context, sessionID string, userID uint) error {
	return c.client.Set(ctx, c.key(sessionID), strconv.FormatUint(uint64(userID), 10), c.ttl).Err()
}

func (c *RedisSessionCache) Touch(ctx context.Context, sessionID string) error {
	ok, err := c.client.Expire(ctx, c.key(sessionID), c.ttl).Result()
	if err != nil {
		return err
	}
	if !ok {
		return domainErrors.ErrNotFound
	}
	return nil
}

func (c *RedisSessionCache) Get(ctx context.Context, sessionID string) (uint, error) {
	value, err := c.client.Get(ctx, c.key(sessionID)).Result()
	if err == redis.Nil {
		return 0, domainErrors.ErrNotFound
	}
	if err != nil {
		return 0, err
	}
	number, parseErr := strconv.ParseUint(value, 10, 64)
	if parseErr != nil {
		return 0, parseErr
	}
	return uint(number), nil
}

func (c *RedisSessionCache) Delete(ctx context.Context, sessionID string) error {
	return c.client.Del(ctx, c.key(sessionID)).Err()
}
