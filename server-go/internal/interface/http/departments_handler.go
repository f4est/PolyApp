package http

import (
	"errors"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/infrastructure/persistence"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type departmentPayload struct {
	Name       string `json:"name"`
	Key        string `json:"key"`
	HeadUserID *uint  `json:"head_user_id"`
}

type departmentGroupPayload struct {
	GroupName string `json:"group_name"`
}

type curatorGroupPayload struct {
	CuratorID uint   `json:"curator_id"`
	GroupName string `json:"group_name"`
}

func (h *Handler) listDepartments(c *gin.Context) {
	var rows []persistence.DBDepartment
	if err := h.db.WithContext(c.Request.Context()).
		Order("name asc").
		Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load departments"})
		return
	}
	var groups []persistence.DBDepartmentGroup
	if err := h.db.WithContext(c.Request.Context()).
		Find(&groups).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load departments"})
		return
	}
	departmentGroups := map[uint][]string{}
	for _, row := range groups {
		departmentGroups[row.DepartmentID] = append(
			departmentGroups[row.DepartmentID],
			strings.TrimSpace(row.GroupName),
		)
	}
	for key := range departmentGroups {
		sort.Strings(departmentGroups[key])
	}
	headIDs := map[uint]struct{}{}
	for _, row := range rows {
		if row.HeadUserID != nil && *row.HeadUserID > 0 {
			headIDs[*row.HeadUserID] = struct{}{}
		}
	}
	headNames := map[uint]string{}
	if len(headIDs) > 0 {
		var users []persistence.DBUser
		if err := h.db.WithContext(c.Request.Context()).
			Where("id IN ?", mapIDSet(headIDs)).
			Find(&users).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load departments"})
			return
		}
		for _, user := range users {
			headNames[user.ID] = user.FullName
		}
	}
	out := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		headID := any(nil)
		headName := any(nil)
		if row.HeadUserID != nil {
			headID = *row.HeadUserID
			if value := strings.TrimSpace(headNames[*row.HeadUserID]); value != "" {
				headName = value
			}
		}
		out = append(out, gin.H{
			"id":           row.ID,
			"name":         row.Name,
			"key":          row.Key,
			"head_user_id": headID,
			"head_name":    headName,
			"groups":       departmentGroups[row.ID],
			"created_at":   row.CreatedAt.Format(time.RFC3339),
			"updated_at":   row.UpdatedAt.Format(time.RFC3339),
		})
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) createDepartment(c *gin.Context) {
	var payload departmentPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	name := strings.TrimSpace(payload.Name)
	key := strings.ToUpper(strings.TrimSpace(payload.Key))
	if name == "" || key == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "name and key are required"})
		return
	}
	row := persistence.DBDepartment{
		Name:       name,
		Key:        key,
		HeadUserID: payload.HeadUserID,
		CreatedAt:  time.Now().UTC(),
		UpdatedAt:  time.Now().UTC(),
	}
	if err := h.db.WithContext(c.Request.Context()).Create(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to create department"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"id":           row.ID,
		"name":         row.Name,
		"key":          row.Key,
		"head_user_id": row.HeadUserID,
	})
}

func (h *Handler) patchDepartment(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid department id"})
		return
	}
	var payload departmentPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	var row persistence.DBDepartment
	if err := h.db.WithContext(c.Request.Context()).First(&row, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Department not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load department"})
		return
	}
	if strings.TrimSpace(payload.Name) != "" {
		row.Name = strings.TrimSpace(payload.Name)
	}
	if strings.TrimSpace(payload.Key) != "" {
		row.Key = strings.ToUpper(strings.TrimSpace(payload.Key))
	}
	row.HeadUserID = payload.HeadUserID
	row.UpdatedAt = time.Now().UTC()
	if err := h.db.WithContext(c.Request.Context()).Save(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update department"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"id":           row.ID,
		"name":         row.Name,
		"key":          row.Key,
		"head_user_id": row.HeadUserID,
	})
}

func (h *Handler) deleteDepartment(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid department id"})
		return
	}
	if err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("department_id = ?", id).Delete(&persistence.DBDepartmentGroup{}).Error; err != nil {
			return err
		}
		return tx.Delete(&persistence.DBDepartment{}, id).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete department"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) listDepartmentGroups(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid department id"})
		return
	}
	var groups []string
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBDepartmentGroup{}).
		Where("department_id = ?", id).
		Order("group_name asc").
		Pluck("group_name", &groups).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load groups"})
		return
	}
	c.JSON(http.StatusOK, groups)
}

func (h *Handler) addDepartmentGroup(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid department id"})
		return
	}
	var payload departmentGroupPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	group := normalizeGroupName(payload.GroupName)
	if group == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name is required"})
		return
	}
	var exists persistence.DBDepartment
	if err := h.db.WithContext(c.Request.Context()).First(&exists, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Department not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save group"})
		return
	}
	row := persistence.DBDepartmentGroup{
		DepartmentID: id,
		GroupName:    group,
		CreatedAt:    time.Now().UTC(),
	}
	if err := h.db.WithContext(c.Request.Context()).
		Where("group_name = ?", group).
		Assign(map[string]any{"department_id": id}).
		FirstOrCreate(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save group"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"id":            row.ID,
		"department_id": row.DepartmentID,
		"group_name":    row.GroupName,
	})
}

func (h *Handler) removeDepartmentGroup(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid department id"})
		return
	}
	group := normalizeGroupName(c.Query("group_name"))
	if group == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name is required"})
		return
	}
	if err := h.db.WithContext(c.Request.Context()).
		Where("department_id = ? AND group_name = ?", id, group).
		Delete(&persistence.DBDepartmentGroup{}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete group"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) listCuratorGroups(c *gin.Context) {
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBCuratorGroupAssignment{})
	if raw := strings.TrimSpace(c.Query("curator_id")); raw != "" {
		value, err := strconv.ParseUint(raw, 10, 64)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid curator_id"})
			return
		}
		query = query.Where("curator_id = ?", uint(value))
	}
	var rows []persistence.DBCuratorGroupAssignment
	if err := query.Order("created_at desc").Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load curator groups"})
		return
	}
	userIDs := map[uint]struct{}{}
	for _, row := range rows {
		userIDs[row.CuratorID] = struct{}{}
	}
	userNames := map[uint]string{}
	if len(userIDs) > 0 {
		var users []persistence.DBUser
		if err := h.db.WithContext(c.Request.Context()).
			Where("id IN ?", mapIDSet(userIDs)).
			Find(&users).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load curator groups"})
			return
		}
		for _, user := range users {
			userNames[user.ID] = user.FullName
		}
	}
	out := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		out = append(out, gin.H{
			"id":           row.ID,
			"curator_id":   row.CuratorID,
			"curator_name": nullOrString(userNames[row.CuratorID]),
			"group_name":   row.GroupName,
			"created_at":   row.CreatedAt.Format(time.RFC3339),
		})
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) createCuratorGroup(c *gin.Context) {
	var payload curatorGroupPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	group := normalizeGroupName(payload.GroupName)
	if payload.CuratorID == 0 || group == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "curator_id and group_name are required"})
		return
	}
	row := persistence.DBCuratorGroupAssignment{
		CuratorID: payload.CuratorID,
		GroupName: group,
		CreatedAt: time.Now().UTC(),
	}
	if err := h.db.WithContext(c.Request.Context()).
		Where("group_name = ?", group).
		Assign(map[string]any{"curator_id": payload.CuratorID}).
		FirstOrCreate(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save curator group"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"id":         row.ID,
		"curator_id": row.CuratorID,
		"group_name": row.GroupName,
	})
}

func (h *Handler) deleteCuratorGroup(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid curator group id"})
		return
	}
	res := h.db.WithContext(c.Request.Context()).Delete(&persistence.DBCuratorGroupAssignment{}, id)
	if res.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete curator group"})
		return
	}
	if res.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"detail": "Curator group not found"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}
