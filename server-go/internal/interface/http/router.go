package http

import (
	"net/http"
	"os"
	"path/filepath"
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

	router.GET("/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})
	router.GET("/roles", func(c *gin.Context) {
		c.JSON(http.StatusOK, []string{"smm", "parent", "request_handler", "admin", "student", "teacher"})
	})

	handler.RegisterAuthRoutes(router, authMiddleware)
	handler.RegisterNewsRoutes(router, authMiddleware)
	handler.RegisterAcademicRoutes(router, authMiddleware)

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
		c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type, Accept")
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
		"id":            user.ID,
		"role":          user.Role,
		"full_name":     user.FullName,
		"email":         user.Email,
		"phone":         nullOrString(user.Phone),
		"avatar_url":    nullOrString(user.AvatarURL),
		"about":         nullOrString(user.About),
		"student_group": nullOrString(user.StudentGroup),
		"teacher_name":  nullOrString(user.TeacherName),
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
