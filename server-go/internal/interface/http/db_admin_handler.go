package http

import (
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	"polyapp/server-go/internal/infrastructure/persistence"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
)

type dbTableMeta struct {
	Name        string   `json:"name"`
	PrimaryKeys []string `json:"primary_keys"`
	Columns     []string `json:"columns"`
}

type dbRowPayload struct {
	Table string                 `json:"table"`
	Row   map[string]any         `json:"row"`
	PK    map[string]any         `json:"pk"`
	Where map[string]any         `json:"where"`
	Rows  []map[string]any       `json:"rows"`
	PKs   []map[string]any       `json:"pks"`
	Meta  map[string]interface{} `json:"meta"`
}

type dbClearPayload struct {
	All    bool     `json:"all"`
	Tables []string `json:"tables"`
}

type dbDemoUsersPayload struct {
	Users []dbDemoUserPayload `json:"users"`
}

type dbDemoUserPayload struct {
	Role          string `json:"role"`
	FullName      string `json:"full_name"`
	Email         string `json:"email"`
	Password      string `json:"password"`
	StudentGroup  string `json:"student_group"`
	TeacherName   string `json:"teacher_name"`
	ChildFullName string `json:"child_full_name"`
	IsApproved    *bool  `json:"is_approved"`
}

const protectedAdminEmail = "admin@demo.local"

func (h *Handler) dbAdminPage(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermUsersManage) {
		return
	}
	c.Header("Content-Type", "text/html; charset=utf-8")
	c.String(http.StatusOK, dbAdminHTML)
}

func (h *Handler) dbListTables(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermUsersManage) {
		return
	}
	tables, err := h.dbPublicTables(c)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load tables"})
		return
	}
	out := make([]dbTableMeta, 0, len(tables))
	for _, table := range tables {
		columns, _ := h.dbTableColumns(c, table)
		primaryKeys, _ := h.dbTablePrimaryKeys(c, table)
		out = append(out, dbTableMeta{Name: table, PrimaryKeys: primaryKeys, Columns: columns})
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) dbListRows(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermUsersManage) {
		return
	}
	table := strings.TrimSpace(c.Query("table"))
	if table == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "table is required"})
		return
	}
	if !h.isAllowedTable(c, table) {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "table is not allowed"})
		return
	}
	limit := 100
	offset := 0
	if raw := strings.TrimSpace(c.Query("limit")); raw != "" {
		if value, err := strconv.Atoi(raw); err == nil && value > 0 && value <= 1000 {
			limit = value
		}
	}
	if raw := strings.TrimSpace(c.Query("offset")); raw != "" {
		if value, err := strconv.Atoi(raw); err == nil && value >= 0 {
			offset = value
		}
	}
	rows := make([]map[string]any, 0)
	if err := h.db.WithContext(c.Request.Context()).
		Table(table).
		Limit(limit).
		Offset(offset).
		Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load rows"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"table":  table,
		"limit":  limit,
		"offset": offset,
		"rows":   rows,
	})
}

func (h *Handler) dbCreateRow(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermUsersManage) {
		return
	}
	var payload dbRowPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	table := strings.TrimSpace(payload.Table)
	if table == "" || len(payload.Row) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "table and row are required"})
		return
	}
	if !h.isAllowedTable(c, table) {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "table is not allowed"})
		return
	}
	if err := h.db.WithContext(c.Request.Context()).Table(table).Create(payload.Row).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to create row"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) dbUpdateRow(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermUsersManage) {
		return
	}
	var payload dbRowPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	table := strings.TrimSpace(payload.Table)
	if table == "" || len(payload.Row) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "table and row are required"})
		return
	}
	if !h.isAllowedTable(c, table) {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "table is not allowed"})
		return
	}
	pk := payload.PK
	if len(pk) == 0 {
		pk = payload.Where
	}
	if len(pk) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "pk is required"})
		return
	}
	query := h.db.WithContext(c.Request.Context()).Table(table)
	for key, value := range pk {
		query = query.Where(fmt.Sprintf("%s = ?", quoteSQLIdent(key)), value)
	}
	res := query.Updates(payload.Row)
	if res.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update row"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok", "updated": res.RowsAffected})
}

func (h *Handler) dbDeleteRows(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermUsersManage) {
		return
	}
	var payload dbRowPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	table := strings.TrimSpace(payload.Table)
	if table == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "table is required"})
		return
	}
	if !h.isAllowedTable(c, table) {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "table is not allowed"})
		return
	}
	deleteOne := func(filters map[string]any) (int64, error) {
		if strings.EqualFold(table, "users") {
			protected, err := h.dbIsProtectedAdminUser(c, filters)
			if err != nil {
				return 0, err
			}
			if protected {
				return 0, errors.New("cannot delete protected admin account")
			}
		}
		query := h.db.WithContext(c.Request.Context()).Table(table)
		for key, value := range filters {
			query = query.Where(fmt.Sprintf("%s = ?", quoteSQLIdent(key)), value)
		}
		res := query.Delete(&map[string]any{})
		return res.RowsAffected, res.Error
	}

	var total int64
	if len(payload.PKs) > 0 {
		for _, filters := range payload.PKs {
			if len(filters) == 0 {
				continue
			}
			affected, err := deleteOne(filters)
			if err != nil {
				if strings.Contains(strings.ToLower(err.Error()), "protected admin") {
					c.JSON(http.StatusBadRequest, gin.H{"detail": "Cannot delete protected admin account"})
					return
				}
				c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete rows"})
				return
			}
			total += affected
		}
	} else {
		filters := payload.PK
		if len(filters) == 0 {
			filters = payload.Where
		}
		if len(filters) == 0 {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "pk is required"})
			return
		}
		affected, err := deleteOne(filters)
		if err != nil {
			if strings.Contains(strings.ToLower(err.Error()), "protected admin") {
				c.JSON(http.StatusBadRequest, gin.H{"detail": "Cannot delete protected admin account"})
				return
			}
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete rows"})
			return
		}
		total = affected
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok", "deleted": total})
}

func (h *Handler) dbClearTables(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermUsersManage) {
		return
	}
	var payload dbClearPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	allowed, err := h.dbPublicTables(c)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load tables"})
		return
	}
	allowSet := make(map[string]struct{}, len(allowed))
	for _, table := range allowed {
		allowSet[table] = struct{}{}
	}
	targets := make([]string, 0, len(payload.Tables))
	if payload.All {
		targets = append(targets, allowed...)
	} else {
		seen := map[string]struct{}{}
		for _, raw := range payload.Tables {
			name := strings.TrimSpace(raw)
			if name == "" {
				continue
			}
			if _, ok := allowSet[name]; !ok {
				continue
			}
			if _, ok := seen[name]; ok {
				continue
			}
			seen[name] = struct{}{}
			targets = append(targets, name)
		}
	}
	if len(targets) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "No tables selected"})
		return
	}

	nonUserTargets := make([]string, 0, len(targets))
	clearUsers := false
	for _, name := range targets {
		if strings.EqualFold(name, "users") {
			clearUsers = true
			continue
		}
		nonUserTargets = append(nonUserTargets, name)
	}
	if len(nonUserTargets) > 0 {
		quoted := make([]string, 0, len(nonUserTargets))
		for _, name := range nonUserTargets {
			quoted = append(quoted, quoteSQLIdent(name))
		}
		sql := "TRUNCATE TABLE " + strings.Join(quoted, ", ") + " RESTART IDENTITY CASCADE"
		if err := h.db.WithContext(c.Request.Context()).Exec(sql).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to clear selected tables"})
			return
		}
	}
	if clearUsers {
		if err := h.dbClearUsersExceptProtected(c); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to clear users table"})
			return
		}
		if err := h.dbEnsureProtectedAdminCredentials(c); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to keep protected admin account"})
			return
		}
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok", "tables": targets})
}

func (h *Handler) dbSeedDemoData(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermUsersManage) {
		return
	}
	if err := h.dbSeedDemo(c); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to seed demo data"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) dbResetDemoData(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermUsersManage) {
		return
	}
	if err := h.dbResetAndSeedDemo(c); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to reset demo data"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) dbListDemoUsers(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermUsersManage) {
		return
	}
	rows := make([]persistence.DBUser, 0)
	if err := h.db.WithContext(c.Request.Context()).
		Where("email ILIKE ?", "%@demo.local").
		Order("id ASC").
		Find(&rows).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load demo users"})
		return
	}
	c.JSON(http.StatusOK, rows)
}

func (h *Handler) dbUpsertDemoUsers(c *gin.Context) {
	if !h.requireAdminPermission(c, AdminPermUsersManage) {
		return
	}
	var payload dbDemoUsersPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	if len(payload.Users) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "users are required"})
		return
	}
	now := time.Now().UTC()
	for _, item := range payload.Users {
		email := strings.ToLower(strings.TrimSpace(item.Email))
		role := strings.TrimSpace(item.Role)
		fullName := strings.TrimSpace(item.FullName)
		if email == "" || role == "" || fullName == "" {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "email, role and full_name are required"})
			return
		}
		if !strings.HasSuffix(email, "@demo.local") {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Only @demo.local emails are allowed"})
			return
		}

		approved := true
		if item.IsApproved != nil {
			approved = *item.IsApproved
		}

		var passwordHash *string
		rawPassword := strings.TrimSpace(item.Password)
		if rawPassword != "" {
			hash, err := bcrypt.GenerateFromPassword([]byte(rawPassword), bcrypt.DefaultCost)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to hash password"})
				return
			}
			hashed := string(hash)
			passwordHash = &hashed
		}

		var existing persistence.DBUser
		err := h.db.WithContext(c.Request.Context()).Where("email = ?", email).First(&existing).Error
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to upsert demo users"})
			return
		}

		if errors.Is(err, gorm.ErrRecordNotFound) {
			if passwordHash == nil {
				hash, hashErr := bcrypt.GenerateFromPassword([]byte("Demo1234"), bcrypt.DefaultCost)
				if hashErr != nil {
					c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to hash password"})
					return
				}
				hashed := string(hash)
				passwordHash = &hashed
			}
			approvedAt := now
			if !approved {
				approvedAt = time.Time{}
			}
			create := persistence.DBUser{
				Role:          role,
				FullName:      fullName,
				Email:         email,
				PasswordHash:  *passwordHash,
				StudentGroup:  strings.TrimSpace(item.StudentGroup),
				TeacherName:   strings.TrimSpace(item.TeacherName),
				ChildFullName: strings.TrimSpace(item.ChildFullName),
				IsApproved:    approved,
				CreatedAt:     now,
				UpdatedAt:     now,
			}
			if approved {
				create.ApprovedAt = &approvedAt
			}
			if err := h.db.WithContext(c.Request.Context()).Create(&create).Error; err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to upsert demo users"})
				return
			}
			continue
		}

		updates := map[string]any{
			"role":            role,
			"full_name":       fullName,
			"student_group":   strings.TrimSpace(item.StudentGroup),
			"teacher_name":    strings.TrimSpace(item.TeacherName),
			"child_full_name": strings.TrimSpace(item.ChildFullName),
			"is_approved":     approved,
			"updated_at":      now,
		}
		if approved {
			updates["approved_at"] = now
		} else {
			updates["approved_at"] = nil
		}
		if passwordHash != nil {
			updates["password_hash"] = *passwordHash
		}
		if strings.EqualFold(email, protectedAdminEmail) {
			hash, hashErr := bcrypt.GenerateFromPassword([]byte("Demo1234"), bcrypt.DefaultCost)
			if hashErr != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to hash password"})
				return
			}
			updates["role"] = "admin"
			updates["is_approved"] = true
			updates["approved_at"] = now
			updates["password_hash"] = string(hash)
		}
		if err := h.db.WithContext(c.Request.Context()).
			Model(&persistence.DBUser{}).
			Where("id = ?", existing.ID).
			Updates(updates).Error; err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to upsert demo users"})
			return
		}
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) dbResetAndSeedDemo(c *gin.Context) error {
	tables, err := h.dbPublicTables(c)
	if err != nil {
		return err
	}
	nonUserTargets := make([]string, 0, len(tables))
	for _, table := range tables {
		if strings.EqualFold(table, "users") {
			continue
		}
		nonUserTargets = append(nonUserTargets, table)
	}
	if len(nonUserTargets) > 0 {
		quoted := make([]string, 0, len(nonUserTargets))
		for _, name := range nonUserTargets {
			quoted = append(quoted, quoteSQLIdent(name))
		}
		sql := "TRUNCATE TABLE " + strings.Join(quoted, ", ") + " RESTART IDENTITY CASCADE"
		if err := h.db.WithContext(c.Request.Context()).Exec(sql).Error; err != nil {
			return err
		}
	}
	if err := h.dbClearUsersExceptProtected(c); err != nil {
		return err
	}
	return h.dbSeedDemo(c)
}

func (h *Handler) dbClearUsersExceptProtected(c *gin.Context) error {
	if err := h.db.WithContext(c.Request.Context()).
		Where("lower(email) <> lower(?)", protectedAdminEmail).
		Delete(&persistence.DBUser{}).Error; err != nil {
		return err
	}
	return h.dbEnsureProtectedAdminCredentials(c)
}

func (h *Handler) dbEnsureProtectedAdminCredentials(c *gin.Context) error {
	hash, err := bcrypt.GenerateFromPassword([]byte("Demo1234"), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	return h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBUser{}).
		Where("lower(email) = lower(?)", protectedAdminEmail).
		Updates(map[string]any{
			"role":          "admin",
			"is_approved":   true,
			"approved_at":   now,
			"password_hash": string(hash),
			"updated_at":    now,
		}).Error
}

func (h *Handler) dbIsProtectedAdminUser(c *gin.Context, filters map[string]any) (bool, error) {
	query := h.db.WithContext(c.Request.Context()).Model(&persistence.DBUser{})
	for key, value := range filters {
		query = query.Where(fmt.Sprintf("%s = ?", quoteSQLIdent(key)), value)
	}
	var user persistence.DBUser
	err := query.First(&user).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return false, nil
		}
		return false, err
	}
	return strings.EqualFold(strings.TrimSpace(user.Email), protectedAdminEmail), nil
}

func (h *Handler) dbSeedDemo(c *gin.Context) error {
	hash, err := bcrypt.GenerateFromPassword([]byte("Demo1234"), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	type demoUser struct {
		Key           string
		Role          string
		FullName      string
		Email         string
		StudentGroup  string
		TeacherName   string
		ChildFullName string
		Permissions   string
	}
	users := []demoUser{
		{Key: "admin", Role: "admin", FullName: "Admin Demo", Email: "admin@demo.local", Permissions: `["all"]`},
		{Key: "student", Role: "student", FullName: "Student Demo", Email: "student@demo.local", StudentGroup: "P22-3E"},
		{Key: "student2", Role: "student", FullName: "Ivan Petrov", Email: "ivan@demo.local", StudentGroup: "P22-3E"},
		{Key: "student3", Role: "student", FullName: "Anna Sidorova", Email: "anna@demo.local", StudentGroup: "P22-3E"},
		{Key: "student4", Role: "student", FullName: "Alina Karim", Email: "alina@demo.local", StudentGroup: "P22-3E"},
		{Key: "student5", Role: "student", FullName: "Nikita Smirnov", Email: "nikita@demo.local", StudentGroup: "P22-3E"},
		{Key: "teacher", Role: "teacher", FullName: "Teacher Demo", Email: "teacher@demo.local", TeacherName: "Teacher Demo"},
		{Key: "teacher2", Role: "teacher", FullName: "Teacher Demo 2", Email: "teacher2@demo.local", TeacherName: "Teacher Demo 2"},
		{Key: "parent", Role: "parent", FullName: "Parent Demo", Email: "parent@demo.local", ChildFullName: "Student Demo"},
		{Key: "handler", Role: "request_handler", FullName: "Handler Demo", Email: "handler@demo.local"},
		{Key: "smm", Role: "smm", FullName: "SMM Demo", Email: "smm@demo.local"},
	}

	ids := map[string]uint{}
	for _, item := range users {
		var row persistence.DBUser
		err := h.db.WithContext(c.Request.Context()).Where("email = ?", item.Email).First(&row).Error
		if err == nil {
			updates := map[string]any{
				"role":                   item.Role,
				"full_name":              item.FullName,
				"student_group":          item.StudentGroup,
				"teacher_name":           item.TeacherName,
				"child_full_name":        item.ChildFullName,
				"is_approved":            true,
				"approved_at":            now,
				"admin_permissions_json": item.Permissions,
				"updated_at":             now,
			}
			if strings.EqualFold(item.Email, protectedAdminEmail) {
				updates["password_hash"] = string(hash)
			}
			if err := h.db.WithContext(c.Request.Context()).Model(&persistence.DBUser{}).Where("id = ?", row.ID).Updates(updates).Error; err != nil {
				return err
			}
			ids[item.Key] = row.ID
			continue
		}
		if !errors.Is(err, gorm.ErrRecordNotFound) {
			return err
		}
		create := persistence.DBUser{
			Role:                 item.Role,
			FullName:             item.FullName,
			Email:                item.Email,
			PasswordHash:         string(hash),
			StudentGroup:         item.StudentGroup,
			TeacherName:          item.TeacherName,
			ChildFullName:        item.ChildFullName,
			AdminPermissionsJSON: item.Permissions,
			IsApproved:           true,
			ApprovedAt:           &now,
			CreatedAt:            now,
			UpdatedAt:            now,
		}
		if err := h.db.WithContext(c.Request.Context()).Create(&create).Error; err != nil {
			return err
		}
		ids[item.Key] = create.ID
	}

	group := "P22-3E"
	if err := h.db.WithContext(c.Request.Context()).
		Where("name = ?", group).
		FirstOrCreate(&persistence.DBJournalGroup{Name: group}).Error; err != nil {
		return err
	}
	assignments := []persistence.DBTeacherGroupAssignment{
		{TeacherID: ids["teacher"], GroupName: group, Subject: "Math", CreatedAt: now},
		{TeacherID: ids["teacher2"], GroupName: group, Subject: "Programming", CreatedAt: now},
	}
	for _, assignment := range assignments {
		var row persistence.DBTeacherGroupAssignment
		if err := h.db.WithContext(c.Request.Context()).
			Where("teacher_id = ? AND group_name = ?", assignment.TeacherID, assignment.GroupName).
			First(&row).Error; err == nil {
			if err := h.db.WithContext(c.Request.Context()).
				Model(&persistence.DBTeacherGroupAssignment{}).
				Where("id = ?", row.ID).
				Updates(map[string]any{"subject": assignment.Subject}).Error; err != nil {
				return err
			}
			continue
		}
		if err := h.db.WithContext(c.Request.Context()).Create(&assignment).Error; err != nil {
			return err
		}
	}
	students := make([]string, 0, 8)
	var demoStudents []persistence.DBUser
	if err := h.db.WithContext(c.Request.Context()).
		Where("role = ? AND is_approved = ? AND student_group = ?", "student", true, group).
		Order("full_name asc").
		Find(&demoStudents).Error; err != nil {
		return err
	}
	for _, item := range demoStudents {
		name := strings.TrimSpace(item.FullName)
		if name != "" {
			students = append(students, name)
		}
	}
	scopedGroups := []string{
		scopedJournalGroupNameForUser(&entity.User{ID: ids["teacher"], Role: "teacher"}, group),
		scopedJournalGroupNameForUser(&entity.User{ID: ids["teacher2"], Role: "teacher"}, group),
	}
	for _, scopedGroup := range scopedGroups {
		for _, name := range students {
			row := persistence.DBJournalStudent{GroupName: scopedGroup, StudentName: name}
			if err := h.db.WithContext(c.Request.Context()).
				Where("group_name = ? AND student_name = ?", scopedGroup, name).
				FirstOrCreate(&row).Error; err != nil {
				return err
			}
		}
		dateValue := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
		dateRow := persistence.DBJournalDate{GroupName: scopedGroup, ClassDate: dateValue, LessonSlot: 1}
		if err := h.db.WithContext(c.Request.Context()).
			Where("group_name = ? AND class_date = ? AND lesson_slot = ?", scopedGroup, dateValue, 1).
			FirstOrCreate(&dateRow).Error; err != nil {
			return err
		}
	}
	return nil
}

func (h *Handler) dbPublicTables(c *gin.Context) ([]string, error) {
	rows := make([]string, 0)
	if err := h.db.WithContext(c.Request.Context()).Raw(`
		SELECT table_name
		FROM information_schema.tables
		WHERE table_schema = 'public'
		  AND table_type = 'BASE TABLE'
		ORDER BY table_name ASC
	`).Scan(&rows).Error; err != nil {
		return nil, err
	}
	out := make([]string, 0, len(rows))
	for _, table := range rows {
		name := strings.TrimSpace(table)
		if name == "" || strings.EqualFold(name, "schema_migrations") {
			continue
		}
		out = append(out, name)
	}
	return out, nil
}

func (h *Handler) dbTableColumns(c *gin.Context, table string) ([]string, error) {
	rows := make([]string, 0)
	err := h.db.WithContext(c.Request.Context()).Raw(`
		SELECT column_name
		FROM information_schema.columns
		WHERE table_schema = 'public' AND table_name = ?
		ORDER BY ordinal_position ASC
	`, table).Scan(&rows).Error
	if err != nil {
		return nil, err
	}
	return rows, nil
}

func (h *Handler) dbTablePrimaryKeys(c *gin.Context, table string) ([]string, error) {
	rows := make([]string, 0)
	err := h.db.WithContext(c.Request.Context()).Raw(`
		SELECT kcu.column_name
		FROM information_schema.table_constraints tc
		JOIN information_schema.key_column_usage kcu
		  ON tc.constraint_name = kcu.constraint_name
		 AND tc.table_schema = kcu.table_schema
		WHERE tc.constraint_type = 'PRIMARY KEY'
		  AND tc.table_schema = 'public'
		  AND tc.table_name = ?
		ORDER BY kcu.ordinal_position ASC
	`, table).Scan(&rows).Error
	if err != nil {
		return nil, err
	}
	return rows, nil
}

func (h *Handler) isAllowedTable(c *gin.Context, table string) bool {
	table = strings.TrimSpace(table)
	if table == "" {
		return false
	}
	tables, err := h.dbPublicTables(c)
	if err != nil {
		return false
	}
	for _, item := range tables {
		if item == table {
			return true
		}
	}
	return false
}

func quoteSQLIdent(value string) string {
	return `"` + strings.ReplaceAll(value, `"`, `""`) + `"`
}

const dbAdminHTML = `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>PolyApp DB Admin</title>
  <style>
    :root { --bg:#0f172a; --card:#111827; --muted:#94a3b8; --text:#e5e7eb; --ok:#10b981; --err:#ef4444; --line:#334155; --accent:#2563eb; }
    html,body{height:100%}
    body{margin:0;background:linear-gradient(135deg,#0b1220,#0f172a);color:var(--text);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;overflow:auto}
    .wrap{max-width:1320px;margin:20px auto;padding:0 14px 30px}
    .card{background:rgba(17,24,39,.9);border:1px solid var(--line);border-radius:14px;padding:14px;margin-bottom:12px}
    h1{font-size:20px;margin:0 0 10px}
    .muted{color:var(--muted)}
    .row{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
    button{background:var(--accent);color:#fff;border:none;border-radius:10px;padding:8px 12px;cursor:pointer}
    button.secondary{background:#334155}
    button.danger{background:#b91c1c}
    input,select,textarea{background:#0b1220;color:var(--text);border:1px solid var(--line);border-radius:10px;padding:8px}
    textarea{min-height:120px;width:100%}
    table{width:100%;border-collapse:collapse;margin-top:10px}
    th,td{border-bottom:1px solid var(--line);padding:6px;text-align:left;vertical-align:top}
    .small{font-size:12px}
    .ok{color:var(--ok)} .err{color:var(--err)}
    .tables{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:8px;max-height:220px;overflow:auto;padding-right:4px}
    .tbl{border:1px solid var(--line);border-radius:10px;padding:8px}
    #rowsWrap{max-height:52vh;overflow:auto;border:1px solid var(--line);border-radius:10px;padding:8px}
    .mono{font-family:Consolas,Monaco,monospace}
  </style>
</head>
<body>
<div class="wrap">
  <div class="card">
    <h1>DB Admin</h1>
    <div class="muted">Admin-only maintenance page (hidden from app UI).</div>
    <div id="status" class="small muted"></div>
  </div>
  <div class="card">
    <div class="row">
      <button onclick="loadTables()">Refresh tables</button>
      <label><input type="checkbox" id="selectAll" onchange="toggleAll(this.checked)"> Select all</label>
      <button class="danger" onclick="clearSelected()">Clear selected</button>
      <button class="danger" onclick="clearAll()">Clear all</button>
    </div>
    <div id="tables" class="tables"></div>
  </div>
  <div class="card">
    <div class="row">
      <strong>Demo data</strong>
      <button onclick="seedDemo()">Create/Update demo</button>
      <button class="secondary" onclick="loadDemoUsers()">Load demo users</button>
      <button class="danger" onclick="resetDemo()">Reset DB + demo</button>
      <button onclick="saveDemoUsers()">Save demo users</button>
    </div>
    <div class="small muted">Delete/clear operations always keep protected admin <span class="mono">admin@demo.local</span>.</div>
    <textarea id="demoUsersPayload" placeholder='{"users":[{"role":"teacher","full_name":"Teacher Demo","email":"teacher@demo.local","password":"Demo1234"}]}'></textarea>
  </div>
  <div class="card">
    <div class="row">
      <select id="tableSelect"></select>
      <button onclick="loadRows()">Load rows</button>
      <select id="limit">
        <option value="25">25</option>
        <option value="50">50</option>
        <option value="100" selected>100</option>
        <option value="200">200</option>
        <option value="500">500</option>
        <option value="1000">1000</option>
      </select>
      <input id="offset" type="number" min="0" value="0" />
    </div>
    <div id="rowsWrap">
      <table id="rowsTable"></table>
    </div>
  </div>
  <div class="card">
    <div class="row"><strong>CRUD JSON</strong></div>
    <div class="small muted">Create: {"table":"users","row":{"full_name":"Test","email":"a@b.c"}}; Update/Delete use "pk".</div>
    <textarea id="payload">{}</textarea>
    <div class="row" style="margin-top:8px">
      <button onclick="crud('POST')">Create</button>
      <button class="secondary" onclick="crud('PATCH')">Update</button>
      <button class="danger" onclick="crud('DELETE')">Delete</button>
    </div>
  </div>
</div>
<script>
let tableMeta = [];
const statusEl = document.getElementById('status');
function setStatus(text, ok=true){ statusEl.className = 'small ' + (ok?'ok':'err'); statusEl.textContent = text; }
async function api(url, opts={}){
  const res = await fetch(url, { ...opts, headers: { 'Content-Type':'application/json', ...(opts.headers||{}) } });
  const txt = await res.text();
  let data = {};
  try { data = txt ? JSON.parse(txt) : {}; } catch { data = {raw:txt}; }
  if(!res.ok) throw new Error(data.detail || data.error || txt || ('HTTP '+res.status));
  return data;
}
function toggleAll(value){
  document.querySelectorAll('input[name="tbl"]').forEach(x => x.checked = value);
}
async function loadTables(){
  try{
    tableMeta = await api('/db/tables');
    const tables = document.getElementById('tables');
    const select = document.getElementById('tableSelect');
    tables.innerHTML = '';
    select.innerHTML = '';
    for(const t of tableMeta){
      const div = document.createElement('div');
      div.className = 'tbl';
      div.innerHTML = '<label><input type="checkbox" name="tbl" value="'+t.name+'"> <strong>'+t.name+'</strong></label>'
        + '<div class="small muted">PK: '+(t.primary_keys||[]).join(', ')+'</div>'
        + '<div class="small muted">Cols: '+(t.columns||[]).join(', ')+'</div>';
      tables.appendChild(div);
      const opt = document.createElement('option');
      opt.value = t.name; opt.textContent = t.name;
      select.appendChild(opt);
    }
    setStatus('Tables loaded: '+tableMeta.length, true);
  }catch(e){ setStatus(e.message, false); }
}
async function loadRows(){
  const table = document.getElementById('tableSelect').value;
  if(!table){ setStatus('Select table', false); return; }
  const limit = document.getElementById('limit').value || '100';
  const offset = document.getElementById('offset').value || '0';
  try{
    const data = await api('/db/rows?table='+encodeURIComponent(table)+'&limit='+encodeURIComponent(limit)+'&offset='+encodeURIComponent(offset));
    const rows = data.rows || [];
    const tableEl = document.getElementById('rowsTable');
    tableEl.innerHTML = '';
    if(rows.length===0){ tableEl.innerHTML='<tr><td class="muted">No rows</td></tr>'; return; }
    const cols = Object.keys(rows[0]);
    const thead = document.createElement('thead');
    const trh = document.createElement('tr');
    cols.forEach(c => { const th = document.createElement('th'); th.textContent = c; trh.appendChild(th); });
    thead.appendChild(trh);
    tableEl.appendChild(thead);
    const tb = document.createElement('tbody');
    rows.forEach(r => {
      const tr = document.createElement('tr');
      cols.forEach(c => {
        const td = document.createElement('td');
        const v = r[c];
        td.textContent = typeof v === 'object' ? JSON.stringify(v) : String(v);
        tr.appendChild(td);
      });
      tb.appendChild(tr);
    });
    tableEl.appendChild(tb);
    setStatus('Rows loaded: '+rows.length, true);
  }catch(e){ setStatus(e.message, false); }
}
async function clearSelected(){
  const names = Array.from(document.querySelectorAll('input[name="tbl"]:checked')).map(x => x.value);
  if(names.length===0){ setStatus('Select at least one table', false); return; }
  if(!confirm('Clear selected tables?')) return;
  try{
    await api('/db/clear', { method:'POST', body: JSON.stringify({ all:false, tables:names }) });
    setStatus('Selected tables cleared', true);
  }catch(e){ setStatus(e.message, false); }
}
async function clearAll(){
  if(!confirm('Clear ALL tables?')) return;
  try{
    await api('/db/clear', { method:'POST', body: JSON.stringify({ all:true }) });
    setStatus('All tables cleared', true);
  }catch(e){ setStatus(e.message, false); }
}
async function seedDemo(){
  if(!confirm('Create or update demo data?')) return;
  try{
    await api('/db/demo/seed', { method:'POST' });
    setStatus('Demo data updated', true);
    await loadTables();
  }catch(e){ setStatus(e.message, false); }
}
async function resetDemo(){
  if(!confirm('Reset DB and seed demo data?')) return;
  try{
    await api('/db/demo/reset', { method:'POST' });
    setStatus('DB reset complete (protected admin preserved)', true);
    await loadTables();
  }catch(e){ setStatus(e.message, false); }
}
async function loadDemoUsers(){
  try{
    const data = await api('/db/demo/users');
    document.getElementById('demoUsersPayload').value = JSON.stringify({ users:data }, null, 2);
    setStatus('Demo users loaded: '+data.length, true);
  }catch(e){ setStatus(e.message, false); }
}
async function saveDemoUsers(){
  const raw = document.getElementById('demoUsersPayload').value || '';
  let payload = {};
  try { payload = JSON.parse(raw); } catch { setStatus('Invalid JSON in demo users payload', false); return; }
  try{
    await api('/db/demo/users', { method:'PUT', body: JSON.stringify(payload) });
    setStatus('Demo users saved', true);
  }catch(e){ setStatus(e.message, false); }
}
async function crud(method){
  try{
    const payload = JSON.parse(document.getElementById('payload').value || '{}');
    await api('/db/rows', { method, body: JSON.stringify(payload) });
    setStatus(method+' success', true);
  }catch(e){ setStatus(e.message, false); }
}
loadTables();
</script>
</body>
</html>`
