package repository

import (
	"context"

	"polyapp/server-go/internal/domain/entity"
)

type UserRepository interface {
	Create(ctx context.Context, user *entity.User) error
	GetByID(ctx context.Context, id uint) (*entity.User, error)
	GetByEmail(ctx context.Context, email string) (*entity.User, error)
	List(ctx context.Context, role string) ([]entity.User, error)
	Update(ctx context.Context, user *entity.User) error
}

type SessionRepository interface {
	Save(ctx context.Context, session entity.AuthSession) error
	GetByID(ctx context.Context, sessionID string) (*entity.AuthSession, error)
	Revoke(ctx context.Context, sessionID string) error
}

type SessionCache interface {
	Set(ctx context.Context, sessionID string, userID uint) error
	Touch(ctx context.Context, sessionID string) error
	Get(ctx context.Context, sessionID string) (uint, error)
	Delete(ctx context.Context, sessionID string) error
}
