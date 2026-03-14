package http

import (
	"errors"
	"fmt"
	"html/template"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

var (
	publicNewsMediaToken = regexp.MustCompile(`^\s*\{\{media:(\d+)\}\}\s*$`)
	publicNewsImageMD    = regexp.MustCompile(`!\[[^\]]*\]\(([^)]+)\)`)
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
	router.GET("/news/public/:id", h.getPublicNews)
	router.GET("/media/news-download/*filepath", h.downloadNewsMedia)
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
		group.PATCH("/:id/comment/:commentId", h.updateComment)
		group.DELETE("/:id/comment/:commentId", h.deleteComment)
		group.POST("/:id/share", h.shareNews)
	}
}

func (h *Handler) getPublicNews(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid post id"})
		return
	}
	post, err := h.newsUC.Get(c.Request.Context(), id, 0)
	if err != nil {
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Post not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load post"})
		return
	}
	c.Header("Content-Type", "text/html; charset=utf-8")
	c.String(http.StatusOK, renderPublicNewsPage(c, *post))
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
	savedPaths := make([]string, 0, len(mediaFiles))
	for _, header := range mediaFiles {
		item, savedPath, err := h.saveNewsMedia(header)
		if err != nil {
			cleanupUploadedNewsFiles(savedPaths)
			_ = h.newsUC.Delete(c.Request.Context(), post.ID)
			c.JSON(http.StatusBadRequest, gin.H{"detail": err.Error()})
			return
		}
		media = append(media, item)
		savedPaths = append(savedPaths, savedPath)
	}
	if err := h.newsUC.AddMedia(c.Request.Context(), post.ID, media); err != nil {
		cleanupUploadedNewsFiles(savedPaths)
		_ = h.newsUC.Delete(c.Request.Context(), post.ID)
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
	c.JSON(http.StatusOK, mapNewsComment(*comment))
}

func (h *Handler) updateComment(c *gin.Context) {
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
	var payload newsCommentPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
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
	comment := findNewsComment(post.Comments, commentID)
	if comment == nil {
		c.JSON(http.StatusNotFound, gin.H{"detail": "Comment not found"})
		return
	}
	if !canManageComment(currentUser, *comment) {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	updated, err := h.newsUC.UpdateComment(c.Request.Context(), postID, commentID, payload.Text)
	if err != nil {
		if errors.Is(err, domainErrors.ErrInvalidInput) {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Comment is required"})
			return
		}
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Comment not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update comment"})
		return
	}
	c.JSON(http.StatusOK, mapNewsComment(*updated))
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
	comment := findNewsComment(post.Comments, commentID)
	if comment == nil {
		c.JSON(http.StatusNotFound, gin.H{"detail": "Comment not found"})
		return
	}
	if !canManageComment(currentUser, *comment) {
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
	count, shared, err := h.newsUC.Share(c.Request.Context(), id, currentUser.ID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to share post"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"share_count": count, "shared": shared})
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
		comments = append(comments, mapNewsComment(item))
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

func mapNewsComment(comment entity.NewsComment) gin.H {
	updatedAt := any(nil)
	if comment.UpdatedAt != nil && !comment.UpdatedAt.IsZero() {
		updatedAt = comment.UpdatedAt.Format(time.RFC3339)
	}
	return gin.H{
		"id":              comment.ID,
		"user_id":         comment.UserID,
		"user_name":       comment.UserName,
		"user_role":       nullOrString(comment.UserRole),
		"user_avatar_url": nullOrString(comment.UserAvatarURL),
		"text":            comment.Text,
		"created_at":      comment.CreatedAt.Format(time.RFC3339),
		"updated_at":      updatedAt,
	}
}

func findNewsComment(comments []entity.NewsComment, commentID uint) *entity.NewsComment {
	for i := range comments {
		if comments[i].ID == commentID {
			return &comments[i]
		}
	}
	return nil
}

func canManageComment(user *entity.User, comment entity.NewsComment) bool {
	if user == nil {
		return false
	}
	if user.Role == "admin" {
		return true
	}
	return comment.UserID == user.ID
}

func (h *Handler) downloadNewsMedia(c *gin.Context) {
	rel := strings.TrimSpace(c.Param("filepath"))
	rel = strings.TrimPrefix(rel, "/")
	if rel == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid media path"})
		return
	}
	cleanRel := filepath.Clean(rel)
	if cleanRel == "." || cleanRel == "" || strings.HasPrefix(cleanRel, "..") || filepath.IsAbs(cleanRel) {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid media path"})
		return
	}
	newsRoot := filepath.Clean(filepath.Join(h.cfg.MediaDir, "news"))
	target := filepath.Clean(filepath.Join(newsRoot, cleanRel))
	if target != newsRoot && !strings.HasPrefix(target, newsRoot+string(filepath.Separator)) {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid media path"})
		return
	}
	if _, err := os.Stat(target); err != nil {
		c.JSON(http.StatusNotFound, gin.H{"detail": "File not found"})
		return
	}
	c.FileAttachment(target, filepath.Base(cleanRel))
}

func renderPublicNewsPage(c *gin.Context, post entity.NewsPost) string {
	escape := template.HTMLEscapeString
	bodyHTML, usedMedia := renderPublicNewsBody(c, post)
	var builder strings.Builder
	builder.WriteString(`<!doctype html><html lang="ru"><head><meta charset="utf-8">`)
	builder.WriteString(`<meta name="viewport" content="width=device-width,initial-scale=1">`)
	builder.WriteString(`<title>`)
	builder.WriteString(escape(post.Title))
	builder.WriteString(`</title>`)
	builder.WriteString(`<style>body{font-family:Arial,sans-serif;max-width:980px;margin:0 auto;padding:20px;background:#f4f7f2;color:#1f2937}h1{margin:0 0 6px}.meta{color:#4b5563;margin-bottom:18px}.card{background:#fff;border:1px solid #d9e5dd;border-radius:14px;padding:16px;margin:12px 0}.body p{margin:0 0 8px;white-space:pre-wrap}.sp{height:8px}.media-block{margin:10px 0}.media-block img,.media-block video{display:block;max-width:100%;border-radius:12px;border:1px solid #d9e5dd}.file-row{display:flex;flex-wrap:wrap;gap:10px;align-items:center;padding:10px 12px;border:1px solid #d9e5dd;border-radius:12px;background:#f8fbf8}.file-name{font-weight:700}.actions a{display:inline-block;margin-right:10px;color:#0f766e;text-decoration:none}</style>`)
	builder.WriteString(`</head><body>`)
	builder.WriteString(`<h1>`)
	builder.WriteString(escape(post.Title))
	builder.WriteString(`</h1>`)
	builder.WriteString(`<div class="meta">`)
	builder.WriteString(escape(post.AuthorName))
	builder.WriteString(` • `)
	builder.WriteString(post.CreatedAt.Format("02.01.2006 15:04"))
	builder.WriteString(`</div>`)
	builder.WriteString(`<div class="card body">`)
	builder.WriteString(bodyHTML)
	builder.WriteString(`</div>`)

	remaining := make([]entity.NewsMedia, 0, len(post.Media))
	for i, media := range post.Media {
		if _, found := usedMedia[i]; found {
			continue
		}
		remaining = append(remaining, media)
	}
	if len(remaining) > 0 {
		builder.WriteString(`<div class="card"><h3 style="margin-top:0">Вложения</h3>`)
		for _, media := range remaining {
			builder.WriteString(renderPublicMediaBlock(c, media))
		}
		builder.WriteString(`</div>`)
	}
	builder.WriteString(`</body></html>`)
	return builder.String()
}

func renderPublicNewsBody(c *gin.Context, post entity.NewsPost) (string, map[int]struct{}) {
	escape := template.HTMLEscapeString
	lines := strings.Split(post.Body, "\n")
	used := map[int]struct{}{}
	var out strings.Builder
	for _, rawLine := range lines {
		line := strings.TrimRight(rawLine, "\r")
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			out.WriteString(`<div class="sp"></div>`)
			continue
		}
		if match := publicNewsMediaToken.FindStringSubmatch(trimmed); len(match) == 2 {
			idx, err := strconv.Atoi(match[1])
			if err == nil && idx >= 1 && idx <= len(post.Media) {
				mediaIndex := idx - 1
				used[mediaIndex] = struct{}{}
				out.WriteString(renderPublicMediaBlock(c, post.Media[mediaIndex]))
				continue
			}
		}
		if match := publicNewsImageMD.FindStringSubmatch(trimmed); len(match) == 2 {
			absURL := escape(publicNewsMediaURL(c, match[1]))
			out.WriteString(`<figure class="media-block"><img src="`)
			out.WriteString(absURL)
			out.WriteString(`" alt="image"></figure>`)
			continue
		}
		out.WriteString(`<p>`)
		out.WriteString(escape(line))
		out.WriteString(`</p>`)
	}
	return out.String(), used
}

func renderPublicMediaBlock(c *gin.Context, media entity.NewsMedia) string {
	escape := template.HTMLEscapeString
	absURL := escape(publicNewsMediaURL(c, media.URL))
	downloadURL := escape(publicNewsDownloadURL(c, media.URL))
	mediaType := classifyNewsMediaType(media.MimeType, strings.ToLower(filepath.Ext(media.OriginalName)))
	var out strings.Builder
	if mediaType == "video" {
		out.WriteString(`<figure class="media-block"><video controls src="`)
		out.WriteString(absURL)
		out.WriteString(`"></video></figure>`)
		return out.String()
	}
	if mediaType == "image" {
		out.WriteString(`<figure class="media-block"><img src="`)
		out.WriteString(absURL)
		out.WriteString(`" alt="media"></figure>`)
		return out.String()
	}
	name := strings.TrimSpace(media.OriginalName)
	if name == "" {
		name = filepath.Base(strings.TrimSpace(media.URL))
	}
	out.WriteString(`<div class="media-block"><div class="file-row"><span class="file-name">`)
	out.WriteString(escape(name))
	out.WriteString(`</span><span class="actions"><a href="`)
	out.WriteString(absURL)
	out.WriteString(`" target="_blank" rel="noopener noreferrer">Открыть</a><a href="`)
	out.WriteString(downloadURL)
	out.WriteString(`" rel="noopener noreferrer">Скачать</a></span></div></div>`)
	return out.String()
}

func publicNewsMediaURL(c *gin.Context, url string) string {
	trimmed := strings.TrimSpace(url)
	if trimmed == "" {
		return ""
	}
	if strings.HasPrefix(trimmed, "http://") || strings.HasPrefix(trimmed, "https://") {
		return trimmed
	}
	scheme := "http"
	if c.Request != nil && c.Request.TLS != nil {
		scheme = "https"
	}
	if xf := strings.TrimSpace(c.GetHeader("X-Forwarded-Proto")); xf != "" {
		scheme = strings.Split(xf, ",")[0]
	}
	host := c.Request.Host
	if host == "" {
		host = "localhost:8000"
	}
	if strings.HasPrefix(trimmed, "/") {
		return scheme + "://" + host + trimmed
	}
	return scheme + "://" + host + "/" + trimmed
}

func publicNewsDownloadURL(c *gin.Context, url string) string {
	trimmed := strings.TrimSpace(url)
	if trimmed == "" {
		return ""
	}
	switch {
	case strings.HasPrefix(trimmed, "http://"), strings.HasPrefix(trimmed, "https://"):
		return trimmed
	case strings.HasPrefix(trimmed, "/media/news/"):
		suffix := strings.TrimPrefix(trimmed, "/media/news/")
		return publicNewsMediaURL(c, fmt.Sprintf("/media/news-download/%s", suffix))
	case strings.HasPrefix(trimmed, "media/news/"):
		suffix := strings.TrimPrefix(trimmed, "media/news/")
		return publicNewsMediaURL(c, fmt.Sprintf("/media/news-download/%s", suffix))
	default:
		return publicNewsMediaURL(c, trimmed)
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

func cleanupUploadedNewsFiles(paths []string) {
	for _, path := range paths {
		if strings.TrimSpace(path) == "" {
			continue
		}
		_ = os.Remove(path)
	}
}

func detectNewsMimeType(header, ext string, raw []byte) string {
	normalized := strings.ToLower(strings.TrimSpace(header))
	if normalized == "" || normalized == "application/octet-stream" {
		if byExt := strings.TrimSpace(mime.TypeByExtension(ext)); byExt != "" {
			normalized = strings.ToLower(byExt)
		}
	}
	if (normalized == "" || normalized == "application/octet-stream") && len(raw) > 0 {
		sample := raw
		if len(sample) > 512 {
			sample = sample[:512]
		}
		normalized = strings.ToLower(http.DetectContentType(sample))
	}
	if normalized == "" {
		return "application/octet-stream"
	}
	return normalized
}

func classifyNewsMediaType(mimeType, ext string) string {
	mimeType = strings.ToLower(strings.TrimSpace(mimeType))
	ext = strings.ToLower(strings.TrimSpace(ext))
	switch {
	case strings.HasPrefix(mimeType, "image/"):
		return "image"
	case strings.HasPrefix(mimeType, "video/"):
		return "video"
	}
	switch ext {
	case ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".svg":
		return "image"
	case ".mp4", ".mov", ".avi", ".webm", ".mkv":
		return "video"
	default:
		return "file"
	}
}

func (h *Handler) saveNewsMedia(file *multipart.FileHeader) (entity.NewsMedia, string, error) {
	if file == nil {
		return entity.NewsMedia{}, "", errors.New("invalid media")
	}
	if file.Size > 50*1024*1024 {
		return entity.NewsMedia{}, "", errors.New("file is too large")
	}
	src, err := file.Open()
	if err != nil {
		return entity.NewsMedia{}, "", err
	}
	defer src.Close()

	data, err := io.ReadAll(src)
	if err != nil {
		return entity.NewsMedia{}, "", err
	}
	if len(data) == 0 {
		return entity.NewsMedia{}, "", errors.New("empty file")
	}

	ext := strings.ToLower(filepath.Ext(file.Filename))
	stored := uuid.NewString() + ext
	newsDir := filepath.Join(h.cfg.MediaDir, "news")
	_ = os.MkdirAll(newsDir, 0o755)
	target := filepath.Join(h.cfg.MediaDir, "news", stored)
	if err := os.WriteFile(target, data, 0o644); err != nil {
		return entity.NewsMedia{}, "", err
	}

	mimeType := detectNewsMimeType(file.Header.Get("Content-Type"), ext, data)
	mediaType := classifyNewsMediaType(mimeType, ext)
	originalName := strings.TrimSpace(file.Filename)
	if originalName == "" {
		originalName = stored
	}

	return entity.NewsMedia{
		URL:          "/media/news/" + stored,
		MediaType:    mediaType,
		OriginalName: originalName,
		MimeType:     mimeType,
		Size:         int64(len(data)),
	}, target, nil
}
