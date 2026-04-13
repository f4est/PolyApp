package persistence

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"

	"gorm.io/gorm"
)

type GradingRepo struct {
	db *gorm.DB
}

func NewGradingRepo(db *gorm.DB) *GradingRepo {
	return &GradingRepo{db: db}
}

func (r *GradingRepo) ListPresets(ctx context.Context, filter entity.PresetSearchFilter) ([]entity.GradingPreset, error) {
	query := r.db.WithContext(ctx).Model(&DBGradingPreset{}).Order("updated_at desc")
	if q := strings.TrimSpace(filter.Query); q != "" {
		query = query.Where("name ILIKE ?", "%"+q+"%")
	}
	if filter.AuthorID != nil && *filter.AuthorID > 0 {
		query = query.Where("owner_id = ?", *filter.AuthorID)
	}
	if tag := strings.ToLower(strings.TrimSpace(filter.Tag)); tag != "" {
		query = query.Where("LOWER(tags_json) LIKE ?", "%\""+tag+"\"%")
	}
	if filter.Visibility != nil {
		vis := strings.ToLower(strings.TrimSpace(string(*filter.Visibility)))
		switch vis {
		case string(entity.PresetVisibilityPublic):
			query = query.Where("visibility = ?", string(entity.PresetVisibilityPublic))
		case string(entity.PresetVisibilityPrivate):
			if strings.EqualFold(filter.ActorRole, "admin") {
				query = query.Where("visibility = ?", string(entity.PresetVisibilityPrivate))
			} else {
				query = query.Where("visibility = ? AND owner_id = ?", string(entity.PresetVisibilityPrivate), filter.ActorID)
			}
		}
	} else if !strings.EqualFold(filter.ActorRole, "admin") {
		query = query.Where("visibility = ? OR owner_id = ?", string(entity.PresetVisibilityPublic), filter.ActorID)
	}

	var rows []DBGradingPreset
	if err := query.Find(&rows).Error; err != nil {
		return nil, err
	}
	out := make([]entity.GradingPreset, 0, len(rows))
	for _, row := range rows {
		out = append(out, mapPresetToDomain(row))
	}
	return out, nil
}

func (r *GradingRepo) CreatePreset(ctx context.Context, preset *entity.GradingPreset, firstVersion *entity.GradingPresetVersion) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		model := mapPresetToModel(*preset)
		if err := tx.Create(&model).Error; err != nil {
			return err
		}
		versionModel := DBGradingPresetVersion{
			PresetID:       model.ID,
			Version:        firstVersion.Version,
			DefinitionJSON: marshalJSON(firstVersion.Definition, "{}"),
			CreatedBy:      firstVersion.CreatedBy,
			CreatedAt:      firstVersion.CreatedAt,
		}
		if versionModel.CreatedAt.IsZero() {
			versionModel.CreatedAt = time.Now().UTC()
		}
		if err := tx.Create(&versionModel).Error; err != nil {
			return err
		}
		*preset = mapPresetToDomain(model)
		*firstVersion = mapPresetVersionToDomain(versionModel)
		return nil
	})
}

func (r *GradingRepo) GetPresetByID(ctx context.Context, id uint) (*entity.GradingPreset, error) {
	var row DBGradingPreset
	if err := r.db.WithContext(ctx).First(&row, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, domainErrors.ErrNotFound
		}
		return nil, err
	}
	preset := mapPresetToDomain(row)
	return &preset, nil
}

func (r *GradingRepo) GetPresetVersionByID(ctx context.Context, id uint) (*entity.GradingPresetVersion, error) {
	var row DBGradingPresetVersion
	if err := r.db.WithContext(ctx).First(&row, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, domainErrors.ErrNotFound
		}
		return nil, err
	}
	item := mapPresetVersionToDomain(row)
	return &item, nil
}

func (r *GradingRepo) GetLatestPresetVersion(ctx context.Context, presetID uint) (*entity.GradingPresetVersion, error) {
	var row DBGradingPresetVersion
	if err := r.db.WithContext(ctx).
		Where("preset_id = ?", presetID).
		Order("version desc").
		First(&row).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, domainErrors.ErrNotFound
		}
		return nil, err
	}
	item := mapPresetVersionToDomain(row)
	return &item, nil
}

func (r *GradingRepo) CreatePresetVersion(ctx context.Context, version *entity.GradingPresetVersion) error {
	row := DBGradingPresetVersion{
		PresetID:       version.PresetID,
		Version:        version.Version,
		DefinitionJSON: marshalJSON(version.Definition, "{}"),
		CreatedBy:      version.CreatedBy,
		CreatedAt:      version.CreatedAt,
	}
	if row.CreatedAt.IsZero() {
		row.CreatedAt = time.Now().UTC()
	}
	if err := r.db.WithContext(ctx).Create(&row).Error; err != nil {
		return err
	}
	*version = mapPresetVersionToDomain(row)
	return nil
}

func (r *GradingRepo) UpdatePreset(ctx context.Context, preset *entity.GradingPreset) error {
	row := mapPresetToModel(*preset)
	res := r.db.WithContext(ctx).Model(&DBGradingPreset{}).Where("id = ?", row.ID).Updates(map[string]any{
		"name":        row.Name,
		"description": row.Description,
		"tags_json":   row.TagsJSON,
		"visibility":  row.Visibility,
		"updated_at":  row.UpdatedAt,
		"archived_at": row.ArchivedAt,
	})
	if res.Error != nil {
		return res.Error
	}
	if res.RowsAffected == 0 {
		return domainErrors.ErrNotFound
	}
	return nil
}

func (r *GradingRepo) GetGroupPresetBinding(ctx context.Context, groupName string) (*entity.GroupPresetBinding, error) {
	var row DBGroupPresetBinding
	if err := r.db.WithContext(ctx).Where("group_name = ?", groupName).First(&row).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, domainErrors.ErrNotFound
		}
		return nil, err
	}
	binding := mapBindingToDomain(row)
	return &binding, nil
}

func (r *GradingRepo) UpsertGroupPresetBinding(ctx context.Context, binding *entity.GroupPresetBinding) error {
	var existing DBGroupPresetBinding
	err := r.db.WithContext(ctx).Where("group_name = ?", binding.GroupName).First(&existing).Error
	switch {
	case err == nil:
		existing.PresetID = binding.PresetID
		existing.PresetVersionID = binding.PresetVersionID
		existing.AutoUpdate = binding.AutoUpdate
		existing.AppliedBy = binding.AppliedBy
		existing.AppliedAt = binding.AppliedAt
		existing.UpdatedAt = binding.UpdatedAt
		if err := r.db.WithContext(ctx).Save(&existing).Error; err != nil {
			return err
		}
		*binding = mapBindingToDomain(existing)
		return nil
	case errors.Is(err, gorm.ErrRecordNotFound):
		row := mapBindingToModel(*binding)
		if err := r.db.WithContext(ctx).Create(&row).Error; err != nil {
			return err
		}
		*binding = mapBindingToDomain(row)
		return nil
	default:
		return err
	}
}

func (r *GradingRepo) DeleteGroupPresetBinding(ctx context.Context, groupName string) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("group_name = ?", groupName).Delete(&DBGroupPresetBinding{}).Error; err != nil {
			return err
		}
		return tx.Where("group_name = ?", groupName).Delete(&DBJournalComputedRowV2{}).Error
	})
}

func (r *GradingRepo) ListJournalStudents(ctx context.Context, groupName string) ([]string, error) {
	var students []string
	if err := r.db.WithContext(ctx).
		Model(&DBJournalStudent{}).
		Where("group_name = ?", groupName).
		Order("student_name asc").
		Pluck("student_name", &students).Error; err != nil {
		return nil, err
	}
	return students, nil
}

func (r *GradingRepo) ListJournalDates(ctx context.Context, groupName string) ([]entity.JournalDate, error) {
	var rows []DBJournalDate
	if err := r.db.WithContext(ctx).
		Where("group_name = ?", groupName).
		Order("class_date asc").
		Order("lesson_slot asc").
		Find(&rows).Error; err != nil {
		return nil, err
	}
	out := make([]entity.JournalDate, 0, len(rows))
	for _, row := range rows {
		out = append(out, entity.JournalDate{
			ClassDate:  row.ClassDate,
			LessonSlot: normalizeLessonSlot(row.LessonSlot),
		})
	}
	return out, nil
}

func normalizeLessonSlot(value int) int {
	if value < 1 {
		return 1
	}
	return value
}

func (r *GradingRepo) ListDateCells(ctx context.Context, groupName string) ([]entity.JournalCell, error) {
	var rows []DBJournalDateCellV2
	if err := r.db.WithContext(ctx).
		Where("group_name = ?", groupName).
		Order("class_date asc").
		Order("lesson_slot asc").
		Order("student_name asc").
		Find(&rows).Error; err != nil {
		return nil, err
	}
	out := make([]entity.JournalCell, 0, len(rows))
	for _, row := range rows {
		out = append(out, mapDateCellToDomain(row))
	}
	return out, nil
}

func (r *GradingRepo) UpsertDateCells(ctx context.Context, cells []entity.JournalCell) error {
	if len(cells) == 0 {
		return nil
	}
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		for _, cell := range cells {
			var existing DBJournalDateCellV2
			err := tx.Where(
				"group_name = ? AND class_date = ? AND lesson_slot = ? AND student_name = ?",
				cell.GroupName,
				cell.ClassDate,
				normalizeLessonSlot(cell.LessonSlot),
				cell.StudentName,
			).First(&existing).Error
			switch {
			case err == nil:
				existing.RawValue = cell.RawValue
				existing.NumericValue = cell.NumericValue
				existing.StatusCode = cell.StatusCode
				existing.UpdatedBy = cell.UpdatedBy
				existing.UpdatedAt = cell.UpdatedAt
				existing.LessonSlot = normalizeLessonSlot(cell.LessonSlot)
				if err := tx.Save(&existing).Error; err != nil {
					return err
				}
			case errors.Is(err, gorm.ErrRecordNotFound):
				row := mapDateCellToModel(cell)
				row.LessonSlot = normalizeLessonSlot(row.LessonSlot)
				if err := tx.Create(&row).Error; err != nil {
					return err
				}
			default:
				return err
			}
		}
		return nil
	})
}

func (r *GradingRepo) DeleteDateCells(ctx context.Context, _ string, items []entity.JournalCell) error {
	if len(items) == 0 {
		return nil
	}
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		for _, item := range items {
			if err := tx.Where(
				"group_name = ? AND class_date = ? AND lesson_slot = ? AND student_name = ?",
				item.GroupName,
				item.ClassDate,
				normalizeLessonSlot(item.LessonSlot),
				item.StudentName,
			).Delete(&DBJournalDateCellV2{}).Error; err != nil {
				return err
			}
		}
		return nil
	})
}

func (r *GradingRepo) ListManualCells(ctx context.Context, groupName string) ([]entity.ManualCell, error) {
	var rows []DBJournalManualCellV2
	if err := r.db.WithContext(ctx).
		Where("group_name = ?", groupName).
		Order("student_name asc").Order("column_key asc").
		Find(&rows).Error; err != nil {
		return nil, err
	}
	out := make([]entity.ManualCell, 0, len(rows))
	for _, row := range rows {
		out = append(out, mapManualCellToDomain(row))
	}
	return out, nil
}

func (r *GradingRepo) UpsertManualCells(ctx context.Context, cells []entity.ManualCell) error {
	if len(cells) == 0 {
		return nil
	}
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		for _, cell := range cells {
			var existing DBJournalManualCellV2
			err := tx.Where("group_name = ? AND student_name = ? AND column_key = ?", cell.GroupName, cell.StudentName, cell.ColumnKey).
				First(&existing).Error
			switch {
			case err == nil:
				existing.RawValue = cell.RawValue
				existing.NumericValue = cell.NumericValue
				existing.UpdatedBy = cell.UpdatedBy
				existing.UpdatedAt = cell.UpdatedAt
				if err := tx.Save(&existing).Error; err != nil {
					return err
				}
			case errors.Is(err, gorm.ErrRecordNotFound):
				row := mapManualCellToModel(cell)
				if err := tx.Create(&row).Error; err != nil {
					return err
				}
			default:
				return err
			}
		}
		return nil
	})
}

func (r *GradingRepo) ListComputedRows(ctx context.Context, groupName string) ([]entity.ComputedRow, error) {
	var rows []DBJournalComputedRowV2
	if err := r.db.WithContext(ctx).
		Where("group_name = ?", groupName).
		Order("student_name asc").
		Find(&rows).Error; err != nil {
		return nil, err
	}
	out := make([]entity.ComputedRow, 0, len(rows))
	for _, row := range rows {
		out = append(out, mapComputedRowToDomain(row))
	}
	return out, nil
}

func (r *GradingRepo) UpsertComputedRows(ctx context.Context, rows []entity.ComputedRow) error {
	if len(rows) == 0 {
		return nil
	}
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		for _, item := range rows {
			var existing DBJournalComputedRowV2
			err := tx.Where("group_name = ? AND student_name = ?", item.GroupName, item.StudentName).First(&existing).Error
			switch {
			case err == nil:
				existing.PresetVersionID = item.PresetVersionID
				existing.ValuesJSON = marshalJSON(item.Values, "{}")
				existing.CalculatedAt = item.CalculatedAt
				if err := tx.Save(&existing).Error; err != nil {
					return err
				}
			case errors.Is(err, gorm.ErrRecordNotFound):
				row := mapComputedRowToModel(item)
				if err := tx.Create(&row).Error; err != nil {
					return err
				}
			default:
				return err
			}
		}
		return nil
	})
}

func (r *GradingRepo) IsTeacherAssignedToGroup(ctx context.Context, teacherID uint, groupName string) (bool, error) {
	var count int64
	if err := r.db.WithContext(ctx).
		Model(&DBTeacherGroupAssignment{}).
		Where("teacher_id = ? AND group_name = ?", teacherID, groupName).
		Count(&count).Error; err != nil {
		return false, err
	}
	return count > 0, nil
}

func mapPresetToDomain(model DBGradingPreset) entity.GradingPreset {
	return entity.GradingPreset{
		ID:          model.ID,
		OwnerID:     model.OwnerID,
		Name:        model.Name,
		Description: model.Description,
		Tags:        unmarshalStringSlice(model.TagsJSON),
		Visibility:  entity.PresetVisibility(model.Visibility),
		CreatedAt:   model.CreatedAt,
		UpdatedAt:   model.UpdatedAt,
		ArchivedAt:  model.ArchivedAt,
	}
}

func mapPresetToModel(item entity.GradingPreset) DBGradingPreset {
	return DBGradingPreset{
		ID:          item.ID,
		OwnerID:     item.OwnerID,
		Name:        item.Name,
		Description: item.Description,
		TagsJSON:    marshalJSON(item.Tags, "[]"),
		Visibility:  string(item.Visibility),
		CreatedAt:   item.CreatedAt,
		UpdatedAt:   item.UpdatedAt,
		ArchivedAt:  item.ArchivedAt,
	}
}

func mapPresetVersionToDomain(model DBGradingPresetVersion) entity.GradingPresetVersion {
	return entity.GradingPresetVersion{
		ID:         model.ID,
		PresetID:   model.PresetID,
		Version:    model.Version,
		Definition: unmarshalPresetDefinition(model.DefinitionJSON),
		CreatedBy:  model.CreatedBy,
		CreatedAt:  model.CreatedAt,
	}
}

func mapBindingToDomain(model DBGroupPresetBinding) entity.GroupPresetBinding {
	return entity.GroupPresetBinding{
		ID:              model.ID,
		GroupName:       model.GroupName,
		PresetID:        model.PresetID,
		PresetVersionID: model.PresetVersionID,
		AutoUpdate:      model.AutoUpdate,
		AppliedBy:       model.AppliedBy,
		AppliedAt:       model.AppliedAt,
		UpdatedAt:       model.UpdatedAt,
	}
}

func mapBindingToModel(item entity.GroupPresetBinding) DBGroupPresetBinding {
	return DBGroupPresetBinding{
		ID:              item.ID,
		GroupName:       item.GroupName,
		PresetID:        item.PresetID,
		PresetVersionID: item.PresetVersionID,
		AutoUpdate:      item.AutoUpdate,
		AppliedBy:       item.AppliedBy,
		AppliedAt:       item.AppliedAt,
		UpdatedAt:       item.UpdatedAt,
	}
}

func mapDateCellToDomain(model DBJournalDateCellV2) entity.JournalCell {
	return entity.JournalCell{
		ID:           model.ID,
		GroupName:    model.GroupName,
		ClassDate:    model.ClassDate,
		LessonSlot:   normalizeLessonSlot(model.LessonSlot),
		StudentName:  model.StudentName,
		RawValue:     model.RawValue,
		NumericValue: model.NumericValue,
		StatusCode:   model.StatusCode,
		UpdatedBy:    model.UpdatedBy,
		UpdatedAt:    model.UpdatedAt,
	}
}

func mapDateCellToModel(item entity.JournalCell) DBJournalDateCellV2 {
	return DBJournalDateCellV2{
		ID:           item.ID,
		GroupName:    item.GroupName,
		ClassDate:    item.ClassDate,
		LessonSlot:   normalizeLessonSlot(item.LessonSlot),
		StudentName:  item.StudentName,
		RawValue:     item.RawValue,
		NumericValue: item.NumericValue,
		StatusCode:   item.StatusCode,
		UpdatedBy:    item.UpdatedBy,
		UpdatedAt:    item.UpdatedAt,
	}
}

func mapManualCellToDomain(model DBJournalManualCellV2) entity.ManualCell {
	return entity.ManualCell{
		ID:           model.ID,
		GroupName:    model.GroupName,
		StudentName:  model.StudentName,
		ColumnKey:    model.ColumnKey,
		RawValue:     model.RawValue,
		NumericValue: model.NumericValue,
		UpdatedBy:    model.UpdatedBy,
		UpdatedAt:    model.UpdatedAt,
	}
}

func mapManualCellToModel(item entity.ManualCell) DBJournalManualCellV2 {
	return DBJournalManualCellV2{
		ID:           item.ID,
		GroupName:    item.GroupName,
		StudentName:  item.StudentName,
		ColumnKey:    item.ColumnKey,
		RawValue:     item.RawValue,
		NumericValue: item.NumericValue,
		UpdatedBy:    item.UpdatedBy,
		UpdatedAt:    item.UpdatedAt,
	}
}

func mapComputedRowToDomain(model DBJournalComputedRowV2) entity.ComputedRow {
	values := map[string]any{}
	if err := json.Unmarshal([]byte(model.ValuesJSON), &values); err != nil {
		values = map[string]any{}
	}
	return entity.ComputedRow{
		ID:              model.ID,
		GroupName:       model.GroupName,
		StudentName:     model.StudentName,
		PresetVersionID: model.PresetVersionID,
		Values:          values,
		CalculatedAt:    model.CalculatedAt,
	}
}

func mapComputedRowToModel(item entity.ComputedRow) DBJournalComputedRowV2 {
	return DBJournalComputedRowV2{
		ID:              item.ID,
		GroupName:       item.GroupName,
		StudentName:     item.StudentName,
		PresetVersionID: item.PresetVersionID,
		ValuesJSON:      marshalJSON(item.Values, "{}"),
		CalculatedAt:    item.CalculatedAt,
	}
}

func unmarshalPresetDefinition(raw string) entity.PresetDefinition {
	out := entity.PresetDefinition{}
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return entity.PresetDefinition{}
	}
	return out
}

func unmarshalStringSlice(raw string) []string {
	out := []string{}
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return []string{}
	}
	return out
}

func marshalJSON(value any, fallback string) string {
	data, err := json.Marshal(value)
	if err != nil {
		return fallback
	}
	return string(data)
}
