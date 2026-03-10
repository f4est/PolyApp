package persistence

import (
	"context"

	"gorm.io/gorm"
)

func CleanupLegacyLabs(ctx context.Context, db *gorm.DB) error {
	if db == nil {
		return nil
	}
	return db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var groups []string
		if err := tx.Model(&DBJournalGroup{}).
			Where("RIGHT(name, 4) = ?", "_Лаб").
			Pluck("name", &groups).Error; err != nil {
			return err
		}
		if len(groups) == 0 {
			return nil
		}

		if err := tx.Where("group_name IN ?", groups).Delete(&DBJournalStudent{}).Error; err != nil {
			return err
		}
		if err := tx.Where("group_name IN ?", groups).Delete(&DBJournalDate{}).Error; err != nil {
			return err
		}
		if err := tx.Where("group_name IN ?", groups).Delete(&DBGradeRecord{}).Error; err != nil {
			return err
		}
		if err := tx.Where("group_name IN ?", groups).Delete(&DBAttendanceRecord{}).Error; err != nil {
			return err
		}
		if err := tx.Where("group_name IN ?", groups).Delete(&DBTeacherGroupAssignment{}).Error; err != nil {
			return err
		}

		if err := tx.Where("group_name IN ?", groups).Delete(&DBGroupPresetBinding{}).Error; err != nil {
			return err
		}
		if err := tx.Where("group_name IN ?", groups).Delete(&DBJournalDateCellV2{}).Error; err != nil {
			return err
		}
		if err := tx.Where("group_name IN ?", groups).Delete(&DBJournalManualCellV2{}).Error; err != nil {
			return err
		}
		if err := tx.Where("group_name IN ?", groups).Delete(&DBJournalComputedRowV2{}).Error; err != nil {
			return err
		}

		return tx.Where("name IN ?", groups).Delete(&DBJournalGroup{}).Error
	})
}
