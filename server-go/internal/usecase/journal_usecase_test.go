package usecase

import (
	"context"
	"errors"
	"testing"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
)

type fakeJournalRepo struct {
	binding          *entity.GroupPresetBinding
	teacherGroups    map[uint]map[string]struct{}
	studentsByGroup  map[string][]string
	datesByGroup     map[string][]time.Time
	dateCellsByGroup map[string][]entity.JournalCell
	manualByGroup    map[string][]entity.ManualCell
	computedByGroup  map[string][]entity.ComputedRow
}

func newFakeJournalRepo() *fakeJournalRepo {
	return &fakeJournalRepo{
		teacherGroups:    map[uint]map[string]struct{}{},
		studentsByGroup:  map[string][]string{},
		datesByGroup:     map[string][]time.Time{},
		dateCellsByGroup: map[string][]entity.JournalCell{},
		manualByGroup:    map[string][]entity.ManualCell{},
		computedByGroup:  map[string][]entity.ComputedRow{},
	}
}

func (r *fakeJournalRepo) GetGroupPresetBinding(_ context.Context, groupName string) (*entity.GroupPresetBinding, error) {
	if r.binding == nil || r.binding.GroupName != groupName {
		return nil, domainErrors.ErrNotFound
	}
	copyBinding := *r.binding
	return &copyBinding, nil
}

func (r *fakeJournalRepo) UpsertGroupPresetBinding(_ context.Context, binding *entity.GroupPresetBinding) error {
	copyBinding := *binding
	r.binding = &copyBinding
	return nil
}

func (r *fakeJournalRepo) DeleteGroupPresetBinding(_ context.Context, groupName string) error {
	if r.binding != nil && r.binding.GroupName == groupName {
		r.binding = nil
	}
	return nil
}

func (r *fakeJournalRepo) ListJournalStudents(_ context.Context, groupName string) ([]string, error) {
	return append([]string{}, r.studentsByGroup[groupName]...), nil
}

func (r *fakeJournalRepo) ListJournalDates(_ context.Context, groupName string) ([]time.Time, error) {
	return append([]time.Time{}, r.datesByGroup[groupName]...), nil
}

func (r *fakeJournalRepo) ListDateCells(_ context.Context, groupName string) ([]entity.JournalCell, error) {
	return append([]entity.JournalCell{}, r.dateCellsByGroup[groupName]...), nil
}

func (r *fakeJournalRepo) UpsertDateCells(_ context.Context, cells []entity.JournalCell) error {
	if len(cells) == 0 {
		return nil
	}
	group := cells[0].GroupName
	r.dateCellsByGroup[group] = cells
	return nil
}

func (r *fakeJournalRepo) DeleteDateCells(_ context.Context, groupName string, _ []entity.JournalCell) error {
	r.dateCellsByGroup[groupName] = nil
	return nil
}

func (r *fakeJournalRepo) ListManualCells(_ context.Context, groupName string) ([]entity.ManualCell, error) {
	return append([]entity.ManualCell{}, r.manualByGroup[groupName]...), nil
}

func (r *fakeJournalRepo) UpsertManualCells(_ context.Context, cells []entity.ManualCell) error {
	if len(cells) == 0 {
		return nil
	}
	group := cells[0].GroupName
	r.manualByGroup[group] = cells
	return nil
}

func (r *fakeJournalRepo) ListComputedRows(_ context.Context, groupName string) ([]entity.ComputedRow, error) {
	return append([]entity.ComputedRow{}, r.computedByGroup[groupName]...), nil
}

func (r *fakeJournalRepo) UpsertComputedRows(_ context.Context, rows []entity.ComputedRow) error {
	if len(rows) == 0 {
		return nil
	}
	r.computedByGroup[rows[0].GroupName] = rows
	return nil
}

func (r *fakeJournalRepo) IsTeacherAssignedToGroup(_ context.Context, teacherID uint, groupName string) (bool, error) {
	groups := r.teacherGroups[teacherID]
	if groups == nil {
		return false, nil
	}
	_, ok := groups[groupName]
	return ok, nil
}

func TestJournalUseCase_ApplyPresetPermission(t *testing.T) {
	presetRepo := newFakePresetRepo()
	journalRepo := newFakeJournalRepo()
	journalRepo.teacherGroups[5] = map[string]struct{}{"P22": {}}
	engine := NewFormulaEngineUseCase()
	presetUC := NewPresetUseCase(presetRepo, engine)
	journalUC := NewJournalUseCase(journalRepo, presetRepo, engine)

	preset, _, err := presetUC.Create(context.Background(), Actor{UserID: 5, Role: "teacher"}, CreatePresetInput{
		Name: "Base",
		Definition: entity.PresetDefinition{
			Columns: []entity.PresetColumn{{
				Key:      "total",
				Kind:     entity.PresetColumnTypeComputed,
				Type:     entity.ValueTypeNumber,
				Formula:  "DATE_AVG",
				Editable: false,
			}},
		},
	})
	if err != nil {
		t.Fatalf("create preset failed: %v", err)
	}

	if _, err := journalUC.ApplyPreset(context.Background(), Actor{UserID: 7, Role: "teacher"}, "P22", preset.ID); !errors.Is(err, domainErrors.ErrForbidden) {
		t.Fatalf("expected forbidden for unassigned teacher, got %v", err)
	}

	if _, err := journalUC.ApplyPreset(context.Background(), Actor{UserID: 5, Role: "teacher"}, "P22", preset.ID); err != nil {
		t.Fatalf("apply preset failed: %v", err)
	}
}

func TestJournalUseCase_Recalculate(t *testing.T) {
	presetRepo := newFakePresetRepo()
	journalRepo := newFakeJournalRepo()
	journalRepo.teacherGroups[1] = map[string]struct{}{"P22": {}}
	journalRepo.studentsByGroup["P22"] = []string{"Alice"}
	journalRepo.dateCellsByGroup["P22"] = []entity.JournalCell{{
		GroupName:   "P22",
		StudentName: "Alice",
		ClassDate:   time.Date(2026, 3, 4, 0, 0, 0, 0, time.UTC),
		RawValue:    "80",
		NumericValue: func() *float64 {
			v := 80.0
			return &v
		}(),
	}}

	engine := NewFormulaEngineUseCase()
	presetUC := NewPresetUseCase(presetRepo, engine)
	journalUC := NewJournalUseCase(journalRepo, presetRepo, engine)

	preset, version, err := presetUC.Create(context.Background(), Actor{UserID: 1, Role: "admin"}, CreatePresetInput{
		Name: "Preset",
		Definition: entity.PresetDefinition{
			Columns: []entity.PresetColumn{
				{Key: "bonus", Kind: entity.PresetColumnTypeManual, Type: entity.ValueTypeNumber, Editable: true},
				{Key: "final", Kind: entity.PresetColumnTypeComputed, Type: entity.ValueTypeNumber, Formula: "DATE_AVG + bonus", Editable: false},
			},
		},
	})
	if err != nil {
		t.Fatalf("create preset failed: %v", err)
	}
	journalRepo.binding = &entity.GroupPresetBinding{
		GroupName:       "P22",
		PresetID:        preset.ID,
		PresetVersionID: version.ID,
		AutoUpdate:      true,
	}
	journalRepo.manualByGroup["P22"] = []entity.ManualCell{{
		GroupName:    "P22",
		StudentName:  "Alice",
		ColumnKey:    "bonus",
		RawValue:     "5",
		NumericValue: func() *float64 { v := 5.0; return &v }(),
	}}

	if err := journalUC.Recalculate(context.Background(), Actor{UserID: 1, Role: "admin"}, "P22"); err != nil {
		t.Fatalf("recalculate failed: %v", err)
	}

	rows := journalRepo.computedByGroup["P22"]
	if len(rows) != 1 {
		t.Fatalf("expected one row, got %d", len(rows))
	}
	if toNumber(rows[0].Values["final"]) != 85 {
		t.Fatalf("expected final 85, got %v", rows[0].Values["final"])
	}
}

func TestJournalUseCase_UpsertDateCellsRejectsUnknownStatusCode(t *testing.T) {
	presetRepo := newFakePresetRepo()
	journalRepo := newFakeJournalRepo()
	journalRepo.teacherGroups[1] = map[string]struct{}{"P22": {}}
	journalRepo.studentsByGroup["P22"] = []string{"Alice"}

	engine := NewFormulaEngineUseCase()
	presetUC := NewPresetUseCase(presetRepo, engine)
	journalUC := NewJournalUseCase(journalRepo, presetRepo, engine)

	preset, version, err := presetUC.Create(context.Background(), Actor{UserID: 1, Role: "admin"}, CreatePresetInput{
		Name: "Preset",
		Definition: entity.PresetDefinition{
			StatusCodes: []entity.StatusCodeRule{
				{Code: "Н", CountsInStats: true},
			},
			Columns: []entity.PresetColumn{
				{Key: "final", Kind: entity.PresetColumnTypeComputed, Type: entity.ValueTypeNumber, Formula: "DATE_AVG", Editable: false},
			},
		},
	})
	if err != nil {
		t.Fatalf("create preset failed: %v", err)
	}
	journalRepo.binding = &entity.GroupPresetBinding{
		GroupName:       "P22",
		PresetID:        preset.ID,
		PresetVersionID: version.ID,
		AutoUpdate:      true,
	}

	err = journalUC.UpsertDateCells(context.Background(), Actor{UserID: 1, Role: "admin"}, "P22", []DateCellUpsertInput{
		{
			ClassDate:   time.Date(2026, 3, 4, 0, 0, 0, 0, time.UTC),
			StudentName: "Alice",
			RawValue:    "BAD_CODE",
		},
	})
	if !errors.Is(err, domainErrors.ErrInvalidInput) {
		t.Fatalf("expected invalid input, got %v", err)
	}
}

func TestJournalUseCase_UpsertDateCellsAcceptsCyrillicStatusCode(t *testing.T) {
	presetRepo := newFakePresetRepo()
	journalRepo := newFakeJournalRepo()
	journalRepo.teacherGroups[1] = map[string]struct{}{"P22": {}}
	journalRepo.studentsByGroup["P22"] = []string{"Alice"}

	engine := NewFormulaEngineUseCase()
	presetUC := NewPresetUseCase(presetRepo, engine)
	journalUC := NewJournalUseCase(journalRepo, presetRepo, engine)

	preset, version, err := presetUC.Create(context.Background(), Actor{UserID: 1, Role: "admin"}, CreatePresetInput{
		Name: "Preset",
		Definition: entity.PresetDefinition{
			StatusCodes: []entity.StatusCodeRule{
				{Key: "НКИ", Code: "н", CountsInStats: true},
			},
			Columns: []entity.PresetColumn{
				{Key: "final", Kind: entity.PresetColumnTypeComputed, Type: entity.ValueTypeNumber, Formula: "CODE_COUNT_НКИ", Editable: false},
			},
		},
	})
	if err != nil {
		t.Fatalf("create preset failed: %v", err)
	}
	journalRepo.binding = &entity.GroupPresetBinding{
		GroupName:       "P22",
		PresetID:        preset.ID,
		PresetVersionID: version.ID,
		AutoUpdate:      true,
	}

	err = journalUC.UpsertDateCells(context.Background(), Actor{UserID: 1, Role: "admin"}, "P22", []DateCellUpsertInput{
		{
			ClassDate:   time.Date(2026, 3, 4, 0, 0, 0, 0, time.UTC),
			StudentName: "Alice",
			RawValue:    "Н",
		},
	})
	if err != nil {
		t.Fatalf("expected Cyrillic status code accepted, got %v", err)
	}
}

func TestJournalUseCase_UpsertDateCellsRejectsOutOfRangeNumeric(t *testing.T) {
	presetRepo := newFakePresetRepo()
	journalRepo := newFakeJournalRepo()
	journalRepo.teacherGroups[1] = map[string]struct{}{"P22": {}}
	journalRepo.studentsByGroup["P22"] = []string{"Alice"}

	engine := NewFormulaEngineUseCase()
	presetUC := NewPresetUseCase(presetRepo, engine)
	journalUC := NewJournalUseCase(journalRepo, presetRepo, engine)

	preset, version, err := presetUC.Create(context.Background(), Actor{UserID: 1, Role: "admin"}, CreatePresetInput{
		Name: "Preset",
		Definition: entity.PresetDefinition{
			Columns: []entity.PresetColumn{
				{Key: "final", Kind: entity.PresetColumnTypeComputed, Type: entity.ValueTypeNumber, Formula: "DATE_AVG", Editable: false},
			},
		},
	})
	if err != nil {
		t.Fatalf("create preset failed: %v", err)
	}
	journalRepo.binding = &entity.GroupPresetBinding{
		GroupName:       "P22",
		PresetID:        preset.ID,
		PresetVersionID: version.ID,
		AutoUpdate:      true,
	}

	err = journalUC.UpsertDateCells(context.Background(), Actor{UserID: 1, Role: "admin"}, "P22", []DateCellUpsertInput{
		{
			ClassDate:   time.Date(2026, 3, 4, 0, 0, 0, 0, time.UTC),
			StudentName: "Alice",
			RawValue:    "101",
		},
	})
	if !errors.Is(err, domainErrors.ErrInvalidInput) {
		t.Fatalf("expected invalid input for value 101, got %v", err)
	}

	err = journalUC.UpsertDateCells(context.Background(), Actor{UserID: 1, Role: "admin"}, "P22", []DateCellUpsertInput{
		{
			ClassDate:   time.Date(2026, 3, 4, 0, 0, 0, 0, time.UTC),
			StudentName: "Alice",
			RawValue:    "-1",
		},
	})
	if !errors.Is(err, domainErrors.ErrInvalidInput) {
		t.Fatalf("expected invalid input for value -1, got %v", err)
	}
}

func TestJournalUseCase_RecalculateGroupStatusCodeCounts(t *testing.T) {
	presetRepo := newFakePresetRepo()
	journalRepo := newFakeJournalRepo()
	journalRepo.teacherGroups[1] = map[string]struct{}{"P22": {}}
	journalRepo.studentsByGroup["P22"] = []string{"Alice", "Bob"}
	journalRepo.dateCellsByGroup["P22"] = []entity.JournalCell{
		{
			GroupName:   "P22",
			StudentName: "Alice",
			ClassDate:   time.Date(2026, 3, 4, 0, 0, 0, 0, time.UTC),
			RawValue:    "Н",
		},
		{
			GroupName:   "P22",
			StudentName: "Bob",
			ClassDate:   time.Date(2026, 3, 4, 0, 0, 0, 0, time.UTC),
			RawValue:    "75",
			NumericValue: func() *float64 {
				v := 75.0
				return &v
			}(),
		},
	}
	journalRepo.manualByGroup["P22"] = []entity.ManualCell{
		{
			GroupName:   "P22",
			StudentName: "Bob",
			ColumnKey:   "behavior",
			RawValue:    "Н",
		},
	}

	engine := NewFormulaEngineUseCase()
	presetUC := NewPresetUseCase(presetRepo, engine)
	journalUC := NewJournalUseCase(journalRepo, presetRepo, engine)

	preset, version, err := presetUC.Create(context.Background(), Actor{UserID: 1, Role: "admin"}, CreatePresetInput{
		Name: "Preset",
		Definition: entity.PresetDefinition{
			StatusCodes: []entity.StatusCodeRule{
				{Code: "Н", CountsAsMiss: true, CountsInStats: true},
			},
			Columns: []entity.PresetColumn{
				{Key: "behavior", Kind: entity.PresetColumnTypeManual, Type: entity.ValueTypeString, Editable: true},
				{Key: "final", Kind: entity.PresetColumnTypeComputed, Type: entity.ValueTypeNumber, Formula: "CODE_COUNT_Н", Editable: false},
			},
		},
	})
	if err != nil {
		t.Fatalf("create preset failed: %v", err)
	}
	journalRepo.binding = &entity.GroupPresetBinding{
		GroupName:       "P22",
		PresetID:        preset.ID,
		PresetVersionID: version.ID,
		AutoUpdate:      true,
	}

	if err := journalUC.Recalculate(context.Background(), Actor{UserID: 1, Role: "admin"}, "P22"); err != nil {
		t.Fatalf("recalculate failed: %v", err)
	}

	rows := journalRepo.computedByGroup["P22"]
	if len(rows) != 2 {
		t.Fatalf("expected two rows, got %d", len(rows))
	}
	for _, row := range rows {
		if toNumber(row.Values["final"]) != 2 {
			t.Fatalf("expected final 2 for %s, got %v", row.StudentName, row.Values["final"])
		}
	}
}
