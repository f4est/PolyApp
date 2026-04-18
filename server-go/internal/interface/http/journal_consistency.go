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
		Where("role = ? AND is_approved = ?", "student", true).
		Where("lower(btrim(student_group)) = lower(?)", baseGroup).
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
	// Keep scoped teacher journals consistent even when assignment links changed:
	// if records already exist in scoped journals, they still must be synchronized.
	var persistedGroupNames []string
	if err := h.db.WithContext(ctx).
		Model(&persistence.DBJournalStudent{}).
		Where(
			"lower(group_name) = lower(?) OR lower(group_name) LIKE lower(?)",
			baseGroup,
			baseGroup+teacherJournalGroupSuffix+"%",
		).
		Distinct("group_name").
		Pluck("group_name", &persistedGroupNames).Error; err != nil {
		return err
	}
	allGroupNames := make([]string, 0, len(groupNames)+len(persistedGroupNames))
	groupSeen := map[string]struct{}{}
	addGroup := func(groupName string) {
		groupName = strings.TrimSpace(groupName)
		if groupName == "" {
			return
		}
		key := strings.ToLower(groupName)
		if _, ok := groupSeen[key]; ok {
			return
		}
		groupSeen[key] = struct{}{}
		allGroupNames = append(allGroupNames, groupName)
	}
	for _, groupName := range groupNames {
		addGroup(groupName)
	}
	for _, groupName := range persistedGroupNames {
		addGroup(groupName)
	}

	return h.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		for _, groupName := range allGroupNames {
			groupName = strings.TrimSpace(groupName)
			if groupName == "" {
				continue
			}

			// Collect students from all related journal tables to avoid stale rows
			// surviving when DBJournalStudent was partially out of sync.
			existingDisplay := map[string]string{}
			collectExisting := func(model any) error {
				var values []string
				if err := tx.Model(model).
					Where("group_name = ?", groupName).
					Pluck("student_name", &values).Error; err != nil {
					return err
				}
				for _, value := range values {
					name := strings.TrimSpace(value)
					if name == "" {
						continue
					}
					key := strings.ToLower(name)
					if _, ok := existingDisplay[key]; ok {
						continue
					}
					existingDisplay[key] = name
				}
				return nil
			}
			for _, model := range []any{
				&persistence.DBJournalStudent{},
				&persistence.DBJournalDateCellV2{},
				&persistence.DBJournalManualCellV2{},
				&persistence.DBJournalComputedRowV2{},
				&persistence.DBAttendanceRecord{},
				&persistence.DBGradeRecord{},
			} {
				if err := collectExisting(model); err != nil {
					return err
				}
			}

			for key, name := range existingDisplay {
				if _, ok := desired[key]; ok {
					continue
				}
				if err := h.deleteStudentFromJournalGroupTx(tx, groupName, name); err != nil {
					return err
				}
			}

			for key := range desired {
				if _, ok := existingDisplay[key]; ok {
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
