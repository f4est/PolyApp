package http

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/infrastructure/persistence"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

type scheduleUploadUpdatePayload struct {
	ScheduleDate *string `json:"schedule_date"`
}

func (h *Handler) uploadSchedule(c *gin.Context) {
	file, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Missing file"})
		return
	}
	src, err := file.Open()
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Failed to open file"})
		return
	}
	defer src.Close()

	buf, err := io.ReadAll(src)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Failed to read file"})
		return
	}
	storedName := uuid.NewString() + strings.ToLower(filepath.Ext(file.Filename))
	scheduleDir := filepath.Join(h.cfg.MediaDir, "schedule")
	_ = os.MkdirAll(scheduleDir, 0o755)
	target := filepath.Join(scheduleDir, storedName)
	if err := os.WriteFile(target, buf, 0o644); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save file"})
		return
	}

	drafts, detectedDate, err := parseScheduleLessonsFromDOCX(file.Filename, buf)
	if err != nil {
		_ = os.Remove(target)
		c.JSON(http.StatusBadRequest, gin.H{"detail": err.Error()})
		return
	}
	if len(drafts) == 0 {
		_ = os.Remove(target)
		c.JSON(http.StatusBadRequest, gin.H{"detail": "No lessons found in DOCX"})
		return
	}

	scheduleDate, err := parseScheduleDateInput(c.PostForm("schedule_date"), file.Filename, detectedDate)
	if err != nil {
		_ = os.Remove(target)
		c.JSON(http.StatusBadRequest, gin.H{"detail": "schedule_date should be YYYY-MM-DD"})
		return
	}
	var previousForDate []persistence.DBScheduleUpload
	if scheduleDate != nil {
		_ = h.db.WithContext(c.Request.Context()).
			Where("schedule_date = ?", *scheduleDate).
			Find(&previousForDate).Error
	}

	upload := persistence.DBScheduleUpload{
		Filename:     file.Filename,
		DBFilename:   storedName,
		ScheduleDate: scheduleDate,
		UploadedAt:   time.Now().UTC(),
	}
	idsToReplace := make([]uint, 0, len(previousForDate))
	filesToRemove := make([]string, 0, len(previousForDate))
	for _, prev := range previousForDate {
		idsToReplace = append(idsToReplace, prev.ID)
		if strings.TrimSpace(prev.DBFilename) != "" {
			filesToRemove = append(filesToRemove, filepath.Join(scheduleDir, prev.DBFilename))
		}
	}

	if err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		if len(idsToReplace) > 0 {
			if err := tx.Where("upload_id IN ?", idsToReplace).Delete(&persistence.DBScheduleLesson{}).Error; err != nil {
				return err
			}
			if err := tx.Where("id IN ?", idsToReplace).Delete(&persistence.DBScheduleUpload{}).Error; err != nil {
				return err
			}
		}

		if err := tx.Create(&upload).Error; err != nil {
			return err
		}

		lessons := make([]persistence.DBScheduleLesson, 0, len(drafts))
		seenLessonKeys := make(map[string]struct{}, len(drafts))
		now := time.Now().UTC()
		for _, draft := range drafts {
			// Ignore duplicate rows from DOCX. We intentionally do not use audience in
			// dedupe key to avoid duplicate same lesson/group/time with accidental room drift.
			dedupeKey := strings.ToLower(strings.TrimSpace(strings.Join([]string{
				strconv.Itoa(draft.Shift),
				strconv.Itoa(draft.Period),
				strings.TrimSpace(draft.TimeText),
				strings.TrimSpace(draft.GroupName),
				strings.TrimSpace(draft.Lesson),
				strings.TrimSpace(draft.TeacherName),
			}, "|")))
			if dedupeKey != "" {
				if _, exists := seenLessonKeys[dedupeKey]; exists {
					continue
				}
				seenLessonKeys[dedupeKey] = struct{}{}
			}
			lessons = append(lessons, persistence.DBScheduleLesson{
				UploadID:    upload.ID,
				Shift:       draft.Shift,
				Period:      draft.Period,
				TimeText:    draft.TimeText,
				Audience:    draft.Audience,
				Lesson:      draft.Lesson,
				GroupName:   draft.GroupName,
				TeacherName: draft.TeacherName,
				CreatedAt:   now,
			})
		}
		if len(lessons) == 0 {
			return errors.New("no parsed lessons")
		}
		return tx.Create(&lessons).Error
	}); err != nil {
		_ = os.Remove(target)
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Failed to parse DOCX lessons"})
		return
	}

	for _, filename := range filesToRemove {
		_ = os.Remove(filename)
	}

	_ = h.cleanupOldSchedules(c.Request.Context(), 30)
	c.JSON(http.StatusOK, mapScheduleUpload(upload))
}

func (h *Handler) updateScheduleUpload(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid schedule id"})
		return
	}
	var payload scheduleUploadUpdatePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	if payload.ScheduleDate == nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "schedule_date is required"})
		return
	}

	var scheduleDate *time.Time
	rawDate := strings.TrimSpace(*payload.ScheduleDate)
	if rawDate != "" {
		parsed, parseErr := parseDate(rawDate)
		if parseErr != nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "schedule_date should be YYYY-MM-DD"})
			return
		}
		scheduleDate = &parsed
	}

	var upload persistence.DBScheduleUpload
	if err := h.db.WithContext(c.Request.Context()).First(&upload, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Schedule upload not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update schedule upload"})
		return
	}

	scheduleDir := filepath.Join(h.cfg.MediaDir, "schedule")
	filesToRemove := []string{}
	if err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		if scheduleDate != nil {
			var duplicates []persistence.DBScheduleUpload
			if err := tx.
				Where("id <> ? AND schedule_date = ?", upload.ID, *scheduleDate).
				Find(&duplicates).Error; err != nil {
				return err
			}
			if len(duplicates) > 0 {
				ids := make([]uint, 0, len(duplicates))
				for _, row := range duplicates {
					ids = append(ids, row.ID)
					if strings.TrimSpace(row.DBFilename) != "" {
						filesToRemove = append(filesToRemove, filepath.Join(scheduleDir, row.DBFilename))
					}
				}
				if err := tx.Where("upload_id IN ?", ids).Delete(&persistence.DBScheduleLesson{}).Error; err != nil {
					return err
				}
				if err := tx.Where("id IN ?", ids).Delete(&persistence.DBScheduleUpload{}).Error; err != nil {
					return err
				}
			}
		}
		upload.ScheduleDate = scheduleDate
		return tx.Save(&upload).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update schedule upload"})
		return
	}

	for _, filename := range filesToRemove {
		_ = os.Remove(filename)
	}
	c.JSON(http.StatusOK, mapScheduleUpload(upload))
}

func (h *Handler) deleteScheduleUpload(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid schedule id"})
		return
	}
	var upload persistence.DBScheduleUpload
	if err := h.db.WithContext(c.Request.Context()).First(&upload, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Schedule upload not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete schedule upload"})
		return
	}
	if err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("upload_id = ?", id).Delete(&persistence.DBScheduleLesson{}).Error; err != nil {
			return err
		}
		return tx.Delete(&upload).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete schedule upload"})
		return
	}
	if strings.TrimSpace(upload.DBFilename) != "" {
		_ = os.Remove(filepath.Join(h.cfg.MediaDir, "schedule", upload.DBFilename))
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) listScheduleUploads(c *gin.Context) {
	var uploads []persistence.DBScheduleUpload
	if err := h.db.WithContext(c.Request.Context()).
		Order("uploaded_at desc").
		Find(&uploads).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule uploads"})
		return
	}
	out := make([]gin.H, 0, len(uploads))
	for _, item := range uploads {
		out = append(out, mapScheduleUpload(item))
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) latestScheduleUpload(c *gin.Context) {
	var upload persistence.DBScheduleUpload
	if err := h.db.WithContext(c.Request.Context()).
		Order("schedule_date desc nulls last").
		Order("uploaded_at desc").
		First(&upload).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusOK, nil)
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule"})
		return
	}
	c.JSON(http.StatusOK, mapScheduleUpload(upload))
}

func (h *Handler) scheduleGroups(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	scheduleAt, err := parseScheduleAt(c.Query("at"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid 'at' date. Use YYYY-MM-DD"})
		return
	}
	uploadID, err := h.resolveScheduleUploadID(c.Request.Context(), scheduleAt)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load groups"})
		return
	}
	if scheduleAt != nil && uploadID == 0 {
		c.JSON(http.StatusOK, []string{})
		return
	}

	var rawGroups []string
	query := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBScheduleLesson{}).
		Where("group_name <> ''")
	if uploadID > 0 {
		query = query.Where("upload_id = ?", uploadID)
	}
	if err := query.Pluck("group_name", &rawGroups).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load groups"})
		return
	}
	unique := map[string]struct{}{}
	groups := make([]string, 0, len(rawGroups))
	var scope groupAccessScope
	if user.Role == "teacher" {
		scope, err = h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load groups"})
			return
		}
	}
	userGroup := normalizeGroupName(user.StudentGroup)
	for _, value := range rawGroups {
		for _, token := range extractGroupTokens(value) {
			normalized := strings.TrimSpace(token)
			if normalized == "" {
				continue
			}
			if user.Role == "teacher" && !scope.canView(normalized) {
				continue
			}
			if (user.Role == "student" || user.Role == "parent") && (userGroup == "" || userGroup != normalized) {
				continue
			}
			key := strings.ToLower(normalized)
			if _, exists := unique[key]; exists {
				continue
			}
			unique[key] = struct{}{}
			groups = append(groups, normalized)
		}
	}
	sort.Strings(groups)
	c.JSON(http.StatusOK, groups)
}

func (h *Handler) scheduleTeachers(c *gin.Context) {
	scheduleAt, err := parseScheduleAt(c.Query("at"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid 'at' date. Use YYYY-MM-DD"})
		return
	}
	uploadID, err := h.resolveScheduleUploadID(c.Request.Context(), scheduleAt)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load teachers"})
		return
	}
	if scheduleAt != nil && uploadID == 0 {
		c.JSON(http.StatusOK, []string{})
		return
	}

	var rows []persistence.DBScheduleLesson
	query := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBScheduleLesson{})
	if uploadID > 0 {
		query = query.Where("upload_id = ?", uploadID)
	}
	if err := query.Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load teachers"})
		return
	}

	unique := map[string]struct{}{}
	teachers := make([]string, 0, len(rows))
	for _, row := range rows {
		candidates := []string{
			strings.TrimSpace(row.TeacherName),
			strings.TrimSpace(deriveTeacherNameFromLesson(row.Lesson)),
		}
		for _, value := range candidates {
			if value == "" {
				continue
			}
			key := strings.ToLower(value)
			if _, exists := unique[key]; exists {
				continue
			}
			unique[key] = struct{}{}
			teachers = append(teachers, value)
		}
	}
	sort.Strings(teachers)
	c.JSON(http.StatusOK, teachers)
}

func (h *Handler) scheduleForMe(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBScheduleLesson{})
	scheduleAt, err := parseScheduleAt(c.Query("at"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid 'at' date. Use YYYY-MM-DD"})
		return
	}
	if user.Role == "student" && strings.TrimSpace(user.StudentGroup) != "" {
		// Student filtering is applied after fetch to support legacy merged group
		// cells like "ИС23-3А ИС25-1Б".
	} else if user.Role == "teacher" {
		teacherName := strings.TrimSpace(user.TeacherName)
		if teacherName == "" {
			teacherName = strings.TrimSpace(user.FullName)
		}
		if teacherName == "" {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		pattern := "%" + strings.ToLower(teacherName) + "%"
		query = query.Where(
			"lower(teacher_name) = lower(?) OR lower(teacher_name) LIKE ? OR lower(lesson) LIKE ?",
			teacherName,
			pattern,
			pattern,
		)
	} else {
		c.JSON(http.StatusOK, []gin.H{})
		return
	}
	uploadID, err := h.resolveScheduleUploadID(c.Request.Context(), scheduleAt)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule"})
		return
	}
	if scheduleAt != nil && uploadID == 0 {
		c.JSON(http.StatusOK, []gin.H{})
		return
	}
	if uploadID > 0 {
		query = query.Where("upload_id = ?", uploadID)
	}
	var lessons []persistence.DBScheduleLesson
	if err := query.Order("shift asc").Order("period asc").Find(&lessons).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule"})
		return
	}
	if user.Role == "student" {
		group := strings.TrimSpace(user.StudentGroup)
		if group != "" {
			filtered := make([]persistence.DBScheduleLesson, 0, len(lessons))
			for _, row := range lessons {
				if groupIncludesToken(row.GroupName, group) {
					filtered = append(filtered, row)
				}
			}
			lessons = filtered
		}
	}
	c.JSON(http.StatusOK, mapScheduleLessons(lessons))
}

func (h *Handler) scheduleForGroup(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	groupName := strings.TrimSpace(c.Param("group"))
	if groupName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Group is required"})
		return
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule"})
			return
		}
		if !scope.canView(groupName) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	if user.Role == "student" || user.Role == "parent" {
		if normalizeGroupName(user.StudentGroup) == "" || normalizeGroupName(user.StudentGroup) != groupName {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	scheduleAt, err := parseScheduleAt(c.Query("at"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid 'at' date. Use YYYY-MM-DD"})
		return
	}
	uploadID, err := h.resolveScheduleUploadID(c.Request.Context(), scheduleAt)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule"})
		return
	}
	if scheduleAt != nil && uploadID == 0 {
		c.JSON(http.StatusOK, []gin.H{})
		return
	}
	var lessons []persistence.DBScheduleLesson
	query := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBScheduleLesson{})
	if uploadID > 0 {
		query = query.Where("upload_id = ?", uploadID)
	}
	if err := query.
		Order("shift asc").Order("period asc").
		Find(&lessons).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule"})
		return
	}
	filtered := make([]persistence.DBScheduleLesson, 0, len(lessons))
	for _, row := range lessons {
		if groupIncludesToken(row.GroupName, groupName) {
			filtered = append(filtered, row)
		}
	}
	lessons = filtered
	c.JSON(http.StatusOK, mapScheduleLessons(lessons))
}

func (h *Handler) scheduleForTeacher(c *gin.Context) {
	teacherName := strings.TrimSpace(c.Param("teacher"))
	if teacherName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Teacher is required"})
		return
	}
	scheduleAt, err := parseScheduleAt(c.Query("at"))
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid 'at' date. Use YYYY-MM-DD"})
		return
	}
	uploadID, err := h.resolveScheduleUploadID(c.Request.Context(), scheduleAt)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule"})
		return
	}
	if scheduleAt != nil && uploadID == 0 {
		c.JSON(http.StatusOK, []gin.H{})
		return
	}
	var lessons []persistence.DBScheduleLesson
	pattern := "%" + strings.ToLower(teacherName) + "%"
	query := h.db.WithContext(c.Request.Context()).
		Where(
			"lower(teacher_name) = lower(?) OR lower(teacher_name) LIKE ? OR lower(lesson) LIKE ?",
			teacherName,
			pattern,
			pattern,
		)
	if uploadID > 0 {
		query = query.Where("upload_id = ?", uploadID)
	}
	if err := query.
		Order("shift asc").Order("period asc").
		Find(&lessons).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule"})
		return
	}
	c.JSON(http.StatusOK, mapScheduleLessons(lessons))
}

func (h *Handler) listJournalGroups(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load groups"})
			return
		}
		c.JSON(http.StatusOK, scope.asList())
		return
	}
	if user.Role == "student" || user.Role == "parent" {
		group := normalizeGroupName(user.StudentGroup)
		if group == "" {
			c.JSON(http.StatusOK, []string{})
		} else {
			c.JSON(http.StatusOK, []string{group})
		}
		return
	}
	var groups []string
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBJournalGroup{}).
		Order("name asc").
		Pluck("name", &groups).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load groups"})
		return
	}
	c.JSON(http.StatusOK, groups)
}

func (h *Handler) upsertJournalGroup(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	if user.Role == "teacher" {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
		return
	}
	var payload journalGroupPayload
	if err := c.ShouldBindJSON(&payload); err != nil || strings.TrimSpace(payload.Name) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Group name is required"})
		return
	}
	name := strings.TrimSpace(payload.Name)
	group := persistence.DBJournalGroup{Name: name}
	if err := h.db.WithContext(c.Request.Context()).Where("name = ?", name).FirstOrCreate(&group).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save group"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"id": group.ID, "name": group.Name})
}

func (h *Handler) deleteJournalGroup(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	if user.Role == "teacher" {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
		return
	}
	name := strings.TrimSpace(c.Query("group_name"))
	if name == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name is required"})
		return
	}
	if err := h.db.WithContext(c.Request.Context()).
		Transaction(func(tx *gorm.DB) error {
			if err := tx.Where("group_name = ?", name).Delete(&persistence.DBJournalStudent{}).Error; err != nil {
				return err
			}
			if err := tx.Where("group_name = ?", name).Delete(&persistence.DBJournalDate{}).Error; err != nil {
				return err
			}
			return tx.Where("name = ?", name).Delete(&persistence.DBJournalGroup{}).Error
		}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete group"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) listJournalStudents(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	groupName := strings.TrimSpace(c.Query("group_name"))
	if groupName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name is required"})
		return
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load students"})
			return
		}
		if !scope.canView(groupName) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	if user.Role == "student" || user.Role == "parent" {
		if normalizeGroupName(user.StudentGroup) == "" || normalizeGroupName(user.StudentGroup) != groupName {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	var students []string
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBJournalStudent{}).
		Where("group_name = ?", groupName).
		Order("student_name asc").
		Pluck("student_name", &students).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load students"})
		return
	}
	c.JSON(http.StatusOK, students)
}

func (h *Handler) upsertJournalStudent(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	var payload journalStudentPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	group := strings.TrimSpace(payload.GroupName)
	name := strings.TrimSpace(payload.StudentName)
	if group == "" || name == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name and student_name are required"})
		return
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save student"})
			return
		}
		if !scope.canEditGrades(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	row := persistence.DBJournalStudent{GroupName: group, StudentName: name}
	if err := h.db.WithContext(c.Request.Context()).
		Where("group_name = ? AND student_name = ?", group, name).
		FirstOrCreate(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save student"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"id":           row.ID,
		"group_name":   row.GroupName,
		"student_name": row.StudentName,
	})
}

func (h *Handler) deleteJournalStudent(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	group := strings.TrimSpace(c.Query("group_name"))
	name := strings.TrimSpace(c.Query("student_name"))
	if group == "" || name == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name and student_name are required"})
		return
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete student"})
			return
		}
		if !scope.canEditGrades(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	if err := h.db.WithContext(c.Request.Context()).
		Where("group_name = ? AND student_name = ?", group, name).
		Delete(&persistence.DBJournalStudent{}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete student"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) listJournalDates(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	group := strings.TrimSpace(c.Query("group_name"))
	if group == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name is required"})
		return
	}
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load dates"})
			return
		}
		if !scope.canView(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	if user.Role == "student" || user.Role == "parent" {
		if normalizeGroupName(user.StudentGroup) == "" || normalizeGroupName(user.StudentGroup) != group {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	var dates []time.Time
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBJournalDate{}).
		Where("group_name = ?", group).
		Order("class_date asc").
		Pluck("class_date", &dates).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load dates"})
		return
	}
	out := make([]string, 0, len(dates))
	for _, d := range dates {
		out = append(out, dateOnly(d))
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) upsertJournalDate(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	var payload journalDatePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	group := strings.TrimSpace(payload.GroupName)
	dateValue, err := parseDate(payload.ClassDate)
	if group == "" || err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid group_name or class_date"})
		return
	}
	if user.Role == "teacher" {
		scope, scopeErr := h.groupScopeForUser(c.Request.Context(), user)
		if scopeErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save date"})
			return
		}
		if !scope.canEditGrades(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	row := persistence.DBJournalDate{
		GroupName: group,
		ClassDate: dateValue,
	}
	if err := h.db.WithContext(c.Request.Context()).
		Where("group_name = ? AND class_date = ?", group, dateValue).
		FirstOrCreate(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save date"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"id":         row.ID,
		"group_name": row.GroupName,
		"class_date": dateOnly(row.ClassDate),
	})
}

func (h *Handler) deleteJournalDate(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	group := strings.TrimSpace(c.Query("group_name"))
	dateValue, err := parseDate(c.Query("class_date"))
	if group == "" || err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid group_name or class_date"})
		return
	}
	if user.Role == "teacher" {
		scope, scopeErr := h.groupScopeForUser(c.Request.Context(), user)
		if scopeErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete date"})
			return
		}
		if !scope.canEditGrades(group) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
			return
		}
	}
	if err := h.db.WithContext(c.Request.Context()).
		Where("group_name = ? AND class_date = ?", group, dateValue).
		Delete(&persistence.DBJournalDate{}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete date"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func parseScheduleDateInput(raw string, filename string, detected *time.Time) (*time.Time, error) {
	raw = strings.TrimSpace(raw)
	if raw != "" {
		parsed, err := parseDate(raw)
		if err != nil {
			return nil, err
		}
		return &parsed, nil
	}
	if detected != nil {
		return detected, nil
	}
	if parsed, ok := parseScheduleDateFromFilename(filename); ok {
		return &parsed, nil
	}
	today := time.Now().UTC()
	defaultDate := time.Date(today.Year(), today.Month(), today.Day(), 0, 0, 0, 0, time.UTC)
	return &defaultDate, nil
}

func parseScheduleDateFromFilename(filename string) (time.Time, bool) {
	base := strings.ToLower(filepath.Base(filename))
	reDots := regexp.MustCompile(`(\d{2}\.\d{2}\.\d{4})`)
	if m := reDots.FindStringSubmatch(base); len(m) == 2 {
		if parsed, err := time.Parse("02.01.2006", m[1]); err == nil {
			value := time.Date(parsed.Year(), parsed.Month(), parsed.Day(), 0, 0, 0, 0, time.UTC)
			return value, true
		}
	}
	base = strings.ReplaceAll(base, "_", "-")
	base = strings.ReplaceAll(base, ".", "-")
	parts := strings.Split(base, "-")
	for i := 0; i+2 < len(parts); i++ {
		a := strings.TrimSpace(parts[i])
		b := strings.TrimSpace(parts[i+1])
		c := strings.TrimSpace(parts[i+2])
		if len(a) == 4 && len(b) == 2 && len(c) == 2 {
			if parsed, err := parseDate(a + "-" + b + "-" + c); err == nil {
				return parsed, true
			}
		}
		if len(a) == 2 && len(b) == 2 && len(c) == 4 {
			if parsed, err := parseDate(c + "-" + b + "-" + a); err == nil {
				return parsed, true
			}
		}
	}
	return time.Time{}, false
}

func parseScheduleAt(value string) (*time.Time, error) {
	raw := strings.TrimSpace(value)
	if raw == "" {
		return nil, nil
	}
	parsed, err := parseDate(raw)
	if err != nil {
		return nil, err
	}
	return &parsed, nil
}

func (h *Handler) resolveScheduleUploadID(ctx context.Context, at *time.Time) (uint, error) {
	query := h.db.WithContext(ctx).Model(&persistence.DBScheduleUpload{})

	var upload persistence.DBScheduleUpload
	if at != nil {
		// Day-specific schedule is strict: only exact date package.
		err := query.
			Where("schedule_date IS NOT NULL AND schedule_date = ?", *at).
			Order("uploaded_at desc").
			First(&upload).Error
		if err == nil {
			return upload.ID, nil
		}
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return 0, nil
		}
		if err != nil {
			return 0, err
		}
	}

	err := query.
		Order("schedule_date desc nulls last").
		Order("uploaded_at desc").
		First(&upload).Error
	if errors.Is(err, gorm.ErrRecordNotFound) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	return upload.ID, nil
}

func (h *Handler) cleanupOldSchedules(ctx context.Context, keepDays int) error {
	if keepDays <= 0 {
		keepDays = 30
	}
	cutoff := time.Now().UTC().AddDate(0, 0, -keepDays)

	var oldUploads []persistence.DBScheduleUpload
	if err := h.db.WithContext(ctx).
		Where("(schedule_date IS NOT NULL AND schedule_date < ?) OR (schedule_date IS NULL AND uploaded_at < ?)", cutoff, cutoff).
		Find(&oldUploads).Error; err != nil {
		return err
	}
	if len(oldUploads) == 0 {
		return nil
	}

	ids := make([]uint, 0, len(oldUploads))
	files := make([]string, 0, len(oldUploads))
	for _, item := range oldUploads {
		ids = append(ids, item.ID)
		if strings.TrimSpace(item.DBFilename) != "" {
			files = append(files, filepath.Join(h.cfg.MediaDir, "schedule", item.DBFilename))
		}
	}

	if err := h.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("upload_id IN ?", ids).Delete(&persistence.DBScheduleLesson{}).Error; err != nil {
			return err
		}
		if err := tx.Where("id IN ?", ids).Delete(&persistence.DBScheduleUpload{}).Error; err != nil {
			return err
		}
		return nil
	}); err != nil {
		return err
	}

	for _, filename := range files {
		_ = os.Remove(filename)
	}
	return nil
}
