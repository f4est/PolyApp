package http

import (
	"context"
	"errors"
	"strings"

	"polyapp/server-go/internal/domain/entity"
	"polyapp/server-go/internal/infrastructure/persistence"

	"gorm.io/gorm"
)

func (h *Handler) parentLinkedStudent(ctx context.Context, parent *entity.User) (*persistence.DBUser, error) {
	if parent == nil || parent.Role != "parent" {
		return nil, nil
	}
	var student persistence.DBUser
	if parent.ParentStudentID != nil && *parent.ParentStudentID > 0 {
		err := h.db.WithContext(ctx).
			Where("id = ? AND role = ? AND is_approved = ?", *parent.ParentStudentID, "student", true).
			First(&student).Error
		if err == nil {
			return &student, nil
		}
		if err != nil && !errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, err
		}
	}
	childName := strings.TrimSpace(parent.ChildFullName)
	childGroup := strings.TrimSpace(parent.StudentGroup)
	if childName == "" {
		return nil, nil
	}
	query := h.db.WithContext(ctx).
		Where("role = ? AND is_approved = ? AND lower(full_name) = lower(?)", "student", true, childName)
	if childGroup != "" {
		query = query.Where("student_group = ?", childGroup)
	}
	err := query.Order("id asc").First(&student).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, nil
		}
		return nil, err
	}
	return &student, nil
}
