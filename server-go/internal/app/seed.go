package app

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/infrastructure/persistence"

	"gorm.io/gorm"
)

type passwordHasher interface {
	Hash(password string) (string, error)
}

type seedDepartment struct {
	Name   string
	Key    string
	Head   string
	Groups []seedGroup
}

type seedGroup struct {
	Name     string
	Curator  string
	Students []string
}

type namedUser struct {
	Name  string
	ID    uint
	Email string
}

func SeedDemo(ctx context.Context, db *gorm.DB, hasher passwordHasher) error {
	return SeedDemoWithMediaDir(ctx, db, hasher, "./data", false)
}

func ResetAndSeedDemo(ctx context.Context, db *gorm.DB, hasher passwordHasher, mediaDir string) error {
	return SeedDemoWithMediaDir(ctx, db, hasher, mediaDir, true)
}

func SeedDemoWithMediaDir(
	ctx context.Context,
	db *gorm.DB,
	hasher passwordHasher,
	mediaDir string,
	reset bool,
) error {
	if db == nil {
		return fmt.Errorf("db is nil")
	}
	if hasher == nil {
		return fmt.Errorf("hasher is nil")
	}

	now := time.Now().UTC()
	rng := rand.New(rand.NewSource(20260427))
	hash, err := hasher.Hash("Demo1234")
	if err != nil {
		return err
	}

	if reset {
		if err := clearMediaDirs(mediaDir); err != nil {
			return err
		}
		if err := truncateAllDemoTables(ctx, db); err != nil {
			return err
		}
	}

	departments := buildDepartments(rng)
	teacherNames := buildTeacherList(departments)
	studentsByGroup := map[string][]string{}
	for _, dept := range departments {
		for _, group := range dept.Groups {
			copied := append([]string(nil), group.Students...)
			studentsByGroup[group.Name] = copied
		}
	}

	userIDs := map[string]uint{}
	teacherByName := map[string]namedUser{}
	studentByName := map[string]namedUser{}
	studentByGroup := map[string][]namedUser{}

	systemUsers := []struct {
		Key      string
		Role     string
		FullName string
		Email    string
	}{
		{Key: "admin", Role: "admin", FullName: "Admin Demo", Email: "admin@demo.local"},
		{Key: "smm", Role: "smm", FullName: "SMM Demo", Email: "smm@demo.local"},
		{Key: "handler", Role: "request_handler", FullName: "Handler Demo", Email: "handler@demo.local"},
		{Key: "parent", Role: "parent", FullName: "Parent Demo", Email: "parent@demo.local"},
	}
	for _, item := range systemUsers {
		id, err := upsertUser(ctx, db, upsertUserInput{
			Role:         item.Role,
			FullName:     item.FullName,
			Email:        item.Email,
			PasswordHash: hash,
			ApprovedAt:   now,
		})
		if err != nil {
			return err
		}
		userIDs[item.Key] = id
	}

	sortedTeachers := append([]string(nil), teacherNames...)
	sort.Strings(sortedTeachers)
	usedEmails := map[string]struct{}{
		"admin@demo.local":   {},
		"smm@demo.local":     {},
		"handler@demo.local": {},
		"parent@demo.local":  {},
	}
	for _, fullName := range sortedTeachers {
		email := emailFromName(fullName, usedEmails, "teacher")
		id, err := upsertUser(ctx, db, upsertUserInput{
			Role:         "teacher",
			FullName:     fullName,
			Email:        email,
			TeacherName:  fullName,
			PasswordHash: hash,
			ApprovedAt:   now,
		})
		if err != nil {
			return err
		}
		teacherByName[fullName] = namedUser{Name: fullName, ID: id, Email: email}
	}

	groupNames := make([]string, 0, len(studentsByGroup))
	for name := range studentsByGroup {
		groupNames = append(groupNames, name)
	}
	sort.Strings(groupNames)

	for _, groupName := range groupNames {
		students := studentsByGroup[groupName]
		for _, fullName := range students {
			email := emailFromName(fullName, usedEmails, "student")
			id, err := upsertUser(ctx, db, upsertUserInput{
				Role:         "student",
				FullName:     fullName,
				Email:        email,
				StudentGroup: groupName,
				PasswordHash: hash,
				ApprovedAt:   now,
			})
			if err != nil {
				return err
			}
			entry := namedUser{Name: fullName, ID: id, Email: email}
			studentByName[fullName] = entry
			studentByGroup[groupName] = append(studentByGroup[groupName], entry)
		}
	}

	lotvin, ok := studentByName["Лотвин Артур"]
	if ok {
		if err := linkParentToStudent(ctx, db, userIDs["parent"], lotvin.ID, lotvin.Name); err != nil {
			return err
		}
	}

	for _, dept := range departments {
		head, ok := teacherByName[dept.Head]
		if !ok {
			return fmt.Errorf("missing department head: %s", dept.Head)
		}
		departmentID, err := upsertDepartment(ctx, db, dept.Name, dept.Key, head.ID, now)
		if err != nil {
			return err
		}

		for _, group := range dept.Groups {
			if err := upsertDepartmentGroup(ctx, db, departmentID, group.Name, now); err != nil {
				return err
			}
			curator, ok := teacherByName[group.Curator]
			if !ok {
				return fmt.Errorf("missing curator %s for group %s", group.Curator, group.Name)
			}
			if err := upsertCuratorAssignment(ctx, db, curator.ID, group.Name, now); err != nil {
				return err
			}
			if err := upsertJournalGroupAndStudents(ctx, db, group.Name, group.Students); err != nil {
				return err
			}
		}
	}

	groupTeachers := map[string][]uint{}
	scopedGroupNames := map[string][]string{}
	for _, dept := range departments {
		for _, group := range dept.Groups {
			pool := pickTeachersForGroup(rng, teacherByName, group.Curator, 4)
			subjects := []string{"Программирование", "Математика", "Базы данных", "Английский язык"}
			if strings.Contains(strings.ToLower(group.Name), "киис") {
				subjects = []string{"Компьютерные сети", "Системное администрирование", "Алгоритмы", "Физика"}
			}
			if strings.Contains(strings.ToLower(group.Name), "пм") {
				subjects = []string{"Мехатроника", "Электроника", "Программирование", "Алгоритмы"}
			}
			if strings.Contains(strings.ToLower(group.Name), "рет") {
				subjects = []string{"Встроенные системы", "Радиотехника", "Математика", "Программирование"}
			}
			if strings.Contains(strings.ToLower(group.Name), "иис") || strings.Contains(strings.ToLower(group.Name), "ис-") {
				subjects = []string{"Информационные системы", "Анализ данных", "Проектирование БД", "Английский язык"}
			}

			for i := 0; i < len(pool) && i < len(subjects); i++ {
				if err := upsertTeacherAssignment(ctx, db, pool[i], group.Name, subjects[i], now); err != nil {
					return err
				}
				groupTeachers[group.Name] = append(groupTeachers[group.Name], pool[i])
				scopedGroupNames[group.Name] = append(scopedGroupNames[group.Name], scopedGroupName(group.Name, pool[i]))
			}
		}
	}

	location := loadKZLocation()
	groupDates := map[string][]time.Time{}
	for _, groupName := range groupNames {
		dateCount := 20 + rng.Intn(11)
		dates := lastBusinessDays(dateCount, location)
		groupDates[groupName] = dates
		for _, classDate := range dates {
			if err := upsertJournalDate(ctx, db, groupName, classDate, 1); err != nil {
				return err
			}
		}
		for _, scoped := range scopedGroupNames[groupName] {
			if err := upsertJournalGroupAndStudents(ctx, db, scoped, studentsByGroup[groupName]); err != nil {
				return err
			}
			for _, classDate := range dates {
				if err := upsertJournalDate(ctx, db, scoped, classDate, 1); err != nil {
					return err
				}
			}
		}
	}

	for _, groupName := range groupNames {
		students := studentByGroup[groupName]
		teachers := groupTeachers[groupName]
		if len(teachers) == 0 {
			continue
		}
		dates := groupDates[groupName]
		for _, classDate := range dates {
			for _, student := range students {
				present := rng.Intn(100) >= 12
				teacherID := teachers[rng.Intn(len(teachers))]
				if err := upsertAttendance(ctx, db, groupName, classDate, 1, student.Name, present, teacherID); err != nil {
					return err
				}
				grade := randomGrade(rng, present)
				if err := upsertGrade(ctx, db, groupName, classDate, student.Name, grade, teacherID); err != nil {
					return err
				}
			}
		}
	}

	if err := seedGradingPresets(ctx, db, userIDs["admin"], groupNames, scopedGroupNames, now); err != nil {
		return err
	}
	if err := seedExamUploads(ctx, db, rng, groupNames, studentByGroup, groupTeachers, now); err != nil {
		return err
	}
	if err := seedRequests(ctx, db, rng, groupNames, studentByGroup, now); err != nil {
		return err
	}
	if err := seedMakeups(ctx, db, rng, groupNames, studentByGroup, groupTeachers, groupDates, now); err != nil {
		return err
	}
	if err := seedNews(ctx, db, rng, mediaDir, userIDs["smm"], studentByName, teacherByName, now); err != nil {
		return err
	}

	return nil
}

type upsertUserInput struct {
	Role            string
	FullName        string
	Email           string
	PasswordHash    string
	StudentGroup    string
	TeacherName     string
	ChildFullName   string
	ParentStudentID *uint
	ApprovedAt      time.Time
}

func upsertUser(ctx context.Context, db *gorm.DB, input upsertUserInput) (uint, error) {
	var row persistence.DBUser
	err := db.WithContext(ctx).Where("email = ?", input.Email).First(&row).Error
	now := time.Now().UTC()
	if err == nil {
		updates := map[string]any{
			"role":              input.Role,
			"full_name":         input.FullName,
			"password_hash":     input.PasswordHash,
			"student_group":     strings.TrimSpace(input.StudentGroup),
			"teacher_name":      strings.TrimSpace(input.TeacherName),
			"child_full_name":   strings.TrimSpace(input.ChildFullName),
			"parent_student_id": input.ParentStudentID,
			"is_approved":       true,
			"approved_at":       input.ApprovedAt,
			"updated_at":        now,
		}
		if err := db.WithContext(ctx).Model(&persistence.DBUser{}).Where("id = ?", row.ID).Updates(updates).Error; err != nil {
			return 0, err
		}
		return row.ID, nil
	}

	row = persistence.DBUser{
		Role:            input.Role,
		FullName:        input.FullName,
		Email:           input.Email,
		PasswordHash:    input.PasswordHash,
		StudentGroup:    strings.TrimSpace(input.StudentGroup),
		TeacherName:     strings.TrimSpace(input.TeacherName),
		ChildFullName:   strings.TrimSpace(input.ChildFullName),
		ParentStudentID: input.ParentStudentID,
		IsApproved:      true,
		ApprovedAt:      &input.ApprovedAt,
		CreatedAt:       now,
		UpdatedAt:       now,
	}
	if err := db.WithContext(ctx).Create(&row).Error; err != nil {
		return 0, err
	}
	return row.ID, nil
}

func linkParentToStudent(ctx context.Context, db *gorm.DB, parentID uint, studentID uint, childName string) error {
	updates := map[string]any{
		"parent_student_id": studentID,
		"child_full_name":   strings.TrimSpace(childName),
		"is_approved":       true,
		"approved_at":       time.Now().UTC(),
		"updated_at":        time.Now().UTC(),
	}
	return db.WithContext(ctx).
		Model(&persistence.DBUser{}).
		Where("id = ?", parentID).
		Updates(updates).Error
}

func upsertDepartment(ctx context.Context, db *gorm.DB, name, key string, headID uint, now time.Time) (uint, error) {
	var row persistence.DBDepartment
	err := db.WithContext(ctx).Where("name = ?", name).First(&row).Error
	if err == nil {
		updates := map[string]any{"key": key, "head_user_id": headID, "updated_at": now}
		if err := db.WithContext(ctx).Model(&persistence.DBDepartment{}).Where("id = ?", row.ID).Updates(updates).Error; err != nil {
			return 0, err
		}
		return row.ID, nil
	}
	row = persistence.DBDepartment{Name: name, Key: key, HeadUserID: &headID, CreatedAt: now, UpdatedAt: now}
	if err := db.WithContext(ctx).Create(&row).Error; err != nil {
		return 0, err
	}
	return row.ID, nil
}

func upsertDepartmentGroup(ctx context.Context, db *gorm.DB, departmentID uint, groupName string, now time.Time) error {
	row := persistence.DBDepartmentGroup{DepartmentID: departmentID, GroupName: groupName, CreatedAt: now}
	return db.WithContext(ctx).
		Where("group_name = ?", groupName).
		Assign(persistence.DBDepartmentGroup{DepartmentID: departmentID, GroupName: groupName, CreatedAt: now}).
		FirstOrCreate(&row).Error
}

func upsertCuratorAssignment(ctx context.Context, db *gorm.DB, curatorID uint, groupName string, now time.Time) error {
	row := persistence.DBCuratorGroupAssignment{CuratorID: curatorID, GroupName: groupName, CreatedAt: now}
	return db.WithContext(ctx).
		Where("group_name = ?", groupName).
		Assign(persistence.DBCuratorGroupAssignment{CuratorID: curatorID, GroupName: groupName, CreatedAt: now}).
		FirstOrCreate(&row).Error
}

func upsertJournalGroupAndStudents(ctx context.Context, db *gorm.DB, groupName string, students []string) error {
	group := persistence.DBJournalGroup{Name: groupName}
	if err := db.WithContext(ctx).Where("name = ?", groupName).FirstOrCreate(&group).Error; err != nil {
		return err
	}
	for _, name := range students {
		student := persistence.DBJournalStudent{GroupName: groupName, StudentName: name}
		if err := db.WithContext(ctx).
			Where("group_name = ? AND student_name = ?", groupName, name).
			FirstOrCreate(&student).Error; err != nil {
			return err
		}
	}
	return nil
}

func upsertTeacherAssignment(ctx context.Context, db *gorm.DB, teacherID uint, groupName, subject string, now time.Time) error {
	row := persistence.DBTeacherGroupAssignment{TeacherID: teacherID, GroupName: groupName, Subject: subject, CreatedAt: now}
	return db.WithContext(ctx).
		Where("teacher_id = ? AND group_name = ? AND subject = ?", teacherID, groupName, subject).
		FirstOrCreate(&row).Error
}

func upsertJournalDate(ctx context.Context, db *gorm.DB, groupName string, classDate time.Time, lessonSlot int) error {
	row := persistence.DBJournalDate{GroupName: groupName, ClassDate: classDate, LessonSlot: lessonSlot}
	return db.WithContext(ctx).
		Where("group_name = ? AND class_date = ? AND lesson_slot = ?", groupName, classDate, lessonSlot).
		FirstOrCreate(&row).Error
}

func upsertAttendance(ctx context.Context, db *gorm.DB, groupName string, classDate time.Time, lessonSlot int, studentName string, present bool, teacherID uint) error {
	row := persistence.DBAttendanceRecord{}
	assign := persistence.DBAttendanceRecord{
		GroupName:   groupName,
		ClassDate:   classDate,
		LessonSlot:  lessonSlot,
		StudentName: studentName,
		Present:     present,
		TeacherID:   teacherID,
	}
	return db.WithContext(ctx).
		Where("group_name = ? AND class_date = ? AND lesson_slot = ? AND student_name = ?", groupName, classDate, lessonSlot, studentName).
		Assign(assign).
		FirstOrCreate(&row).Error
}

func upsertGrade(ctx context.Context, db *gorm.DB, groupName string, classDate time.Time, studentName string, grade int, teacherID uint) error {
	row := persistence.DBGradeRecord{}
	assign := persistence.DBGradeRecord{
		GroupName:   groupName,
		ClassDate:   classDate,
		StudentName: studentName,
		Grade:       grade,
		TeacherID:   teacherID,
	}
	if err := db.WithContext(ctx).
		Where("group_name = ? AND class_date = ? AND student_name = ?", groupName, classDate, studentName).
		Assign(assign).
		FirstOrCreate(&row).Error; err != nil {
		return err
	}
	return upsertJournalGradeCell(ctx, db, groupName, classDate, studentName, grade, teacherID)
}

func upsertJournalGradeCell(ctx context.Context, db *gorm.DB, groupName string, classDate time.Time, studentName string, grade int, teacherID uint) error {
	numeric := float64(grade)
	now := time.Now().UTC()
	row := persistence.DBJournalDateCellV2{}
	assign := persistence.DBJournalDateCellV2{
		GroupName:    groupName,
		ClassDate:    classDate,
		LessonSlot:   1,
		StudentName:  studentName,
		RawValue:     strconv.Itoa(grade),
		NumericValue: &numeric,
		StatusCode:   "",
		UpdatedBy:    teacherID,
		UpdatedAt:    now,
	}
	return db.WithContext(ctx).
		Where("group_name = ? AND class_date = ? AND lesson_slot = ? AND student_name = ?", groupName, classDate, 1, studentName).
		Assign(assign).
		FirstOrCreate(&row).Error
}

func seedGradingPresets(ctx context.Context, db *gorm.DB, ownerID uint, groups []string, scopedGroups map[string][]string, now time.Time) error {
	if ownerID == 0 {
		return nil
	}
	presets := []struct {
		Name        string
		Description string
		Tags        []string
		Definition  map[string]any
	}{
		{
			Name:        "Стандартный журнал",
			Description: "Средний балл по датам, бонус и итог.",
			Tags:        []string{"demo", "standard"},
			Definition: map[string]any{
				"status_codes": []map[string]any{
					{"key": "ABSENT", "code": "Н", "counts_as_miss": true, "counts_in_stats": true},
				},
				"variables": []map[string]any{},
				"columns": []map[string]any{
					{"key": "bonus", "title": "Бонус", "kind": "manual", "type": "number", "editable": true},
					{"key": "final", "title": "Итог", "kind": "computed", "type": "number", "formula": "DATE_AVG + bonus", "format": "0.0"},
				},
			},
		},
		{
			Name:        "Экзаменационный контроль",
			Description: "Средний балл, экзамен и итоговая оценка.",
			Tags:        []string{"demo", "exam"},
			Definition: map[string]any{
				"status_codes": []map[string]any{
					{"key": "ABSENT", "code": "Н", "counts_as_miss": true, "counts_in_stats": true},
				},
				"variables": []map[string]any{},
				"columns": []map[string]any{
					{"key": "exam", "title": "Экзамен", "kind": "manual", "type": "number", "editable": true},
					{"key": "course_avg", "title": "Среднее", "kind": "computed", "type": "number", "formula": "DATE_AVG", "format": "0.0"},
					{"key": "total", "title": "Итог", "kind": "computed", "type": "number", "formula": "DATE_AVG * 0.6 + exam * 0.4", "format": "0.0"},
				},
			},
		},
		{
			Name:        "Посещаемость и активность",
			Description: "Учитывает средний балл и количество пропусков.",
			Tags:        []string{"demo", "attendance"},
			Definition: map[string]any{
				"status_codes": []map[string]any{
					{"key": "ABSENT", "code": "Н", "counts_as_miss": true, "counts_in_stats": true},
				},
				"variables": []map[string]any{},
				"columns": []map[string]any{
					{"key": "activity", "title": "Активность", "kind": "manual", "type": "number", "editable": true},
					{"key": "misses", "title": "Пропуски", "kind": "computed", "type": "number", "formula": "STUDENT_MISS_COUNT"},
					{"key": "rating", "title": "Рейтинг", "kind": "computed", "type": "number", "formula": "DATE_AVG + activity - STUDENT_MISS_COUNT * 2", "format": "0.0"},
				},
			},
		},
	}

	var firstPresetID uint
	var firstVersionID uint
	for _, item := range presets {
		tags, _ := json.Marshal(item.Tags)
		definition, _ := json.Marshal(item.Definition)
		preset := persistence.DBGradingPreset{}
		assignPreset := persistence.DBGradingPreset{
			OwnerID:     ownerID,
			Name:        item.Name,
			Description: item.Description,
			TagsJSON:    string(tags),
			Visibility:  "public",
			CreatedAt:   now,
			UpdatedAt:   now,
		}
		if err := db.WithContext(ctx).
			Where("name = ? AND owner_id = ?", item.Name, ownerID).
			Assign(assignPreset).
			FirstOrCreate(&preset).Error; err != nil {
			return err
		}
		version := persistence.DBGradingPresetVersion{}
		assignVersion := persistence.DBGradingPresetVersion{
			PresetID:       preset.ID,
			Version:        1,
			DefinitionJSON: string(definition),
			CreatedBy:      ownerID,
			CreatedAt:      now,
		}
		if err := db.WithContext(ctx).
			Where("preset_id = ? AND version = ?", preset.ID, 1).
			Assign(assignVersion).
			FirstOrCreate(&version).Error; err != nil {
			return err
		}
		if firstPresetID == 0 {
			firstPresetID = preset.ID
			firstVersionID = version.ID
		}
	}

	if firstPresetID == 0 || firstVersionID == 0 {
		return nil
	}
	targets := make([]string, 0, len(groups)*2)
	for _, group := range groups {
		targets = append(targets, group)
		targets = append(targets, scopedGroups[group]...)
	}
	for _, group := range targets {
		group = strings.TrimSpace(group)
		if group == "" {
			continue
		}
		binding := persistence.DBGroupPresetBinding{}
		assign := persistence.DBGroupPresetBinding{
			GroupName:       group,
			PresetID:        firstPresetID,
			PresetVersionID: firstVersionID,
			AutoUpdate:      true,
			AppliedBy:       ownerID,
			AppliedAt:       now,
			UpdatedAt:       now,
		}
		if err := db.WithContext(ctx).
			Where("group_name = ?", group).
			Assign(assign).
			FirstOrCreate(&binding).Error; err != nil {
			return err
		}
	}
	return nil
}

func seedExamUploads(
	ctx context.Context,
	db *gorm.DB,
	rng *rand.Rand,
	groups []string,
	studentByGroup map[string][]namedUser,
	groupTeachers map[string][]uint,
	now time.Time,
) error {
	examNames := []string{"Математика", "Физика", "Русский язык", "История", "Английский язык"}
	for i, group := range groups {
		teachers := groupTeachers[group]
		if len(teachers) == 0 {
			continue
		}
		examName := examNames[i%len(examNames)]
		upload := persistence.DBExamUpload{}
		assign := persistence.DBExamUpload{
			GroupName:  group,
			ExamName:   examName,
			Filename:   strings.ToLower(strings.ReplaceAll(group, " ", "_")) + "_exam.xlsx",
			RowsCount:  len(studentByGroup[group]),
			UploadedAt: now.Add(-time.Duration(rng.Intn(20)) * 24 * time.Hour),
			TeacherID:  teachers[0],
		}
		if err := db.WithContext(ctx).
			Where("group_name = ? AND exam_name = ?", group, examName).
			Assign(assign).
			FirstOrCreate(&upload).Error; err != nil {
			return err
		}
		for _, student := range studentByGroup[group] {
			grade := 60 + rng.Intn(41)
			row := persistence.DBExamGrade{}
			assignGrade := persistence.DBExamGrade{
				GroupName:   group,
				ExamName:    examName,
				StudentName: student.Name,
				Grade:       grade,
				TeacherID:   teachers[0],
				UploadID:    upload.ID,
				CreatedAt:   assign.UploadedAt,
			}
			if err := db.WithContext(ctx).
				Where("group_name = ? AND exam_name = ? AND student_name = ?", group, examName, student.Name).
				Assign(assignGrade).
				FirstOrCreate(&row).Error; err != nil {
				return err
			}
		}
	}
	return nil
}

func seedRequests(
	ctx context.Context,
	db *gorm.DB,
	rng *rand.Rand,
	groups []string,
	studentByGroup map[string][]namedUser,
	now time.Time,
) error {
	requestTypes := []string{
		"Справка на онай",
		"Справка на военкомат",
		"Справка по месту требования",
		"Приложение №2",
		"Приложение №4",
		"Приложение №6",
		"Приложение №29",
		"Приложение №31",
		"Справка в школу",
	}
	statuses := []string{"Отправлена", "На рассмотрении", "Отклонена", "В работе", "Готова"}
	allStudents := make([]namedUser, 0, 512)
	for _, group := range groups {
		allStudents = append(allStudents, studentByGroup[group]...)
	}
	if len(allStudents) == 0 {
		return nil
	}
	for i := 0; i < 14; i++ {
		student := allStudents[rng.Intn(len(allStudents))]
		typeName := requestTypes[rng.Intn(len(requestTypes))]
		status := statuses[rng.Intn(len(statuses))]
		createdAt := now.Add(-time.Duration(2+rng.Intn(65)) * 24 * time.Hour)
		details := fmt.Sprintf("Демо-заявка #%02d: прошу подготовить документ в учебный отдел.", i+1)
		ticket := persistence.DBRequestTicket{}
		assign := persistence.DBRequestTicket{
			StudentID:   student.ID,
			RequestType: typeName,
			Status:      status,
			Details:     details,
			Comment:     requestCommentByStatus(status),
			CreatedAt:   createdAt,
			UpdatedAt:   ptrTime(createdAt.Add(time.Duration(rng.Intn(5)) * 24 * time.Hour)),
		}
		if err := db.WithContext(ctx).
			Where("student_id = ? AND request_type = ? AND details = ?", student.ID, typeName, details).
			Assign(assign).
			FirstOrCreate(&ticket).Error; err != nil {
			return err
		}
	}
	return nil
}

func requestCommentByStatus(status string) string {
	switch status {
	case "Отправлена":
		return "Принято системой"
	case "На рассмотрении":
		return "Проверка данных в процессе"
	case "Отклонена":
		return "Не хватает подтверждающих данных"
	case "В работе":
		return "Документ готовится"
	case "Готова":
		return "Можно забрать в учебной части"
	default:
		return ""
	}
}

func seedMakeups(
	ctx context.Context,
	db *gorm.DB,
	rng *rand.Rand,
	groups []string,
	studentByGroup map[string][]namedUser,
	groupTeachers map[string][]uint,
	groupDates map[string][]time.Time,
	now time.Time,
) error {
	statuses := []string{
		"awaiting_proof",
		"proof_submitted",
		"task_assigned",
		"submission_sent",
		"graded",
		"rejected",
	}
	for i := 0; i < 22; i++ {
		group := groups[rng.Intn(len(groups))]
		students := studentByGroup[group]
		teachers := groupTeachers[group]
		dates := groupDates[group]
		if len(students) == 0 || len(teachers) == 0 || len(dates) == 0 {
			continue
		}
		student := students[rng.Intn(len(students))]
		teacherID := teachers[rng.Intn(len(teachers))]
		classDate := dates[rng.Intn(len(dates))]
		status := statuses[i%len(statuses)]
		caseRow := persistence.DBMakeupCase{}
		createdAt := classDate.Add(10 * time.Hour)
		if createdAt.After(now) {
			createdAt = now.Add(-24 * time.Hour)
		}
		teacherNote := "Отработка назначена по пропущенной паре"
		assign := persistence.DBMakeupCase{
			GroupName:   group,
			TeacherID:   teacherID,
			StudentID:   student.ID,
			ClassDate:   classDate,
			Status:      status,
			TeacherNote: teacherNote,
			CreatedAt:   createdAt,
			UpdatedAt:   createdAt,
		}
		noteAt := createdAt
		assign.TeacherNoteAt = &noteAt
		proofAt := createdAt.Add(12 * time.Hour)
		submittedAt := proofAt.Add(24 * time.Hour)
		gradedAt := submittedAt.Add(24 * time.Hour)
		switch status {
		case "proof_submitted":
			assign.MedicalProofURL = "/media/makeup/demo_proof.pdf"
			assign.MedicalProofComment = "Справка от врача"
			assign.ProofSubmittedAt = &proofAt
		case "task_assigned":
			assign.MedicalProofURL = "/media/makeup/demo_proof.pdf"
			assign.MedicalProofComment = "Справка от врача"
			assign.ProofSubmittedAt = &proofAt
			assign.TeacherTask = "Подготовить конспект и решить 8 задач"
			assign.TeacherTaskAt = &proofAt
		case "submission_sent":
			assign.MedicalProofURL = "/media/makeup/demo_proof.pdf"
			assign.MedicalProofComment = "Справка от врача"
			assign.ProofSubmittedAt = &proofAt
			assign.TeacherTask = "Подготовить конспект и решить 8 задач"
			assign.TeacherTaskAt = &proofAt
			assign.StudentSubmission = "Решения отправлены в полном объеме"
			assign.StudentSubmissionURL = "/media/makeup/demo_submission.pdf"
			assign.SubmissionSentAt = &submittedAt
		case "graded":
			assign.MedicalProofURL = "/media/makeup/demo_proof.pdf"
			assign.MedicalProofComment = "Справка от врача"
			assign.ProofSubmittedAt = &proofAt
			assign.TeacherTask = "Подготовить конспект и решить 8 задач"
			assign.TeacherTaskAt = &proofAt
			assign.StudentSubmission = "Решения отправлены"
			assign.StudentSubmissionURL = "/media/makeup/demo_submission.pdf"
			assign.SubmissionSentAt = &submittedAt
			assign.Grade = fmt.Sprintf("%d", 72+rng.Intn(24))
			assign.GradeComment = "Работа принята"
			assign.GradeSetAt = &gradedAt
			assign.ClosedAt = &gradedAt
		case "rejected":
			assign.MedicalProofURL = "/media/makeup/demo_proof.pdf"
			assign.MedicalProofComment = "Справка требует уточнения"
			assign.ProofSubmittedAt = &proofAt
			assign.GradeComment = "Отработка отклонена, требуется новая справка"
			assign.ClosedAt = &proofAt
		}

		res := db.WithContext(ctx).
			Where("group_name = ? AND teacher_id = ? AND student_id = ? AND class_date = ?", group, teacherID, student.ID, classDate).
			Assign(assign).
			FirstOrCreate(&caseRow)
		if res.Error != nil {
			return res.Error
		}
		if caseRow.ID == 0 {
			if err := db.WithContext(ctx).
				Where("group_name = ? AND teacher_id = ? AND student_id = ? AND class_date = ?", group, teacherID, student.ID, classDate).
				First(&caseRow).Error; err != nil {
				return err
			}
		}
		if res.RowsAffected > 0 {
			if err := upsertMakeupMessage(ctx, db, caseRow.ID, teacherID, "Проверьте задания по отработке", createdAt.Add(30*time.Minute)); err != nil {
				return err
			}
			if status == "submission_sent" || status == "graded" {
				if err := upsertMakeupMessage(ctx, db, caseRow.ID, student.ID, "Отправил решение, прошу проверить", submittedAt); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func upsertMakeupMessage(ctx context.Context, db *gorm.DB, caseID, senderID uint, body string, createdAt time.Time) error {
	row := persistence.DBMakeupMessage{}
	assign := persistence.DBMakeupMessage{
		MakeupCaseID: caseID,
		SenderID:     senderID,
		Body:         body,
		CreatedAt:    createdAt,
	}
	return db.WithContext(ctx).
		Where("makeup_case_id = ? AND sender_id = ? AND body = ?", caseID, senderID, body).
		Assign(assign).
		FirstOrCreate(&row).Error
}

func seedNews(
	ctx context.Context,
	db *gorm.DB,
	rng *rand.Rand,
	mediaDir string,
	authorID uint,
	students map[string]namedUser,
	teachers map[string]namedUser,
	now time.Time,
) error {
	_ = mediaDir
	if authorID == 0 {
		return nil
	}
	allUsers := make([]uint, 0, len(students)+len(teachers))
	for _, s := range students {
		allUsers = append(allUsers, s.ID)
	}
	for _, t := range teachers {
		allUsers = append(allUsers, t.ID)
	}
	categories := []string{"news", "study", "announcements", "events"}
	topicsByCategory := map[string][]string{
		"news": {
			"Лента новостей колледжа",
			"Открытая встреча с IT-компанией",
			"Новые партнёрские программы",
			"Итоги учебной недели",
			"Интервью с выпускниками",
		},
		"study": {
			"Подготовка к экзаменам по математике",
			"Практикум по физике для 2 курса",
			"Консультации по русскому языку",
			"Разбор задач по истории",
			"Интенсив по английскому языку",
		},
		"announcements": {
			"Обновление расписания консультаций",
			"Сроки сдачи ведомостей",
			"Работа библиотеки в выходные",
			"Доступ к компьютерным классам",
			"Регистрация на элективы",
		},
		"events": {
			"Студенческий хакатон",
			"Встреча с выпускниками",
			"День открытых дверей",
			"Турнир по киберспорту",
			"Олимпиада по программированию",
		},
	}
	imageURLs := []string{
		"https://picsum.photos/seed/polyapp-news-1/1200/630",
		"https://picsum.photos/seed/polyapp-news-2/1200/630",
		"https://picsum.photos/seed/polyapp-news-3/1200/630",
		"https://picsum.photos/seed/polyapp-news-4/1200/630",
		"https://picsum.photos/seed/polyapp-news-5/1200/630",
		"https://picsum.photos/seed/polyapp-news-6/1200/630",
		"https://picsum.photos/seed/polyapp-news-7/1200/630",
		"https://picsum.photos/seed/polyapp-news-8/1200/630",
		"https://picsum.photos/seed/polyapp-news-9/1200/630",
		"https://picsum.photos/seed/polyapp-news-10/1200/630",
	}
	for i := 1; i <= 50; i++ {
		category := categories[(i-1)%len(categories)]
		topicPool := topicsByCategory[category]
		title := fmt.Sprintf("%02d. %s", i, topicPool[(i-1)%len(topicPool)])
		body := fmt.Sprintf(
			"%s. Подробности и время проведения опубликованы в разделе расписания и объявлений.",
			topicPool[(i-1)%len(topicPool)],
		)
		createdAt := now.Add(-time.Duration(1+rng.Intn(120)) * 24 * time.Hour)
		post := persistence.DBNewsPost{}
		assign := persistence.DBNewsPost{
			Title:      title,
			Body:       body,
			AuthorID:   authorID,
			Category:   category,
			Pinned:     i <= 3,
			ShareCount: 0,
			CreatedAt:  createdAt,
			UpdatedAt:  createdAt,
		}
		if err := db.WithContext(ctx).
			Where("title = ?", title).
			Assign(assign).
			FirstOrCreate(&post).Error; err != nil {
			return err
		}

		if i <= 46 {
			storedName := imageURLs[(i-1)%len(imageURLs)]
			media := persistence.DBNewsMedia{}
			if err := db.WithContext(ctx).
				Where("post_id = ? AND stored_name = ?", post.ID, storedName).
				Assign(persistence.DBNewsMedia{
					PostID:       post.ID,
					OriginalName: fmt.Sprintf("news_%03d.jpg", i),
					StoredName:   storedName,
					MediaType:    "image",
					MimeType:     "image/jpeg",
					Size:         0,
					CreatedAt:    createdAt,
				}).
				FirstOrCreate(&media).Error; err != nil {
				return err
			}
		}

		maxLikes := 2 + rng.Intn(7)
		if maxLikes > len(allUsers) {
			maxLikes = len(allUsers)
		}
		likedUsers := shuffledCopy(rng, allUsers)
		for k := 0; k < maxLikes; k++ {
			like := persistence.DBNewsLike{}
			if err := db.WithContext(ctx).
				Where("post_id = ? AND user_id = ?", post.ID, likedUsers[k]).
				Assign(persistence.DBNewsLike{PostID: post.ID, UserID: likedUsers[k], Reaction: "like", CreatedAt: createdAt.Add(time.Duration(k) * time.Hour)}).
				FirstOrCreate(&like).Error; err != nil {
				return err
			}
		}

		maxComments := 1 + rng.Intn(4)
		for c := 0; c < maxComments; c++ {
			uid := allUsers[rng.Intn(len(allUsers))]
			text := fmt.Sprintf("Отличная новость, спасибо! (%d)", c+1)
			comment := persistence.DBNewsComment{}
			commentAt := createdAt.Add(time.Duration(2+c) * time.Hour)
			if err := db.WithContext(ctx).
				Where("post_id = ? AND user_id = ? AND text = ?", post.ID, uid, text).
				Assign(persistence.DBNewsComment{PostID: post.ID, UserID: uid, Text: text, CreatedAt: commentAt, UpdatedAt: commentAt}).
				FirstOrCreate(&comment).Error; err != nil {
				return err
			}
		}

		maxShares := rng.Intn(5)
		sharedUsers := shuffledCopy(rng, allUsers)
		shareCount := 0
		for s := 0; s < maxShares && s < len(sharedUsers); s++ {
			share := persistence.DBNewsShare{}
			if err := db.WithContext(ctx).
				Where("post_id = ? AND user_id = ?", post.ID, sharedUsers[s]).
				Assign(persistence.DBNewsShare{PostID: post.ID, UserID: sharedUsers[s], CreatedAt: createdAt.Add(time.Duration(3+s) * time.Hour)}).
				FirstOrCreate(&share).Error; err != nil {
				return err
			}
			shareCount++
		}
		if err := db.WithContext(ctx).Model(&persistence.DBNewsPost{}).Where("id = ?", post.ID).Update("share_count", shareCount).Error; err != nil {
			return err
		}
	}
	return nil
}

func ensureDemoSVG(mediaDir, storedName, title string, idx int) error {
	dir := filepath.Join(mediaDir, "news")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	target := filepath.Join(dir, storedName)
	if _, err := os.Stat(target); err == nil {
		return nil
	}
	palette := []string{"#0ea5e9", "#14b8a6", "#f97316", "#84cc16", "#f43f5e", "#6366f1"}
	color := palette[idx%len(palette)]
	svg := fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630"><rect width="1200" height="630" fill="%s"/><rect x="36" y="36" width="1128" height="558" rx="28" fill="white" fill-opacity="0.15"/><text x="60" y="210" font-size="44" fill="white" font-family="Arial">PolyApp News</text><text x="60" y="300" font-size="38" fill="white" font-family="Arial">%s</text></svg>`, color, escapeXML(title))
	return os.WriteFile(target, []byte(svg), 0o644)
}

func emailFromName(fullName string, used map[string]struct{}, prefix string) string {
	base := nameSlug(fullName)
	if base == "" {
		base = prefix
	}
	candidate := base
	suffix := 2
	for {
		email := candidate + "@demo.local"
		if _, exists := used[email]; !exists {
			used[email] = struct{}{}
			return email
		}
		candidate = fmt.Sprintf("%s%d", base, suffix)
		suffix++
	}
}

func nameSlug(fullName string) string {
	trimmed := strings.TrimSpace(fullName)
	if trimmed == "" {
		return ""
	}
	parts := strings.Fields(trimmed)
	source := parts[0]
	if len(parts) > 0 {
		source = parts[0]
	}
	var builder strings.Builder
	for _, r := range strings.ToLower(source) {
		builder.WriteString(translitChar(r))
	}
	out := builder.String()
	out = regexp.MustCompile(`[^a-z0-9]+`).ReplaceAllString(out, "")
	return strings.TrimSpace(out)
}

func translitChar(r rune) string {
	m := map[rune]string{
		'а': "a", 'ә': "a", 'б': "b", 'в': "v", 'г': "g", 'ғ': "g", 'д': "d", 'е': "e", 'ё': "e",
		'ж': "zh", 'з': "z", 'и': "i", 'й': "y", 'к': "k", 'қ': "k", 'л': "l", 'м': "m", 'н': "n",
		'ң': "n", 'о': "o", 'ө': "o", 'п': "p", 'р': "r", 'с': "s", 'т': "t", 'у': "u", 'ұ': "u",
		'ү': "u", 'ф': "f", 'х': "h", 'һ': "h", 'ц': "ts", 'ч': "ch", 'ш': "sh", 'щ': "sh",
		'ы': "y", 'і': "i", 'э': "e", 'ю': "yu", 'я': "ya", 'ъ': "", 'ь': "",
	}
	if v, ok := m[r]; ok {
		return v
	}
	if r >= 'a' && r <= 'z' {
		return string(r)
	}
	if r >= '0' && r <= '9' {
		return string(r)
	}
	return ""
}

func escapeXML(input string) string {
	replacer := strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
		`"`, "&quot;",
		"'", "&apos;",
	)
	return replacer.Replace(input)
}

func shuffledCopy(rng *rand.Rand, src []uint) []uint {
	out := append([]uint(nil), src...)
	rng.Shuffle(len(out), func(i, j int) {
		out[i], out[j] = out[j], out[i]
	})
	return out
}

func truncateAllDemoTables(ctx context.Context, db *gorm.DB) error {
	if db == nil {
		return nil
	}
	tables := make([]string, 0, len(persistence.ModelSet()))
	seen := map[string]struct{}{}
	for _, model := range persistence.ModelSet() {
		stmt := &gorm.Statement{DB: db}
		if err := stmt.Parse(model); err != nil {
			return err
		}
		table := stmt.Schema.Table
		if table == "" {
			continue
		}
		if _, ok := seen[table]; ok {
			continue
		}
		seen[table] = struct{}{}
		tables = append(tables, table)
	}
	if len(tables) == 0 {
		return nil
	}
	sort.Strings(tables)
	quoted := make([]string, 0, len(tables))
	for _, table := range tables {
		quoted = append(quoted, `"`+strings.ReplaceAll(table, `"`, `""`)+`"`)
	}
	query := "TRUNCATE TABLE " + strings.Join(quoted, ", ") + " RESTART IDENTITY CASCADE"
	return db.WithContext(ctx).Exec(query).Error
}

func clearMediaDirs(mediaDir string) error {
	if strings.TrimSpace(mediaDir) == "" {
		mediaDir = "./data"
	}
	targets := []string{"news", "schedule", "makeup"}
	for _, name := range targets {
		dir := filepath.Join(mediaDir, name)
		if err := os.RemoveAll(dir); err != nil {
			return err
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	return nil
}

func loadKZLocation() *time.Location {
	candidates := []string{"Asia/Qyzylorda", "Asia/Almaty"}
	for _, zone := range candidates {
		loc, err := time.LoadLocation(zone)
		if err == nil {
			return loc
		}
	}
	return time.UTC
}

func lastBusinessDays(count int, loc *time.Location) []time.Time {
	if count <= 0 {
		return []time.Time{}
	}
	cursor := time.Now().In(loc)
	out := make([]time.Time, 0, count)
	for len(out) < count {
		wd := cursor.Weekday()
		if wd >= time.Monday && wd <= time.Friday {
			dateOnly := time.Date(cursor.Year(), cursor.Month(), cursor.Day(), 0, 0, 0, 0, time.UTC)
			out = append(out, dateOnly)
		}
		cursor = cursor.AddDate(0, 0, -1)
	}
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out
}

func randomGrade(rng *rand.Rand, present bool) int {
	if !present {
		if rng.Intn(100) < 70 {
			return 50 + rng.Intn(18)
		}
		return 68 + rng.Intn(17)
	}
	roll := rng.Intn(100)
	switch {
	case roll < 8:
		return 55 + rng.Intn(10)
	case roll < 28:
		return 65 + rng.Intn(11)
	case roll < 62:
		return 76 + rng.Intn(10)
	case roll < 90:
		return 86 + rng.Intn(9)
	default:
		return 95 + rng.Intn(6)
	}
}

func buildTeacherList(departments []seedDepartment) []string {
	set := map[string]struct{}{}
	for _, dept := range departments {
		set[dept.Head] = struct{}{}
		for _, group := range dept.Groups {
			set[group.Curator] = struct{}{}
		}
	}
	extra := []string{
		"Айтмагамбетов Нуржан Рашидович",
		"Бегалиева Алина Руслановна",
		"Данияров Тимур Маратович",
		"Естай Еркебулан Серикович",
		"Жаксылыкова Гульмира Бауыржановна",
		"Имангалиев Руслан Кайратович",
		"Касымбекова Зарина Алмасовна",
		"Мусин Абзал Нурланович",
		"Нуртаев Диас Ермекович",
		"Оспанова Акерке Сериковна",
		"Пак Сергей Юрьевич",
		"Рахимжанова Айсана Маратовна",
		"Сарсенов Ербол Канатович",
		"Толеугалиев Арман Саматович",
		"Уразова Айым Шынгысовна",
		"Фролов Николай Петрович",
		"Худайбергенов Жандос Бекетович",
		"Цой Александр Евгеньевич",
		"Чижова Марина Валерьевна",
		"Шарипов Алишер Талгатович",
		"Юсупова Мадина Рустемовна",
		"Яковлев Илья Андреевич",
	}
	for _, item := range extra {
		set[item] = struct{}{}
	}
	out := make([]string, 0, len(set))
	for name := range set {
		out = append(out, name)
	}
	return out
}

func buildDepartments(rng *rand.Rand) []seedDepartment {
	used := map[string]struct{}{}

	mandatoryGroupStudents := []string{
		"Гильт Артур",
		"Едиге Назар",
		"Идилов Шахмурат",
		"Илимов Наиль",
		"Исмаил Илхам",
		"Касенев Амиржан",
		"Келбатыр Арнай",
		"Куанышпай Арсен",
		"Кыдырманов Бекжан",
		"Лотвин Артур",
		"Насырова Карина",
		"Панна Борис",
		"Самойлов Кирилл",
		"Сеитов Сухраб",
		"Темирбергенов Ислам",
		"Токаев Радик",
		"Хасанов Дурсун",
		"Чемакин Станислав",
		"Чернова Анджели",
		"Шаврель Андрей",
		"Шафиев Тимур",
		"Ширин Артём",
		"Ыргынбаев Елмурат",
		"Климкой Николай",
		"Негматов Аъзам",
	}
	for _, name := range mandatoryGroupStudents {
		used[name] = struct{}{}
	}

	return []seedDepartment{
		{
			Name: "Программное обеспечение",
			Key:  "П",
			Head: "Саурбек Улжан Болатханқызы",
			Groups: []seedGroup{
				{
					Name:     "П22-4Д",
					Curator:  "Сонурова Мира Мухтаровна",
					Students: mandatoryGroupStudents,
				},
				{
					Name:     "П22-4А",
					Curator:  "Амангельдина Диляра Руслановна",
					Students: generateStudents(rng, used, 23),
				},
			},
		},
		{
			Name: "Программное обеспечение и системы информационной безопасности",
			Key:  "ПСИБ",
			Head: "Тажибаев Нурбек Канатович",
			Groups: []seedGroup{
				{Name: "ПСИБ-23-1", Curator: "Абдрахманова Айгерим Маратовна", Students: generateStudents(rng, used, 20)},
				{Name: "ПСИБ-23-2", Curator: "Бейсенов Еркебулан Сагындыкулы", Students: generateStudents(rng, used, 19)},
			},
		},
		{
			Name: "Компьютерная инженерия и информационные сети",
			Key:  "КИИС",
			Head: "Мадиев Рустам Талгатович",
			Groups: []seedGroup{
				{Name: "КИИС-23-1", Curator: "Ганиева Ляззат Еркиновна", Students: generateStudents(rng, used, 18)},
				{Name: "КИИС-23-2", Curator: "Дюсенбеков Аскар Ермекович", Students: generateStudents(rng, used, 19)},
			},
		},
		{
			Name: "Программное обеспечение и мехатроника",
			Key:  "ПМ",
			Head: "Еспаев Даурен Бахытович",
			Groups: []seedGroup{
				{Name: "ПМ-23-1", Curator: "Жанузакова Айша Куанышевна", Students: generateStudents(rng, used, 18)},
				{Name: "ПМ-23-2", Curator: "Зарубина Наталья Сергеевна", Students: generateStudents(rng, used, 17)},
			},
		},
		{
			Name: "Программное обеспечение и RET",
			Key:  "ПРЕТ",
			Head: "Искаков Ержан Мухтарович",
			Groups: []seedGroup{
				{Name: "ПРЕТ-23-1", Curator: "Кенжеханова Гаухар Амангельдыкызы", Students: generateStudents(rng, used, 18)},
				{Name: "ПРЕТ-23-2", Curator: "Ли Виталий Геннадьевич", Students: generateStudents(rng, used, 18)},
			},
		},
		{
			Name: "Информатика и информационные сети",
			Key:  "ИИС",
			Head: "Нургалиев Айдос Кайратович",
			Groups: []seedGroup{
				{Name: "ИИС-23-1", Curator: "Омарова Арай Бекболатовна", Students: generateStudents(rng, used, 20)},
				{Name: "ИИС-23-2", Curator: "Пахомов Кирилл Владиславович", Students: generateStudents(rng, used, 20)},
			},
		},
		{
			Name: "Информационные системы",
			Key:  "ИС",
			Head: "Рыскулов Самат Турсынбекович",
			Groups: []seedGroup{
				{Name: "ИС-23-1", Curator: "Сулейменова Айдана Мараткызы", Students: generateStudents(rng, used, 21)},
				{Name: "ИС-23-2", Curator: "Ткаченко Антон Андреевич", Students: generateStudents(rng, used, 20)},
			},
		},
	}
}

func generateStudents(rng *rand.Rand, used map[string]struct{}, count int) []string {
	lastNames := []string{
		"Абдрахимов", "Алиев", "Аманжолов", "Аскаров", "Ахметов", "Байкенов", "Байтурсын", "Бекболат", "Болатов", "Гайнуллин",
		"Джумабаев", "Есимов", "Жаксылыков", "Жанабаев", "Жумабеков", "Зейнуллин", "Ибраев", "Кадыров", "Калиев", "Канапьянов",
		"Каратаев", "Касымов", "Кожахметов", "Кудайберген", "Кулманов", "Мамедов", "Мусабаев", "Мухамеджанов", "Набиев", "Нургазин",
		"Оразов", "Плотников", "Рахманов", "Сабитов", "Садыков", "Сеитов", "Смагулов", "Ташенов", "Утегенов", "Файзуллин",
		"Хамзин", "Шарипов", "Шаяхметов", "Ыбыраев", "Юлдашев", "Яруллин", "Бахытжанова", "Галимова", "Досанова", "Ержанова",
		"Жумабаева", "Ибрагимова", "Кайсарова", "Камалова", "Карабаева", "Куандыкова", "Муханова", "Нуркенова", "Омарова", "Сағындык",
		"Сейдахметова", "Токтарова", "Уалиева", "Федорова", "Халикова", "Шынгысова", "Юсупова", "Якупова",
	}
	firstNames := []string{
		"Азамат", "Алихан", "Амир", "Арман", "Арсен", "Аслан", "Бекзат", "Бекнур", "Даулет", "Диас", "Елдос", "Ерасыл",
		"Жанибек", "Жасулан", "Ильяс", "Кайрат", "Максат", "Мансур", "Мирас", "Назар", "Нурали", "Нурбол", "Нуржан", "Рамазан",
		"Руслан", "Санжар", "Султан", "Талгат", "Темирлан", "Тимур", "Шынгыс", "Эльдар", "Аделина", "Айгерим", "Айдана",
		"Айым", "Алина", "Алтынай", "Аружан", "Асель", "Балжан", "Гульдана", "Дана", "Дильназ", "Жанна", "Зарина", "Инкар",
		"Камилла", "Карина", "Лейла", "Мадина", "Малика", "Нурай", "Самал", "Сезим", "Томирис", "Фарида", "Элина",
	}
	result := make([]string, 0, count)
	attempts := 0
	for len(result) < count && attempts < 5000 {
		attempts++
		fullName := strings.TrimSpace(lastNames[rng.Intn(len(lastNames))] + " " + firstNames[rng.Intn(len(firstNames))])
		if _, exists := used[fullName]; exists {
			continue
		}
		used[fullName] = struct{}{}
		result = append(result, fullName)
	}
	if len(result) < count {
		for len(result) < count {
			candidate := fmt.Sprintf("СтудентДемо %d", len(used)+1)
			if _, exists := used[candidate]; exists {
				continue
			}
			used[candidate] = struct{}{}
			result = append(result, candidate)
		}
	}
	return result
}

func pickTeachersForGroup(rng *rand.Rand, teachers map[string]namedUser, preferred string, count int) []uint {
	unique := map[uint]struct{}{}
	out := make([]uint, 0, count)
	if t, ok := teachers[preferred]; ok {
		unique[t.ID] = struct{}{}
		out = append(out, t.ID)
	}
	pool := make([]namedUser, 0, len(teachers))
	for _, item := range teachers {
		pool = append(pool, item)
	}
	rng.Shuffle(len(pool), func(i, j int) {
		pool[i], pool[j] = pool[j], pool[i]
	})
	for _, item := range pool {
		if len(out) >= count {
			break
		}
		if _, exists := unique[item.ID]; exists {
			continue
		}
		unique[item.ID] = struct{}{}
		out = append(out, item.ID)
	}
	return out
}

func ptrTime(value time.Time) *time.Time {
	return &value
}

func scopedGroupName(groupName string, teacherID uint) string {
	return strings.TrimSpace(groupName) + "@@t" + fmt.Sprintf("%d", teacherID)
}
