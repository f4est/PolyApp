package http

import (
	"context"
	"errors"
	"sort"
	"strings"

	"polyapp/server-go/internal/domain/entity"
	"polyapp/server-go/internal/infrastructure/persistence"

	"gorm.io/gorm"
)

type groupAccessScope struct {
	Teaching   map[string]struct{}
	Curator    map[string]struct{}
	Department map[string]struct{}
	All        map[string]struct{}
}

func newGroupAccessScope() groupAccessScope {
	return groupAccessScope{
		Teaching:   map[string]struct{}{},
		Curator:    map[string]struct{}{},
		Department: map[string]struct{}{},
		All:        map[string]struct{}{},
	}
}

func normalizeGroupName(value string) string {
	return strings.TrimSpace(value)
}

func groupsMatch(accessGroup, requestedGroup string) bool {
	a := normalizeGroupName(accessGroup)
	b := normalizeGroupName(requestedGroup)
	if a == "" || b == "" {
		return false
	}
	if strings.EqualFold(a, b) {
		return true
	}
	return groupIncludesToken(a, b) || groupIncludesToken(b, a)
}

func mapHasGroup(groups map[string]struct{}, target string) bool {
	for group := range groups {
		if groupsMatch(group, target) {
			return true
		}
	}
	return false
}

func (s *groupAccessScope) addTeaching(group string) {
	group = normalizeGroupName(group)
	if group == "" {
		return
	}
	s.Teaching[group] = struct{}{}
	s.All[group] = struct{}{}
}

func (s *groupAccessScope) addCurator(group string) {
	group = normalizeGroupName(group)
	if group == "" {
		return
	}
	s.Curator[group] = struct{}{}
	s.All[group] = struct{}{}
}

func (s *groupAccessScope) addDepartment(group string) {
	group = normalizeGroupName(group)
	if group == "" {
		return
	}
	s.Department[group] = struct{}{}
	s.All[group] = struct{}{}
}

func (s groupAccessScope) canView(group string) bool {
	group = normalizeGroupName(group)
	if group == "" {
		return false
	}
	return mapHasGroup(s.All, group)
}

func (s groupAccessScope) canEditAttendance(group string) bool {
	group = normalizeGroupName(group)
	if group == "" {
		return false
	}
	if mapHasGroup(s.Teaching, group) {
		return true
	}
	if mapHasGroup(s.Curator, group) {
		return true
	}
	if mapHasGroup(s.Department, group) {
		return true
	}
	return false
}

func (s groupAccessScope) canEditGrades(group string) bool {
	group = normalizeGroupName(group)
	if group == "" {
		return false
	}
	return mapHasGroup(s.Teaching, group)
}

func (s groupAccessScope) asList() []string {
	out := make([]string, 0, len(s.All))
	for key := range s.All {
		out = append(out, key)
	}
	sort.Strings(out)
	return out
}

func (h *Handler) groupScopeForUser(ctx context.Context, user *entity.User) (groupAccessScope, error) {
	scope := newGroupAccessScope()
	if user == nil {
		return scope, nil
	}
	if user.Role == "admin" {
		var groups []string
		if err := h.db.WithContext(ctx).
			Model(&persistence.DBJournalGroup{}).
			Pluck("name", &groups).Error; err != nil {
			return scope, err
		}
		for _, group := range groups {
			scope.addTeaching(group)
		}
		return scope, nil
	}

	var deptIDs []uint
	if err := h.db.WithContext(ctx).
		Model(&persistence.DBDepartment{}).
		Where("head_user_id = ?", user.ID).
		Pluck("id", &deptIDs).Error; err != nil {
		return scope, err
	}
	var departmentGroups []string
	if len(deptIDs) > 0 {
		if err := h.db.WithContext(ctx).
			Model(&persistence.DBDepartmentGroup{}).
			Where("department_id IN ?", deptIDs).
			Distinct("group_name").
			Pluck("group_name", &departmentGroups).Error; err != nil {
			return scope, err
		}
	}
	for _, group := range departmentGroups {
		scope.addDepartment(group)
	}
	if len(deptIDs) > 0 {
		return scope, nil
	}

	var teaching []string
	if err := h.db.WithContext(ctx).
		Model(&persistence.DBTeacherGroupAssignment{}).
		Where("teacher_id = ?", user.ID).
		Distinct("group_name").
		Pluck("group_name", &teaching).Error; err != nil {
		return scope, err
	}
	for _, group := range teaching {
		scope.addTeaching(group)
	}

	var curated []string
	if err := h.db.WithContext(ctx).
		Model(&persistence.DBCuratorGroupAssignment{}).
		Where("curator_id = ?", user.ID).
		Distinct("group_name").
		Pluck("group_name", &curated).Error; err != nil {
		return scope, err
	}
	for _, group := range curated {
		scope.addCurator(group)
	}

	teacherNames := map[string]struct{}{}
	for _, value := range []string{user.TeacherName, user.FullName} {
		name := strings.TrimSpace(value)
		if name == "" {
			continue
		}
		teacherNames[strings.ToLower(name)] = struct{}{}
	}
	for lowerName := range teacherNames {
		var scheduled []string
		if err := h.db.WithContext(ctx).
			Model(&persistence.DBScheduleLesson{}).
			Where("lower(teacher_name) = ?", lowerName).
			Distinct("group_name").
			Pluck("group_name", &scheduled).Error; err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return scope, err
		}
		for _, group := range scheduled {
			scope.addTeaching(group)
		}
	}

	return scope, nil
}
