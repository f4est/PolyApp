package http

import (
	"bytes"
	"encoding/csv"
	"fmt"
	"io"
	"net/http"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/infrastructure/persistence"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"

	"github.com/gin-gonic/gin"
	"github.com/xuri/excelize/v2"
	"gorm.io/gorm"
)

func (h *Handler) listTeacherAssignments(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	groupName := strings.TrimSpace(c.Query("group_name"))
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBTeacherGroupAssignment{})
	if groupName != "" {
		query = query.Where("group_name = ?", groupName)
	}
	if user.Role == "teacher" {
		query = query.Where("teacher_id = ?", user.ID)
	}
	var rows []persistence.DBTeacherGroupAssignment
	if err := query.Order("created_at desc").Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load assignments"})
		return
	}
	out, err := h.mapTeacherAssignments(c, rows)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load assignments"})
		return
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) createTeacherAssignment(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermAcademicManage) {
		return
	}
	var payload teacherAssignmentPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	if payload.TeacherID == 0 || strings.TrimSpace(payload.GroupName) == "" || strings.TrimSpace(payload.Subject) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "teacher_id, group_name and subject are required"})
		return
	}
	row := persistence.DBTeacherGroupAssignment{
		TeacherID: payload.TeacherID,
		GroupName: strings.TrimSpace(payload.GroupName),
		Subject:   strings.TrimSpace(payload.Subject),
		CreatedAt: time.Now().UTC(),
	}
	if err := h.db.WithContext(c.Request.Context()).Create(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to create assignment"})
		return
	}
	items, err := h.mapTeacherAssignments(c, []persistence.DBTeacherGroupAssignment{row})
	if err != nil || len(items) == 0 {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load assignment"})
		return
	}
	c.JSON(http.StatusOK, items[0])
}

func (h *Handler) updateTeacherAssignment(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermAcademicManage) {
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid assignment id"})
		return
	}
	var payload teacherAssignmentUpdatePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	var row persistence.DBTeacherGroupAssignment
	if err := h.db.WithContext(c.Request.Context()).First(&row, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Assignment not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load assignment"})
		return
	}
	if payload.GroupName != nil {
		row.GroupName = strings.TrimSpace(*payload.GroupName)
	}
	if payload.Subject != nil {
		row.Subject = strings.TrimSpace(*payload.Subject)
	}
	if err := h.db.WithContext(c.Request.Context()).Save(&row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update assignment"})
		return
	}
	items, err := h.mapTeacherAssignments(c, []persistence.DBTeacherGroupAssignment{row})
	if err != nil || len(items) == 0 {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load assignment"})
		return
	}
	c.JSON(http.StatusOK, items[0])
}

func (h *Handler) deleteTeacherAssignment(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermAcademicManage) {
		return
	}
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid assignment id"})
		return
	}
	res := h.db.WithContext(c.Request.Context()).Delete(&persistence.DBTeacherGroupAssignment{}, id)
	if res.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete assignment"})
		return
	}
	if res.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"detail": "Assignment not found"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) analyticsGroups(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	if user.Role == "admin" && !h.requireAdminPermission(c, AdminPermAnalyticsView) {
		return
	}
	var rows []persistence.DBTeacherGroupAssignment
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBTeacherGroupAssignment{})
	if user.Role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load analytics"})
			return
		}
		allowed := scope.asList()
		if len(allowed) == 0 {
			c.JSON(http.StatusOK, []gin.H{})
			return
		}
		query = query.Where("group_name IN ?", allowed)
	}
	if err := query.Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load analytics"})
		return
	}
	type analyticsRow struct {
		GroupName string   `json:"group_name"`
		Subjects  []string `json:"subjects"`
		Teachers  []string `json:"teachers"`
	}
	teacherIDs := map[uint]struct{}{}
	for _, row := range rows {
		teacherIDs[row.TeacherID] = struct{}{}
	}
	var teachers []persistence.DBUser
	if len(teacherIDs) > 0 {
		if err := h.db.WithContext(c.Request.Context()).
			Where("id IN ?", mapIDSet(teacherIDs)).
			Find(&teachers).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load analytics"})
			return
		}
	}
	teacherNames := map[uint]string{}
	for _, teacher := range teachers {
		teacherNames[teacher.ID] = teacher.FullName
	}
	collect := map[string]*analyticsRow{}
	for _, row := range rows {
		entry, ok := collect[row.GroupName]
		if !ok {
			entry = &analyticsRow{
				GroupName: row.GroupName,
				Subjects:  []string{},
				Teachers:  []string{},
			}
			collect[row.GroupName] = entry
		}
		if !contains(entry.Subjects, row.Subject) {
			entry.Subjects = append(entry.Subjects, row.Subject)
		}
		name := teacherNames[row.TeacherID]
		if name == "" {
			name = "Unknown"
		}
		if !contains(entry.Teachers, name) {
			entry.Teachers = append(entry.Teachers, name)
		}
	}
	if user.Role == "admin" {
		var journalGroups []string
		_ = h.db.WithContext(c.Request.Context()).
			Model(&persistence.DBJournalGroup{}).
			Pluck("name", &journalGroups).Error
		for _, name := range journalGroups {
			if _, ok := collect[name]; !ok {
				collect[name] = &analyticsRow{GroupName: name, Subjects: []string{}, Teachers: []string{}}
			}
		}
	}
	out := make([]analyticsRow, 0, len(collect))
	for _, row := range collect {
		sort.Strings(row.Subjects)
		sort.Strings(row.Teachers)
		out = append(out, *row)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].GroupName < out[j].GroupName })
	c.JSON(http.StatusOK, out)
}

func (h *Handler) listExamGrades(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	group := strings.TrimSpace(c.Query("group_name"))
	exam := strings.TrimSpace(c.Query("exam_name"))
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBExamGrade{})
	if user.Role == "student" {
		query = query.Where("student_name = ?", user.FullName)
		if strings.TrimSpace(user.StudentGroup) != "" {
			query = query.Where("group_name = ?", user.StudentGroup)
		}
	} else if user.Role == "parent" {
		child, childErr := h.parentLinkedStudent(c.Request.Context(), user)
		if childErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load exam grades"})
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
	if group != "" {
		query = query.Where("group_name = ?", group)
	}
	if exam != "" {
		query = query.Where("exam_name = ?", exam)
	}
	var rows []persistence.DBExamGrade
	if err := query.Order("created_at desc").Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load exam grades"})
		return
	}
	out := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		out = append(out, mapExamGrade(row))
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) listExamUploads(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	group := strings.TrimSpace(c.Query("group_name"))
	exam := strings.TrimSpace(c.Query("exam_name"))
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBExamUpload{})
	if user.Role == "teacher" {
		query = query.Where("teacher_id = ?", user.ID)
	}
	if group != "" {
		query = query.Where("group_name = ?", group)
	}
	if exam != "" {
		query = query.Where("exam_name = ?", exam)
	}
	var rows []persistence.DBExamUpload
	if err := query.Order("uploaded_at desc").Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load uploads"})
		return
	}
	out, err := h.mapExamUploads(c, rows)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load uploads"})
		return
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) updateExamUpload(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid upload id"})
		return
	}
	var payload examUploadUpdatePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	var upload persistence.DBExamUpload
	if err := h.db.WithContext(c.Request.Context()).First(&upload, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Upload not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load upload"})
		return
	}
	if user.Role == "teacher" && upload.TeacherID != user.ID {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
		return
	}
	if payload.GroupName != nil {
		upload.GroupName = strings.TrimSpace(*payload.GroupName)
	}
	if payload.ExamName != nil {
		upload.ExamName = strings.TrimSpace(*payload.ExamName)
	}
	err = h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		if err := tx.Save(&upload).Error; err != nil {
			return err
		}
		updates := map[string]any{}
		if payload.GroupName != nil {
			updates["group_name"] = upload.GroupName
		}
		if payload.ExamName != nil {
			updates["exam_name"] = upload.ExamName
		}
		if len(updates) > 0 {
			return tx.Model(&persistence.DBExamGrade{}).Where("upload_id = ?", upload.ID).Updates(updates).Error
		}
		return nil
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update upload"})
		return
	}
	out, err := h.mapExamUploads(c, []persistence.DBExamUpload{upload})
	if err != nil || len(out) == 0 {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load upload"})
		return
	}
	c.JSON(http.StatusOK, out[0])
}

func (h *Handler) deleteExamUpload(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid upload id"})
		return
	}
	var upload persistence.DBExamUpload
	if err := h.db.WithContext(c.Request.Context()).First(&upload, id).Error; err != nil {
		if err == gorm.ErrRecordNotFound {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Upload not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load upload"})
		return
	}
	if user.Role == "teacher" && upload.TeacherID != user.ID {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
		return
	}
	var deleted int64
	if err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		res := tx.Where("upload_id = ?", id).Delete(&persistence.DBExamGrade{})
		if res.Error != nil {
			return res.Error
		}
		deleted = res.RowsAffected
		return tx.Delete(&upload).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete upload"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"deleted": deleted})
}

func (h *Handler) uploadExamGrades(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	groupName := strings.TrimSpace(c.PostForm("group_name"))
	examName := strings.TrimSpace(c.PostForm("exam_name"))
	if groupName == "" || examName == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Group and exam name are required"})
		return
	}
	file, err := c.FormFile("file")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Missing file"})
		return
	}
	src, err := file.Open()
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Failed to read file"})
		return
	}
	defer src.Close()
	data, err := io.ReadAll(src)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Failed to read file"})
		return
	}
	rows, err := parseExamRows(data, file.Filename)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": err.Error()})
		return
	}
	if len(rows) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "No grades found"})
		return
	}
	now := time.Now().UTC()
	var upload persistence.DBExamUpload
	var records []persistence.DBExamGrade
	err = h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		upload = persistence.DBExamUpload{
			GroupName:  groupName,
			ExamName:   examName,
			Filename:   file.Filename,
			RowsCount:  len(rows),
			UploadedAt: now,
			TeacherID:  user.ID,
		}
		if err := tx.Create(&upload).Error; err != nil {
			return err
		}
		records = make([]persistence.DBExamGrade, 0, len(rows))
		for _, row := range rows {
			record := persistence.DBExamGrade{
				GroupName:   groupName,
				ExamName:    examName,
				StudentName: row.StudentName,
				Grade:       row.Grade,
				CreatedAt:   now,
				TeacherID:   user.ID,
				UploadID:    upload.ID,
			}
			if err := tx.Create(&record).Error; err != nil {
				return err
			}
			records = append(records, record)
		}
		return nil
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to save grades"})
		return
	}
	studentNames := map[string]struct{}{}
	for _, row := range rows {
		studentNames[row.StudentName] = struct{}{}
	}
	var users []persistence.DBUser
	if err := h.db.WithContext(c.Request.Context()).
		Where("role IN ?", []string{"student", "parent"}).
		Find(&users).Error; err == nil {
		targetSet := map[uint]struct{}{}
		studentByID := map[uint]persistence.DBUser{}
		for _, item := range users {
			if item.Role == "student" {
				studentByID[item.ID] = item
			}
		}
		for _, item := range users {
			if item.Role == "student" {
				if _, ok := studentNames[item.FullName]; ok && (item.StudentGroup == "" || item.StudentGroup == groupName) {
					targetSet[item.ID] = struct{}{}
				}
			} else if item.Role == "parent" {
				if item.ParentStudentID == nil {
					continue
				}
				student, ok := studentByID[*item.ParentStudentID]
				if !ok {
					continue
				}
				if _, ok := studentNames[student.FullName]; ok &&
					(strings.TrimSpace(student.StudentGroup) == "" || strings.TrimSpace(student.StudentGroup) == groupName) {
					targetSet[item.ID] = struct{}{}
				}
			}
		}
		targetIDs := make([]uint, 0, len(targetSet))
		for id := range targetSet {
			targetIDs = append(targetIDs, id)
		}
		_ = h.createNotifications(
			c.Request.Context(),
			targetIDs,
			fmt.Sprintf("Новые экзаменационные оценки: %s", examName),
			fmt.Sprintf("Группа %s", groupName),
			map[string]any{"type": "exam_grades", "group": groupName, "exam": examName},
		)
	}
	out := make([]gin.H, 0, len(records))
	for _, row := range records {
		out = append(out, mapExamGrade(row))
	}
	c.JSON(http.StatusOK, out)
}

type examRow struct {
	StudentName string
	Grade       int
}

func parseExamRows(data []byte, filename string) ([]examRow, error) {
	ext := strings.ToLower(filepath.Ext(filename))
	switch ext {
	case ".csv":
		reader := csv.NewReader(bytes.NewReader(data))
		rows, err := reader.ReadAll()
		if err != nil {
			return nil, fmt.Errorf("invalid csv file")
		}
		return parseExamTable(rows)
	default:
		xlsx, err := excelize.OpenReader(bytes.NewReader(data))
		if err != nil {
			return nil, fmt.Errorf("invalid excel file")
		}
		defer xlsx.Close()
		sheet := xlsx.GetSheetName(0)
		if sheet == "" {
			return nil, fmt.Errorf("excel file has no sheets")
		}
		rows, err := xlsx.GetRows(sheet)
		if err != nil {
			return nil, fmt.Errorf("failed to parse excel file")
		}
		return parseExamTable(rows)
	}
}

func parseExamTable(rows [][]string) ([]examRow, error) {
	out := []examRow{}
	for _, row := range rows {
		if len(row) < 2 {
			continue
		}
		name := strings.TrimSpace(row[0])
		gradeRaw := strings.TrimSpace(row[1])
		if name == "" || gradeRaw == "" {
			continue
		}
		grade, err := strconv.Atoi(gradeRaw)
		if err != nil {
			return nil, fmt.Errorf("invalid grade for %s", name)
		}
		out = append(out, examRow{StudentName: name, Grade: grade})
	}
	return out, nil
}

func mapExamGrade(row persistence.DBExamGrade) gin.H {
	return gin.H{
		"id":           row.ID,
		"group_name":   row.GroupName,
		"exam_name":    row.ExamName,
		"student_name": row.StudentName,
		"grade":        row.Grade,
		"created_at":   row.CreatedAt.Format(time.RFC3339),
	}
}

func (h *Handler) mapTeacherAssignments(c *gin.Context, rows []persistence.DBTeacherGroupAssignment) ([]gin.H, error) {
	teacherIDs := map[uint]struct{}{}
	for _, row := range rows {
		teacherIDs[row.TeacherID] = struct{}{}
	}
	teachers := map[uint]string{}
	if len(teacherIDs) > 0 {
		var users []persistence.DBUser
		if err := h.db.WithContext(c.Request.Context()).Where("id IN ?", mapIDSet(teacherIDs)).Find(&users).Error; err != nil {
			return nil, err
		}
		for _, user := range users {
			teachers[user.ID] = user.FullName
		}
	}
	out := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		name := teachers[row.TeacherID]
		if name == "" {
			name = "Unknown"
		}
		out = append(out, gin.H{
			"id":           row.ID,
			"teacher_id":   row.TeacherID,
			"teacher_name": name,
			"group_name":   row.GroupName,
			"subject":      row.Subject,
			"created_at":   row.CreatedAt.Format(time.RFC3339),
		})
	}
	return out, nil
}

func (h *Handler) mapExamUploads(c *gin.Context, rows []persistence.DBExamUpload) ([]gin.H, error) {
	teacherIDs := map[uint]struct{}{}
	for _, row := range rows {
		if row.TeacherID > 0 {
			teacherIDs[row.TeacherID] = struct{}{}
		}
	}
	teachers := map[uint]string{}
	if len(teacherIDs) > 0 {
		var users []persistence.DBUser
		if err := h.db.WithContext(c.Request.Context()).Where("id IN ?", mapIDSet(teacherIDs)).Find(&users).Error; err != nil {
			return nil, err
		}
		for _, user := range users {
			teachers[user.ID] = user.FullName
		}
	}
	out := make([]gin.H, 0, len(rows))
	for _, row := range rows {
		out = append(out, gin.H{
			"id":           row.ID,
			"group_name":   row.GroupName,
			"exam_name":    row.ExamName,
			"filename":     row.Filename,
			"rows_count":   row.RowsCount,
			"uploaded_at":  row.UploadedAt.Format(time.RFC3339),
			"teacher_name": nullOrString(teachers[row.TeacherID]),
		})
	}
	return out, nil
}
