package app

import (
	"context"
	"errors"
	"time"

	"polyapp/server-go/internal/infrastructure/persistence"

	"gorm.io/gorm"
)

type passwordHasher interface {
	Hash(password string) (string, error)
}

func SeedDemo(ctx context.Context, db *gorm.DB, hasher passwordHasher) error {
	const demoPassword = "Demo1234"
	defaultRequestTypes := []string{
		"Справка на онай",
		"Справка на военкомат",
		"Справка по месту требования",
	}
	defaultRequestStatuses := []string{
		"Отправлена",
		"На рассмотрении",
		"Отклонена",
		"В работе",
		"Готова",
	}

	type demoUser struct {
		Role         string
		FullName     string
		Email        string
		StudentGroup string
		TeacherName  string
	}
	users := []demoUser{
		{Role: "admin", FullName: "Admin Demo", Email: "admin@demo.local"},
		{Role: "student", FullName: "Student Demo", Email: "student@demo.local", StudentGroup: "P22-3E"},
		{Role: "teacher", FullName: "Teacher Demo", Email: "teacher@demo.local", TeacherName: "Teacher Demo"},
		{Role: "parent", FullName: "Parent Demo", Email: "parent@demo.local", StudentGroup: "P22-3E"},
		{Role: "request_handler", FullName: "Handler Demo", Email: "handler@demo.local"},
		{Role: "smm", FullName: "SMM Demo", Email: "smm@demo.local"},
	}

	hash, err := hasher.Hash(demoPassword)
	if err != nil {
		return err
	}
	now := time.Now().UTC()
	userIDs := map[string]uint{}
	for _, item := range users {
		var row persistence.DBUser
		err := db.WithContext(ctx).Where("email = ?", item.Email).First(&row).Error
		switch {
		case err == nil:
			userIDs[item.Role] = row.ID
			continue
		case !errors.Is(err, gorm.ErrRecordNotFound):
			return err
		}
		row = persistence.DBUser{
			Role:         item.Role,
			FullName:     item.FullName,
			Email:        item.Email,
			PasswordHash: hash,
			StudentGroup: item.StudentGroup,
			TeacherName:  item.TeacherName,
			CreatedAt:    now,
			UpdatedAt:    now,
		}
		if err := db.WithContext(ctx).Create(&row).Error; err != nil {
			return err
		}
		userIDs[item.Role] = row.ID
	}

	group := "P22-3E"
	if err := db.WithContext(ctx).Where("name = ?", group).FirstOrCreate(&persistence.DBJournalGroup{Name: group}).Error; err != nil {
		return err
	}
	students := []string{"Ivan Petrov", "Anna Sidorova", "Alina Karim", "Nikita Smirnov"}
	for _, name := range students {
		row := persistence.DBJournalStudent{GroupName: group, StudentName: name}
		if err := db.WithContext(ctx).Where("group_name = ? AND student_name = ?", group, name).FirstOrCreate(&row).Error; err != nil {
			return err
		}
	}

	dates := []time.Time{
		time.Now().AddDate(0, 0, -2).UTC(),
		time.Now().AddDate(0, 0, -1).UTC(),
		time.Now().UTC(),
	}
	for _, d := range dates {
		dateOnly := time.Date(d.Year(), d.Month(), d.Day(), 0, 0, 0, 0, time.UTC)
		row := persistence.DBJournalDate{GroupName: group, ClassDate: dateOnly}
		if err := db.WithContext(ctx).Where("group_name = ? AND class_date = ?", group, dateOnly).FirstOrCreate(&row).Error; err != nil {
			return err
		}
		for _, student := range students {
			attendance := persistence.DBAttendanceRecord{
				GroupName:   group,
				ClassDate:   dateOnly,
				StudentName: student,
				Present:     true,
				TeacherID:   userIDs["teacher"],
			}
			if err := db.WithContext(ctx).Where("group_name = ? AND class_date = ? AND student_name = ?", group, dateOnly, student).FirstOrCreate(&attendance).Error; err != nil {
				return err
			}

			grade := persistence.DBGradeRecord{
				GroupName:   group,
				ClassDate:   dateOnly,
				StudentName: student,
				Grade:       85,
				TeacherID:   userIDs["teacher"],
			}
			if err := db.WithContext(ctx).Where("group_name = ? AND class_date = ? AND student_name = ?", group, dateOnly, student).FirstOrCreate(&grade).Error; err != nil {
				return err
			}
		}
	}

	assignment := persistence.DBTeacherGroupAssignment{
		TeacherID: userIDs["teacher"],
		GroupName: group,
		Subject:   "Math",
		CreatedAt: now,
	}
	if err := db.WithContext(ctx).Where("teacher_id = ? AND group_name = ? AND subject = ?", assignment.TeacherID, assignment.GroupName, assignment.Subject).FirstOrCreate(&assignment).Error; err != nil {
		return err
	}

	post := persistence.DBNewsPost{
		Title:      "Welcome",
		Body:       "Welcome to PolyApp demo feed!",
		AuthorID:   userIDs["smm"],
		Category:   "news",
		CreatedAt:  now,
		UpdatedAt:  now,
		ShareCount: 0,
	}
	if err := db.WithContext(ctx).Where("title = ?", post.Title).FirstOrCreate(&post).Error; err != nil {
		return err
	}
	comment := persistence.DBNewsComment{
		PostID:    post.ID,
		UserID:    userIDs["student"],
		Text:      "Great to be here!",
		CreatedAt: now,
	}
	if err := db.WithContext(ctx).Where("post_id = ? AND user_id = ? AND text = ?", comment.PostID, comment.UserID, comment.Text).FirstOrCreate(&comment).Error; err != nil {
		return err
	}
	like := persistence.DBNewsLike{
		PostID:    post.ID,
		UserID:    userIDs["student"],
		Reaction:  "like",
		CreatedAt: now,
	}
	if err := db.WithContext(ctx).Where("post_id = ? AND user_id = ?", like.PostID, like.UserID).FirstOrCreate(&like).Error; err != nil {
		return err
	}

	request := persistence.DBRequestTicket{
		StudentID:   userIDs["student"],
		RequestType: defaultRequestTypes[0],
		Status:      defaultRequestStatuses[0],
		Details:     "Demo request",
		CreatedAt:   now,
	}
	if err := db.WithContext(ctx).Where("student_id = ? AND request_type = ?", request.StudentID, request.RequestType).FirstOrCreate(&request).Error; err != nil {
		return err
	}

	upload := persistence.DBExamUpload{
		GroupName:  group,
		ExamName:   "Math Final",
		Filename:   "demo.xlsx",
		RowsCount:  len(students),
		TeacherID:  userIDs["teacher"],
		UploadedAt: now,
	}
	if err := db.WithContext(ctx).Where("group_name = ? AND exam_name = ?", upload.GroupName, upload.ExamName).FirstOrCreate(&upload).Error; err != nil {
		return err
	}
	for _, student := range students {
		grade := persistence.DBExamGrade{
			GroupName:   group,
			ExamName:    "Math Final",
			StudentName: student,
			Grade:       90,
			TeacherID:   userIDs["teacher"],
			UploadID:    upload.ID,
			CreatedAt:   now,
		}
		if err := db.WithContext(ctx).Where("group_name = ? AND exam_name = ? AND student_name = ?", grade.GroupName, grade.ExamName, grade.StudentName).FirstOrCreate(&grade).Error; err != nil {
			return err
		}
	}
	return nil
}
