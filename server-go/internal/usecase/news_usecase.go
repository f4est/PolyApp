package usecase

import (
	"context"
	"strings"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
	"polyapp/server-go/internal/domain/repository"
)

type NewsUseCase struct {
	repo repository.NewsRepository
}

func NewNewsUseCase(repo repository.NewsRepository) *NewsUseCase {
	return &NewsUseCase{repo: repo}
}

func (u *NewsUseCase) List(ctx context.Context, offset, limit int, category string, currentUserID uint) ([]entity.NewsPost, error) {
	if limit <= 0 {
		limit = 20
	}
	if limit > 100 {
		limit = 100
	}
	if offset < 0 {
		offset = 0
	}
	return u.repo.List(ctx, offset, limit, strings.TrimSpace(category), currentUserID)
}

func (u *NewsUseCase) Get(ctx context.Context, postID, currentUserID uint) (*entity.NewsPost, error) {
	if postID == 0 {
		return nil, domainErrors.ErrInvalidInput
	}
	return u.repo.Get(ctx, postID, currentUserID)
}

func (u *NewsUseCase) Create(ctx context.Context, post *entity.NewsPost) error {
	if post == nil || strings.TrimSpace(post.Title) == "" || strings.TrimSpace(post.Body) == "" || post.AuthorID == 0 {
		return domainErrors.ErrInvalidInput
	}
	if strings.TrimSpace(post.Category) == "" {
		post.Category = "news"
	}
	return u.repo.Create(ctx, post)
}

func (u *NewsUseCase) Update(ctx context.Context, post *entity.NewsPost) error {
	if post == nil || post.ID == 0 {
		return domainErrors.ErrInvalidInput
	}
	if post.Title != "" {
		post.Title = strings.TrimSpace(post.Title)
	}
	if post.Body != "" {
		post.Body = strings.TrimSpace(post.Body)
	}
	if post.Category != "" {
		post.Category = strings.TrimSpace(post.Category)
	}
	return u.repo.Update(ctx, post)
}

func (u *NewsUseCase) Delete(ctx context.Context, postID uint) error {
	if postID == 0 {
		return domainErrors.ErrInvalidInput
	}
	return u.repo.Delete(ctx, postID)
}

func (u *NewsUseCase) AddComment(ctx context.Context, postID, userID uint, text string) (*entity.NewsComment, error) {
	if postID == 0 || userID == 0 || strings.TrimSpace(text) == "" {
		return nil, domainErrors.ErrInvalidInput
	}
	return u.repo.AddComment(ctx, postID, userID, strings.TrimSpace(text))
}

func (u *NewsUseCase) UpdateComment(ctx context.Context, postID, commentID uint, text string) (*entity.NewsComment, error) {
	if postID == 0 || commentID == 0 || strings.TrimSpace(text) == "" {
		return nil, domainErrors.ErrInvalidInput
	}
	return u.repo.UpdateComment(ctx, postID, commentID, strings.TrimSpace(text))
}

func (u *NewsUseCase) DeleteComment(ctx context.Context, postID, commentID uint) error {
	if postID == 0 || commentID == 0 {
		return domainErrors.ErrInvalidInput
	}
	return u.repo.DeleteComment(ctx, postID, commentID)
}

func (u *NewsUseCase) ToggleReaction(ctx context.Context, postID, userID uint, like *bool, reaction string) (*entity.NewsLikeResult, error) {
	if postID == 0 || userID == 0 {
		return nil, domainErrors.ErrInvalidInput
	}
	normalized := strings.TrimSpace(strings.ToLower(reaction))
	if normalized == "" {
		normalized = "like"
	}
	if like != nil && !*like {
		normalized = ""
	}
	return u.repo.ToggleReaction(ctx, postID, userID, normalized)
}

func (u *NewsUseCase) Share(ctx context.Context, postID, userID uint) (int, bool, error) {
	if postID == 0 || userID == 0 {
		return 0, false, domainErrors.ErrInvalidInput
	}
	return u.repo.IncrementShare(ctx, postID, userID)
}

func (u *NewsUseCase) AddMedia(ctx context.Context, postID uint, media []entity.NewsMedia) error {
	if postID == 0 {
		return domainErrors.ErrInvalidInput
	}
	if len(media) == 0 {
		return nil
	}
	return u.repo.AddMedia(ctx, postID, media)
}
