package http

import (
	"context"
	"strings"
	"time"

	"polyapp/server-go/internal/infrastructure/persistence"

	"gorm.io/gorm"
)

func (h *Handler) ensureJournalDateEntry(
	ctx context.Context,
	groupName string,
	classDate time.Time,
	lessonSlot int,
) error {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" {
		return nil
	}
	row := persistence.DBJournalDate{
		GroupName:  groupName,
		ClassDate:  classDate,
		LessonSlot: normalizeLessonSlot(lessonSlot),
	}
	return h.db.WithContext(ctx).
		Where("group_name = ? AND class_date = ? AND lesson_slot = ?", row.GroupName, row.ClassDate, row.LessonSlot).
		FirstOrCreate(&row).Error
}

func (h *Handler) syncStudentsForBaseGroup(ctx context.Context, baseGroup string) error {
	baseGroup = strings.TrimSpace(baseJournalGroupName(baseGroup))
	if baseGroup == "" {
		return nil
	}

	var approved []persistence.DBUser
	if err := h.db.WithContext(ctx).
		Where("role = ? AND is_approved = ? AND student_group = ?", "student", true, baseGroup).
		Find(&approved).Error; err != nil {
		return err
	}

	desired := make(map[string]struct{}, len(approved))
	desiredDisplay := make(map[string]string, len(approved))
	for _, student := range approved {
		name := strings.TrimSpace(student.FullName)
		if name != "" {
			key := strings.ToLower(name)
			desired[key] = struct{}{}
			desiredDisplay[key] = name
		}
	}

	groupNames, err := h.journalGroupNamesForBaseGroup(ctx, nil, baseGroup, baseGroup)
	if err != nil {
		return err
	}

	return h.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		for _, groupName := range groupNames {
			groupName = strings.TrimSpace(groupName)
			if groupName == "" {
				continue
			}

			existing := make([]string, 0)
			if err := tx.Model(&persistence.DBJournalStudent{}).
				Where("group_name = ?", groupName).
				Pluck("student_name", &existing).Error; err != nil {
				return err
			}
			existingSet := map[string]struct{}{}
			for _, name := range existing {
				trimmed := strings.TrimSpace(name)
				if trimmed == "" {
					continue
				}
				key := strings.ToLower(trimmed)
				existingSet[key] = struct{}{}
				if _, ok := desired[key]; ok {
					continue
				}
				if err := h.deleteStudentFromJournalGroupTx(tx, groupName, trimmed); err != nil {
					return err
				}
			}

			for key := range desired {
				if _, ok := existingSet[key]; ok {
					continue
				}
				name := desiredDisplay[key]
				row := persistence.DBJournalStudent{
					GroupName:   groupName,
					StudentName: name,
				}
				if err := tx.Where("group_name = ? AND student_name = ?", groupName, name).
					FirstOrCreate(&row).Error; err != nil {
					return err
				}
			}
		}
		return nil
	})
}

func (h *Handler) deleteStudentFromJournalGroupTx(tx *gorm.DB, groupName, studentName string) error {
	name := strings.TrimSpace(studentName)
	if name == "" {
		return nil
	}
	if err := tx.Where("group_name = ? AND lower(btrim(student_name)) = lower(?)", groupName, name).
		Delete(&persistence.DBJournalStudent{}).Error; err != nil {
		return err
	}
	if err := tx.Where("group_name = ? AND lower(btrim(student_name)) = lower(?)", groupName, name).
		Delete(&persistence.DBJournalDateCellV2{}).Error; err != nil {
		return err
	}
	if err := tx.Where("group_name = ? AND lower(btrim(student_name)) = lower(?)", groupName, name).
		Delete(&persistence.DBJournalManualCellV2{}).Error; err != nil {
		return err
	}
	if err := tx.Where("group_name = ? AND lower(btrim(student_name)) = lower(?)", groupName, name).
		Delete(&persistence.DBJournalComputedRowV2{}).Error; err != nil {
		return err
	}
	if err := tx.Where("group_name = ? AND lower(btrim(student_name)) = lower(?)", groupName, name).
		Delete(&persistence.DBAttendanceRecord{}).Error; err != nil {
		return err
	}
	if err := tx.Where("group_name = ? AND lower(btrim(student_name)) = lower(?)", groupName, name).
		Delete(&persistence.DBGradeRecord{}).Error; err != nil {
		return err
	}
	return nil
}
