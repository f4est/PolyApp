package persistence

import (
	"fmt"
	"time"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func OpenPostgres(dsn string) (*gorm.DB, error) {
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Silent),
	})
	if err != nil {
		return nil, err
	}
	sqlDB, err := db.DB()
	if err != nil {
		return nil, err
	}
	sqlDB.SetMaxOpenConns(20)
	sqlDB.SetMaxIdleConns(10)
	sqlDB.SetConnMaxLifetime(30 * time.Minute)
	return db, nil
}

func AutoMigrate(db *gorm.DB) error {
	if db == nil {
		return fmt.Errorf("db is nil")
	}
	if err := db.AutoMigrate(ModelSet()...); err != nil {
		return err
	}
	if err := ensureLessonSlotSchema(db); err != nil {
		return err
	}
	return nil
}

func ensureLessonSlotSchema(db *gorm.DB) error {
	// Backfill newly introduced lesson slot columns for existing rows.
	if err := db.Model(&DBJournalDate{}).
		Where("lesson_slot IS NULL OR lesson_slot < 1").
		Update("lesson_slot", 1).Error; err != nil {
		return err
	}
	if err := db.Model(&DBJournalDateCellV2{}).
		Where("lesson_slot IS NULL OR lesson_slot < 1").
		Update("lesson_slot", 1).Error; err != nil {
		return err
	}
	if err := db.Model(&DBAttendanceRecord{}).
		Where("lesson_slot IS NULL OR lesson_slot < 1").
		Update("lesson_slot", 1).Error; err != nil {
		return err
	}

	indexes := []struct {
		model any
		name  string
	}{
		{model: &DBJournalDate{}, name: "idx_journal_date"},
		{model: &DBJournalDateCellV2{}, name: "idx_journal_date_cell_v2"},
		{model: &DBAttendanceRecord{}, name: "idx_attendance_record"},
	}
	for _, item := range indexes {
		if db.Migrator().HasIndex(item.model, item.name) {
			if err := db.Migrator().DropIndex(item.model, item.name); err != nil {
				return err
			}
		}
		if err := db.Migrator().CreateIndex(item.model, item.name); err != nil {
			return err
		}
	}
	return nil
}
