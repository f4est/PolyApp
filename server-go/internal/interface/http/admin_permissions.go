package http

import (
	"sort"
	"strings"

	"polyapp/server-go/internal/domain/entity"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"

	"github.com/gin-gonic/gin"
)

const (
	AdminPermUsersManage       = "users_manage"
	AdminPermScheduleManage    = "schedule_manage"
	AdminPermAcademicManage    = "academic_manage"
	AdminPermDepartmentsManage = "departments_manage"
	AdminPermAnalyticsView     = "analytics_view"
	AdminPermAll               = "all"
)

var allowedAdminPermissions = map[string]struct{}{
	AdminPermUsersManage:       {},
	AdminPermScheduleManage:    {},
	AdminPermAcademicManage:    {},
	AdminPermDepartmentsManage: {},
	AdminPermAnalyticsView:     {},
	AdminPermAll:               {},
}

func normalizeAdminPermissions(items []string) []string {
	uniq := map[string]struct{}{}
	for _, item := range items {
		key := strings.ToLower(strings.TrimSpace(item))
		if key == "" {
			continue
		}
		if _, ok := allowedAdminPermissions[key]; !ok {
			continue
		}
		uniq[key] = struct{}{}
	}
	out := make([]string, 0, len(uniq))
	for key := range uniq {
		out = append(out, key)
	}
	sort.Strings(out)
	return out
}

func hasAdminPermission(user *entity.User, permission string) bool {
	if user == nil || strings.TrimSpace(user.Role) != "admin" {
		return false
	}
	permission = strings.ToLower(strings.TrimSpace(permission))
	if permission == "" {
		return true
	}
	permissions := normalizeAdminPermissions(user.AdminPermissions)
	if len(permissions) == 0 {
		return true
	}
	for _, item := range permissions {
		if item == AdminPermAll || item == permission {
			return true
		}
	}
	return false
}

func (h *Handler) requireAdminPermission(c *gin.Context, permission string) bool {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(401, gin.H{"detail": "Unauthorized"})
		return false
	}
	if user.Role != "admin" {
		c.JSON(403, gin.H{"detail": "Forbidden"})
		return false
	}
	if !hasAdminPermission(user, permission) {
		c.JSON(403, gin.H{"detail": "Admin permission denied"})
		return false
	}
	return true
}
