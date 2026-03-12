package http

import (
	"context"
	"sort"
	"strings"

	"polyapp/server-go/internal/domain/entity"
	"polyapp/server-go/internal/infrastructure/persistence"
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
	_, ok := s.All[group]
	return ok
}

func (s groupAccessScope) canEditAttendance(group string) bool {
	group = normalizeGroupName(group)
	if group == "" {
		return false
	}
	if _, ok := s.Teaching[group]; ok {
		return true
	}
	if _, ok := s.Curator[group]; ok {
		return true
	}
	if _, ok := s.Department[group]; ok {
		return true
	}
	return false
}

func (s groupAccessScope) canEditGrades(group string) bool {
	group = normalizeGroupName(group)
	if group == "" {
		return false
	}
	_, ok := s.Teaching[group]
	return ok
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

	return scope, nil
}
