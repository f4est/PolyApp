package repository

import (
	"context"
	"time"

	"polyapp/server-go/internal/domain/entity"
)

type GradingPresetRepository interface {
	ListPresets(ctx context.Context, filter entity.PresetSearchFilter) ([]entity.GradingPreset, error)
	CreatePreset(ctx context.Context, preset *entity.GradingPreset, firstVersion *entity.GradingPresetVersion) error
	GetPresetByID(ctx context.Context, id uint) (*entity.GradingPreset, error)
	GetPresetVersionByID(ctx context.Context, id uint) (*entity.GradingPresetVersion, error)
	GetLatestPresetVersion(ctx context.Context, presetID uint) (*entity.GradingPresetVersion, error)
	CreatePresetVersion(ctx context.Context, version *entity.GradingPresetVersion) error
	UpdatePreset(ctx context.Context, preset *entity.GradingPreset) error
}

type JournalRepository interface {
	GetGroupPresetBinding(ctx context.Context, groupName string) (*entity.GroupPresetBinding, error)
	UpsertGroupPresetBinding(ctx context.Context, binding *entity.GroupPresetBinding) error
	DeleteGroupPresetBinding(ctx context.Context, groupName string) error

	ListJournalStudents(ctx context.Context, groupName string) ([]string, error)
	ListJournalDates(ctx context.Context, groupName string) ([]time.Time, error)

	ListDateCells(ctx context.Context, groupName string) ([]entity.JournalCell, error)
	UpsertDateCells(ctx context.Context, cells []entity.JournalCell) error
	DeleteDateCells(ctx context.Context, groupName string, items []entity.JournalCell) error

	ListManualCells(ctx context.Context, groupName string) ([]entity.ManualCell, error)
	UpsertManualCells(ctx context.Context, cells []entity.ManualCell) error

	ListComputedRows(ctx context.Context, groupName string) ([]entity.ComputedRow, error)
	UpsertComputedRows(ctx context.Context, rows []entity.ComputedRow) error

	IsTeacherAssignedToGroup(ctx context.Context, teacherID uint, groupName string) (bool, error)
}
