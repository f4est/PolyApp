package repository

import (
	"context"

	"polyapp/server-go/internal/domain/entity"
)

type NewsRepository interface {
	List(ctx context.Context, offset, limit int, category string, currentUserID uint) ([]entity.NewsPost, error)
	Get(ctx context.Context, postID uint, currentUserID uint) (*entity.NewsPost, error)
	Create(ctx context.Context, post *entity.NewsPost) error
	Update(ctx context.Context, post *entity.NewsPost) error
	Delete(ctx context.Context, postID uint) error
	AddComment(ctx context.Context, postID, userID uint, text string) (*entity.NewsComment, error)
	UpdateComment(ctx context.Context, postID, commentID uint, text string) (*entity.NewsComment, error)
	DeleteComment(ctx context.Context, postID, commentID uint) error
	ToggleReaction(ctx context.Context, postID, userID uint, reaction string) (*entity.NewsLikeResult, error)
	IncrementShare(ctx context.Context, postID, userID uint) (int, bool, error)
	AddMedia(ctx context.Context, postID uint, media []entity.NewsMedia) error
}
