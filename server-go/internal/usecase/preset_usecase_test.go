package usecase

import (
	"context"
	"errors"
	"testing"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
)

type fakePresetRepo struct {
	presets       map[uint]entity.GradingPreset
	versions      map[uint][]entity.GradingPresetVersion
	nextPresetID  uint
	nextVersionID uint
}

func newFakePresetRepo() *fakePresetRepo {
	return &fakePresetRepo{
		presets:       map[uint]entity.GradingPreset{},
		versions:      map[uint][]entity.GradingPresetVersion{},
		nextPresetID:  1,
		nextVersionID: 1,
	}
}

func (r *fakePresetRepo) ListPresets(_ context.Context, _ entity.PresetSearchFilter) ([]entity.GradingPreset, error) {
	out := make([]entity.GradingPreset, 0, len(r.presets))
	for _, item := range r.presets {
		out = append(out, item)
	}
	return out, nil
}

func (r *fakePresetRepo) CreatePreset(_ context.Context, preset *entity.GradingPreset, firstVersion *entity.GradingPresetVersion) error {
	preset.ID = r.nextPresetID
	r.nextPresetID++
	copyPreset := *preset
	r.presets[preset.ID] = copyPreset
	firstVersion.ID = r.nextVersionID
	r.nextVersionID++
	firstVersion.PresetID = preset.ID
	r.versions[preset.ID] = []entity.GradingPresetVersion{*firstVersion}
	return nil
}

func (r *fakePresetRepo) GetPresetByID(_ context.Context, id uint) (*entity.GradingPreset, error) {
	preset, ok := r.presets[id]
	if !ok {
		return nil, domainErrors.ErrNotFound
	}
	copyPreset := preset
	return &copyPreset, nil
}

func (r *fakePresetRepo) GetPresetVersionByID(_ context.Context, id uint) (*entity.GradingPresetVersion, error) {
	for _, list := range r.versions {
		for _, item := range list {
			if item.ID == id {
				copyItem := item
				return &copyItem, nil
			}
		}
	}
	return nil, domainErrors.ErrNotFound
}

func (r *fakePresetRepo) GetLatestPresetVersion(_ context.Context, presetID uint) (*entity.GradingPresetVersion, error) {
	list, ok := r.versions[presetID]
	if !ok || len(list) == 0 {
		return nil, domainErrors.ErrNotFound
	}
	copyItem := list[len(list)-1]
	return &copyItem, nil
}

func (r *fakePresetRepo) CreatePresetVersion(_ context.Context, version *entity.GradingPresetVersion) error {
	version.ID = r.nextVersionID
	r.nextVersionID++
	r.versions[version.PresetID] = append(r.versions[version.PresetID], *version)
	return nil
}

func (r *fakePresetRepo) UpdatePreset(_ context.Context, preset *entity.GradingPreset) error {
	if _, ok := r.presets[preset.ID]; !ok {
		return domainErrors.ErrNotFound
	}
	copyPreset := *preset
	r.presets[preset.ID] = copyPreset
	return nil
}

func TestPresetUseCase_CreatePermissions(t *testing.T) {
	repo := newFakePresetRepo()
	engine := NewFormulaEngineUseCase()
	uc := NewPresetUseCase(repo, engine)

	_, _, err := uc.Create(context.Background(), Actor{UserID: 2, Role: "student"}, CreatePresetInput{
		Name: "Preset",
		Definition: entity.PresetDefinition{
			Columns: []entity.PresetColumn{{
				Key:      "total",
				Kind:     entity.PresetColumnTypeComputed,
				Type:     entity.ValueTypeNumber,
				Formula:  "1+1",
				Editable: false,
			}},
		},
	})
	if !errors.Is(err, domainErrors.ErrForbidden) {
		t.Fatalf("expected forbidden, got %v", err)
	}

	preset, version, err := uc.Create(context.Background(), Actor{UserID: 3, Role: "teacher"}, CreatePresetInput{
		Name:       "Preset",
		Visibility: entity.PresetVisibilityPublic,
		Definition: entity.PresetDefinition{
			Columns: []entity.PresetColumn{{
				Key:      "total",
				Kind:     entity.PresetColumnTypeComputed,
				Type:     entity.ValueTypeNumber,
				Formula:  "SUM(10, 5)",
				Editable: false,
			}},
		},
	})
	if err != nil {
		t.Fatalf("create failed: %v", err)
	}
	if preset.ID == 0 || version.ID == 0 {
		t.Fatalf("expected ids assigned")
	}
}

func TestPresetUseCase_UpdateOwnerOrAdminOnly(t *testing.T) {
	repo := newFakePresetRepo()
	engine := NewFormulaEngineUseCase()
	uc := NewPresetUseCase(repo, engine)
	uc.now = func() time.Time { return time.Date(2026, 3, 4, 10, 0, 0, 0, time.UTC) }

	preset, _, err := uc.Create(context.Background(), Actor{UserID: 10, Role: "teacher"}, CreatePresetInput{
		Name: "P1",
		Definition: entity.PresetDefinition{
			Columns: []entity.PresetColumn{{
				Key:      "total",
				Kind:     entity.PresetColumnTypeComputed,
				Type:     entity.ValueTypeNumber,
				Formula:  "1",
				Editable: false,
			}},
		},
	})
	if err != nil {
		t.Fatalf("create failed: %v", err)
	}

	newName := "P2"
	_, _, err = uc.Update(context.Background(), Actor{UserID: 99, Role: "teacher"}, preset.ID, UpdatePresetInput{Name: &newName})
	if !errors.Is(err, domainErrors.ErrForbidden) {
		t.Fatalf("expected forbidden, got %v", err)
	}

	updated, version, err := uc.Update(context.Background(), Actor{UserID: 1, Role: "admin"}, preset.ID, UpdatePresetInput{
		Name: &newName,
		Definition: &entity.PresetDefinition{
			Columns: []entity.PresetColumn{{
				Key:      "total",
				Kind:     entity.PresetColumnTypeComputed,
				Type:     entity.ValueTypeNumber,
				Formula:  "2",
				Editable: false,
			}},
		},
	})
	if err != nil {
		t.Fatalf("admin update failed: %v", err)
	}
	if updated.Name != "P2" {
		t.Fatalf("unexpected name %s", updated.Name)
	}
	if version.Version != 2 {
		t.Fatalf("expected version 2, got %d", version.Version)
	}
}
