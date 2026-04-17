package middleware

import (
	"net/http"
	"strings"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
	"polyapp/server-go/internal/domain/service"
	"polyapp/server-go/internal/usecase"

	"github.com/gin-gonic/gin"
)

const currentUserKey = "current_user"

type AuthMiddleware struct {
	tokens service.TokenService
	authUC *usecase.AuthUseCase
}

func NewAuthMiddleware(tokens service.TokenService, authUC *usecase.AuthUseCase) *AuthMiddleware {
	return &AuthMiddleware{
		tokens: tokens,
		authUC: authUC,
	}
}

func (m *AuthMiddleware) RequireAuth() gin.HandlerFunc {
	return func(c *gin.Context) {
		header := c.GetHeader("Authorization")
		token := strings.TrimSpace(strings.TrimPrefix(header, "Bearer"))
		if token == "" {
			if cookieToken, err := c.Cookie("polyapp_token"); err == nil {
				token = strings.TrimSpace(cookieToken)
			}
		}
		if token == "" && strings.HasPrefix(c.Request.URL.Path, "/db") {
			token = strings.TrimSpace(c.Query("token"))
			if token == "" {
				token = strings.TrimSpace(c.Query("access_token"))
			}
		}
		if token == "" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"detail": "Missing token"})
			return
		}
		claims, err := m.tokens.Parse(token)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"detail": "Invalid token"})
			return
		}
		user, err := m.authUC.GetCurrentUser(c.Request.Context(), *claims)
		if err != nil {
			if err == domainErrors.ErrSessionExpired {
				c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"detail": "Session expired"})
				return
			}
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
			return
		}
		c.Set(currentUserKey, user)
		c.Set("token_claims", claims)
		c.Next()
	}
}

func RequireRoles(roles ...string) gin.HandlerFunc {
	allowed := map[string]struct{}{}
	for _, role := range roles {
		allowed[role] = struct{}{}
	}
	return func(c *gin.Context) {
		user := CurrentUser(c)
		if user == nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
			return
		}
		if _, ok := allowed[user.Role]; !ok {
			c.AbortWithStatusJSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
			return
		}
		c.Next()
	}
}

func CurrentUser(c *gin.Context) *entity.User {
	raw, exists := c.Get(currentUserKey)
	if !exists {
		return nil
	}
	user, ok := raw.(*entity.User)
	if !ok {
		return nil
	}
	return user
}

func CurrentClaims(c *gin.Context) *entity.TokenClaims {
	raw, exists := c.Get("token_claims")
	if !exists {
		return nil
	}
	claims, ok := raw.(*entity.TokenClaims)
	if !ok {
		return nil
	}
	return claims
}
