package http

import (
	"context"
	"errors"
	"net/http"
	"sort"
	"strconv"
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
	role := strings.ToLower(strings.TrimSpace(user.Role))
	if role == "parent" {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	if role != "student" && role != "teacher" && role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	var payload requestPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "request_type is required"})
		return
	}
	requestType := strings.TrimSpace(payload.RequestType)
	details := strings.TrimSpace(payload.Details)
	if role == "teacher" {
		groupName := strings.TrimSpace(payload.GroupName)
		if groupName == "" {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name is required for teacher request"})
			return
		}
		if h.teacherHasDirectAssignment(c.Request.Context(), user.ID, groupName) {
			c.JSON(http.StatusConflict, gin.H{"detail": "Вы уже назначены на эту группу"})
			return
		}
		var existing persistence.DBRequestTicket
		groupPrefix := "группа: " + strings.ToLower(groupName)
		err := h.db.WithContext(c.Request.Context()).
			Where("student_id = ?", user.ID).
			Where("lower(request_type) LIKE ? AND lower(request_type) LIKE ?", "%преподаван%", "%груп%").
			Where("lower(details) LIKE ?", groupPrefix+"%").
			Where("lower(status) NOT IN ?", []string{"approved", "rejected", "одобрено", "отклонена", "отклонено"}).
			Order("id desc").
			First(&existing).Error
		if err == nil {
			c.JSON(http.StatusConflict, gin.H{"detail": "Заявка на эту группу уже подана"})
			return
		}
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to validate request"})
			return
		}
		requestType = "Запрос на преподавание группы"
		if details == "" {
			details = "Группа: " + groupName
		} else {
			details = "Группа: " + groupName + "\n" + details
		}
	}
	if requestType == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "request_type is required"})
		return
	}
	ticket := persistence.DBRequestTicket{
		StudentID:   user.ID,
		RequestType: requestType,
		Status:      requestStatuses[0],
		Details:     details,
		CreatedAt:   time.Now().UTC(),
		UpdatedAt:   nil,
	}
	now := time.Now().UTC()
	ticket.UpdatedAt = &now
	if err := h.db.WithContext(c.Request.Context()).Create(&ticket).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to create request"})
		return
	}
	out := h.mapRequestTicket(c, ticket)
	recipientLoader := h.requestHandlerRecipientIDs
	if isTeacherGroupAccessRequest(requestType) {
		recipientLoader = h.adminRecipientIDs
	}
	if recipients, err := recipientLoader(c.Request.Context()); err == nil && len(recipients) > 0 {
		title := "Новая заявка"
		if role == "teacher" {
			title = "Новая заявка преподавателя"
		}
		body := "Поступила новая заявка от " + strings.TrimSpace(user.FullName)
		_ = h.createNotifications(
			c.Request.Context(),
			recipients,
			title,
			body,
			map[string]any{
				"type":       "request_created",
				"request_id": ticket.ID,
				"status":     ticket.Status,
			},
		)
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) listRequests(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBRequestTicket{})
	role := strings.ToLower(strings.TrimSpace(user.Role))
	switch role {
	case "admin":
		// Full access.
	case "request_handler", "request-handler":
		query = query.Where(
			`NOT ((lower(request_type) LIKE ? AND lower(request_type) LIKE ?) OR lower(request_type) LIKE ?)`,
			"%преподаван%",
			"%груп%",
			"%teacher%group%",
		)
	case "student", "teacher":
		query = query.Where("student_id = ?", user.ID)
	case "parent":
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	default:
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
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
	role := strings.ToLower(strings.TrimSpace(user.Role))
	if role != "admin" && role != "request_handler" && role != "request-handler" && ticket.StudentID != user.ID {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	if (role == "request_handler" || role == "request-handler") && isTeacherGroupAccessRequest(ticket.RequestType) {
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
	role := strings.ToLower(strings.TrimSpace(user.Role))
	if role != "admin" && role != "request_handler" && role != "request-handler" {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	if (role == "request_handler" || role == "request-handler") && isTeacherGroupAccessRequest(ticket.RequestType) {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	if payload.Status != nil {
		next := strings.TrimSpace(*payload.Status)
		if isTeacherGroupAccessRequest(ticket.RequestType) {
			if !isTeacherGroupDecisionStatus(next) {
				c.JSON(http.StatusBadRequest, gin.H{"detail": "Only approve/reject is allowed for teacher group request"})
				return
			}
			next = normalizeTeacherGroupDecisionStatus(next)
		}
		ticket.Status = next
	}
	if payload.Details != nil {
		ticket.Details = strings.TrimSpace(*payload.Details)
	}
	if payload.Comment != nil {
		ticket.Comment = strings.TrimSpace(*payload.Comment)
	}
	now := time.Now().UTC()
	ticket.UpdatedAt = &now
	if err := h.db.WithContext(c.Request.Context()).Save(&ticket).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update ticket"})
		return
	}
	if shouldGrantTeacherGroupAccess(ticket.RequestType, ticket.Status) {
		groupName := extractGroupNameFromRequestDetails(ticket.Details)
		if groupName != "" {
			var canonicalGroup string
			_ = h.db.WithContext(c.Request.Context()).
				Model(&persistence.DBJournalGroup{}).
				Where("lower(name) = lower(?)", groupName).
				Limit(1).
				Pluck("name", &canonicalGroup).Error
			if strings.TrimSpace(canonicalGroup) != "" {
				groupName = strings.TrimSpace(canonicalGroup)
			}
			assignment := persistence.DBTeacherGroupAssignment{
				TeacherID: ticket.StudentID,
				GroupName: groupName,
				Subject:   "Назначено администратором",
				CreatedAt: time.Now().UTC(),
			}
			if err := h.db.WithContext(c.Request.Context()).
				Where("teacher_id = ? AND group_name = ?", assignment.TeacherID, assignment.GroupName).
				FirstOrCreate(&assignment).Error; err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to grant group access"})
				return
			}
		}
	}
	out := h.mapRequestTicket(c, ticket)
	if ticket.StudentID > 0 {
		title := "Статус заявки изменён"
		body := "Заявка #" + strconv.FormatUint(uint64(ticket.ID), 10) + ": " + ticket.Status
		if strings.TrimSpace(ticket.Comment) != "" {
			body += "\nКомментарий: " + strings.TrimSpace(ticket.Comment)
		}
		recipients := []uint{ticket.StudentID}
		if parentIDs, parentErr := h.parentUserIDsForStudents(c.Request.Context(), []uint{ticket.StudentID}); parentErr == nil {
			recipients = append(recipients, parentIDs...)
		}
		seen := map[uint]struct{}{}
		uniqueRecipients := make([]uint, 0, len(recipients))
		for _, id := range recipients {
			if id == 0 {
				continue
			}
			if _, ok := seen[id]; ok {
				continue
			}
			seen[id] = struct{}{}
			uniqueRecipients = append(uniqueRecipients, id)
		}
		_ = h.createNotifications(
			c.Request.Context(),
			uniqueRecipients,
			title,
			body,
			map[string]any{
				"type":       "request_updated",
				"request_id": ticket.ID,
				"status":     ticket.Status,
			},
		)
	}
	if isTeacherGroupAccessRequest(ticket.RequestType) && shouldCloseTeacherGroupRequest(ticket.Status) {
		if err := h.db.WithContext(c.Request.Context()).Delete(&ticket).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to close ticket"})
			return
		}
		payload := h.mapRequestTicket(c, ticket)
		payload["deleted"] = true
		payload["resolved"] = true
		c.JSON(http.StatusOK, payload)
		return
	}
	c.JSON(http.StatusOK, out)
}

func shouldGrantTeacherGroupAccess(requestType, status string) bool {
	if !isTeacherGroupAccessRequest(requestType) {
		return false
	}
	normalized := strings.ToLower(strings.TrimSpace(status))
	return normalized == "approved"
}

func shouldCloseTeacherGroupRequest(status string) bool {
	normalized := strings.ToLower(strings.TrimSpace(status))
	return normalized == "approved" || normalized == "rejected"
}

func isTeacherGroupAccessRequest(requestType string) bool {
	normalized := strings.ToLower(strings.TrimSpace(requestType))
	return (strings.Contains(normalized, "преподаван") &&
		strings.Contains(normalized, "груп")) ||
		(strings.Contains(normalized, "teacher") &&
			strings.Contains(normalized, "group"))
}

func isTeacherGroupDecisionStatus(status string) bool {
	normalized := strings.ToLower(strings.TrimSpace(status))
	return normalized == "approved" ||
		normalized == "rejected" ||
		normalized == strings.ToLower("Принята") ||
		normalized == strings.ToLower("Одобрена") ||
		normalized == strings.ToLower("Отклонена")
}

func normalizeTeacherGroupDecisionStatus(status string) string {
	normalized := strings.ToLower(strings.TrimSpace(status))
	if normalized == "approved" ||
		normalized == strings.ToLower("Принята") ||
		normalized == strings.ToLower("Одобрена") {
		return "approved"
	}
	return "rejected"
}

func extractGroupNameFromRequestDetails(details string) string {
	lines := strings.Split(details, "\n")
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		lower := strings.ToLower(trimmed)
		if strings.HasPrefix(lower, strings.ToLower("Группа:")) {
			return strings.TrimSpace(strings.TrimPrefix(trimmed, "Группа:"))
		}
		if strings.HasPrefix(lower, strings.ToLower("group:")) {
			return strings.TrimSpace(strings.TrimPrefix(trimmed, "Group:"))
		}
	}
	return ""
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
		LessonSlot:  lessonSlotFromPointer(payload.LessonSlot),
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
	actor := actorFromContext(c)
	var existing persistence.DBAttendanceRecord
	err = tx.Where(
		"group_name = ? AND class_date = ? AND lesson_slot = ? AND student_name = ?",
		row.GroupName,
		row.ClassDate,
		row.LessonSlot,
		row.StudentName,
	).
		First(&existing).Error
	switch {
	case err == nil:
		existing.Present = row.Present
		existing.TeacherID = user.ID
		if err := tx.Save(&existing).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save attendance"})
			return
		}
		if syncErr := h.syncAttendanceToJournalV2(c.Request.Context(), actor, existing); syncErr != nil {
			// keep attendance write successful even if v2 sync fails
		}
		_ = h.notifyAttendanceChanged(c.Request.Context(), existing)
		c.JSON(http.StatusOK, mapAttendance(existing))
	case errors.Is(err, gorm.ErrRecordNotFound):
		if err := tx.Create(&row).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save attendance"})
			return
		}
		if syncErr := h.syncAttendanceToJournalV2(c.Request.Context(), actor, row); syncErr != nil {
			// keep attendance write successful even if v2 sync fails
		}
		_ = h.notifyAttendanceChanged(c.Request.Context(), row)
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
		child, childErr := h.parentLinkedStudent(c.Request.Context(), user)
		if childErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load attendance"})
			return
		}
		if child == nil {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		query = query.Where("student_name = ?", strings.TrimSpace(child.FullName))
		if strings.TrimSpace(child.StudentGroup) != "" {
			query = query.Where("group_name = ?", strings.TrimSpace(child.StudentGroup))
		}
	}
	var rows []persistence.DBAttendanceRecord
	if err := query.Order("class_date desc").Order("lesson_slot desc").Find(&rows).Error; err != nil {
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
	slotPtr, slotErr := parseOptionalLessonSlot(c.Query("lesson_slot"))
	if group == "" || student == "" || err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name, class_date and student_name are required"})
		return
	}
	if slotErr != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "lesson_slot should be a positive integer"})
		return
	}
	slot := 1
	if slotPtr != nil {
		slot = *slotPtr
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
		Where(
			"group_name = ? AND class_date = ? AND lesson_slot = ? AND student_name = ?",
			group,
			classDate,
			slot,
			student,
		).
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
		child, childErr := h.parentLinkedStudent(c.Request.Context(), user)
		if childErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load attendance"})
			return
		}
		if child == nil {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		query = query.Where("student_name = ?", strings.TrimSpace(child.FullName))
		if strings.TrimSpace(child.StudentGroup) != "" {
			query = query.Where("group_name = ?", strings.TrimSpace(child.StudentGroup))
		}
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
	if payload.Grade < 0 || payload.Grade > 100 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Grade must be 0..100"})
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
		if syncErr := h.syncGradeToAttendance(c.Request.Context(), user.ID, existing); syncErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to synchronize attendance"})
			return
		}
		_ = h.notifyGradeChanged(c.Request.Context(), existing)
		c.JSON(http.StatusOK, mapGrade(existing))
	case errors.Is(err, gorm.ErrRecordNotFound):
		if err := tx.Create(&row).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save grade"})
			return
		}
		if syncErr := h.syncGradeToAttendance(c.Request.Context(), user.ID, row); syncErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to synchronize attendance"})
			return
		}
		_ = h.notifyGradeChanged(c.Request.Context(), row)
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
		child, childErr := h.parentLinkedStudent(c.Request.Context(), user)
		if childErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load grades"})
			return
		}
		if child == nil {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		query = query.Where("student_name = ?", strings.TrimSpace(child.FullName))
		if strings.TrimSpace(child.StudentGroup) != "" {
			query = query.Where("group_name = ?", strings.TrimSpace(child.StudentGroup))
		}
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
		child, childErr := h.parentLinkedStudent(c.Request.Context(), user)
		if childErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load grades"})
			return
		}
		if child == nil {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		query = query.Where("student_name = ?", strings.TrimSpace(child.FullName))
		if strings.TrimSpace(child.StudentGroup) != "" {
			query = query.Where("group_name = ?", strings.TrimSpace(child.StudentGroup))
		}
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
	if user.Role == "admin" && !h.requireAdminPermission(c, AdminPermAnalyticsView) {
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
	if err := query.Order("class_date desc").Order("lesson_slot desc").Find(&rows).Error; err != nil {
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
	if user.Role == "admin" && !h.requireAdminPermission(c, AdminPermAnalyticsView) {
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
	creatorName := ""
	creatorRole := ""
	var creator persistence.DBUser
	if err := h.db.WithContext(c.Request.Context()).First(&creator, ticket.StudentID).Error; err == nil {
		creatorName = creator.FullName
		creatorRole = creator.Role
	}
	updatedAt := ticket.CreatedAt
	if ticket.UpdatedAt != nil {
		updatedAt = *ticket.UpdatedAt
	}
	return gin.H{
		"id":           ticket.ID,
		"student_id":   ticket.StudentID,
		"student_name": creatorName,
		"request_type": ticket.RequestType,
		"status":       ticket.Status,
		"details":      nullOrString(ticket.Details),
		"comment":      nullOrString(ticket.Comment),
		"creator_role": creatorRole,
		"created_at":   ticket.CreatedAt.Format(time.RFC3339),
		"updated_at":   updatedAt.Format(time.RFC3339),
	}
}

func mapAttendance(row persistence.DBAttendanceRecord) gin.H {
	return gin.H{
		"id":           row.ID,
		"group_name":   row.GroupName,
		"class_date":   dateOnly(row.ClassDate),
		"lesson_slot":  normalizeLessonSlot(row.LessonSlot),
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

func (h *Handler) notifyAttendanceChanged(ctx context.Context, row persistence.DBAttendanceRecord) error {
	studentIDs, err := h.findStudentIDsByNameAndGroup(ctx, row.StudentName, row.GroupName)
	if err != nil || len(studentIDs) == 0 {
		return err
	}
	recipients := append([]uint{}, studentIDs...)
	if parentIDs, parentErr := h.parentUserIDsForStudents(ctx, studentIDs); parentErr == nil {
		recipients = append(recipients, parentIDs...)
	}
	recipients = uniqueUintIDs(recipients)
	if len(recipients) == 0 {
		return nil
	}
	status := "отсутствует"
	if row.Present {
		status = "присутствует"
	}
	return h.createNotifications(
		ctx,
		recipients,
		"Обновлена посещаемость",
		"Студент "+row.StudentName+": "+status+" ("+row.GroupName+")",
		map[string]any{
			"type":         "attendance_updated",
			"group_name":   row.GroupName,
			"class_date":   dateOnly(row.ClassDate),
			"lesson_slot":  normalizeLessonSlot(row.LessonSlot),
			"student_name": row.StudentName,
			"present":      row.Present,
		},
	)
}

func (h *Handler) notifyGradeChanged(ctx context.Context, row persistence.DBGradeRecord) error {
	studentIDs, err := h.findStudentIDsByNameAndGroup(ctx, row.StudentName, row.GroupName)
	if err != nil || len(studentIDs) == 0 {
		return err
	}
	recipients := append([]uint{}, studentIDs...)
	if parentIDs, parentErr := h.parentUserIDsForStudents(ctx, studentIDs); parentErr == nil {
		recipients = append(recipients, parentIDs...)
	}
	recipients = uniqueUintIDs(recipients)
	if len(recipients) == 0 {
		return nil
	}
	return h.createNotifications(
		ctx,
		recipients,
		"Обновлена оценка",
		"Студент "+row.StudentName+": "+strconv.Itoa(row.Grade)+" ("+row.GroupName+")",
		map[string]any{
			"type":         "grade_updated",
			"group_name":   row.GroupName,
			"class_date":   dateOnly(row.ClassDate),
			"student_name": row.StudentName,
			"grade":        row.Grade,
		},
	)
}

func (h *Handler) findStudentIDsByNameAndGroup(ctx context.Context, studentName, groupName string) ([]uint, error) {
	name := strings.TrimSpace(studentName)
	group := strings.TrimSpace(groupName)
	if name == "" {
		return nil, nil
	}
	query := h.db.WithContext(ctx).
		Model(&persistence.DBUser{}).
		Where("role = ? AND full_name = ? AND is_approved = ?", "student", name, true)
	if group != "" {
		query = query.Where("student_group = ?", group)
	}
	var ids []uint
	if err := query.Pluck("id", &ids).Error; err != nil {
		return nil, err
	}
	return ids, nil
}

func uniqueUintIDs(ids []uint) []uint {
	seen := map[uint]struct{}{}
	out := make([]uint, 0, len(ids))
	for _, id := range ids {
		if id == 0 {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		out = append(out, id)
	}
	return out
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

	var teacher persistence.DBUser
	if err := h.db.WithContext(c.Request.Context()).
		Where("id = ? AND role = ?", teacherID, "teacher").
		First(&teacher).Error; err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, err
	}
	teacherNames := map[string]struct{}{}
	for _, value := range []string{teacher.TeacherName, teacher.FullName} {
		name := strings.TrimSpace(value)
		if name == "" {
			continue
		}
		teacherNames[strings.ToLower(name)] = struct{}{}
	}
	for lowerName := range teacherNames {
		var scheduled []string
		if err := h.db.WithContext(c.Request.Context()).
			Model(&persistence.DBScheduleLesson{}).
			Where("lower(teacher_name) = ?", lowerName).
			Distinct("group_name").
			Pluck("group_name", &scheduled).Error; err != nil {
			return nil, err
		}
		for _, group := range scheduled {
			group = normalizeGroupName(group)
			if group != "" {
				unique[group] = struct{}{}
			}
		}
	}

	out := make([]string, 0, len(unique))
	for group := range unique {
		out = append(out, group)
	}
	sort.Strings(out)
	return out, nil
}

func (h *Handler) requestHandlerRecipientIDs(ctx context.Context) ([]uint, error) {
	var ids []uint
	if err := h.db.WithContext(ctx).
		Model(&persistence.DBUser{}).
		Where("role IN ?", []string{"admin", "request_handler"}).
		Where("is_approved = ?", true).
		Pluck("id", &ids).Error; err != nil {
		return nil, err
	}
	return ids, nil
}

func (h *Handler) adminRecipientIDs(ctx context.Context) ([]uint, error) {
	var ids []uint
	if err := h.db.WithContext(ctx).
		Model(&persistence.DBUser{}).
		Where("role = ?", "admin").
		Where("is_approved = ?", true).
		Pluck("id", &ids).Error; err != nil {
		return nil, err
	}
	return ids, nil
}
