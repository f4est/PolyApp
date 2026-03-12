package http

import (
	"errors"
	"net/http"
	"sort"
	"strings"
	"time"

	"polyapp/server-go/internal/infrastructure/persistence"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

func (h *Handler) createRequest(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	if user.Role != "student" && user.Role != "parent" && user.Role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	var payload requestPayload
	if err := c.ShouldBindJSON(&payload); err != nil || strings.TrimSpace(payload.RequestType) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "request_type is required"})
		return
	}
	ticket := persistence.DBRequestTicket{
		StudentID:   user.ID,
		RequestType: strings.TrimSpace(payload.RequestType),
		Status:      requestStatuses[0],
		Details:     strings.TrimSpace(payload.Details),
		CreatedAt:   time.Now().UTC(),
		UpdatedAt:   nil,
	}
	now := time.Now().UTC()
	ticket.UpdatedAt = &now
	if err := h.db.WithContext(c.Request.Context()).Create(&ticket).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to create request"})
		return
	}
	c.JSON(http.StatusOK, h.mapRequestTicket(c, ticket))
}

func (h *Handler) listRequests(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBRequestTicket{})
	if user.Role == "student" || user.Role == "parent" {
		query = query.Where("student_id = ?", user.ID)
	}
	var tickets []persistence.DBRequestTicket
	if err := query.Order("created_at desc").Find(&tickets).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load requests"})
		return
	}
	out := make([]gin.H, 0, len(tickets))
	for _, ticket := range tickets {
		out = append(out, h.mapRequestTicket(c, ticket))
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) deleteRequest(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid ticket id"})
		return
	}
	var ticket persistence.DBRequestTicket
	if err := h.db.WithContext(c.Request.Context()).First(&ticket, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Ticket not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load ticket"})
		return
	}
	if user.Role != "admin" && user.Role != "request_handler" && ticket.StudentID != user.ID {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	if err := h.db.WithContext(c.Request.Context()).Delete(&ticket).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete ticket"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) updateRequest(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid ticket id"})
		return
	}
	var payload requestUpdatePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	var ticket persistence.DBRequestTicket
	if err := h.db.WithContext(c.Request.Context()).First(&ticket, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Ticket not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load ticket"})
		return
	}
	if user.Role != "admin" && user.Role != "request_handler" {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	if payload.Status != nil {
		ticket.Status = strings.TrimSpace(*payload.Status)
	}
	if payload.Details != nil {
		ticket.Details = strings.TrimSpace(*payload.Details)
	}
	now := time.Now().UTC()
	ticket.UpdatedAt = &now
	if err := h.db.WithContext(c.Request.Context()).Save(&ticket).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update ticket"})
		return
	}
	c.JSON(http.StatusOK, h.mapRequestTicket(c, ticket))
}

func (h *Handler) upsertAttendance(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	var payload attendancePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	classDate, err := parseDate(payload.ClassDate)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "class_date should be YYYY-MM-DD"})
		return
	}
	row := persistence.DBAttendanceRecord{
		GroupName:   strings.TrimSpace(payload.GroupName),
		ClassDate:   classDate,
		StudentName: strings.TrimSpace(payload.StudentName),
		Present:     payload.Present,
		TeacherID:   user.ID,
	}
	if row.GroupName == "" || row.StudentName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name and student_name are required"})
		return
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save attendance"})
			return
		}
		if !scope.canEditAttendance(row.GroupName) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	tx := h.db.WithContext(c.Request.Context())
	var existing persistence.DBAttendanceRecord
	err = tx.Where("group_name = ? AND class_date = ? AND student_name = ?", row.GroupName, row.ClassDate, row.StudentName).
		First(&existing).Error
	switch {
	case err == nil:
		existing.Present = row.Present
		existing.TeacherID = user.ID
		if err := tx.Save(&existing).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save attendance"})
			return
		}
		c.JSON(http.StatusOK, mapAttendance(existing))
	case errors.Is(err, gorm.ErrRecordNotFound):
		if err := tx.Create(&row).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save attendance"})
			return
		}
		c.JSON(http.StatusOK, mapAttendance(row))
	default:
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save attendance"})
	}
}

func (h *Handler) listAttendance(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	group := strings.TrimSpace(c.Query("group_name"))
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBAttendanceRecord{})
	if group != "" {
		query = query.Where("group_name = ?", group)
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load attendance"})
			return
		}
		if group != "" && !scope.canView(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
		allowed := scope.asList()
		if group == "" && len(allowed) == 0 {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		if group == "" {
			query = query.Where("group_name IN ?", allowed)
		}
	}
	if user.Role == "parent" {
		if strings.TrimSpace(user.StudentGroup) == "" {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		query = query.Where("group_name = ?", strings.TrimSpace(user.StudentGroup))
	}
	var rows []persistence.DBAttendanceRecord
	if err := query.Order("class_date desc").Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load attendance"})
		return
	}
	out := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		out = append(out, mapAttendance(row))
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) deleteAttendance(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	group := strings.TrimSpace(c.Query("group_name"))
	student := strings.TrimSpace(c.Query("student_name"))
	classDate, err := parseDate(c.Query("class_date"))
	if group == "" || student == "" || err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name, class_date and student_name are required"})
		return
	}
	if user.Role == "teacher" {
		scope, scopeErr := h.groupScopeForUser(c.Request.Context(), user)
		if scopeErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete attendance"})
			return
		}
		if !scope.canEditAttendance(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	res := h.db.WithContext(c.Request.Context()).
		Where("group_name = ? AND class_date = ? AND student_name = ?", group, classDate, student).
		Delete(&persistence.DBAttendanceRecord{})
	if res.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete attendance"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"deleted": res.RowsAffected})
}

func (h *Handler) attendanceSummary(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	group := strings.TrimSpace(c.Query("group_name"))
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBAttendanceRecord{})
	if group != "" {
		query = query.Where("group_name = ?", group)
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load attendance"})
			return
		}
		if group != "" && !scope.canView(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
		allowed := scope.asList()
		if group == "" && len(allowed) == 0 {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		if group == "" {
			query = query.Where("group_name IN ?", allowed)
		}
	}
	if user.Role == "parent" {
		if strings.TrimSpace(user.StudentGroup) == "" {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		query = query.Where("group_name = ?", strings.TrimSpace(user.StudentGroup))
	}
	var rows []persistence.DBAttendanceRecord
	if err := query.Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load attendance"})
		return
	}
	type summary struct {
		GroupName    string `json:"group_name"`
		PresentCount int    `json:"present_count"`
		TotalCount   int    `json:"total_count"`
	}
	total := map[string]summary{}
	for _, row := range rows {
		item := total[row.GroupName]
		item.GroupName = row.GroupName
		item.TotalCount++
		if row.Present {
			item.PresentCount++
		}
		total[row.GroupName] = item
	}
	out := make([]summary, 0, len(total))
	for _, item := range total {
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].GroupName < out[j].GroupName })
	c.JSON(http.StatusOK, out)
}

func (h *Handler) upsertGrade(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	var payload gradePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	if payload.Grade < 1 || payload.Grade > 100 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Grade must be 1..100"})
		return
	}
	classDate, err := parseDate(payload.ClassDate)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "class_date should be YYYY-MM-DD"})
		return
	}
	row := persistence.DBGradeRecord{
		GroupName:   strings.TrimSpace(payload.GroupName),
		ClassDate:   classDate,
		StudentName: strings.TrimSpace(payload.StudentName),
		Grade:       payload.Grade,
		TeacherID:   user.ID,
	}
	if row.GroupName == "" || row.StudentName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name and student_name are required"})
		return
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save grade"})
			return
		}
		if !scope.canEditGrades(row.GroupName) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	tx := h.db.WithContext(c.Request.Context())
	var existing persistence.DBGradeRecord
	err = tx.Where("group_name = ? AND class_date = ? AND student_name = ?", row.GroupName, row.ClassDate, row.StudentName).
		First(&existing).Error
	switch {
	case err == nil:
		existing.Grade = row.Grade
		existing.TeacherID = user.ID
		if err := tx.Save(&existing).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save grade"})
			return
		}
		c.JSON(http.StatusOK, mapGrade(existing))
	case errors.Is(err, gorm.ErrRecordNotFound):
		if err := tx.Create(&row).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save grade"})
			return
		}
		c.JSON(http.StatusOK, mapGrade(row))
	default:
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save grade"})
	}
}

func (h *Handler) listGrades(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	group := strings.TrimSpace(c.Query("group_name"))
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBGradeRecord{})
	if group != "" {
		query = query.Where("group_name = ?", group)
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load grades"})
			return
		}
		if group != "" && !scope.canView(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
		allowed := scope.asList()
		if group == "" && len(allowed) == 0 {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		if group == "" {
			query = query.Where("group_name IN ?", allowed)
		}
	}
	if user.Role == "parent" {
		if strings.TrimSpace(user.StudentGroup) == "" {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		query = query.Where("group_name = ?", strings.TrimSpace(user.StudentGroup))
	}
	var rows []persistence.DBGradeRecord
	if err := query.Order("class_date desc").Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load grades"})
		return
	}
	out := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		out = append(out, mapGrade(row))
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) deleteGrade(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	group := strings.TrimSpace(c.Query("group_name"))
	student := strings.TrimSpace(c.Query("student_name"))
	classDate, err := parseDate(c.Query("class_date"))
	if group == "" || student == "" || err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name, class_date and student_name are required"})
		return
	}
	if user.Role == "teacher" {
		scope, scopeErr := h.groupScopeForUser(c.Request.Context(), user)
		if scopeErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete grade"})
			return
		}
		if !scope.canEditGrades(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	res := h.db.WithContext(c.Request.Context()).
		Where("group_name = ? AND class_date = ? AND student_name = ?", group, classDate, student).
		Delete(&persistence.DBGradeRecord{})
	if res.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete grade"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"deleted": res.RowsAffected})
}

func (h *Handler) gradeSummary(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	group := strings.TrimSpace(c.Query("group_name"))
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBGradeRecord{})
	if group != "" {
		query = query.Where("group_name = ?", group)
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load grades"})
			return
		}
		if group != "" && !scope.canView(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
		allowed := scope.asList()
		if group == "" && len(allowed) == 0 {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		if group == "" {
			query = query.Where("group_name IN ?", allowed)
		}
	}
	if user.Role == "parent" {
		if strings.TrimSpace(user.StudentGroup) == "" {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		query = query.Where("group_name = ?", strings.TrimSpace(user.StudentGroup))
	}
	var rows []persistence.DBGradeRecord
	if err := query.Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load grades"})
		return
	}
	type sum struct {
		Group string
		Total int
		Count int
	}
	groups := map[string]sum{}
	for _, row := range rows {
		item := groups[row.GroupName]
		item.Group = row.GroupName
		item.Total += row.Grade
		item.Count++
		groups[row.GroupName] = item
	}
	out := make([]gin.H, 0, len(groups))
	for _, item := range groups {
		average := 0.0
		if item.Count > 0 {
			average = float64(item.Total) / float64(item.Count)
		}
		out = append(out, gin.H{
			"group_name": item.Group,
			"average":    average,
			"count":      item.Count,
		})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i]["group_name"].(string) < out[j]["group_name"].(string)
	})
	c.JSON(http.StatusOK, out)
}

func (h *Handler) analyticsAttendance(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	group := strings.TrimSpace(c.Query("group_name"))
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBAttendanceRecord{})
	if group != "" {
		query = query.Where("group_name = ?", group)
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load analytics"})
			return
		}
		if group != "" && !scope.canView(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
		allowed := scope.asList()
		if group == "" && len(allowed) == 0 {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		if group == "" {
			query = query.Where("group_name IN ?", allowed)
		}
	}
	var rows []persistence.DBAttendanceRecord
	if err := query.Order("class_date desc").Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load analytics"})
		return
	}
	out := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		out = append(out, mapAttendance(row))
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) analyticsGrades(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	group := strings.TrimSpace(c.Query("group_name"))
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBGradeRecord{})
	if group != "" {
		query = query.Where("group_name = ?", group)
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load analytics"})
			return
		}
		if group != "" && !scope.canView(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
		allowed := scope.asList()
		if group == "" && len(allowed) == 0 {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		if group == "" {
			query = query.Where("group_name IN ?", allowed)
		}
	}
	var rows []persistence.DBGradeRecord
	if err := query.Order("class_date desc").Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load analytics"})
		return
	}
	out := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		out = append(out, mapGrade(row))
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) mapRequestTicket(c *gin.Context, ticket persistence.DBRequestTicket) gin.H {
	studentName := ""
	var user persistence.DBUser
	if err := h.db.WithContext(c.Request.Context()).First(&user, ticket.StudentID).Error; err == nil {
		studentName = user.FullName
	}
	updatedAt := ticket.CreatedAt
	if ticket.UpdatedAt != nil {
		updatedAt = *ticket.UpdatedAt
	}
	return gin.H{
		"id":           ticket.ID,
		"student_id":   ticket.StudentID,
		"student_name": studentName,
		"request_type": ticket.RequestType,
		"status":       ticket.Status,
		"details":      nullOrString(ticket.Details),
		"created_at":   ticket.CreatedAt.Format(time.RFC3339),
		"updated_at":   updatedAt.Format(time.RFC3339),
	}
}

func mapAttendance(row persistence.DBAttendanceRecord) gin.H {
	return gin.H{
		"id":           row.ID,
		"group_name":   row.GroupName,
		"class_date":   dateOnly(row.ClassDate),
		"student_name": row.StudentName,
		"present":      row.Present,
	}
}

func mapGrade(row persistence.DBGradeRecord) gin.H {
	return gin.H{
		"id":           row.ID,
		"group_name":   row.GroupName,
		"class_date":   dateOnly(row.ClassDate),
		"student_name": row.StudentName,
		"grade":        row.Grade,
	}
}

func (h *Handler) allowedGroupsForTeacher(c *gin.Context, teacherID uint) ([]string, error) {
	unique := map[string]struct{}{}
	var deptIDs []uint
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBDepartment{}).
		Where("head_user_id = ?", teacherID).
		Pluck("id", &deptIDs).Error; err != nil {
		return nil, err
	}
	if len(deptIDs) > 0 {
		var departmentGroups []string
		if err := h.db.WithContext(c.Request.Context()).
			Model(&persistence.DBDepartmentGroup{}).
			Where("department_id IN ?", deptIDs).
			Distinct("group_name").
			Pluck("group_name", &departmentGroups).Error; err != nil {
			return nil, err
		}
		for _, group := range departmentGroups {
			group = normalizeGroupName(group)
			if group != "" {
				unique[group] = struct{}{}
			}
		}
		if len(unique) > 0 {
			out := make([]string, 0, len(unique))
			for group := range unique {
				out = append(out, group)
			}
			sort.Strings(out)
			return out, nil
		}
	}

	var teaching []string
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBTeacherGroupAssignment{}).
		Where("teacher_id = ?", teacherID).
		Distinct("group_name").
		Pluck("group_name", &teaching).Error; err != nil {
		return nil, err
	}
	for _, group := range teaching {
		group = normalizeGroupName(group)
		if group != "" {
			unique[group] = struct{}{}
		}
	}

	var curated []string
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBCuratorGroupAssignment{}).
		Where("curator_id = ?", teacherID).
		Distinct("group_name").
		Pluck("group_name", &curated).Error; err != nil {
		return nil, err
	}
	for _, group := range curated {
		group = normalizeGroupName(group)
		if group != "" {
			unique[group] = struct{}{}
		}
	}

	out := make([]string, 0, len(unique))
	for group := range unique {
		out = append(out, group)
	}
	sort.Strings(out)
	return out, nil
}
