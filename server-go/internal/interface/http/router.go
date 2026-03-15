package http

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"polyapp/server-go/internal/config"
	"polyapp/server-go/internal/domain/entity"
	"polyapp/server-go/internal/infrastructure/persistence"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"
	"polyapp/server-go/internal/usecase"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type Handler struct {
	cfg       config.Config
	db        *gorm.DB
	redis     *redis.Client
	authUC    *usecase.AuthUseCase
	newsUC    *usecase.NewsUseCase
	presetUC  *usecase.PresetUseCase
	journalUC *usecase.JournalUseCase
	userRepo  *persistence.UserRepo
	newsRepo  *persistence.NewsRepo
}

func NewHandler(
	cfg config.Config,
	db *gorm.DB,
	redisClient *redis.Client,
	authUC *usecase.AuthUseCase,
	newsUC *usecase.NewsUseCase,
	presetUC *usecase.PresetUseCase,
	journalUC *usecase.JournalUseCase,
	userRepo *persistence.UserRepo,
	newsRepo *persistence.NewsRepo,
) *Handler {
	return &Handler{
		cfg:       cfg,
		db:        db,
		redis:     redisClient,
		authUC:    authUC,
		newsUC:    newsUC,
		presetUC:  presetUC,
		journalUC: journalUC,
		userRepo:  userRepo,
		newsRepo:  newsRepo,
	}
}

func NewRouter(handler *Handler, authMiddleware *httpMiddleware.AuthMiddleware) *gin.Engine {
	router := gin.New()
	router.Use(gin.Logger(), gin.Recovery(), corsMiddleware(handler.cfg.CORSOrigin))

	newsDir := filepath.Join(handler.cfg.MediaDir, "news")
	_ = os.MkdirAll(newsDir, 0o755)
	router.Static("/media/news", newsDir)
	makeupDir := filepath.Join(handler.cfg.MediaDir, "makeup")
	_ = os.MkdirAll(makeupDir, 0o755)
	router.Static("/media/makeup", makeupDir)
	avatarsDir := filepath.Join(handler.cfg.MediaDir, "avatars")
	_ = os.MkdirAll(avatarsDir, 0o755)
	router.Static("/media/avatars", avatarsDir)

	router.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})
	router.GET("/time-sync", func(c *gin.Context) {
		nowUTC := time.Now().UTC()
		deviceTimeRaw := strings.TrimSpace(c.GetHeader("X-Device-Time"))
		offsetRaw := strings.TrimSpace(c.GetHeader("X-Timezone-Offset-Minutes"))
		out := gin.H{
			"server_utc": nowUTC.Format(time.RFC3339),
			"device_time": func() any {
				if deviceTimeRaw == "" {
					return nil
				}
				return deviceTimeRaw
			}(),
			"timezone_offset_minutes": func() any {
				if offsetRaw == "" {
					return nil
				}
				return offsetRaw
			}(),
		}
		if deviceTimeRaw != "" {
			if parsed, err := time.Parse(time.RFC3339, deviceTimeRaw); err == nil {
				diff := nowUTC.Sub(parsed.UTC())
				out["drift_seconds"] = int(diff.Seconds())
			}
		}
		c.JSON(http.StatusOK, out)
	})
	router.GET("/roles", func(c *gin.Context) {
		c.JSON(http.StatusOK, []string{"smm", "parent", "request_handler", "admin", "student", "teacher"})
	})

	handler.RegisterAuthRoutes(router, authMiddleware)
	handler.RegisterNewsRoutes(router, authMiddleware)
	handler.RegisterAcademicRoutes(router, authMiddleware)

	// Compatibility alias: allow clients that use API_BASE_URL ending with "/api".
	router.Any("/api/*path", func(c *gin.Context) {
		path := c.Param("path")
		if path == "" {
			path = "/"
		}
		c.Request.URL.Path = path
		router.HandleContext(c)
	})

	return router
}

func corsMiddleware(allowedOrigin string) gin.HandlerFunc {
	return func(c *gin.Context) {
		origin := c.GetHeader("Origin")
		allow := allowedOrigin
		if allow == "*" && origin != "" {
			allow = origin
		}
		if allow != "" {
			c.Header("Access-Control-Allow-Origin", allow)
		}
		c.Header("Access-Control-Allow-Credentials", "true")
		c.Header(
			"Access-Control-Allow-Headers",
			"Authorization, Content-Type, Accept, X-Device-Time, X-Timezone-Offset-Minutes",
		)
		c.Header("Access-Control-Allow-Methods", "GET, POST, PATCH, PUT, DELETE, OPTIONS")
		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}
		c.Next()
	}
}

func toUserPublic(user entity.User) gin.H {
	out := gin.H{
		"id":                user.ID,
		"role":              user.Role,
		"full_name":         user.FullName,
		"email":             user.Email,
		"phone":             nullOrString(user.Phone),
		"avatar_url":        nullOrString(user.AvatarURL),
		"about":             nullOrString(user.About),
		"notify_schedule":   user.NotifySchedule,
		"notify_requests":   user.NotifyRequests,
		"student_group":     nullOrString(user.StudentGroup),
		"teacher_name":      nullOrString(user.TeacherName),
		"child_full_name":   nullOrString(user.ChildFullName),
		"parent_student_id": user.ParentStudentID,
		"admin_permissions": user.AdminPermissions,
		"is_approved":       user.IsApproved,
		"approved_by":       user.ApprovedBy,
		"created_at":        user.CreatedAt.Format(time.RFC3339),
		"updated_at":        user.UpdatedAt.Format(time.RFC3339),
	}
	if user.ApprovedAt != nil {
		out["approved_at"] = user.ApprovedAt.Format(time.RFC3339)
	} else {
		out["approved_at"] = nil
	}
	if user.BirthDate != nil {
		out["birth_date"] = user.BirthDate.Format("2006-01-02")
	} else {
		out["birth_date"] = nil
	}
	return out
}

func nullOrString(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func dateOnly(t time.Time) string {
	return t.Format("2006-01-02")
}
