package usecase

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
	"polyapp/server-go/internal/domain/repository"
)

type Actor struct {
	UserID       uint
	Role         string
	StudentGroup string
}

func (a Actor) IsAdmin() bool {
	return strings.EqualFold(strings.TrimSpace(a.Role), "admin")
}

func (a Actor) IsTeacher() bool {
	return strings.EqualFold(strings.TrimSpace(a.Role), "teacher")
}

type PresetUseCase struct {
	repo   repository.GradingPresetRepository
	engine *FormulaEngineUseCase
	now    func() time.Time
}

func NewPresetUseCase(repo repository.GradingPresetRepository, engine *FormulaEngineUseCase) *PresetUseCase {
	return &PresetUseCase{
		repo:   repo,
		engine: engine,
		now:    time.Now,
	}
}

type CreatePresetInput struct {
	Name        string
	Description string
	Tags        []string
	Visibility  entity.PresetVisibility
	Definition  entity.PresetDefinition
}

type UpdatePresetInput struct {
	Name        *string
	Description *string
	Tags        []string
	Visibility  *entity.PresetVisibility
	Definition  *entity.PresetDefinition
}

func (u *PresetUseCase) List(ctx context.Context, actor Actor, filter entity.PresetSearchFilter) ([]entity.GradingPreset, error) {
	filter.ActorID = actor.UserID
	filter.ActorRole = actor.Role
	if filter.Visibility != nil {
		vis := entity.PresetVisibility(strings.ToLower(strings.TrimSpace(string(*filter.Visibility))))
		filter.Visibility = &vis
	}
	return u.repo.ListPresets(ctx, filter)
}

func (u *PresetUseCase) Create(ctx context.Context, actor Actor, in CreatePresetInput) (*entity.GradingPreset, *entity.GradingPresetVersion, error) {
	if !actor.IsAdmin() && !actor.IsTeacher() {
		return nil, nil, domainErrors.ErrForbidden
	}
	name := strings.TrimSpace(in.Name)
	if name == "" {
		return nil, nil, domainErrors.ErrInvalidInput
	}

	asts, _, err := u.engine.ValidateDefinition(in.Definition)
	if err != nil {
		return nil, nil, err
	}
	visibility := normalizeVisibility(in.Visibility)
	now := u.now().UTC()

	preset := &entity.GradingPreset{
		OwnerID:     actor.UserID,
		Name:        name,
		Description: strings.TrimSpace(in.Description),
		Tags:        normalizeTags(in.Tags),
		Visibility:  visibility,
		CreatedAt:   now,
		UpdatedAt:   now,
	}
	version := &entity.GradingPresetVersion{
		Version:       1,
		Definition:    in.Definition,
		CreatedBy:     actor.UserID,
		CreatedAt:     now,
		DefinitionAST: asts,
	}
	if err := u.repo.CreatePreset(ctx, preset, version); err != nil {
		return nil, nil, err
	}
	return preset, version, nil
}

func (u *PresetUseCase) Get(ctx context.Context, actor Actor, presetID uint) (*entity.GradingPreset, *entity.GradingPresetVersion, error) {
	if presetID == 0 {
		return nil, nil, domainErrors.ErrInvalidInput
	}
	preset, err := u.repo.GetPresetByID(ctx, presetID)
	if err != nil {
		return nil, nil, err
	}
	if err := ensurePresetReadPermission(actor, preset); err != nil {
		return nil, nil, err
	}
	version, err := u.repo.GetLatestPresetVersion(ctx, preset.ID)
	if err != nil {
		return nil, nil, err
	}
	asts, _, err := u.engine.ValidateDefinition(version.Definition)
	if err != nil {
		return nil, nil, err
	}
	version.DefinitionAST = asts
	return preset, version, nil
}

func (u *PresetUseCase) Update(ctx context.Context, actor Actor, presetID uint, in UpdatePresetInput) (*entity.GradingPreset, *entity.GradingPresetVersion, error) {
	if presetID == 0 {
		return nil, nil, domainErrors.ErrInvalidInput
	}
	preset, err := u.repo.GetPresetByID(ctx, presetID)
	if err != nil {
		return nil, nil, err
	}
	if !canEditPreset(actor, preset) {
		return nil, nil, domainErrors.ErrForbidden
	}

	if in.Name != nil {
		preset.Name = strings.TrimSpace(*in.Name)
	}
	if in.Description != nil {
		preset.Description = strings.TrimSpace(*in.Description)
	}
	if in.Tags != nil {
		preset.Tags = normalizeTags(in.Tags)
	}
	if in.Visibility != nil {
		preset.Visibility = normalizeVisibility(*in.Visibility)
	}
	if strings.TrimSpace(preset.Name) == "" {
		return nil, nil, domainErrors.ErrInvalidInput
	}

	latest, err := u.repo.GetLatestPresetVersion(ctx, preset.ID)
	if err != nil {
		return nil, nil, err
	}
	latestAST, _, err := u.engine.ValidateDefinition(latest.Definition)
	if err != nil {
		return nil, nil, err
	}
	latest.DefinitionAST = latestAST

	var createdVersion *entity.GradingPresetVersion
	if in.Definition != nil {
		newAsts, _, err := u.engine.ValidateDefinition(*in.Definition)
		if err != nil {
			return nil, nil, err
		}
		if !sameDefinition(latest.Definition, *in.Definition) {
			createdVersion = &entity.GradingPresetVersion{
				PresetID:      preset.ID,
				Version:       latest.Version + 1,
				Definition:    *in.Definition,
				CreatedBy:     actor.UserID,
				CreatedAt:     u.now().UTC(),
				DefinitionAST: newAsts,
			}
			if err := u.repo.CreatePresetVersion(ctx, createdVersion); err != nil {
				return nil, nil, err
			}
		}
	}

	preset.UpdatedAt = u.now().UTC()
	if err := u.repo.UpdatePreset(ctx, preset); err != nil {
		return nil, nil, err
	}
	if createdVersion == nil {
		createdVersion = latest
	}
	return preset, createdVersion, nil
}

func (u *PresetUseCase) Publish(ctx context.Context, actor Actor, presetID uint, public bool) (*entity.GradingPreset, error) {
	preset, err := u.repo.GetPresetByID(ctx, presetID)
	if err != nil {
		return nil, err
	}
	if !canEditPreset(actor, preset) {
		return nil, domainErrors.ErrForbidden
	}
	if public {
		preset.Visibility = entity.PresetVisibilityPublic
	} else {
		preset.Visibility = entity.PresetVisibilityPrivate
	}
	preset.UpdatedAt = u.now().UTC()
	if err := u.repo.UpdatePreset(ctx, preset); err != nil {
		return nil, err
	}
	return preset, nil
}

func ensurePresetReadPermission(actor Actor, preset *entity.GradingPreset) error {
	if preset == nil {
		return domainErrors.ErrNotFound
	}
	if preset.Visibility == entity.PresetVisibilityPublic {
		return nil
	}
	if actor.IsAdmin() || preset.OwnerID == actor.UserID {
		return nil
	}
	return domainErrors.ErrForbidden
}

func canEditPreset(actor Actor, preset *entity.GradingPreset) bool {
	if preset == nil {
		return false
	}
	return actor.IsAdmin() || preset.OwnerID == actor.UserID
}

func normalizeVisibility(vis entity.PresetVisibility) entity.PresetVisibility {
	normalized := strings.ToLower(strings.TrimSpace(string(vis)))
	if normalized == string(entity.PresetVisibilityPublic) {
		return entity.PresetVisibilityPublic
	}
	return entity.PresetVisibilityPrivate
}

func normalizeTags(tags []string) []string {
	uniq := map[string]struct{}{}
	out := make([]string, 0, len(tags))
	for _, tag := range tags {
		normalized := strings.ToLower(strings.TrimSpace(tag))
		if normalized == "" {
			continue
		}
		if _, ok := uniq[normalized]; ok {
			continue
		}
		uniq[normalized] = struct{}{}
		out = append(out, normalized)
	}
	return out
}

func sameDefinition(a entity.PresetDefinition, b entity.PresetDefinition) bool {
	left, err := json.Marshal(a)
	if err != nil {
		return false
	}
	right, err := json.Marshal(b)
	if err != nil {
		return false
	}
	return string(left) == string(right)
}

func (u *PresetUseCase) MustGetVersion(ctx context.Context, presetID uint) (*entity.GradingPresetVersion, error) {
	version, err := u.repo.GetLatestPresetVersion(ctx, presetID)
	if err != nil {
		return nil, err
	}
	asts, _, err := u.engine.ValidateDefinition(version.Definition)
	if err != nil {
		return nil, fmt.Errorf("preset definition invalid: %w", err)
	}
	version.DefinitionAST = asts
	return version, nil
}
