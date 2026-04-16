package http

import (
	"context"
	"errors"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	"polyapp/server-go/internal/infrastructure/persistence"
	"polyapp/server-go/internal/usecase"

	"gorm.io/gorm"
	"gorm.io/gorm/clause"
)

type dateCellAttendanceSync struct {
	ClassDate   time.Time
	LessonSlot  int
	StudentName string
	RawValue    string
}

func isAbsenceToken(raw string) bool {
	token := strings.ToUpper(strings.TrimSpace(raw))
	return token == "Н" || token == "N"
}

func (h *Handler) syncAttendanceToJournalV2(
	ctx context.Context,
	actor usecase.Actor,
	row persistence.DBAttendanceRecord,
) error {
	groupName := strings.TrimSpace(row.GroupName)
	if strings.EqualFold(strings.TrimSpace(actor.Role), "teacher") && actor.UserID > 0 {
		groupName = scopedJournalGroupNameForUser(&entity.User{ID: actor.UserID, Role: actor.Role}, groupName)
	}
	studentName := strings.TrimSpace(row.StudentName)
	if groupName == "" || studentName == "" {
		return nil
	}

	if row.Present {
		var existing persistence.DBJournalDateCellV2
		err := h.db.WithContext(ctx).
			Where(
				"group_name = ? AND class_date = ? AND lesson_slot = ? AND student_name = ?",
				groupName,
				row.ClassDate,
				normalizeLessonSlot(row.LessonSlot),
				studentName,
			).
			First(&existing).Error
		if err != nil {
			if errors.Is(err, gorm.ErrRecordNotFound) {
				return nil
			}
			return err
		}
		if !isAbsenceToken(existing.RawValue) {
			return nil
		}
		if err := h.db.WithContext(ctx).
			Where(
				"group_name = ? AND class_date = ? AND lesson_slot = ? AND student_name = ?",
				groupName,
				row.ClassDate,
				normalizeLessonSlot(row.LessonSlot),
				studentName,
			).
			Delete(&persistence.DBJournalDateCellV2{}).Error; err != nil {
			return err
		}
	} else {
		now := time.Now().UTC()
		cell := persistence.DBJournalDateCellV2{
			GroupName:   groupName,
			ClassDate:   row.ClassDate,
			LessonSlot:  normalizeLessonSlot(row.LessonSlot),
			StudentName: studentName,
			RawValue:    "Н",
			StatusCode:  "Н",
			UpdatedBy:   actor.UserID,
			UpdatedAt:   now,
		}
		if err := h.db.WithContext(ctx).
			Clauses(clause.OnConflict{
				Columns: []clause.Column{
					{Name: "group_name"},
					{Name: "class_date"},
					{Name: "lesson_slot"},
					{Name: "student_name"},
				},
				DoUpdates: clause.Assignments(map[string]any{
					"raw_value":     cell.RawValue,
					"numeric_value": nil,
					"status_code":   cell.StatusCode,
					"lesson_slot":   cell.LessonSlot,
					"updated_by":    cell.UpdatedBy,
					"updated_at":    cell.UpdatedAt,
				}),
			}).
			Create(&cell).Error; err != nil {
			return err
		}
	}

	if h.journalUC != nil {
		_ = h.journalUC.Recalculate(ctx, actor, groupName)
	}
	return nil
}

func (h *Handler) syncDateCellsToAttendance(
	ctx context.Context,
	actor usecase.Actor,
	groupName string,
	items []dateCellAttendanceSync,
) error {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" || len(items) == 0 {
		return nil
	}
	for _, item := range items {
		studentName := strings.TrimSpace(item.StudentName)
		if studentName == "" {
			continue
		}
		rawValue := strings.TrimSpace(item.RawValue)
		if rawValue == "" {
			continue
		}
		present := !isAbsenceToken(rawValue)
		attendanceGroupName := strings.TrimSpace(groupName)
		row := persistence.DBAttendanceRecord{
			GroupName:   attendanceGroupName,
			ClassDate:   item.ClassDate,
			LessonSlot:  normalizeLessonSlot(item.LessonSlot),
			StudentName: studentName,
			Present:     present,
			TeacherID:   actor.UserID,
		}
		if err := h.db.WithContext(ctx).
			Clauses(clause.OnConflict{
				Columns: []clause.Column{
					{Name: "group_name"},
					{Name: "class_date"},
					{Name: "lesson_slot"},
					{Name: "student_name"},
				},
				DoUpdates: clause.Assignments(map[string]any{
					"lesson_slot": row.LessonSlot,
					"present":     present,
					"teacher_id":  actor.UserID,
				}),
			}).
			Create(&row).Error; err != nil {
			return err
		}
	}
	return nil
}

func (h *Handler) syncGradeToAttendance(
	ctx context.Context,
	teacherID uint,
	row persistence.DBGradeRecord,
) error {
	groupName := strings.TrimSpace(row.GroupName)
	studentName := strings.TrimSpace(row.StudentName)
	if groupName == "" || studentName == "" {
		return nil
	}
	attendance := persistence.DBAttendanceRecord{
		GroupName:   groupName,
		ClassDate:   row.ClassDate,
		LessonSlot:  1,
		StudentName: studentName,
		Present:     true,
		TeacherID:   teacherID,
	}
	return h.db.WithContext(ctx).
		Clauses(clause.OnConflict{
			Columns: []clause.Column{
				{Name: "group_name"},
				{Name: "class_date"},
				{Name: "lesson_slot"},
				{Name: "student_name"},
			},
			DoUpdates: clause.Assignments(map[string]any{
				"lesson_slot": attendance.LessonSlot,
				"present":     true,
				"teacher_id":  teacherID,
			}),
		}).
		Create(&attendance).Error
}
