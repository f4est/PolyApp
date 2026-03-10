package http

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	"polyapp/server-go/internal/infrastructure/persistence"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

const (
	makeupStatusAwaitingProof = "awaiting_proof"
	makeupStatusProofSent     = "proof_submitted"
	makeupStatusTaskAssigned  = "task_assigned"
	makeupStatusSubmitted     = "submission_sent"
	makeupStatusGraded        = "graded"
	makeupStatusRejected      = "rejected"
)

var validMakeupStatuses = map[string]struct{}{
	makeupStatusAwaitingProof: {},
	makeupStatusProofSent:     {},
	makeupStatusTaskAssigned:  {},
	makeupStatusSubmitted:     {},
	makeupStatusGraded:        {},
	makeupStatusRejected:      {},
}

type makeupCaseCreatePayload struct {
	TeacherID   *uint  `json:"teacher_id"`
	StudentID   uint   `json:"student_id"`
	GroupName   string `json:"group_name"`
	ClassDate   string `json:"class_date"`
	TeacherNote string `json:"teacher_note"`
}

type makeupCasePatchPayload struct {
	TeacherID    *uint   `json:"teacher_id"`
	StudentID    *uint   `json:"student_id"`
	GroupName    *string `json:"group_name"`
	ClassDate    *string `json:"class_date"`
	Status       *string `json:"status"`
	TeacherTask  *string `json:"teacher_task"`
	TeacherNote  *string `json:"teacher_note"`
	Grade        *string `json:"grade"`
	GradeComment *string `json:"grade_comment"`
}

type makeupMessagePayload struct {
	Text string `json:"text"`
}

func (h *Handler) listMakeupCases(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}

	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBMakeupCase{})
	switch user.Role {
	case "admin":
		// Full access.
	case "teacher":
		allowedGroups, err := h.allowedGroupsForTeacher(c, user.ID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeups"})
			return
		}
		if len(allowedGroups) == 0 {
			query = query.Where("teacher_id = ?", user.ID)
		} else {
			query = query.Where("teacher_id = ? OR group_name IN ?", user.ID, allowedGroups)
		}
	case "student":
		query = query.Where("student_id = ?", user.ID)
	case "parent":
		if strings.TrimSpace(user.StudentGroup) == "" {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		query = query.Where("group_name = ?", strings.TrimSpace(user.StudentGroup))
	default:
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}

	if groupName := strings.TrimSpace(c.Query("group_name")); groupName != "" {
		query = query.Where("group_name = ?", groupName)
	}
	if status := strings.TrimSpace(c.Query("status")); status != "" {
		query = query.Where("status = ?", strings.ToLower(status))
	}
	if studentRaw := strings.TrimSpace(c.Query("student_id")); studentRaw != "" {
		studentID, err := strconv.ParseUint(studentRaw, 10, 64)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid student_id"})
			return
		}
		query = query.Where("student_id = ?", uint(studentID))
	}
	if teacherRaw := strings.TrimSpace(c.Query("teacher_id")); teacherRaw != "" {
		teacherID, err := strconv.ParseUint(teacherRaw, 10, 64)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid teacher_id"})
			return
		}
		query = query.Where("teacher_id = ?", uint(teacherID))
	}

	var rows []persistence.DBMakeupCase
	if err := query.Order("updated_at desc").Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeups"})
		return
	}
	out, err := h.mapMakeupCases(c, rows)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeups"})
		return
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) createMakeupCase(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}

	var payload makeupCaseCreatePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	if payload.StudentID == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "student_id is required"})
		return
	}
	classDate, err := parseDate(payload.ClassDate)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "class_date should be YYYY-MM-DD"})
		return
	}

	var student persistence.DBUser
	if err := h.db.WithContext(c.Request.Context()).First(&student, payload.StudentID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Student not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load student"})
		return
	}
	if student.Role != "student" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "student_id must reference a student"})
		return
	}

	groupName := strings.TrimSpace(payload.GroupName)
	if groupName == "" {
		groupName = strings.TrimSpace(student.StudentGroup)
	}
	if groupName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name is required"})
		return
	}

	teacherID := user.ID
	if user.Role == "admin" && payload.TeacherID != nil && *payload.TeacherID > 0 {
		teacherID = *payload.TeacherID
	}
	if user.Role == "teacher" {
		allowedGroups, err := h.allowedGroupsForTeacher(c, user.ID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to create makeup"})
			return
		}
		if !contains(allowedGroups, groupName) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Group is not assigned to teacher"})
			return
		}
	}

	row := persistence.DBMakeupCase{
		GroupName:   groupName,
		TeacherID:   teacherID,
		StudentID:   payload.StudentID,
		ClassDate:   classDate,
		Status:      makeupStatusAwaitingProof,
		TeacherNote: strings.TrimSpace(payload.TeacherNote),
		CreatedAt:   time.Now().UTC(),
		UpdatedAt:   time.Now().UTC(),
	}
	if strings.TrimSpace(payload.TeacherNote) != "" {
		noteAt := time.Now().UTC()
		row.TeacherNoteAt = &noteAt
	}
	if err := h.db.WithContext(c.Request.Context()).Create(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to create makeup"})
		return
	}
	h.notifyMakeup(
		c.Request.Context(),
		row,
		[]uint{row.StudentID},
		"Новая отработка",
		fmt.Sprintf("Группа %s, дата %s", row.GroupName, dateOnly(row.ClassDate)),
	)
	if row.TeacherID != user.ID {
		h.notifyMakeup(
			c.Request.Context(),
			row,
			[]uint{row.TeacherID},
			"Назначена отработка",
			fmt.Sprintf("Группа %s, дата %s", row.GroupName, dateOnly(row.ClassDate)),
		)
	}
	out, err := h.mapMakeupCases(c, []persistence.DBMakeupCase{row})
	if err != nil || len(out) == 0 {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	c.JSON(http.StatusOK, out[0])
}

func (h *Handler) getMakeupCase(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid makeup id"})
		return
	}
	var row persistence.DBMakeupCase
	if err := h.db.WithContext(c.Request.Context()).First(&row, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Makeup not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	allowed, err := h.canAccessMakeupCase(c, user, row)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	if !allowed {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
		return
	}
	out, err := h.mapMakeupCases(c, []persistence.DBMakeupCase{row})
	if err != nil || len(out) == 0 {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	c.JSON(http.StatusOK, out[0])
}

func (h *Handler) patchMakeupCase(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid makeup id"})
		return
	}
	var payload makeupCasePatchPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	var row persistence.DBMakeupCase
	if err := h.db.WithContext(c.Request.Context()).First(&row, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Makeup not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}

	if user.Role != "admin" {
		allowed, err := h.canTeacherManageMakeup(c, user, row)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update makeup"})
			return
		}
		if !allowed {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}

	previousStatus := row.Status
	previousTeacherTask := row.TeacherTask
	previousTeacherNote := row.TeacherNote
	previousGrade := row.Grade
	previousGradeComment := row.GradeComment

	now := time.Now().UTC()
	if payload.Status != nil {
		nextStatus := strings.ToLower(strings.TrimSpace(*payload.Status))
		if _, ok := validMakeupStatuses[nextStatus]; !ok {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid status"})
			return
		}
		row.Status = nextStatus
		if nextStatus == makeupStatusGraded || nextStatus == makeupStatusRejected {
			row.ClosedAt = &now
		}
	}
	if payload.TeacherTask != nil {
		nextTask := strings.TrimSpace(*payload.TeacherTask)
		if row.TeacherTask != nextTask {
			if nextTask == "" {
				row.TeacherTaskAt = nil
			} else {
				row.TeacherTaskAt = &now
			}
		}
		row.TeacherTask = strings.TrimSpace(*payload.TeacherTask)
		if row.TeacherTask != "" && row.Status == makeupStatusProofSent {
			row.Status = makeupStatusTaskAssigned
		}
	}
	if payload.TeacherNote != nil {
		nextNote := strings.TrimSpace(*payload.TeacherNote)
		if row.TeacherNote != nextNote {
			if nextNote == "" {
				row.TeacherNoteAt = nil
			} else {
				row.TeacherNoteAt = &now
			}
		}
		row.TeacherNote = strings.TrimSpace(*payload.TeacherNote)
	}
	if payload.Grade != nil {
		nextGrade := strings.TrimSpace(*payload.Grade)
		if row.Grade != nextGrade && nextGrade != "" {
			row.GradeSetAt = &now
		}
		row.Grade = strings.TrimSpace(*payload.Grade)
		if row.Grade != "" {
			row.Status = makeupStatusGraded
			row.ClosedAt = &now
		}
	}
	if payload.GradeComment != nil {
		nextComment := strings.TrimSpace(*payload.GradeComment)
		if row.GradeComment != nextComment && strings.TrimSpace(row.Grade) != "" {
			row.GradeSetAt = &now
		}
		row.GradeComment = strings.TrimSpace(*payload.GradeComment)
	}
	if user.Role == "admin" {
		if payload.GroupName != nil {
			row.GroupName = strings.TrimSpace(*payload.GroupName)
		}
		if payload.TeacherID != nil && *payload.TeacherID > 0 {
			row.TeacherID = *payload.TeacherID
		}
		if payload.StudentID != nil && *payload.StudentID > 0 {
			row.StudentID = *payload.StudentID
		}
		if payload.ClassDate != nil {
			classDate, err := parseDate(*payload.ClassDate)
			if err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"detail": "class_date should be YYYY-MM-DD"})
				return
			}
			row.ClassDate = classDate
		}
	}
	row.UpdatedAt = now

	if err := h.db.WithContext(c.Request.Context()).Save(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update makeup"})
		return
	}

	studentTitle := ""
	studentBody := ""
	switch {
	case row.Status != previousStatus && row.Status == makeupStatusRejected:
		studentTitle = "Отработка отклонена"
		studentBody = fmt.Sprintf("Группа %s, дата %s", row.GroupName, dateOnly(row.ClassDate))
	case row.Grade != previousGrade || row.GradeComment != previousGradeComment || (row.Status == makeupStatusGraded && previousStatus != makeupStatusGraded):
		studentTitle = "Отработка оценена"
		if strings.TrimSpace(row.Grade) != "" {
			studentBody = fmt.Sprintf("Оценка: %s", strings.TrimSpace(row.Grade))
		} else {
			studentBody = fmt.Sprintf("Группа %s, дата %s", row.GroupName, dateOnly(row.ClassDate))
		}
	case row.TeacherTask != previousTeacherTask && strings.TrimSpace(row.TeacherTask) != "":
		studentTitle = "Назначено задание по отработке"
		studentBody = fmt.Sprintf("Группа %s, дата %s", row.GroupName, dateOnly(row.ClassDate))
	case row.TeacherNote != previousTeacherNote && strings.TrimSpace(row.TeacherNote) != "":
		studentTitle = "Комментарий преподавателя по отработке"
		studentBody = strings.TrimSpace(row.TeacherNote)
	}
	if studentTitle != "" {
		h.notifyMakeup(c.Request.Context(), row, []uint{row.StudentID}, studentTitle, studentBody)
	}

	out, err := h.mapMakeupCases(c, []persistence.DBMakeupCase{row})
	if err != nil || len(out) == 0 {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	c.JSON(http.StatusOK, out[0])
}

func (h *Handler) deleteMakeupCase(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid makeup id"})
		return
	}
	var row persistence.DBMakeupCase
	if err := h.db.WithContext(c.Request.Context()).First(&row, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Makeup not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	if user.Role != "admin" {
		allowed, err := h.canTeacherManageMakeup(c, user, row)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete makeup"})
			return
		}
		if !allowed {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}

	if err := h.db.WithContext(c.Request.Context()).
		Transaction(func(tx *gorm.DB) error {
			if err := tx.Where("makeup_case_id = ?", row.ID).Delete(&persistence.DBMakeupMessage{}).Error; err != nil {
				return err
			}
			return tx.Delete(&row).Error
		}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete makeup"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) listMakeupMessages(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid makeup id"})
		return
	}
	var row persistence.DBMakeupCase
	if err := h.db.WithContext(c.Request.Context()).First(&row, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Makeup not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	allowed, err := h.canAccessMakeupCase(c, user, row)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load messages"})
		return
	}
	if !allowed {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
		return
	}

	var messages []persistence.DBMakeupMessage
	if err := h.db.WithContext(c.Request.Context()).
		Where("makeup_case_id = ?", row.ID).
		Order("created_at asc").
		Find(&messages).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load messages"})
		return
	}
	out, err := h.mapMakeupMessages(c, messages)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load messages"})
		return
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) createMakeupMessage(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid makeup id"})
		return
	}
	var row persistence.DBMakeupCase
	if err := h.db.WithContext(c.Request.Context()).First(&row, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Makeup not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	allowed, err := h.canAccessMakeupCase(c, user, row)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save message"})
		return
	}
	if !allowed {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
		return
	}

	text := ""
	attachmentURL := ""
	if strings.Contains(strings.ToLower(c.GetHeader("Content-Type")), "multipart/form-data") {
		text = strings.TrimSpace(c.PostForm("text"))
		file, err := c.FormFile("file")
		if err == nil && file != nil {
			url, saveErr := h.saveMakeupMedia(file)
			if saveErr != nil {
				c.JSON(http.StatusBadRequest, gin.H{"detail": "Failed to save attachment"})
				return
			}
			attachmentURL = url
		}
	} else {
		var payload makeupMessagePayload
		if err := c.ShouldBindJSON(&payload); err == nil {
			text = strings.TrimSpace(payload.Text)
		}
	}
	if text == "" && attachmentURL == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Message text or file is required"})
		return
	}
	msg := persistence.DBMakeupMessage{
		MakeupCaseID:  row.ID,
		SenderID:      user.ID,
		Body:          text,
		AttachmentURL: attachmentURL,
		CreatedAt:     time.Now().UTC(),
	}
	if err := h.db.WithContext(c.Request.Context()).Create(&msg).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save message"})
		return
	}
	row.UpdatedAt = time.Now().UTC()
	_ = h.db.WithContext(c.Request.Context()).Save(&row).Error
	targetIDs := []uint{}
	if user.ID == row.StudentID {
		targetIDs = append(targetIDs, row.TeacherID)
	} else {
		targetIDs = append(targetIDs, row.StudentID)
	}
	if len(targetIDs) > 0 {
		h.notifyMakeup(
			c.Request.Context(),
			row,
			targetIDs,
			"Новое сообщение по отработке",
			fmt.Sprintf("Группа %s, дата %s", row.GroupName, dateOnly(row.ClassDate)),
		)
	}
	out, err := h.mapMakeupMessages(c, []persistence.DBMakeupMessage{msg})
	if err != nil || len(out) == 0 {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load message"})
		return
	}
	c.JSON(http.StatusOK, out[0])
}

func (h *Handler) uploadMakeupProof(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid makeup id"})
		return
	}
	var row persistence.DBMakeupCase
	if err := h.db.WithContext(c.Request.Context()).First(&row, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Makeup not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	if user.Role != "admin" && row.StudentID != user.ID {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
		return
	}
	file, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "file is required"})
		return
	}
	url, err := h.saveMakeupMedia(file)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Failed to save proof file"})
		return
	}
	row.MedicalProofURL = url
	row.MedicalProofComment = strings.TrimSpace(c.PostForm("comment"))
	row.ProofSubmittedAt = ptrTime(time.Now().UTC())
	if row.Status == makeupStatusAwaitingProof {
		row.Status = makeupStatusProofSent
	}
	row.UpdatedAt = time.Now().UTC()
	if err := h.db.WithContext(c.Request.Context()).Save(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save proof"})
		return
	}
	h.notifyMakeup(
		c.Request.Context(),
		row,
		[]uint{row.TeacherID},
		"Справка по отработке отправлена",
		fmt.Sprintf("Группа %s, дата %s", row.GroupName, dateOnly(row.ClassDate)),
	)
	out, err := h.mapMakeupCases(c, []persistence.DBMakeupCase{row})
	if err != nil || len(out) == 0 {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	c.JSON(http.StatusOK, out[0])
}

func (h *Handler) uploadMakeupSubmission(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid makeup id"})
		return
	}
	var row persistence.DBMakeupCase
	if err := h.db.WithContext(c.Request.Context()).First(&row, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Makeup not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	if user.Role != "admin" && row.StudentID != user.ID {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
		return
	}

	text := strings.TrimSpace(c.PostForm("text"))
	if file, err := c.FormFile("file"); err == nil && file != nil {
		url, saveErr := h.saveMakeupMedia(file)
		if saveErr != nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Failed to save submission file"})
			return
		}
		row.StudentSubmissionURL = url
	}
	if text != "" {
		row.StudentSubmission = text
	}
	if row.StudentSubmission == "" && row.StudentSubmissionURL == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "text or file is required"})
		return
	}
	row.Status = makeupStatusSubmitted
	row.SubmissionSentAt = ptrTime(time.Now().UTC())
	row.UpdatedAt = time.Now().UTC()
	if err := h.db.WithContext(c.Request.Context()).Save(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save submission"})
		return
	}
	h.notifyMakeup(
		c.Request.Context(),
		row,
		[]uint{row.TeacherID},
		"Выполнение отработки отправлено",
		fmt.Sprintf("Группа %s, дата %s", row.GroupName, dateOnly(row.ClassDate)),
	)
	out, err := h.mapMakeupCases(c, []persistence.DBMakeupCase{row})
	if err != nil || len(out) == 0 {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load makeup"})
		return
	}
	c.JSON(http.StatusOK, out[0])
}

func (h *Handler) listMakeupGroupsForActor(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	switch user.Role {
	case "admin":
		var groups []string
		if err := h.db.WithContext(c.Request.Context()).
			Model(&persistence.DBJournalGroup{}).
			Order("name asc").
			Pluck("name", &groups).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load groups"})
			return
		}
		c.JSON(http.StatusOK, groups)
	case "teacher":
		groups, err := h.allowedGroupsForTeacher(c, user.ID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load groups"})
			return
		}
		sort.Strings(groups)
		c.JSON(http.StatusOK, groups)
	default:
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
	}
}

func (h *Handler) listMakeupStudentsForGroup(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	groupName := strings.TrimSpace(c.Param("group_name"))
	if groupName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name is required"})
		return
	}
	if user.Role == "teacher" {
		allowedGroups, err := h.allowedGroupsForTeacher(c, user.ID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load students"})
			return
		}
		if !contains(allowedGroups, groupName) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Group is not assigned to teacher"})
			return
		}
	}
	var students []persistence.DBUser
	if err := h.db.WithContext(c.Request.Context()).
		Where("role = ? AND student_group = ?", "student", groupName).
		Order("full_name asc").
		Find(&students).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load students"})
		return
	}
	out := make([]gin.H, 0, len(students))
	for _, student := range students {
		out = append(out, gin.H{
			"id":            student.ID,
			"role":          student.Role,
			"full_name":     student.FullName,
			"avatar_url":    nullOrString(student.AvatarURL),
			"about":         nullOrString(student.About),
			"student_group": nullOrString(student.StudentGroup),
			"teacher_name":  nullOrString(student.TeacherName),
		})
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) canAccessMakeupCase(c *gin.Context, user *entity.User, row persistence.DBMakeupCase) (bool, error) {
	if user == nil {
		return false, nil
	}
	if user.Role == "admin" {
		return true, nil
	}
	if user.Role == "teacher" {
		return h.canTeacherManageMakeup(c, user, row)
	}
	if user.Role == "student" {
		return row.StudentID == user.ID, nil
	}
	if user.Role == "parent" {
		return strings.TrimSpace(user.StudentGroup) != "" && strings.TrimSpace(user.StudentGroup) == strings.TrimSpace(row.GroupName), nil
	}
	return false, nil
}

func (h *Handler) canTeacherManageMakeup(c *gin.Context, user *entity.User, row persistence.DBMakeupCase) (bool, error) {
	if user == nil || user.Role != "teacher" {
		return false, nil
	}
	if row.TeacherID == user.ID {
		return true, nil
	}
	allowedGroups, err := h.allowedGroupsForTeacher(c, user.ID)
	if err != nil {
		return false, err
	}
	return contains(allowedGroups, row.GroupName), nil
}

func (h *Handler) mapMakeupCases(c *gin.Context, rows []persistence.DBMakeupCase) ([]gin.H, error) {
	if len(rows) == 0 {
		return []gin.H{}, nil
	}
	userIDs := map[uint]struct{}{}
	for _, row := range rows {
		userIDs[row.TeacherID] = struct{}{}
		userIDs[row.StudentID] = struct{}{}
	}
	var users []persistence.DBUser
	if err := h.db.WithContext(c.Request.Context()).
		Where("id IN ?", mapIDSet(userIDs)).
		Find(&users).Error; err != nil {
		return nil, err
	}
	userNames := map[uint]string{}
	for _, user := range users {
		userNames[user.ID] = user.FullName
	}

	out := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		item := gin.H{
			"id":                     row.ID,
			"group_name":             row.GroupName,
			"teacher_id":             row.TeacherID,
			"teacher_name":           userNames[row.TeacherID],
			"student_id":             row.StudentID,
			"student_name":           userNames[row.StudentID],
			"class_date":             dateOnly(row.ClassDate),
			"status":                 row.Status,
			"teacher_note":           nullOrString(row.TeacherNote),
			"medical_proof_url":      nullOrString(row.MedicalProofURL),
			"medical_proof_comment":  nullOrString(row.MedicalProofComment),
			"teacher_task":           nullOrString(row.TeacherTask),
			"teacher_task_at":        nil,
			"student_submission":     nullOrString(row.StudentSubmission),
			"student_submission_url": nullOrString(row.StudentSubmissionURL),
			"submission_sent_at":     nil,
			"grade":                  nullOrString(row.Grade),
			"grade_comment":          nullOrString(row.GradeComment),
			"grade_set_at":           nil,
			"proof_submitted_at":     nil,
			"teacher_note_at":        nil,
			"created_at":             row.CreatedAt.Format(time.RFC3339),
			"updated_at":             row.UpdatedAt.Format(time.RFC3339),
			"closed_at":              nil,
		}
		if row.TeacherTaskAt != nil {
			item["teacher_task_at"] = row.TeacherTaskAt.Format(time.RFC3339)
		}
		if row.SubmissionSentAt != nil {
			item["submission_sent_at"] = row.SubmissionSentAt.Format(time.RFC3339)
		}
		if row.GradeSetAt != nil {
			item["grade_set_at"] = row.GradeSetAt.Format(time.RFC3339)
		}
		if row.ProofSubmittedAt != nil {
			item["proof_submitted_at"] = row.ProofSubmittedAt.Format(time.RFC3339)
		}
		if row.TeacherNoteAt != nil {
			item["teacher_note_at"] = row.TeacherNoteAt.Format(time.RFC3339)
		}
		if row.ClosedAt != nil {
			item["closed_at"] = row.ClosedAt.Format(time.RFC3339)
		}
		out = append(out, item)
	}
	return out, nil
}

func ptrTime(value time.Time) *time.Time {
	return &value
}

func (h *Handler) mapMakeupMessages(c *gin.Context, rows []persistence.DBMakeupMessage) ([]gin.H, error) {
	if len(rows) == 0 {
		return []gin.H{}, nil
	}
	userIDs := map[uint]struct{}{}
	for _, row := range rows {
		userIDs[row.SenderID] = struct{}{}
	}
	var users []persistence.DBUser
	if err := h.db.WithContext(c.Request.Context()).
		Where("id IN ?", mapIDSet(userIDs)).
		Find(&users).Error; err != nil {
		return nil, err
	}
	userMap := map[uint]persistence.DBUser{}
	for _, user := range users {
		userMap[user.ID] = user
	}
	out := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		sender := userMap[row.SenderID]
		out = append(out, gin.H{
			"id":             row.ID,
			"makeup_case_id": row.MakeupCaseID,
			"sender_id":      row.SenderID,
			"sender_name":    sender.FullName,
			"sender_role":    sender.Role,
			"body":           nullOrString(row.Body),
			"attachment_url": nullOrString(row.AttachmentURL),
			"created_at":     row.CreatedAt.Format(time.RFC3339),
		})
	}
	return out, nil
}

func (h *Handler) saveMakeupMedia(file *multipart.FileHeader) (string, error) {
	if file == nil {
		return "", errors.New("invalid file")
	}
	if file.Size > 30*1024*1024 {
		return "", errors.New("file too large")
	}
	src, err := file.Open()
	if err != nil {
		return "", err
	}
	defer src.Close()

	ext := strings.ToLower(filepath.Ext(file.Filename))
	stored := uuid.NewString() + ext
	target := filepath.Join(h.cfg.MediaDir, "makeup", stored)
	dst, err := os.Create(target)
	if err != nil {
		return "", err
	}
	defer dst.Close()
	if _, err := io.Copy(dst, src); err != nil {
		return "", err
	}
	return "/media/makeup/" + stored, nil
}

func (h *Handler) notifyMakeup(
	ctx context.Context,
	row persistence.DBMakeupCase,
	userIDs []uint,
	title string,
	body string,
) {
	if strings.TrimSpace(title) == "" || len(userIDs) == 0 {
		return
	}
	unique := make([]uint, 0, len(userIDs))
	seen := map[uint]struct{}{}
	for _, id := range userIDs {
		if id == 0 {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		unique = append(unique, id)
	}
	if len(unique) == 0 {
		return
	}
	_ = h.createNotifications(
		ctx,
		unique,
		title,
		strings.TrimSpace(body),
		map[string]any{
			"type":       "makeup",
			"makeup_id":  row.ID,
			"group_name": row.GroupName,
			"class_date": dateOnly(row.ClassDate),
			"status":     row.Status,
		},
	)
}
