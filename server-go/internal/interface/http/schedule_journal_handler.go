package http

import (
	"bytes"
	"context"
	"encoding/csv"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/infrastructure/persistence"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"gorm.io/gorm"
)

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

	upload := persistence.DBScheduleUpload{
		Filename:   file.Filename,
		DBFilename: storedName,
		UploadedAt: time.Now().UTC(),
	}
	if err := h.db.WithContext(c.Request.Context()).Create(&upload).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save upload"})
		return
	}
	_ = h.tryParseScheduleCSV(c.Request.Context(), upload.ID, buf)
	c.JSON(http.StatusOK, mapScheduleUpload(upload))
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
	var groups []string
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBScheduleLesson{}).
		Distinct("group_name").
		Where("group_name <> ''").
		Order("group_name asc").
		Pluck("group_name", &groups).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load groups"})
		return
	}
	c.JSON(http.StatusOK, groups)
}

func (h *Handler) scheduleTeachers(c *gin.Context) {
	var teachers []string
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBScheduleLesson{}).
		Distinct("teacher_name").
		Where("teacher_name <> ''").
		Order("teacher_name asc").
		Pluck("teacher_name", &teachers).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load teachers"})
		return
	}
	c.JSON(http.StatusOK, teachers)
}

func (h *Handler) scheduleForMe(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBScheduleLesson{})
	if user.Role == "student" && strings.TrimSpace(user.StudentGroup) != "" {
		query = query.Where("group_name = ?", user.StudentGroup)
	} else if user.Role == "teacher" && strings.TrimSpace(user.TeacherName) != "" {
		query = query.Where("teacher_name = ?", user.TeacherName)
	} else {
		c.JSON(http.StatusOK, []gin.H{})
		return
	}
	var lessons []persistence.DBScheduleLesson
	if err := query.Order("shift asc").Order("period asc").Find(&lessons).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule"})
		return
	}
	c.JSON(http.StatusOK, mapScheduleLessons(lessons))
}

func (h *Handler) scheduleForGroup(c *gin.Context) {
	groupName := strings.TrimSpace(c.Param("group"))
	if groupName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Group is required"})
		return
	}
	var lessons []persistence.DBScheduleLesson
	if err := h.db.WithContext(c.Request.Context()).
		Where("group_name = ?", groupName).
		Order("shift asc").Order("period asc").
		Find(&lessons).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule"})
		return
	}
	c.JSON(http.StatusOK, mapScheduleLessons(lessons))
}

func (h *Handler) scheduleForTeacher(c *gin.Context) {
	teacherName := strings.TrimSpace(c.Param("teacher"))
	if teacherName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Teacher is required"})
		return
	}
	var lessons []persistence.DBScheduleLesson
	if err := h.db.WithContext(c.Request.Context()).
		Where("teacher_name = ?", teacherName).
		Order("shift asc").Order("period asc").
		Find(&lessons).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load schedule"})
		return
	}
	c.JSON(http.StatusOK, mapScheduleLessons(lessons))
}

func (h *Handler) listJournalGroups(c *gin.Context) {
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
	groupName := strings.TrimSpace(c.Query("group_name"))
	if groupName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name is required"})
		return
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
	group := strings.TrimSpace(c.Query("group_name"))
	name := strings.TrimSpace(c.Query("student_name"))
	if group == "" || name == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name and student_name are required"})
		return
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
	group := strings.TrimSpace(c.Query("group_name"))
	if group == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "group_name is required"})
		return
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
	group := strings.TrimSpace(c.Query("group_name"))
	dateValue, err := parseDate(c.Query("class_date"))
	if group == "" || err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid group_name or class_date"})
		return
	}
	if err := h.db.WithContext(c.Request.Context()).
		Where("group_name = ? AND class_date = ?", group, dateValue).
		Delete(&persistence.DBJournalDate{}).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete date"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) tryParseScheduleCSV(ctx context.Context, uploadID uint, data []byte) error {
	reader := csv.NewReader(bytes.NewReader(data))
	rows, err := reader.ReadAll()
	if err != nil {
		return err
	}
	if len(rows) == 0 {
		return nil
	}
	lessons := make([]persistence.DBScheduleLesson, 0, len(rows))
	for _, row := range rows {
		if len(row) < 6 {
			continue
		}
		shift, err1 := strconv.Atoi(strings.TrimSpace(row[0]))
		period, err2 := strconv.Atoi(strings.TrimSpace(row[1]))
		if err1 != nil || err2 != nil {
			continue
		}
		teacher := ""
		if len(row) > 6 {
			teacher = strings.TrimSpace(row[6])
		}
		lessons = append(lessons, persistence.DBScheduleLesson{
			UploadID:    uploadID,
			Shift:       shift,
			Period:      period,
			TimeText:    strings.TrimSpace(row[2]),
			Audience:    strings.TrimSpace(row[3]),
			Lesson:      strings.TrimSpace(row[4]),
			GroupName:   strings.TrimSpace(row[5]),
			TeacherName: teacher,
			CreatedAt:   time.Now().UTC(),
		})
	}
	if len(lessons) == 0 {
		return nil
	}
	return h.db.WithContext(ctx).Create(&lessons).Error
}
