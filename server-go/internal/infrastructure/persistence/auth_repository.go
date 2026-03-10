package persistence

import (
	"context"
	"errors"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"

	"gorm.io/gorm"
)

type UserRepo struct {
	db *gorm.DB
}

func NewUserRepo(db *gorm.DB) *UserRepo {
	return &UserRepo{db: db}
}

func (r *UserRepo) Create(ctx context.Context, user *entity.User) error {
	model := DBUser{
		Role:         user.Role,
		FullName:     user.FullName,
		Email:        strings.ToLower(user.Email),
		PasswordHash: user.PasswordHash,
		Phone:        user.Phone,
		AvatarURL:    user.AvatarURL,
		About:        user.About,
		StudentGroup: user.StudentGroup,
		TeacherName:  user.TeacherName,
		BirthDate:    user.BirthDate,
	}
	if err := r.db.WithContext(ctx).Create(&model).Error; err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "duplicate") {
			return domainErrors.ErrConflict
		}
		return err
	}
	*user = toDomainUser(model)
	return nil
}

func (r *UserRepo) GetByID(ctx context.Context, id uint) (*entity.User, error) {
	var model DBUser
	if err := r.db.WithContext(ctx).First(&model, id).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, domainErrors.ErrNotFound
		}
		return nil, err
	}
	user := toDomainUser(model)
	return &user, nil
}

func (r *UserRepo) GetByEmail(ctx context.Context, email string) (*entity.User, error) {
	var model DBUser
	if err := r.db.WithContext(ctx).Where("email = ?", strings.ToLower(strings.TrimSpace(email))).First(&model).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, domainErrors.ErrNotFound
		}
		return nil, err
	}
	user := toDomainUser(model)
	return &user, nil
}

func (r *UserRepo) List(ctx context.Context, role string) ([]entity.User, error) {
	var models []DBUser
	query := r.db.WithContext(ctx).Order("id asc")
	if role != "" {
		query = query.Where("role = ?", role)
	}
	if err := query.Find(&models).Error; err != nil {
		return nil, err
	}
	out := make([]entity.User, 0, len(models))
	for _, model := range models {
		out = append(out, toDomainUser(model))
	}
	return out, nil
}

func (r *UserRepo) Update(ctx context.Context, user *entity.User) error {
	var model DBUser
	if err := r.db.WithContext(ctx).First(&model, user.ID).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return domainErrors.ErrNotFound
		}
		return err
	}
	if user.Role != "" {
		model.Role = user.Role
	}
	if user.FullName != "" {
		model.FullName = user.FullName
	}
	if user.Email != "" {
		model.Email = strings.ToLower(user.Email)
	}
	if user.PasswordHash != "" {
		model.PasswordHash = user.PasswordHash
	}
	model.Phone = user.Phone
	model.AvatarURL = user.AvatarURL
	model.About = user.About
	model.StudentGroup = user.StudentGroup
	model.TeacherName = user.TeacherName
	model.BirthDate = user.BirthDate
	if err := r.db.WithContext(ctx).Save(&model).Error; err != nil {
		return err
	}
	*user = toDomainUser(model)
	return nil
}

func (r *UserRepo) Delete(ctx context.Context, id uint) error {
	return r.db.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		if err := tx.Where("user_id = ?", id).Delete(&DBAuthSession{}).Error; err != nil {
			return err
		}
		if err := tx.Where("user_id = ?", id).Delete(&DBDeviceToken{}).Error; err != nil {
			return err
		}
		res := tx.Delete(&DBUser{}, id)
		if res.Error != nil {
			return res.Error
		}
		if res.RowsAffected == 0 {
			return domainErrors.ErrNotFound
		}
		return nil
	})
}

type SessionRepo struct {
	db *gorm.DB
}

func NewSessionRepo(db *gorm.DB) *SessionRepo {
	return &SessionRepo{db: db}
}

func (r *SessionRepo) Save(ctx context.Context, session entity.AuthSession) error {
	model := DBAuthSession{
		SessionID:  session.SessionID,
		UserID:     session.UserID,
		DeviceID:   session.DeviceID,
		CreatedAt:  session.CreatedAt,
		LastSeenAt: session.LastSeenAt,
		RevokedAt:  session.RevokedAt,
	}
	if model.CreatedAt.IsZero() {
		now := time.Now().UTC()
		model.CreatedAt = now
		model.LastSeenAt = now
	}
	return r.db.WithContext(ctx).Create(&model).Error
}

func (r *SessionRepo) GetByID(ctx context.Context, sessionID string) (*entity.AuthSession, error) {
	var model DBAuthSession
	if err := r.db.WithContext(ctx).Where("session_id = ?", sessionID).First(&model).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, domainErrors.ErrNotFound
		}
		return nil, err
	}
	session := &entity.AuthSession{
		SessionID:  model.SessionID,
		UserID:     model.UserID,
		DeviceID:   model.DeviceID,
		CreatedAt:  model.CreatedAt,
		LastSeenAt: model.LastSeenAt,
		RevokedAt:  model.RevokedAt,
	}
	return session, nil
}

func (r *SessionRepo) Revoke(ctx context.Context, sessionID string) error {
	now := time.Now().UTC()
	result := r.db.WithContext(ctx).
		Model(&DBAuthSession{}).
		Where("session_id = ? AND revoked_at IS NULL", sessionID).
		Updates(map[string]any{
			"revoked_at":   now,
			"last_seen_at": now,
		})
	if result.Error != nil {
		return result.Error
	}
	if result.RowsAffected == 0 {
		return domainErrors.ErrNotFound
	}
	return nil
}

func toDomainUser(model DBUser) entity.User {
	return entity.User{
		ID:           model.ID,
		Role:         model.Role,
		FullName:     model.FullName,
		Email:        model.Email,
		PasswordHash: model.PasswordHash,
		Phone:        model.Phone,
		AvatarURL:    model.AvatarURL,
		About:        model.About,
		StudentGroup: model.StudentGroup,
		TeacherName:  model.TeacherName,
		BirthDate:    model.BirthDate,
		CreatedAt:    model.CreatedAt,
		UpdatedAt:    model.UpdatedAt,
	}
}
