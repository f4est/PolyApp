package http

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"polyapp/server-go/internal/config"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"

	"github.com/gin-gonic/gin"
)

func TestRouterAPIAliasHealth(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := NewHandler(config.Config{}, nil, nil, nil, nil, nil, nil, nil, nil)
	auth := httpMiddleware.NewAuthMiddleware(nil, nil)
	router := NewRouter(handler, auth)

	req := httptest.NewRequest(http.MethodGet, "/api/health", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 for /api/health, got %d", rec.Code)
	}
}

func TestRouterAPIAliasSecuredRouteExists(t *testing.T) {
	gin.SetMode(gin.TestMode)
	handler := NewHandler(config.Config{}, nil, nil, nil, nil, nil, nil, nil, nil)
	auth := httpMiddleware.NewAuthMiddleware(nil, nil)
	router := NewRouter(handler, auth)

	req := httptest.NewRequest(http.MethodGet, "/api/makeups", nil)
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 for /api/makeups without token, got %d", rec.Code)
	}
}
