package http

import (
	"strconv"
	"strings"

	"polyapp/server-go/internal/domain/entity"
)

const teacherJournalGroupSuffix = "@@t"

func scopedJournalGroupNameForUser(user *entity.User, groupName string) string {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" || user == nil {
		return groupName
	}
	if strings.ToLower(strings.TrimSpace(user.Role)) != "teacher" {
		return groupName
	}
	return groupName + teacherJournalGroupSuffix + strconv.FormatUint(uint64(user.ID), 10)
}

func resolvedJournalGroupNameForUser(user *entity.User, groupName string) string {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" || user == nil {
		return groupName
	}
	if strings.ToLower(strings.TrimSpace(user.Role)) != "teacher" {
		return groupName
	}
	if teacherID, ok := teacherIDFromScopedJournalGroupName(groupName); ok {
		if teacherID == user.ID {
			return groupName
		}
	}
	return scopedJournalGroupNameForUser(user, baseJournalGroupName(groupName))
}

func baseJournalGroupName(groupName string) string {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" {
		return groupName
	}
	idx := strings.LastIndex(groupName, teacherJournalGroupSuffix)
	if idx <= 0 {
		return groupName
	}
	tail := strings.TrimSpace(groupName[idx+len(teacherJournalGroupSuffix):])
	if tail == "" {
		return groupName
	}
	for _, ch := range tail {
		if ch < '0' || ch > '9' {
			return groupName
		}
	}
	return strings.TrimSpace(groupName[:idx])
}

func teacherIDFromScopedJournalGroupName(groupName string) (uint, bool) {
	groupName = strings.TrimSpace(groupName)
	if groupName == "" {
		return 0, false
	}
	idx := strings.LastIndex(groupName, teacherJournalGroupSuffix)
	if idx <= 0 {
		return 0, false
	}
	tail := strings.TrimSpace(groupName[idx+len(teacherJournalGroupSuffix):])
	if tail == "" {
		return 0, false
	}
	value, err := strconv.ParseUint(tail, 10, 64)
	if err != nil || value == 0 {
		return 0, false
	}
	return uint(value), true
}
