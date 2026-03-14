package usecase

import (
	"context"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
	"polyapp/server-go/internal/domain/repository"
	"polyapp/server-go/internal/domain/service"

	"github.com/google/uuid"
)

const (
	DefaultRole        = "student"
	TokenTTL           = 7 * 24 * time.Hour
	SessionTTLFallback = 7 * 24 * time.Hour
)

var AllowedRoles = map[string]struct{}{
	"smm":             {},
	"parent":          {},
	"request_handler": {},
	"admin":           {},
	"student":         {},
	"teacher":         {},
}

type AuthUseCase struct {
	users       repository.UserRepository
	sessions    repository.SessionRepository
	cache       repository.SessionCache
	passwords   service.PasswordService
	tokens      service.TokenService
	now         func() time.Time
	tokenTTL    time.Duration
	defaultRole string
}

func NewAuthUseCase(
	users repository.UserRepository,
	sessions repository.SessionRepository,
	cache repository.SessionCache,
	passwords service.PasswordService,
	tokens service.TokenService,
) *AuthUseCase {
	return &AuthUseCase{
		users:       users,
		sessions:    sessions,
		cache:       cache,
		passwords:   passwords,
		tokens:      tokens,
		now:         time.Now,
		tokenTTL:    TokenTTL,
		defaultRole: DefaultRole,
	}
}

type RegisterInput struct {
	Role            string
	FullName        string
	Email           string
	Password        string
	DeviceID        string
	NotifySchedule  *bool
	NotifyRequests  *bool
	StudentGroup    string
	TeacherName     string
	ChildFullName   string
	ParentStudentID *uint
	AutoApprove     bool
}

type LoginInput struct {
	Email    string
	Password string
	DeviceID string
}

type AuthResult struct {
	TokenType       string
	AccessToken     string
	User            entity.User
	PendingApproval bool
}

func (u *AuthUseCase) Register(ctx context.Context, in RegisterInput) (*AuthResult, error) {
	email := strings.ToLower(strings.TrimSpace(in.Email))
	fullName := strings.TrimSpace(in.FullName)
	password := strings.TrimSpace(in.Password)
	role := strings.TrimSpace(in.Role)
	studentGroup := strings.TrimSpace(in.StudentGroup)
	teacherName := strings.TrimSpace(in.TeacherName)
	childFullName := strings.TrimSpace(in.ChildFullName)

	if email == "" || fullName == "" || password == "" {
		return nil, domainErrors.ErrInvalidInput
	}
	if len(password) < 8 {
		return nil, domainErrors.ErrInvalidInput
	}
	if role == "" {
		role = u.defaultRole
	}
	if _, ok := AllowedRoles[role]; !ok {
		return nil, domainErrors.ErrInvalidInput
	}
	switch role {
	case "student":
		if studentGroup == "" {
			return nil, domainErrors.ErrInvalidInput
		}
	case "teacher":
		if teacherName == "" {
			return nil, domainErrors.ErrInvalidInput
		}
	case "parent":
		if childFullName == "" {
			return nil, domainErrors.ErrInvalidInput
		}
	}

	existing, err := u.users.GetByEmail(ctx, email)
	if err != nil && err != domainErrors.ErrNotFound {
		return nil, err
	}
	if existing != nil {
		return nil, domainErrors.ErrConflict
	}

	hash, err := u.passwords.Hash(password)
	if err != nil {
		return nil, err
	}
	isApproved := in.AutoApprove || role == "admin"
	notifySchedule := true
	if in.NotifySchedule != nil {
		notifySchedule = *in.NotifySchedule
	}
	notifyRequests := true
	if in.NotifyRequests != nil {
		notifyRequests = *in.NotifyRequests
	}
	now := u.now().UTC()
	user := &entity.User{
		Role:            role,
		FullName:        fullName,
		Email:           email,
		PasswordHash:    hash,
		NotifySchedule:  notifySchedule,
		NotifyRequests:  notifyRequests,
		StudentGroup:    studentGroup,
		TeacherName:     teacherName,
		ChildFullName:   childFullName,
		ParentStudentID: in.ParentStudentID,
		IsApproved:      isApproved,
		ApprovedAt:      nil,
		ApprovedBy:      nil,
	}
	if teacherName == "" && role == "teacher" {
		user.TeacherName = fullName
	}
	if isApproved {
		user.ApprovedAt = &now
	}
	if err := u.users.Create(ctx, user); err != nil {
		return nil, err
	}
	if !user.IsApproved {
		return &AuthResult{
			User:            *user,
			PendingApproval: true,
		}, nil
	}
	return u.issueToken(ctx, *user, strings.TrimSpace(in.DeviceID))
}

func (u *AuthUseCase) Login(ctx context.Context, in LoginInput) (*AuthResult, error) {
	email := strings.ToLower(strings.TrimSpace(in.Email))
	password := strings.TrimSpace(in.Password)
	if email == "" || password == "" {
		return nil, domainErrors.ErrInvalidInput
	}
	user, err := u.users.GetByEmail(ctx, email)
	if err != nil {
		return nil, domainErrors.ErrUnauthorized
	}
	if !u.passwords.Compare(user.PasswordHash, password) {
		return nil, domainErrors.ErrUnauthorized
	}
	if !user.IsApproved {
		return nil, domainErrors.ErrPendingApproval
	}
	return u.issueToken(ctx, *user, strings.TrimSpace(in.DeviceID))
}

func (u *AuthUseCase) GetCurrentUser(ctx context.Context, claims entity.TokenClaims) (*entity.User, error) {
	if claims.UserID == 0 || claims.SessionID == "" {
		return nil, domainErrors.ErrUnauthorized
	}
	userID, err := u.cache.Get(ctx, claims.SessionID)
	if err != nil {
		return nil, domainErrors.ErrSessionExpired
	}
	if userID != claims.UserID {
		return nil, domainErrors.ErrUnauthorized
	}
	if err := u.cache.Touch(ctx, claims.SessionID); err != nil {
		return nil, domainErrors.ErrSessionExpired
	}
	session, err := u.sessions.GetByID(ctx, claims.SessionID)
	if err != nil {
		return nil, domainErrors.ErrSessionExpired
	}
	if session.RevokedAt != nil {
		return nil, domainErrors.ErrSessionExpired
	}
	user, err := u.users.GetByID(ctx, claims.UserID)
	if err != nil {
		return nil, domainErrors.ErrUnauthorized
	}
	return user, nil
}

func (u *AuthUseCase) Logout(ctx context.Context, sessionID string) error {
	if sessionID == "" {
		return domainErrors.ErrInvalidInput
	}
	if err := u.sessions.Revoke(ctx, sessionID); err != nil {
		return err
	}
	if err := u.cache.Delete(ctx, sessionID); err != nil {
		return err
	}
	return nil
}

func (u *AuthUseCase) HashPassword(raw string) (string, error) {
	password := strings.TrimSpace(raw)
	if password == "" || len(password) < 8 {
		return "", domainErrors.ErrInvalidInput
	}
	return u.passwords.Hash(password)
}

func (u *AuthUseCase) issueToken(ctx context.Context, user entity.User, deviceID string) (*AuthResult, error) {
	now := u.now().UTC()
	sessionID := uuid.NewString()
	session := entity.AuthSession{
		SessionID:  sessionID,
		UserID:     user.ID,
		DeviceID:   deviceID,
		CreatedAt:  now,
		LastSeenAt: now,
	}
	if err := u.sessions.Save(ctx, session); err != nil {
		return nil, err
	}
	if err := u.cache.Set(ctx, sessionID, user.ID); err != nil {
		return nil, err
	}
	token, err := u.tokens.Generate(entity.TokenClaims{
		UserID:    user.ID,
		Role:      user.Role,
		SessionID: sessionID,
		ExpiresAt: now.Add(u.tokenTTL),
	})
	if err != nil {
		return nil, err
	}
	return &AuthResult{
		TokenType:   "bearer",
		AccessToken: token,
		User:        user,
	}, nil
}
