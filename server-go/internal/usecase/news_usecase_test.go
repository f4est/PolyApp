package usecase

import (
	"context"
	"errors"
	"testing"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
)

type fakeNewsRepo struct {
	posts      map[uint]entity.NewsPost
	nextPostID uint
	shares     map[uint]map[uint]bool
}

func newFakeNewsRepo() *fakeNewsRepo {
	return &fakeNewsRepo{
		posts:      map[uint]entity.NewsPost{},
		nextPostID: 1,
		shares:     map[uint]map[uint]bool{},
	}
}

func (r *fakeNewsRepo) List(_ context.Context, offset, limit int, _ string, _ uint) ([]entity.NewsPost, error) {
	all := make([]entity.NewsPost, 0, len(r.posts))
	for _, post := range r.posts {
		all = append(all, post)
	}
	if offset >= len(all) {
		return []entity.NewsPost{}, nil
	}
	end := offset + limit
	if end > len(all) {
		end = len(all)
	}
	return all[offset:end], nil
}

func (r *fakeNewsRepo) Get(_ context.Context, postID uint, _ uint) (*entity.NewsPost, error) {
	post, ok := r.posts[postID]
	if !ok {
		return nil, domainErrors.ErrNotFound
	}
	copy := post
	return &copy, nil
}

func (r *fakeNewsRepo) Create(_ context.Context, post *entity.NewsPost) error {
	post.ID = r.nextPostID
	r.nextPostID++
	post.CreatedAt = time.Now().UTC()
	if post.ReactionCounts == nil {
		post.ReactionCounts = map[string]int{}
	}
	copy := *post
	r.posts[post.ID] = copy
	return nil
}

func (r *fakeNewsRepo) Update(_ context.Context, post *entity.NewsPost) error {
	current, ok := r.posts[post.ID]
	if !ok {
		return domainErrors.ErrNotFound
	}
	if post.Title != "" {
		current.Title = post.Title
	}
	if post.Body != "" {
		current.Body = post.Body
	}
	if post.Category != "" {
		current.Category = post.Category
	}
	if post.UpdatedAt != nil {
		current.UpdatedAt = post.UpdatedAt
	}
	current.Pinned = post.Pinned
	r.posts[post.ID] = current
	return nil
}

func (r *fakeNewsRepo) Delete(_ context.Context, postID uint) error {
	delete(r.posts, postID)
	return nil
}

func (r *fakeNewsRepo) AddComment(_ context.Context, postID, userID uint, text string) (*entity.NewsComment, error) {
	post, ok := r.posts[postID]
	if !ok {
		return nil, domainErrors.ErrNotFound
	}
	comment := entity.NewsComment{
		ID:        uint(len(post.Comments) + 1),
		UserID:    userID,
		UserName:  "User",
		UserRole:  "student",
		Text:      text,
		CreatedAt: time.Now().UTC(),
	}
	post.Comments = append(post.Comments, comment)
	post.CommentsCount = len(post.Comments)
	r.posts[postID] = post
	return &comment, nil
}

func (r *fakeNewsRepo) UpdateComment(_ context.Context, postID, commentID uint, text string) (*entity.NewsComment, error) {
	post, ok := r.posts[postID]
	if !ok {
		return nil, domainErrors.ErrNotFound
	}
	for i := range post.Comments {
		if post.Comments[i].ID == commentID {
			post.Comments[i].Text = text
			now := time.Now().UTC()
			post.Comments[i].UpdatedAt = &now
			r.posts[postID] = post
			comment := post.Comments[i]
			return &comment, nil
		}
	}
	return nil, domainErrors.ErrNotFound
}

func (r *fakeNewsRepo) DeleteComment(_ context.Context, postID, commentID uint) error {
	post, ok := r.posts[postID]
	if !ok {
		return domainErrors.ErrNotFound
	}
	filtered := make([]entity.NewsComment, 0, len(post.Comments))
	for _, c := range post.Comments {
		if c.ID != commentID {
			filtered = append(filtered, c)
		}
	}
	post.Comments = filtered
	post.CommentsCount = len(filtered)
	r.posts[postID] = post
	return nil
}

func (r *fakeNewsRepo) ToggleReaction(_ context.Context, postID, _ uint, reaction string) (*entity.NewsLikeResult, error) {
	post, ok := r.posts[postID]
	if !ok {
		return nil, domainErrors.ErrNotFound
	}
	if post.ReactionCounts == nil {
		post.ReactionCounts = map[string]int{}
	}
	if reaction == "" {
		post.ReactionCounts = map[string]int{}
		post.LikesCount = 0
		post.LikedByMe = false
		post.MyReaction = nil
		r.posts[postID] = post
		return &entity.NewsLikeResult{
			LikesCount:     0,
			Liked:          false,
			ReactionCounts: map[string]int{},
		}, nil
	}
	post.ReactionCounts[reaction]++
	total := 0
	for _, count := range post.ReactionCounts {
		total += count
	}
	post.LikesCount = total
	post.LikedByMe = true
	post.MyReaction = &reaction
	r.posts[postID] = post
	return &entity.NewsLikeResult{
		LikesCount:     total,
		Liked:          true,
		ReactionCounts: post.ReactionCounts,
		MyReaction:     &reaction,
	}, nil
}

func (r *fakeNewsRepo) IncrementShare(_ context.Context, postID, userID uint) (int, bool, error) {
	post, ok := r.posts[postID]
	if !ok {
		return 0, false, domainErrors.ErrNotFound
	}
	if r.shares[postID] == nil {
		r.shares[postID] = map[uint]bool{}
	}
	already := r.shares[postID][userID]
	if !already {
		post.ShareCount++
		r.shares[postID][userID] = true
	}
	r.posts[postID] = post
	return post.ShareCount, !already, nil
}

func (r *fakeNewsRepo) AddMedia(_ context.Context, postID uint, media []entity.NewsMedia) error {
	post, ok := r.posts[postID]
	if !ok {
		return domainErrors.ErrNotFound
	}
	post.Media = append(post.Media, media...)
	r.posts[postID] = post
	return nil
}

func TestNewsUseCase_CreateListAndUpdate(t *testing.T) {
	repo := newFakeNewsRepo()
	uc := NewNewsUseCase(repo)
	ctx := context.Background()

	post := &entity.NewsPost{
		Title:    "Hello",
		Body:     "Body",
		AuthorID: 1,
	}
	if err := uc.Create(ctx, post); err != nil {
		t.Fatalf("create failed: %v", err)
	}
	if post.ID == 0 {
		t.Fatalf("post id is not assigned")
	}
	if post.Category != "news" {
		t.Fatalf("expected default category news")
	}

	items, err := uc.List(ctx, 0, 20, "", 1)
	if err != nil {
		t.Fatalf("list failed: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("expected 1 item, got %d", len(items))
	}

	updatedBody := "Updated body"
	post.Body = updatedBody
	if err := uc.Update(ctx, post); err != nil {
		t.Fatalf("update failed: %v", err)
	}
	got, err := uc.Get(ctx, post.ID, 1)
	if err != nil {
		t.Fatalf("get failed: %v", err)
	}
	if got.Body != updatedBody {
		t.Fatalf("unexpected body: %s", got.Body)
	}
}

func TestNewsUseCase_CommentsReactionsAndShare(t *testing.T) {
	repo := newFakeNewsRepo()
	uc := NewNewsUseCase(repo)
	ctx := context.Background()

	post := &entity.NewsPost{
		Title:    "Post",
		Body:     "Body",
		AuthorID: 1,
	}
	if err := uc.Create(ctx, post); err != nil {
		t.Fatalf("create failed: %v", err)
	}

	comment, err := uc.AddComment(ctx, post.ID, 5, "Cool")
	if err != nil {
		t.Fatalf("add comment failed: %v", err)
	}
	if comment.Text != "Cool" {
		t.Fatalf("unexpected comment text")
	}
	updatedComment, err := uc.UpdateComment(ctx, post.ID, comment.ID, "Updated")
	if err != nil {
		t.Fatalf("update comment failed: %v", err)
	}
	if updatedComment.Text != "Updated" {
		t.Fatalf("unexpected updated comment text")
	}
	if err := uc.DeleteComment(ctx, post.ID, comment.ID); err != nil {
		t.Fatalf("delete comment failed: %v", err)
	}

	result, err := uc.ToggleReaction(ctx, post.ID, 5, nil, "like")
	if err != nil {
		t.Fatalf("toggle reaction failed: %v", err)
	}
	if !result.Liked || result.LikesCount != 1 {
		t.Fatalf("unexpected reaction result: %+v", result)
	}

	disable := false
	result, err = uc.ToggleReaction(ctx, post.ID, 5, &disable, "like")
	if err != nil {
		t.Fatalf("toggle off failed: %v", err)
	}
	if result.Liked || result.LikesCount != 0 {
		t.Fatalf("expected no likes after toggle off")
	}

	shareCount, shared, err := uc.Share(ctx, post.ID, 5)
	if err != nil {
		t.Fatalf("share failed: %v", err)
	}
	if shareCount != 1 {
		t.Fatalf("expected share count 1, got %d", shareCount)
	}
	if !shared {
		t.Fatalf("expected first share to be shared=true")
	}
	shareCount, shared, err = uc.Share(ctx, post.ID, 5)
	if err != nil {
		t.Fatalf("second share failed: %v", err)
	}
	if shareCount != 1 || shared {
		t.Fatalf("expected idempotent share, got count=%d shared=%v", shareCount, shared)
	}
}

func TestNewsUseCase_InvalidInput(t *testing.T) {
	repo := newFakeNewsRepo()
	uc := NewNewsUseCase(repo)

	err := uc.Create(context.Background(), &entity.NewsPost{})
	if !errors.Is(err, domainErrors.ErrInvalidInput) {
		t.Fatalf("expected invalid input, got: %v", err)
	}
}
