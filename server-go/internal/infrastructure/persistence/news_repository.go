package persistence

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"

	"gorm.io/gorm"
)

type NewsRepo struct {
	db *gorm.DB
}

func NewNewsRepo(db *gorm.DB) *NewsRepo {
	return &NewsRepo{db: db}
}

func (r *NewsRepo) List(ctx context.Context, offset, limit int, category string, currentUserID uint) ([]entity.NewsPost, error) {
	var posts []DBNewsPost
	query := r.db.WithContext(ctx).Order("pinned desc").Order("created_at desc")
	if category != "" {
		query = query.Where("category = ?", category)
	}
	if err := query.Offset(offset).Limit(limit).Find(&posts).Error; err != nil {
		return nil, err
	}
	return r.mapPosts(ctx, posts, currentUserID)
}

func (r *NewsRepo) Get(ctx context.Context, postID uint, currentUserID uint) (*entity.NewsPost, error) {
	var post DBNewsPost
	if err := r.db.WithContext(ctx).First(&post, postID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, domainErrors.ErrNotFound
		}
		return nil, err
	}
	items, err := r.mapPosts(ctx, []DBNewsPost{post}, currentUserID)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, domainErrors.ErrNotFound
	}
	result := items[0]
	return &result, nil
}

func (r *NewsRepo) Create(ctx context.Context, post *entity.NewsPost) error {
	model := DBNewsPost{
		Title:      strings.TrimSpace(post.Title),
		Body:       strings.TrimSpace(post.Body),
		AuthorID:   post.AuthorID,
		Category:   strings.TrimSpace(post.Category),
		Pinned:     post.Pinned,
		ShareCount: 0,
	}
	if model.Category == "" {
		model.Category = "news"
	}
	if err := r.db.WithContext(ctx).Create(&model).Error; err != nil {
		return err
	}
	post.ID = model.ID
	post.CreatedAt = model.CreatedAt
	post.UpdatedAt = nil
	post.ShareCount = 0
	return nil
}

func (r *NewsRepo) Update(ctx context.Context, post *entity.NewsPost) error {
	updates := map[string]any{
		"pinned": post.Pinned,
	}
	if title := strings.TrimSpace(post.Title); title != "" {
		updates["title"] = title
	}
	if body := strings.TrimSpace(post.Body); body != "" {
		updates["body"] = body
	}
	if category := strings.TrimSpace(post.Category); category != "" {
		updates["category"] = category
	}
	updates["updated_at"] = time.Now().UTC()
	result := r.db.WithContext(ctx).Model(&DBNewsPost{}).Where("id = ?", post.ID).Updates(updates)
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return domainErrors.ErrNotFound
	}
	return nil
}

func (r *NewsRepo) Delete(ctx context.Context, postID uint) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("post_id = ?", postID).Delete(&DBNewsLike{}).Error; err != nil {
			return err
		}
		if err := tx.Where("post_id = ?", postID).Delete(&DBNewsComment{}).Error; err != nil {
			return err
		}
		if err := tx.Where("post_id = ?", postID).Delete(&DBNewsMedia{}).Error; err != nil {
			return err
		}
		res := tx.Delete(&DBNewsPost{}, postID)
		if res.Error != nil {
			return res.Error
		}
		if res.RowsAffected == 0 {
			return domainErrors.ErrNotFound
		}
		return nil
	})
}

func (r *NewsRepo) AddComment(ctx context.Context, postID, userID uint, text string) (*entity.NewsComment, error) {
	comment := DBNewsComment{
		PostID: postID,
		UserID: userID,
		Text:   strings.TrimSpace(text),
	}
	if err := r.db.WithContext(ctx).Create(&comment).Error; err != nil {
		return nil, err
	}
	var user DBUser
	if err := r.db.WithContext(ctx).First(&user, userID).Error; err != nil {
		return nil, err
	}
	return &entity.NewsComment{
		ID:        comment.ID,
		UserID:    userID,
		UserName:  user.FullName,
		Text:      comment.Text,
		CreatedAt: comment.CreatedAt,
	}, nil
}

func (r *NewsRepo) DeleteComment(ctx context.Context, postID, commentID uint) error {
	result := r.db.WithContext(ctx).
		Where("id = ? AND post_id = ?", commentID, postID).
		Delete(&DBNewsComment{})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return domainErrors.ErrNotFound
	}
	return nil
}

func (r *NewsRepo) ToggleReaction(ctx context.Context, postID, userID uint, reaction string) (*entity.NewsLikeResult, error) {
	err := r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var like DBNewsLike
		findErr := tx.Where("post_id = ? AND user_id = ?", postID, userID).First(&like).Error
		switch {
		case findErr == nil:
			if reaction == "" || like.Reaction == reaction {
				return tx.Delete(&like).Error
			}
			like.Reaction = reaction
			return tx.Save(&like).Error
		case errors.Is(findErr, gorm.ErrRecordNotFound):
			if reaction == "" {
				return nil
			}
			return tx.Create(&DBNewsLike{
				PostID:   postID,
				UserID:   userID,
				Reaction: reaction,
			}).Error
		default:
			return findErr
		}
	})
	if err != nil {
		return nil, err
	}

	counts, myReaction, err := r.reactionStats(ctx, postID, userID)
	if err != nil {
		return nil, err
	}
	total := 0
	for _, count := range counts {
		total += count
	}
	return &entity.NewsLikeResult{
		LikesCount:     total,
		Liked:          myReaction != nil,
		ReactionCounts: counts,
		MyReaction:     myReaction,
	}, nil
}

func (r *NewsRepo) IncrementShare(ctx context.Context, postID uint) (int, error) {
	result := r.db.WithContext(ctx).Model(&DBNewsPost{}).
		Where("id = ?", postID).
		UpdateColumn("share_count", gorm.Expr("share_count + 1"))
	if result.Error != nil {
		return 0, result.Error
	}
	if result.RowsAffected == 0 {
		return 0, domainErrors.ErrNotFound
	}
	var post DBNewsPost
	if err := r.db.WithContext(ctx).First(&post, postID).Error; err != nil {
		return 0, err
	}
	return post.ShareCount, nil
}

func (r *NewsRepo) AddMedia(ctx context.Context, postID uint, media []entity.NewsMedia) error {
	if len(media) == 0 {
		return nil
	}
	models := make([]DBNewsMedia, 0, len(media))
	for _, item := range media {
		models = append(models, DBNewsMedia{
			PostID:       postID,
			OriginalName: item.OriginalName,
			StoredName:   strings.TrimPrefix(item.URL, "/media/news/"),
			MediaType:    item.MediaType,
			MimeType:     item.MimeType,
			Size:         item.Size,
		})
	}
	return r.db.WithContext(ctx).Create(&models).Error
}

func (r *NewsRepo) reactionStats(ctx context.Context, postID, userID uint) (map[string]int, *string, error) {
	type row struct {
		Reaction string
		Count    int
	}
	var rows []row
	if err := r.db.WithContext(ctx).
		Model(&DBNewsLike{}).
		Select("reaction, count(*) as count").
		Where("post_id = ?", postID).
		Group("reaction").
		Scan(&rows).Error; err != nil {
		return nil, nil, err
	}
	counts := map[string]int{}
	for _, item := range rows {
		counts[item.Reaction] = item.Count
	}
	var my DBNewsLike
	if err := r.db.WithContext(ctx).Where("post_id = ? AND user_id = ?", postID, userID).First(&my).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return counts, nil, nil
		}
		return nil, nil, err
	}
	reaction := my.Reaction
	return counts, &reaction, nil
}

func (r *NewsRepo) mapPosts(ctx context.Context, posts []DBNewsPost, currentUserID uint) ([]entity.NewsPost, error) {
	if len(posts) == 0 {
		return []entity.NewsPost{}, nil
	}
	ids := make([]uint, 0, len(posts))
	authorIDs := make(map[uint]struct{}, len(posts))
	for _, post := range posts {
		ids = append(ids, post.ID)
		authorIDs[post.AuthorID] = struct{}{}
	}

	var users []DBUser
	if err := r.db.WithContext(ctx).Where("id IN ?", mapKeys(authorIDs)).Find(&users).Error; err != nil {
		return nil, err
	}
	userNameMap := map[uint]string{}
	for _, user := range users {
		userNameMap[user.ID] = user.FullName
	}

	var mediaRows []DBNewsMedia
	if err := r.db.WithContext(ctx).Where("post_id IN ?", ids).Order("id asc").Find(&mediaRows).Error; err != nil {
		return nil, err
	}
	mediaByPost := map[uint][]entity.NewsMedia{}
	for _, row := range mediaRows {
		mediaByPost[row.PostID] = append(mediaByPost[row.PostID], entity.NewsMedia{
			ID:           row.ID,
			URL:          fmt.Sprintf("/media/news/%s", row.StoredName),
			MediaType:    row.MediaType,
			OriginalName: row.OriginalName,
			MimeType:     row.MimeType,
			Size:         row.Size,
		})
	}

	var commentRows []DBNewsComment
	if err := r.db.WithContext(ctx).Where("post_id IN ?", ids).Order("created_at asc").Find(&commentRows).Error; err != nil {
		return nil, err
	}
	commentUserIDs := map[uint]struct{}{}
	for _, row := range commentRows {
		commentUserIDs[row.UserID] = struct{}{}
	}
	if len(commentUserIDs) > 0 {
		var commenters []DBUser
		if err := r.db.WithContext(ctx).Where("id IN ?", mapKeys(commentUserIDs)).Find(&commenters).Error; err != nil {
			return nil, err
		}
		for _, user := range commenters {
			userNameMap[user.ID] = user.FullName
		}
	}
	commentsByPost := map[uint][]entity.NewsComment{}
	for _, row := range commentRows {
		commentsByPost[row.PostID] = append(commentsByPost[row.PostID], entity.NewsComment{
			ID:        row.ID,
			UserID:    row.UserID,
			UserName:  userNameMap[row.UserID],
			Text:      row.Text,
			CreatedAt: row.CreatedAt,
		})
	}

	var likeRows []DBNewsLike
	if err := r.db.WithContext(ctx).Where("post_id IN ?", ids).Find(&likeRows).Error; err != nil {
		return nil, err
	}
	type reactionMeta struct {
		counts map[string]int
		my     *string
	}
	likesByPost := map[uint]reactionMeta{}
	for _, like := range likeRows {
		meta := likesByPost[like.PostID]
		if meta.counts == nil {
			meta.counts = map[string]int{}
		}
		meta.counts[like.Reaction]++
		if like.UserID == currentUserID {
			reaction := like.Reaction
			meta.my = &reaction
		}
		likesByPost[like.PostID] = meta
	}

	results := make([]entity.NewsPost, 0, len(posts))
	for _, post := range posts {
		meta := likesByPost[post.ID]
		totalLikes := 0
		for _, c := range meta.counts {
			totalLikes += c
		}
		updated := post.UpdatedAt
		out := entity.NewsPost{
			ID:             post.ID,
			Title:          post.Title,
			Body:           post.Body,
			AuthorID:       post.AuthorID,
			AuthorName:     userNameMap[post.AuthorID],
			Category:       post.Category,
			Pinned:         post.Pinned,
			CreatedAt:      post.CreatedAt,
			UpdatedAt:      &updated,
			ShareCount:     post.ShareCount,
			LikesCount:     totalLikes,
			CommentsCount:  len(commentsByPost[post.ID]),
			LikedByMe:      meta.my != nil,
			ReactionCounts: meta.counts,
			MyReaction:     meta.my,
			Media:          mediaByPost[post.ID],
			Comments:       commentsByPost[post.ID],
		}
		if post.UpdatedAt.IsZero() {
			out.UpdatedAt = nil
		}
		if out.ReactionCounts == nil {
			out.ReactionCounts = map[string]int{}
		}
		if out.Media == nil {
			out.Media = []entity.NewsMedia{}
		}
		if out.Comments == nil {
			out.Comments = []entity.NewsComment{}
		}
		results = append(results, out)
	}
	return results, nil
}

func mapKeys(in map[uint]struct{}) []uint {
	out := make([]uint, 0, len(in))
	for id := range in {
		out = append(out, id)
	}
	return out
}
