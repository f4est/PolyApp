package service

import (
	"context"

	"polyapp/server-go/internal/domain/entity"
)

type PasswordService interface {
	Hash(password string) (string, error)
	Compare(hash, password string) bool
}

type TokenService interface {
	Generate(claims entity.TokenClaims) (string, error)
	Parse(token string) (*entity.TokenClaims, error)
}

type Clock interface {
	Now() int64
}

type ContextUserProvider interface {
	UserFromContext(ctx context.Context) (*entity.User, error)
}
