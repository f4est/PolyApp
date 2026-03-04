package http

import (
	"errors"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

type newsCreatePayload struct {
	Title    string `json:"title"`
	Body     string `json:"body"`
	Category string `json:"category"`
	Pinned   *bool  `json:"pinned"`
}

type newsUpdatePayload struct {
	Title    *string `json:"title"`
	Body     *string `json:"body"`
	Category *string `json:"category"`
	Pinned   *bool   `json:"pinned"`
}

type newsLikePayload struct {
	Like     *bool  `json:"like"`
	Reaction string `json:"reaction"`
}

type newsCommentPayload struct {
	Text string `json:"text"`
}

func (h *Handler) RegisterNewsRoutes(router *gin.Engine, auth *httpMiddleware.AuthMiddleware) {
	group := router.Group("/news")
	group.Use(auth.RequireAuth())
	{
		group.POST("", httpMiddleware.RequireRoles("smm", "admin", "teacher"), h.createNews)
		group.GET("", h.listNews)
		group.GET("/:id", h.getNews)
		group.PATCH("/:id", h.updateNews)
		group.DELETE("/:id", h.deleteNews)
		group.POST("/:id/like", h.toggleLike)
		group.POST("/:id/comment", h.addComment)
		group.DELETE("/:id/comment/:commentId", h.deleteComment)
		group.POST("/:id/share", h.shareNews)
	}
}

func (h *Handler) createNews(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	var payload newsCreatePayload
	pinned := false
	var mediaFiles []*multipart.FileHeader

	contentType := strings.ToLower(c.GetHeader("Content-Type"))
	if strings.Contains(contentType, "multipart/form-data") {
		payload.Title = c.PostForm("title")
		payload.Body = c.PostForm("body")
		payload.Category = c.PostForm("category")
		if rawPinned := strings.TrimSpace(c.PostForm("pinned")); rawPinned != "" {
			val := strings.EqualFold(rawPinned, "true")
			pinned = val
			payload.Pinned = &val
		}
		form, err := c.MultipartForm()
		if err == nil && form != nil {
			mediaFiles = form.File["files"]
		}
	} else {
		if err := c.ShouldBindJSON(&payload); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
			return
		}
		if payload.Pinned != nil {
			pinned = *payload.Pinned
		}
	}

	post := &entity.NewsPost{
		Title:    payload.Title,
		Body:     payload.Body,
		AuthorID: currentUser.ID,
		Category: payload.Category,
		Pinned:   pinned,
	}
	if err := h.newsUC.Create(c.Request.Context(), post); err != nil {
		if errors.Is(err, domainErrors.ErrInvalidInput) {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to create post"})
		return
	}

	media := make([]entity.NewsMedia, 0, len(mediaFiles))
	for _, header := range mediaFiles {
		item, err := h.saveNewsMedia(header)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": err.Error()})
			return
		}
		media = append(media, item)
	}
	if err := h.newsUC.AddMedia(c.Request.Context(), post.ID, media); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save media"})
		return
	}

	full, err := h.newsUC.Get(c.Request.Context(), post.ID, currentUser.ID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load post"})
		return
	}
	c.JSON(http.StatusOK, mapNewsPost(*full))
}

func (h *Handler) listNews(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "20"))
	category := strings.TrimSpace(c.Query("category"))
	items, err := h.newsUC.List(c.Request.Context(), offset, limit, category, currentUser.ID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load news"})
		return
	}
	out := make([]gin.H, 0, len(items))
	for _, item := range items {
		out = append(out, mapNewsPost(item))
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) getNews(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid post id"})
		return
	}
	post, err := h.newsUC.Get(c.Request.Context(), id, currentUser.ID)
	if err != nil {
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Post not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load post"})
		return
	}
	c.JSON(http.StatusOK, mapNewsPost(*post))
}

func (h *Handler) updateNews(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid post id"})
		return
	}
	existing, err := h.newsUC.Get(c.Request.Context(), id, currentUser.ID)
	if err != nil {
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Post not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load post"})
		return
	}
	if !canManagePost(currentUser, *existing) {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	var payload newsUpdatePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	update := &entity.NewsPost{
		ID:     id,
		Pinned: existing.Pinned,
	}
	if payload.Title != nil {
		update.Title = *payload.Title
	}
	if payload.Body != nil {
		update.Body = *payload.Body
	}
	if payload.Category != nil {
		update.Category = *payload.Category
	}
	if payload.Pinned != nil {
		update.Pinned = *payload.Pinned
	}
	if err := h.newsUC.Update(c.Request.Context(), update); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update post"})
		return
	}
	updated, err := h.newsUC.Get(c.Request.Context(), id, currentUser.ID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load post"})
		return
	}
	c.JSON(http.StatusOK, mapNewsPost(*updated))
}

func (h *Handler) deleteNews(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid post id"})
		return
	}
	existing, err := h.newsUC.Get(c.Request.Context(), id, currentUser.ID)
	if err != nil {
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Post not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load post"})
		return
	}
	if !canManagePost(currentUser, *existing) {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	if err := h.newsUC.Delete(c.Request.Context(), id); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete post"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) toggleLike(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid post id"})
		return
	}
	var payload newsLikePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	result, err := h.newsUC.ToggleReaction(c.Request.Context(), id, currentUser.ID, payload.Like, payload.Reaction)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to set reaction"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"likes_count":     result.LikesCount,
		"liked":           result.Liked,
		"reaction_counts": result.ReactionCounts,
		"my_reaction":     result.MyReaction,
	})
}

func (h *Handler) addComment(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid post id"})
		return
	}
	var payload newsCommentPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	comment, err := h.newsUC.AddComment(c.Request.Context(), id, currentUser.ID, payload.Text)
	if err != nil {
		if errors.Is(err, domainErrors.ErrInvalidInput) {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Comment is required"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to add comment"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"id":         comment.ID,
		"user_id":    comment.UserID,
		"user_name":  comment.UserName,
		"text":       comment.Text,
		"created_at": comment.CreatedAt.Format(time.RFC3339),
	})
}

func (h *Handler) deleteComment(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	postID, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid post id"})
		return
	}
	commentID, err := parseUintParam(c, "commentId")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid comment id"})
		return
	}
	post, err := h.newsUC.Get(c.Request.Context(), postID, currentUser.ID)
	if err != nil {
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Post not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load post"})
		return
	}
	if !canManagePost(currentUser, *post) {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	if err := h.newsUC.DeleteComment(c.Request.Context(), postID, commentID); err != nil {
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Comment not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete comment"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) shareNews(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid post id"})
		return
	}
	count, err := h.newsUC.Share(c.Request.Context(), id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to share post"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"share_count": count})
}

func canManagePost(user *entity.User, post entity.NewsPost) bool {
	if user == nil {
		return false
	}
	if user.Role == "admin" || user.Role == "smm" {
		return true
	}
	return post.AuthorID == user.ID
}

func mapNewsPost(post entity.NewsPost) gin.H {
	media := make([]gin.H, 0, len(post.Media))
	for _, item := range post.Media {
		media = append(media, gin.H{
			"id":            item.ID,
			"url":           item.URL,
			"media_type":    item.MediaType,
			"original_name": item.OriginalName,
			"mime_type":     nullOrString(item.MimeType),
			"size":          item.Size,
		})
	}
	comments := make([]gin.H, 0, len(post.Comments))
	for _, item := range post.Comments {
		comments = append(comments, gin.H{
			"id":         item.ID,
			"user_id":    item.UserID,
			"user_name":  item.UserName,
			"text":       item.Text,
			"created_at": item.CreatedAt.Format(time.RFC3339),
		})
	}
	updatedAt := any(nil)
	if post.UpdatedAt != nil && !post.UpdatedAt.IsZero() {
		updatedAt = post.UpdatedAt.Format(time.RFC3339)
	}
	return gin.H{
		"id":             post.ID,
		"title":          post.Title,
		"body":           post.Body,
		"author_id":      post.AuthorID,
		"author_name":    post.AuthorName,
		"category":       post.Category,
		"pinned":         post.Pinned,
		"created_at":     post.CreatedAt.Format(time.RFC3339),
		"updated_at":     updatedAt,
		"share_count":    post.ShareCount,
		"likes_count":    post.LikesCount,
		"comments_count": post.CommentsCount,
		"liked_by_me":    post.LikedByMe,
		"reaction_counts": func() map[string]int {
			if post.ReactionCounts == nil {
				return map[string]int{}
			}
			return post.ReactionCounts
		}(),
		"my_reaction": post.MyReaction,
		"media":       media,
		"comments":    comments,
	}
}

func parseUintParam(c *gin.Context, name string) (uint, error) {
	value := strings.TrimSpace(c.Param(name))
	id, err := strconv.ParseUint(value, 10, 64)
	if err != nil || id == 0 {
		return 0, errors.New("invalid id")
	}
	return uint(id), nil
}

func (h *Handler) saveNewsMedia(file *multipart.FileHeader) (entity.NewsMedia, error) {
	if file == nil {
		return entity.NewsMedia{}, errors.New("invalid media")
	}
	if file.Size > 50*1024*1024 {
		return entity.NewsMedia{}, errors.New("file is too large")
	}
	src, err := file.Open()
	if err != nil {
		return entity.NewsMedia{}, err
	}
	defer src.Close()

	ext := strings.ToLower(filepath.Ext(file.Filename))
	stored := uuid.NewString() + ext
	target := filepath.Join(h.cfg.MediaDir, "news", stored)

	dst, err := os.Create(target)
	if err != nil {
		return entity.NewsMedia{}, err
	}
	defer dst.Close()
	if _, err := io.Copy(dst, src); err != nil {
		return entity.NewsMedia{}, err
	}

	mediaType := "file"
	mimeType := file.Header.Get("Content-Type")
	switch {
	case strings.HasPrefix(mimeType, "image/"):
		mediaType = "image"
	case strings.HasPrefix(mimeType, "video/"):
		mediaType = "video"
	}

	return entity.NewsMedia{
		URL:          "/media/news/" + stored,
		MediaType:    mediaType,
		OriginalName: file.Filename,
		MimeType:     mimeType,
		Size:         file.Size,
	}, nil
}
