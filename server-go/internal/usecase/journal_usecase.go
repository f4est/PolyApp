package usecase

import (
	"context"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
	"polyapp/server-go/internal/domain/repository"
)

type JournalUseCase struct {
	journalRepo repository.JournalRepository
	presetRepo  repository.GradingPresetRepository
	engine      *FormulaEngineUseCase
	now         func() time.Time
}

func NewJournalUseCase(
	journalRepo repository.JournalRepository,
	presetRepo repository.GradingPresetRepository,
	engine *FormulaEngineUseCase,
) *JournalUseCase {
	return &JournalUseCase{
		journalRepo: journalRepo,
		presetRepo:  presetRepo,
		engine:      engine,
		now:         time.Now,
	}
}

type DateCellUpsertInput struct {
	ClassDate   time.Time
	StudentName string
	RawValue    string
}

type ManualCellUpsertInput struct {
	StudentName string
	ColumnKey   string
	RawValue    string
}

func (u *JournalUseCase) GetBinding(ctx context.Context, actor Actor, groupName string) (*entity.GroupPresetBinding, error) {
	if strings.TrimSpace(groupName) == "" {
		return nil, domainErrors.ErrInvalidInput
	}
	if err := u.ensureCanReadGroup(ctx, actor, groupName); err != nil {
		return nil, err
	}
	return u.journalRepo.GetGroupPresetBinding(ctx, groupName)
}

func (u *JournalUseCase) ApplyPreset(ctx context.Context, actor Actor, groupName string, presetID uint) (*entity.GroupPresetBinding, error) {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" || presetID == 0 {
		return nil, domainErrors.ErrInvalidInput
	}
	if err := u.ensureCanManageGroup(ctx, actor, groupName); err != nil {
		return nil, err
	}

	preset, err := u.presetRepo.GetPresetByID(ctx, presetID)
	if err != nil {
		return nil, err
	}
	if err := ensurePresetReadPermission(actor, preset); err != nil {
		return nil, err
	}
	version, err := u.presetRepo.GetLatestPresetVersion(ctx, presetID)
	if err != nil {
		return nil, err
	}
	if _, _, err := u.engine.ValidateDefinition(version.Definition); err != nil {
		return nil, err
	}

	binding := &entity.GroupPresetBinding{
		GroupName:       groupName,
		PresetID:        presetID,
		PresetVersionID: version.ID,
		AutoUpdate:      true,
		AppliedBy:       actor.UserID,
		AppliedAt:       u.now().UTC(),
		UpdatedAt:       u.now().UTC(),
	}
	if err := u.journalRepo.UpsertGroupPresetBinding(ctx, binding); err != nil {
		return nil, err
	}
	if err := u.Recalculate(ctx, actor, groupName); err != nil {
		return nil, err
	}
	return binding, nil
}

func (u *JournalUseCase) UnapplyPreset(ctx context.Context, actor Actor, groupName string) error {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" {
		return domainErrors.ErrInvalidInput
	}
	if err := u.ensureCanManageGroup(ctx, actor, groupName); err != nil {
		return err
	}
	return u.journalRepo.DeleteGroupPresetBinding(ctx, groupName)
}

func (u *JournalUseCase) GetGrid(ctx context.Context, actor Actor, groupName string) (*entity.JournalGrid, error) {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" {
		return nil, domainErrors.ErrInvalidInput
	}
	if err := u.ensureCanReadGroup(ctx, actor, groupName); err != nil {
		return nil, err
	}

	binding, err := u.journalRepo.GetGroupPresetBinding(ctx, groupName)
	if err != nil && err != domainErrors.ErrNotFound {
		return nil, err
	}
	if err == domainErrors.ErrNotFound {
		binding = nil
	}

	students, err := u.journalRepo.ListJournalStudents(ctx, groupName)
	if err != nil {
		return nil, err
	}
	dates, err := u.journalRepo.ListJournalDates(ctx, groupName)
	if err != nil {
		return nil, err
	}
	dateCells, err := u.journalRepo.ListDateCells(ctx, groupName)
	if err != nil {
		return nil, err
	}
	manualCells, err := u.journalRepo.ListManualCells(ctx, groupName)
	if err != nil {
		return nil, err
	}
	computedRows, err := u.journalRepo.ListComputedRows(ctx, groupName)
	if err != nil {
		return nil, err
	}

	grid := &entity.JournalGrid{
		GroupName:   groupName,
		Students:    students,
		Dates:       dates,
		DateCells:   dateCells,
		ManualCells: manualCells,
		Computed:    computedRows,
		Binding:     binding,
		SyncState:   "authoritative",
	}
	if binding != nil {
		preset, err := u.presetRepo.GetPresetByID(ctx, binding.PresetID)
		if err != nil {
			return nil, err
		}
		version, err := u.presetRepo.GetPresetVersionByID(ctx, binding.PresetVersionID)
		if err != nil {
			return nil, err
		}
		asts, _, err := u.engine.ValidateDefinition(version.Definition)
		if err != nil {
			return nil, err
		}
		version.DefinitionAST = asts
		grid.Preset = preset
		grid.Version = version
	}
	return grid, nil
}

func (u *JournalUseCase) UpsertDateCells(ctx context.Context, actor Actor, groupName string, input []DateCellUpsertInput) error {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" {
		return domainErrors.ErrInvalidInput
	}
	if err := u.ensureCanManageGroup(ctx, actor, groupName); err != nil {
		return err
	}

	binding, err := u.journalRepo.GetGroupPresetBinding(ctx, groupName)
	if err != nil && err != domainErrors.ErrNotFound {
		return err
	}
	statusRules := map[string]entity.StatusCodeRule{}
	if binding != nil && binding.PresetID != 0 {
		version, err := u.presetRepo.GetPresetVersionByID(ctx, binding.PresetVersionID)
		if err != nil {
			return err
		}
		for _, rule := range version.Definition.StatusCodes {
			statusRules[normalizeStatusCodeToken(rule.Code)] = rule
		}
	}

	cells := make([]entity.JournalCell, 0, len(input))
	for _, item := range input {
		student := strings.TrimSpace(item.StudentName)
		if student == "" {
			return domainErrors.ErrInvalidInput
		}
		dateOnly := normalizeDate(item.ClassDate)
		raw, numeric, status, err := normalizeRawValue(item.RawValue, statusRules, true)
		if err != nil {
			return err
		}
		cells = append(cells, entity.JournalCell{
			GroupName:    groupName,
			ClassDate:    dateOnly,
			StudentName:  student,
			RawValue:     raw,
			NumericValue: numeric,
			StatusCode:   status,
			UpdatedBy:    actor.UserID,
			UpdatedAt:    u.now().UTC(),
		})
	}
	if len(cells) > 0 {
		if err := u.journalRepo.UpsertDateCells(ctx, cells); err != nil {
			return err
		}
	}
	return u.Recalculate(ctx, actor, groupName)
}

func (u *JournalUseCase) DeleteDateCells(ctx context.Context, actor Actor, groupName string, input []DateCellUpsertInput) error {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" {
		return domainErrors.ErrInvalidInput
	}
	if err := u.ensureCanManageGroup(ctx, actor, groupName); err != nil {
		return err
	}
	cells := make([]entity.JournalCell, 0, len(input))
	for _, item := range input {
		student := strings.TrimSpace(item.StudentName)
		if student == "" {
			return domainErrors.ErrInvalidInput
		}
		cells = append(cells, entity.JournalCell{
			GroupName:   groupName,
			ClassDate:   normalizeDate(item.ClassDate),
			StudentName: student,
		})
	}
	if len(cells) == 0 {
		return nil
	}
	if err := u.journalRepo.DeleteDateCells(ctx, groupName, cells); err != nil {
		return err
	}
	return u.Recalculate(ctx, actor, groupName)
}

func (u *JournalUseCase) UpsertManualCells(ctx context.Context, actor Actor, groupName string, input []ManualCellUpsertInput) error {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" {
		return domainErrors.ErrInvalidInput
	}
	if err := u.ensureCanManageGroup(ctx, actor, groupName); err != nil {
		return err
	}

	binding, err := u.journalRepo.GetGroupPresetBinding(ctx, groupName)
	if err != nil {
		return err
	}
	version, err := u.presetRepo.GetPresetVersionByID(ctx, binding.PresetVersionID)
	if err != nil {
		return err
	}
	statusRules := map[string]entity.StatusCodeRule{}
	for _, rule := range version.Definition.StatusCodes {
		statusRules[normalizeStatusCodeToken(rule.Code)] = rule
	}

	manualColumns := map[string]entity.PresetColumn{}
	for _, col := range version.Definition.Columns {
		if col.Kind == entity.PresetColumnTypeManual {
			manualColumns[col.Key] = col
		}
	}

	cells := make([]entity.ManualCell, 0, len(input))
	for _, item := range input {
		student := strings.TrimSpace(item.StudentName)
		key := strings.TrimSpace(item.ColumnKey)
		if student == "" || key == "" {
			return domainErrors.ErrInvalidInput
		}
		if _, ok := manualColumns[key]; !ok {
			return fmt.Errorf("%w: unknown manual column %s", domainErrors.ErrInvalidInput, key)
		}
		raw, numeric, _, err := normalizeRawValue(item.RawValue, statusRules, false)
		if err != nil {
			return err
		}
		cells = append(cells, entity.ManualCell{
			GroupName:    groupName,
			StudentName:  student,
			ColumnKey:    key,
			RawValue:     raw,
			NumericValue: numeric,
			UpdatedBy:    actor.UserID,
			UpdatedAt:    u.now().UTC(),
		})
	}
	if len(cells) > 0 {
		if err := u.journalRepo.UpsertManualCells(ctx, cells); err != nil {
			return err
		}
	}
	return u.Recalculate(ctx, actor, groupName)
}

func (u *JournalUseCase) Recalculate(ctx context.Context, actor Actor, groupName string) error {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" {
		return domainErrors.ErrInvalidInput
	}
	if err := u.ensureCanManageGroup(ctx, actor, groupName); err != nil {
		return err
	}

	binding, err := u.journalRepo.GetGroupPresetBinding(ctx, groupName)
	if err != nil {
		if err == domainErrors.ErrNotFound {
			return nil
		}
		return err
	}

	version, err := u.presetRepo.GetPresetVersionByID(ctx, binding.PresetVersionID)
	if err != nil {
		return err
	}
	asts, order, err := u.engine.ValidateDefinition(version.Definition)
	if err != nil {
		return err
	}

	students, err := u.journalRepo.ListJournalStudents(ctx, groupName)
	if err != nil {
		return err
	}
	sort.Strings(students)
	dateCells, err := u.journalRepo.ListDateCells(ctx, groupName)
	if err != nil {
		return err
	}
	manualCells, err := u.journalRepo.ListManualCells(ctx, groupName)
	if err != nil {
		return err
	}
	statusRules := map[string]entity.StatusCodeRule{}
	statusRefs := map[string]string{}
	for _, rule := range version.Definition.StatusCodes {
		code := normalizeStatusCodeToken(rule.Code)
		if code == "" {
			continue
		}
		statusRules[code] = rule
		statusRefs[code] = strings.ToUpper(statusCounterSuffix(rule))
	}

	manualByStudent := map[string]map[string]entity.ManualCell{}
	for _, item := range manualCells {
		if _, ok := manualByStudent[item.StudentName]; !ok {
			manualByStudent[item.StudentName] = map[string]entity.ManualCell{}
		}
		manualByStudent[item.StudentName][item.ColumnKey] = item
	}

	datesByStudent := map[string][]entity.JournalCell{}
	for _, cell := range dateCells {
		datesByStudent[cell.StudentName] = append(datesByStudent[cell.StudentName], cell)
	}

	groupCodeCounts := map[string]float64{}
	missCount := 0.0
	for _, suffix := range statusRefs {
		groupCodeCounts[suffix] = 0
	}
	for _, item := range dateCells {
		code := statusCodeFromRaw(item.RawValue, statusRules)
		if code == "" {
			continue
		}
		rule, ok := statusRules[code]
		if !ok {
			continue
		}
		if rule.CountsAsMiss {
			missCount += 1
		}
		if !rule.CountsInStats {
			continue
		}
		suffix := statusRefs[code]
		groupCodeCounts[suffix] = groupCodeCounts[suffix] + 1
	}
	for _, item := range manualCells {
		code := statusCodeFromRaw(item.RawValue, statusRules)
		if code == "" {
			continue
		}
		rule, ok := statusRules[code]
		if !ok {
			continue
		}
		if rule.CountsAsMiss {
			missCount += 1
		}
		if !rule.CountsInStats {
			continue
		}
		suffix := statusRefs[code]
		groupCodeCounts[suffix] = groupCodeCounts[suffix] + 1
	}

	computedRows := make([]entity.ComputedRow, 0, len(students))
	for _, student := range students {
		contextValues := map[string]any{}

		for _, variable := range version.Definition.Variables {
			contextValues[variable.Key] = variable.DefaultValue
		}
		for suffix, count := range groupCodeCounts {
			contextValues["CODE_COUNT_"+suffix] = count
			contextValues["STATUS_COUNT_"+suffix] = count
		}
		contextValues["MISS_COUNT"] = missCount
		studentCodeCounts := map[string]float64{}
		studentMissCount := 0.0
		for _, suffix := range statusRefs {
			studentCodeCounts[suffix] = 0
		}
		for _, item := range datesByStudent[student] {
			code := statusCodeFromRaw(item.RawValue, statusRules)
			if code == "" {
				continue
			}
			rule, ok := statusRules[code]
			if !ok {
				continue
			}
			if rule.CountsAsMiss {
				studentMissCount += 1
			}
			if !rule.CountsInStats {
				continue
			}
			suffix := statusRefs[code]
			studentCodeCounts[suffix] = studentCodeCounts[suffix] + 1
		}
		for _, item := range manualByStudent[student] {
			code := statusCodeFromRaw(item.RawValue, statusRules)
			if code == "" {
				continue
			}
			rule, ok := statusRules[code]
			if !ok {
				continue
			}
			if rule.CountsAsMiss {
				studentMissCount += 1
			}
			if !rule.CountsInStats {
				continue
			}
			suffix := statusRefs[code]
			studentCodeCounts[suffix] = studentCodeCounts[suffix] + 1
		}
		for suffix, count := range studentCodeCounts {
			contextValues["STUDENT_CODE_COUNT_"+suffix] = count
		}
		contextValues["STUDENT_MISS_COUNT"] = studentMissCount

		for _, col := range version.Definition.Columns {
			if col.Kind != entity.PresetColumnTypeManual {
				continue
			}
			manual := manualByStudent[student][col.Key]
			value := any(manual.RawValue)
			if manual.NumericValue != nil {
				value = *manual.NumericValue
			}
			if manual.RawValue == "" {
				value = 0.0
			}
			contextValues[col.Key] = castValueType(value, col.Type)
		}

		dateValues := datesByStudent[student]
		dateSum := 0.0
		dateCount := 0.0
		dateMin := 0.0
		dateMax := 0.0
		seenNumeric := false
		for _, item := range dateValues {
			if item.NumericValue != nil {
				number := *item.NumericValue
				dateSum += number
				dateCount += 1
				if !seenNumeric {
					dateMin = number
					dateMax = number
					seenNumeric = true
				} else {
					if number < dateMin {
						dateMin = number
					}
					if number > dateMax {
						dateMax = number
					}
				}
			}
			key := fmt.Sprintf("DATE_%04d_%02d_%02d", item.ClassDate.Year(), item.ClassDate.Month(), item.ClassDate.Day())
			if item.NumericValue != nil {
				contextValues[key] = *item.NumericValue
			} else {
				contextValues[key] = item.RawValue
			}
		}
		contextValues["DATE_SUM"] = dateSum
		contextValues["DATE_COUNT"] = dateCount
		if dateCount > 0 {
			contextValues["DATE_AVG"] = dateSum / dateCount
		} else {
			contextValues["DATE_AVG"] = 0.0
		}
		if seenNumeric {
			contextValues["DATE_MIN"] = dateMin
			contextValues["DATE_MAX"] = dateMax
		} else {
			contextValues["DATE_MIN"] = 0.0
			contextValues["DATE_MAX"] = 0.0
		}

		computedValues, err := u.engine.EvaluateComputedColumns(version.Definition, asts, order, contextValues)
		if err != nil {
			return err
		}

		computedRows = append(computedRows, entity.ComputedRow{
			GroupName:       groupName,
			StudentName:     student,
			PresetVersionID: version.ID,
			Values:          computedValues,
			CalculatedAt:    u.now().UTC(),
		})
	}
	if len(computedRows) == 0 {
		return nil
	}
	return u.journalRepo.UpsertComputedRows(ctx, computedRows)
}

func (u *JournalUseCase) ensureCanManageGroup(ctx context.Context, actor Actor, groupName string) error {
	if actor.IsAdmin() {
		return nil
	}
	if !actor.IsTeacher() {
		return domainErrors.ErrForbidden
	}
	assigned, err := u.journalRepo.IsTeacherAssignedToGroup(ctx, actor.UserID, groupName)
	if err != nil {
		return err
	}
	if !assigned {
		return domainErrors.ErrForbidden
	}
	return nil
}

func (u *JournalUseCase) ensureCanReadGroup(ctx context.Context, actor Actor, groupName string) error {
	if actor.IsAdmin() {
		return nil
	}
	if actor.IsTeacher() {
		assigned, err := u.journalRepo.IsTeacherAssignedToGroup(ctx, actor.UserID, groupName)
		if err != nil {
			return err
		}
		if !assigned {
			return domainErrors.ErrForbidden
		}
		return nil
	}
	role := strings.ToLower(strings.TrimSpace(actor.Role))
	if role == "student" || role == "parent" {
		if strings.TrimSpace(actor.StudentGroup) == strings.TrimSpace(groupName) {
			return nil
		}
		return domainErrors.ErrForbidden
	}
	return domainErrors.ErrForbidden
}

func normalizeDate(value time.Time) time.Time {
	utc := value.UTC()
	return time.Date(utc.Year(), utc.Month(), utc.Day(), 0, 0, 0, 0, time.UTC)
}

func normalizeRawValue(
	raw string,
	status map[string]entity.StatusCodeRule,
	enforceGradeRange bool,
) (string, *float64, string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", nil, "", nil
	}
	if number, err := strconvToFloat(trimmed); err == nil {
		if enforceGradeRange && (number < 0 || number > 100) {
			return "", nil, "", fmt.Errorf("%w: value must be in range 0..100", domainErrors.ErrInvalidInput)
		}
		return trimmed, &number, "", nil
	}
	key, rule, ok := resolveStatusCode(status, trimmed)
	if !ok {
		allowed := allowedStatusCodes(status)
		if len(allowed) == 0 {
			return "", nil, "", fmt.Errorf("%w: only numeric values are allowed", domainErrors.ErrInvalidInput)
		}
		return "", nil, "", fmt.Errorf(
			"%w: unknown status code %q (allowed: %s)",
			domainErrors.ErrInvalidInput,
			trimmed,
			strings.Join(allowed, ", "),
		)
	}
	if rule.NumericValue != nil {
		copyValue := *rule.NumericValue
		if enforceGradeRange && (copyValue < 0 || copyValue > 100) {
			return "", nil, "", fmt.Errorf("%w: value must be in range 0..100", domainErrors.ErrInvalidInput)
		}
		return trimmed, &copyValue, key, nil
	}
	return trimmed, nil, key, nil
}

func strconvToFloat(value string) (float64, error) {
	value = strings.ReplaceAll(strings.TrimSpace(value), ",", ".")
	return strconv.ParseFloat(value, 64)
}

func allowedStatusCodes(status map[string]entity.StatusCodeRule) []string {
	if len(status) == 0 {
		return nil
	}
	out := make([]string, 0, len(status))
	for _, item := range status {
		code := strings.TrimSpace(item.Code)
		if code == "" {
			continue
		}
		out = append(out, code)
	}
	sort.Strings(out)
	return out
}

func statusCodeFromRaw(raw string, status map[string]entity.StatusCodeRule) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	if _, err := strconvToFloat(trimmed); err == nil {
		return ""
	}
	key, _, ok := resolveStatusCode(status, trimmed)
	if !ok {
		return ""
	}
	return key
}

func statusCodeRefSuffix(code string) string {
	code = strings.ToUpper(strings.TrimSpace(code))
	if code == "" {
		return "CODE"
	}
	var b strings.Builder
	lastUnderscore := false
	for _, r := range code {
		if unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' {
			b.WriteRune(r)
			lastUnderscore = false
			continue
		}
		if !lastUnderscore {
			b.WriteRune('_')
			lastUnderscore = true
		}
	}
	out := strings.Trim(b.String(), "_")
	if out == "" {
		return "CODE"
	}
	return out
}

func normalizeStatusCodeToken(value string) string {
	return strings.ToUpper(strings.TrimSpace(value))
}

func resolveStatusCode(
	status map[string]entity.StatusCodeRule,
	raw string,
) (string, entity.StatusCodeRule, bool) {
	normalized := normalizeStatusCodeToken(raw)
	if rule, ok := status[normalized]; ok {
		return normalized, rule, true
	}
	trimmed := strings.TrimSpace(raw)
	for key, rule := range status {
		if strings.EqualFold(strings.TrimSpace(key), trimmed) {
			return normalizeStatusCodeToken(key), rule, true
		}
		if strings.EqualFold(strings.TrimSpace(rule.Code), trimmed) {
			return normalizeStatusCodeToken(rule.Code), rule, true
		}
	}
	return "", entity.StatusCodeRule{}, false
}
