package http

import (
	"errors"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
	"polyapp/server-go/internal/infrastructure/persistence"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"
	"polyapp/server-go/internal/usecase"

	"github.com/gin-gonic/gin"
)

type createPresetV2Payload struct {
	Name        string                  `json:"name"`
	Description string                  `json:"description"`
	Tags        []string                `json:"tags"`
	Visibility  string                  `json:"visibility"`
	Definition  entity.PresetDefinition `json:"definition"`
}

type updatePresetV2Payload struct {
	Name        *string                  `json:"name"`
	Description *string                  `json:"description"`
	Tags        []string                 `json:"tags"`
	Visibility  *string                  `json:"visibility"`
	Definition  *entity.PresetDefinition `json:"definition"`
}

type applyPresetV2Payload struct {
	PresetID uint `json:"preset_id"`
}

type bulkDateCellsV2Payload struct {
	Items []bulkDateCellV2Item `json:"items"`
}

type bulkDateCellV2Item struct {
	ClassDate   string `json:"class_date"`
	LessonSlot  *int   `json:"lesson_slot"`
	StudentName string `json:"student_name"`
	RawValue    string `json:"raw_value"`
}

type bulkManualCellsV2Payload struct {
	Items []bulkManualCellV2Item `json:"items"`
}

type bulkManualCellV2Item struct {
	StudentName string `json:"student_name"`
	ColumnKey   string `json:"column_key"`
	RawValue    string `json:"raw_value"`
}

func (h *Handler) listGradingPresetsV2(c *gin.Context) {
	filter := entity.PresetSearchFilter{
		Query: strings.TrimSpace(c.Query("q")),
		Tag:   strings.TrimSpace(c.Query("tag")),
	}
	if authorRaw := strings.TrimSpace(c.Query("author_id")); authorRaw != "" {
		value, err := strconv.ParseUint(authorRaw, 10, 64)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid author_id"})
			return
		}
		authorID := uint(value)
		filter.AuthorID = &authorID
	}
	if visibilityRaw := strings.TrimSpace(c.Query("visibility")); visibilityRaw != "" {
		value := entity.PresetVisibility(strings.ToLower(visibilityRaw))
		filter.Visibility = &value
	}
	items, err := h.presetUC.List(c.Request.Context(), actorFromContext(c), filter)
	if err != nil {
		writeUseCaseError(c, err, "Failed to list presets")
		return
	}
	out := make([]gin.H, 0, len(items))
	for _, item := range items {
		out = append(out, mapPreset(item, nil))
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) createGradingPresetV2(c *gin.Context) {
	var payload createPresetV2Payload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	preset, version, err := h.presetUC.Create(c.Request.Context(), actorFromContext(c), usecase.CreatePresetInput{
		Name:        payload.Name,
		Description: payload.Description,
		Tags:        payload.Tags,
		Visibility:  entity.PresetVisibility(payload.Visibility),
		Definition:  payload.Definition,
	})
	if err != nil {
		writeUseCaseError(c, err, "Failed to create preset")
		return
	}
	c.JSON(http.StatusOK, mapPreset(*preset, version))
}

func (h *Handler) getGradingPresetV2(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid preset id"})
		return
	}
	preset, version, err := h.presetUC.Get(c.Request.Context(), actorFromContext(c), id)
	if err != nil {
		writeUseCaseError(c, err, "Failed to load preset")
		return
	}
	c.JSON(http.StatusOK, mapPreset(*preset, version))
}

func (h *Handler) updateGradingPresetV2(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid preset id"})
		return
	}
	var payload updatePresetV2Payload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	var vis *entity.PresetVisibility
	if payload.Visibility != nil {
		value := entity.PresetVisibility(strings.ToLower(strings.TrimSpace(*payload.Visibility)))
		vis = &value
	}
	preset, version, err := h.presetUC.Update(c.Request.Context(), actorFromContext(c), id, usecase.UpdatePresetInput{
		Name:        payload.Name,
		Description: payload.Description,
		Tags:        payload.Tags,
		Visibility:  vis,
		Definition:  payload.Definition,
	})
	if err != nil {
		writeUseCaseError(c, err, "Failed to update preset")
		return
	}
	c.JSON(http.StatusOK, mapPreset(*preset, version))
}

func (h *Handler) publishGradingPresetV2(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid preset id"})
		return
	}
	preset, err := h.presetUC.Publish(c.Request.Context(), actorFromContext(c), id, true)
	if err != nil {
		writeUseCaseError(c, err, "Failed to publish preset")
		return
	}
	c.JSON(http.StatusOK, mapPreset(*preset, nil))
}

func (h *Handler) unpublishGradingPresetV2(c *gin.Context) {
	id, err := parseUintParam(c, "id")
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid preset id"})
		return
	}
	preset, err := h.presetUC.Publish(c.Request.Context(), actorFromContext(c), id, false)
	if err != nil {
		writeUseCaseError(c, err, "Failed to unpublish preset")
		return
	}
	c.JSON(http.StatusOK, mapPreset(*preset, nil))
}

func (h *Handler) getGroupPresetBindingV2(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	groupName := strings.TrimSpace(c.Param("group_name"))
	scopedGroupName := scopedJournalGroupNameForUser(user, groupName)
	binding, err := h.journalUC.GetBinding(c.Request.Context(), actorFromContext(c), scopedGroupName)
	if err != nil {
		if err == domainErrors.ErrNotFound {
			c.JSON(http.StatusOK, nil)
			return
		}
		writeUseCaseError(c, err, "Failed to load binding")
		return
	}
	c.JSON(http.StatusOK, mapBinding(*binding))
}

func (h *Handler) applyGroupPresetBindingV2(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	groupName := strings.TrimSpace(c.Param("group_name"))
	scopedGroupName := scopedJournalGroupNameForUser(user, groupName)
	var payload applyPresetV2Payload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	binding, err := h.journalUC.ApplyPreset(c.Request.Context(), actorFromContext(c), scopedGroupName, payload.PresetID)
	if err != nil {
		writeUseCaseError(c, err, "Failed to apply preset")
		return
	}
	c.JSON(http.StatusOK, mapBinding(*binding))
}

func (h *Handler) deleteGroupPresetBindingV2(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	groupName := strings.TrimSpace(c.Param("group_name"))
	scopedGroupName := scopedJournalGroupNameForUser(user, groupName)
	if err := h.journalUC.UnapplyPreset(c.Request.Context(), actorFromContext(c), scopedGroupName); err != nil {
		writeUseCaseError(c, err, "Failed to remove preset binding")
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) getJournalGridV2(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	groupName := strings.TrimSpace(c.Param("group_name"))
	scopedGroupName := scopedJournalGroupNameForUser(user, groupName)
	grid, err := h.journalUC.GetGrid(c.Request.Context(), actorFromContext(c), scopedGroupName)
	if err != nil {
		writeUseCaseError(c, err, "Failed to load journal grid")
		return
	}
	c.JSON(http.StatusOK, mapGrid(*grid))
}

func (h *Handler) bulkUpsertDateCellsV2(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	groupName := strings.TrimSpace(c.Param("group_name"))
	scopedGroupName := scopedJournalGroupNameForUser(user, groupName)
	var payload bulkDateCellsV2Payload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	items := make([]usecase.DateCellUpsertInput, 0, len(payload.Items))
	syncItems := make([]dateCellAttendanceSync, 0, len(payload.Items))
	for _, item := range payload.Items {
		classDate, err := parseDate(item.ClassDate)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid class_date"})
			return
		}
		items = append(items, usecase.DateCellUpsertInput{
			ClassDate:   classDate,
			LessonSlot:  lessonSlotFromPointer(item.LessonSlot),
			StudentName: item.StudentName,
			RawValue:    item.RawValue,
		})
		syncItems = append(syncItems, dateCellAttendanceSync{
			ClassDate:   classDate,
			LessonSlot:  lessonSlotFromPointer(item.LessonSlot),
			StudentName: item.StudentName,
			RawValue:    item.RawValue,
		})
	}
	actor := actorFromContext(c)
	if err := h.journalUC.UpsertDateCells(c.Request.Context(), actor, scopedGroupName, items); err != nil {
		writeUseCaseError(c, err, "Failed to save date cells")
		return
	}
	_ = h.syncDateCellsToAttendance(c.Request.Context(), actor, scopedGroupName, syncItems)
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) listJournalGroupCatalogV2(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	role := strings.ToLower(strings.TrimSpace(user.Role))
	if role == "teacher" {
		scope, err := h.groupScopeForUser(c.Request.Context(), user)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load groups"})
			return
		}
		items := make([]gin.H, 0, len(scope.All))
		for _, group := range scope.asList() {
			items = append(items, gin.H{
				"group_name": group,
				"label":      group,
			})
		}
		c.JSON(http.StatusOK, items)
		return
	}
	if role != "admin" {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
		return
	}

	type item struct {
		GroupName string
		Label     string
	}
	itemsByGroup := map[string]item{}
	teacherNameByID := map[uint]string{}
	resolveTeacherName := func(id uint) string {
		if id == 0 {
			return ""
		}
		if value, ok := teacherNameByID[id]; ok {
			return value
		}
		var user persistence.DBUser
		if err := h.db.WithContext(c.Request.Context()).
			Select("id", "full_name", "teacher_name").
			First(&user, id).Error; err == nil {
			name := strings.TrimSpace(user.TeacherName)
			if name == "" {
				name = strings.TrimSpace(user.FullName)
			}
			teacherNameByID[id] = name
			return name
		}
		return ""
	}
	add := func(groupName string) {
		groupName = strings.TrimSpace(groupName)
		if groupName == "" {
			return
		}
		base := baseJournalGroupName(groupName)
		label := base
		if teacherID, ok := teacherIDFromScopedJournalGroupName(groupName); ok {
			teacherName := resolveTeacherName(teacherID)
			if teacherName == "" {
				teacherName = "#" + strconv.FormatUint(uint64(teacherID), 10)
			}
			label = base + " - " + teacherName
		}
		itemsByGroup[groupName] = item{GroupName: groupName, Label: label}
	}

	var assignments []persistence.DBTeacherGroupAssignment
	if err := h.db.WithContext(c.Request.Context()).
		Find(&assignments).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load groups"})
		return
	}
	for _, row := range assignments {
		scoped := scopedJournalGroupNameForUser(&entity.User{ID: row.TeacherID, Role: "teacher"}, row.GroupName)
		add(scoped)
	}

	var rawGroups []string
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBJournalGroup{}).
		Distinct("name").
		Pluck("name", &rawGroups).Error; err == nil {
		for _, group := range rawGroups {
			add(group)
		}
	}
	rawGroups = rawGroups[:0]
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBJournalStudent{}).
		Distinct("group_name").
		Pluck("group_name", &rawGroups).Error; err == nil {
		for _, group := range rawGroups {
			add(group)
		}
	}
	rawGroups = rawGroups[:0]
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBJournalDate{}).
		Distinct("group_name").
		Pluck("group_name", &rawGroups).Error; err == nil {
		for _, group := range rawGroups {
			add(group)
		}
	}
	rawGroups = rawGroups[:0]
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBJournalDateCellV2{}).
		Distinct("group_name").
		Pluck("group_name", &rawGroups).Error; err == nil {
		for _, group := range rawGroups {
			add(group)
		}
	}
	rawGroups = rawGroups[:0]
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBJournalManualCellV2{}).
		Distinct("group_name").
		Pluck("group_name", &rawGroups).Error; err == nil {
		for _, group := range rawGroups {
			add(group)
		}
	}
	rawGroups = rawGroups[:0]
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBJournalComputedRowV2{}).
		Distinct("group_name").
		Pluck("group_name", &rawGroups).Error; err == nil {
		for _, group := range rawGroups {
			add(group)
		}
	}
	rawGroups = rawGroups[:0]
	if err := h.db.WithContext(c.Request.Context()).
		Model(&persistence.DBGroupPresetBinding{}).
		Distinct("group_name").
		Pluck("group_name", &rawGroups).Error; err == nil {
		for _, group := range rawGroups {
			add(group)
		}
	}

	out := make([]item, 0, len(itemsByGroup))
	for _, item := range itemsByGroup {
		out = append(out, item)
	}
	sort.Slice(out, func(i, j int) bool {
		li := strings.ToLower(out[i].Label)
		lj := strings.ToLower(out[j].Label)
		if li == lj {
			return out[i].GroupName < out[j].GroupName
		}
		return li < lj
	})
	response := make([]gin.H, 0, len(out))
	for _, row := range out {
		response = append(response, gin.H{
			"group_name": row.GroupName,
			"label":      row.Label,
		})
	}
	c.JSON(http.StatusOK, response)
}

func (h *Handler) bulkDeleteDateCellsV2(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	groupName := strings.TrimSpace(c.Param("group_name"))
	scopedGroupName := scopedJournalGroupNameForUser(user, groupName)
	var payload bulkDateCellsV2Payload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	items := make([]usecase.DateCellUpsertInput, 0, len(payload.Items))
	for _, item := range payload.Items {
		classDate, err := parseDate(item.ClassDate)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid class_date"})
			return
		}
		items = append(items, usecase.DateCellUpsertInput{
			ClassDate:   classDate,
			LessonSlot:  lessonSlotFromPointer(item.LessonSlot),
			StudentName: item.StudentName,
		})
	}
	if err := h.journalUC.DeleteDateCells(c.Request.Context(), actorFromContext(c), scopedGroupName, items); err != nil {
		writeUseCaseError(c, err, "Failed to delete date cells")
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) bulkUpsertManualCellsV2(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	groupName := strings.TrimSpace(c.Param("group_name"))
	scopedGroupName := scopedJournalGroupNameForUser(user, groupName)
	var payload bulkManualCellsV2Payload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	items := make([]usecase.ManualCellUpsertInput, 0, len(payload.Items))
	for _, item := range payload.Items {
		items = append(items, usecase.ManualCellUpsertInput{
			StudentName: item.StudentName,
			ColumnKey:   item.ColumnKey,
			RawValue:    item.RawValue,
		})
	}
	if err := h.journalUC.UpsertManualCells(c.Request.Context(), actorFromContext(c), scopedGroupName, items); err != nil {
		writeUseCaseError(c, err, "Failed to save manual cells")
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) recalculateJournalV2(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	groupName := strings.TrimSpace(c.Param("group_name"))
	scopedGroupName := scopedJournalGroupNameForUser(user, groupName)
	if err := h.journalUC.Recalculate(c.Request.Context(), actorFromContext(c), scopedGroupName); err != nil {
		writeUseCaseError(c, err, "Failed to recalculate")
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func actorFromContext(c *gin.Context) usecase.Actor {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		return usecase.Actor{}
	}
	return usecase.Actor{
		UserID:       user.ID,
		Role:         user.Role,
		StudentGroup: user.StudentGroup,
	}
}

func mapPreset(preset entity.GradingPreset, version *entity.GradingPresetVersion) gin.H {
	out := gin.H{
		"id":          preset.ID,
		"owner_id":    preset.OwnerID,
		"name":        preset.Name,
		"description": nullOrString(preset.Description),
		"tags":        preset.Tags,
		"visibility":  string(preset.Visibility),
		"created_at":  preset.CreatedAt.Format(time.RFC3339),
		"updated_at":  preset.UpdatedAt.Format(time.RFC3339),
	}
	if preset.ArchivedAt != nil {
		out["archived_at"] = preset.ArchivedAt.Format(time.RFC3339)
	} else {
		out["archived_at"] = nil
	}
	if version != nil {
		out["current_version"] = mapPresetVersion(*version)
	}
	return out
}

func mapPresetVersion(version entity.GradingPresetVersion) gin.H {
	return gin.H{
		"id":         version.ID,
		"preset_id":  version.PresetID,
		"version":    version.Version,
		"created_by": version.CreatedBy,
		"created_at": version.CreatedAt.Format(time.RFC3339),
		"definition": version.Definition,
	}
}

func mapBinding(binding entity.GroupPresetBinding) gin.H {
	return gin.H{
		"id":                binding.ID,
		"group_name":        baseJournalGroupName(binding.GroupName),
		"preset_id":         binding.PresetID,
		"preset_version_id": binding.PresetVersionID,
		"auto_update":       binding.AutoUpdate,
		"applied_by":        binding.AppliedBy,
		"applied_at":        binding.AppliedAt.Format(time.RFC3339),
		"updated_at":        binding.UpdatedAt.Format(time.RFC3339),
	}
}

func mapGrid(grid entity.JournalGrid) gin.H {
	dates := make([]gin.H, 0, len(grid.Dates))
	for _, date := range grid.Dates {
		dates = append(dates, gin.H{
			"class_date":  dateOnly(date.ClassDate),
			"lesson_slot": normalizeLessonSlot(date.LessonSlot),
		})
	}
	dateCells := make([]gin.H, 0, len(grid.DateCells))
	for _, item := range grid.DateCells {
		dateCells = append(dateCells, mapDateCell(item))
	}
	manualCells := make([]gin.H, 0, len(grid.ManualCells))
	for _, item := range grid.ManualCells {
		manualCells = append(manualCells, mapManualCell(item))
	}
	computedRows := make([]gin.H, 0, len(grid.Computed))
	for _, item := range grid.Computed {
		computedRows = append(computedRows, mapComputedRow(item))
	}

	out := gin.H{
		"group_name":     baseJournalGroupName(grid.GroupName),
		"students":       grid.Students,
		"dates":          dates,
		"date_cells":     dateCells,
		"manual_cells":   manualCells,
		"computed_cells": computedRows,
		"sync_state":     grid.SyncState,
		"binding":        nil,
		"preset":         nil,
		"preset_version": nil,
	}
	if grid.Binding != nil {
		out["binding"] = mapBinding(*grid.Binding)
	}
	if grid.Preset != nil {
		out["preset"] = mapPreset(*grid.Preset, nil)
	}
	if grid.Version != nil {
		out["preset_version"] = mapPresetVersion(*grid.Version)
	}
	return out
}

func mapDateCell(item entity.JournalCell) gin.H {
	out := gin.H{
		"id":            item.ID,
		"group_name":    baseJournalGroupName(item.GroupName),
		"class_date":    dateOnly(item.ClassDate),
		"lesson_slot":   normalizeLessonSlot(item.LessonSlot),
		"student_name":  item.StudentName,
		"raw_value":     item.RawValue,
		"status_code":   nullOrString(item.StatusCode),
		"updated_by":    item.UpdatedBy,
		"updated_at":    item.UpdatedAt.Format(time.RFC3339),
		"numeric_value": nil,
	}
	if item.NumericValue != nil {
		out["numeric_value"] = *item.NumericValue
	}
	return out
}

func mapManualCell(item entity.ManualCell) gin.H {
	out := gin.H{
		"id":            item.ID,
		"group_name":    baseJournalGroupName(item.GroupName),
		"student_name":  item.StudentName,
		"column_key":    item.ColumnKey,
		"raw_value":     item.RawValue,
		"updated_by":    item.UpdatedBy,
		"updated_at":    item.UpdatedAt.Format(time.RFC3339),
		"numeric_value": nil,
	}
	if item.NumericValue != nil {
		out["numeric_value"] = *item.NumericValue
	}
	return out
}

func mapComputedRow(item entity.ComputedRow) gin.H {
	return gin.H{
		"id":                item.ID,
		"group_name":        baseJournalGroupName(item.GroupName),
		"student_name":      item.StudentName,
		"preset_version_id": item.PresetVersionID,
		"values":            item.Values,
		"calculated_at":     item.CalculatedAt.Format(time.RFC3339),
	}
}

func writeUseCaseError(c *gin.Context, err error, fallback string) {
	switch {
	case err == nil:
		return
	case errors.Is(err, domainErrors.ErrInvalidInput):
		c.JSON(http.StatusBadRequest, gin.H{"detail": err.Error()})
	case errors.Is(err, domainErrors.ErrForbidden):
		c.JSON(http.StatusForbidden, gin.H{"detail": "Forbidden"})
	case errors.Is(err, domainErrors.ErrNotFound):
		c.JSON(http.StatusNotFound, gin.H{"detail": "Not found"})
	default:
		c.JSON(http.StatusInternalServerError, gin.H{"detail": fallback})
	}
}
