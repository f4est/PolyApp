package usecase

import (
	"context"
	"errors"
	"testing"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
)

type fakeUserRepo struct {
	byID    map[uint]entity.User
	byEmail map[string]entity.User
	nextID  uint
}

func newFakeUserRepo() *fakeUserRepo {
	return &fakeUserRepo{
		byID:    map[uint]entity.User{},
		byEmail: map[string]entity.User{},
		nextID:  1,
	}
}

func (r *fakeUserRepo) Create(_ context.Context, user *entity.User) error {
	if _, exists := r.byEmail[user.Email]; exists {
		return domainErrors.ErrConflict
	}
	user.ID = r.nextID
	r.nextID++
	copy := *user
	r.byID[user.ID] = copy
	r.byEmail[user.Email] = copy
	return nil
}

func (r *fakeUserRepo) GetByID(_ context.Context, id uint) (*entity.User, error) {
	user, ok := r.byID[id]
	if !ok {
		return nil, domainErrors.ErrNotFound
	}
	copy := user
	return &copy, nil
}

func (r *fakeUserRepo) GetByEmail(_ context.Context, email string) (*entity.User, error) {
	user, ok := r.byEmail[email]
	if !ok {
		return nil, domainErrors.ErrNotFound
	}
	copy := user
	return &copy, nil
}

func (r *fakeUserRepo) List(_ context.Context, _ string) ([]entity.User, error) {
	out := make([]entity.User, 0, len(r.byID))
	for _, user := range r.byID {
		out = append(out, user)
	}
	return out, nil
}

func (r *fakeUserRepo) Update(_ context.Context, user *entity.User) error {
	if _, ok := r.byID[user.ID]; !ok {
		return domainErrors.ErrNotFound
	}
	copy := *user
	r.byID[user.ID] = copy
	r.byEmail[user.Email] = copy
	return nil
}

func (r *fakeUserRepo) Delete(_ context.Context, id uint) error {
	user, ok := r.byID[id]
	if !ok {
		return domainErrors.ErrNotFound
	}
	delete(r.byID, id)
	delete(r.byEmail, user.Email)
	return nil
}

type fakeSessionRepo struct {
	items map[string]entity.AuthSession
}

func newFakeSessionRepo() *fakeSessionRepo {
	return &fakeSessionRepo{items: map[string]entity.AuthSession{}}
}

func (r *fakeSessionRepo) Save(_ context.Context, session entity.AuthSession) error {
	r.items[session.SessionID] = session
	return nil
}

func (r *fakeSessionRepo) GetByID(_ context.Context, sessionID string) (*entity.AuthSession, error) {
	session, ok := r.items[sessionID]
	if !ok {
		return nil, domainErrors.ErrNotFound
	}
	copy := session
	return &copy, nil
}

func (r *fakeSessionRepo) Revoke(_ context.Context, sessionID string) error {
	session, ok := r.items[sessionID]
	if !ok {
		return domainErrors.ErrNotFound
	}
	now := time.Now().UTC()
	session.RevokedAt = &now
	r.items[sessionID] = session
	return nil
}

type fakeSessionCache struct {
	items map[string]uint
}

func newFakeSessionCache() *fakeSessionCache {
	return &fakeSessionCache{items: map[string]uint{}}
}

func (c *fakeSessionCache) Set(_ context.Context, sessionID string, userID uint) error {
	c.items[sessionID] = userID
	return nil
}

func (c *fakeSessionCache) Touch(_ context.Context, sessionID string) error {
	if _, ok := c.items[sessionID]; !ok {
		return domainErrors.ErrNotFound
	}
	return nil
}

func (c *fakeSessionCache) Get(_ context.Context, sessionID string) (uint, error) {
	userID, ok := c.items[sessionID]
	if !ok {
		return 0, domainErrors.ErrNotFound
	}
	return userID, nil
}

func (c *fakeSessionCache) Delete(_ context.Context, sessionID string) error {
	delete(c.items, sessionID)
	return nil
}

type fakePasswordService struct{}

func (fakePasswordService) Hash(password string) (string, error) {
	return "h:" + password, nil
}

func (fakePasswordService) Compare(hash, password string) bool {
	return hash == "h:"+password
}

type fakeTokenService struct {
	lastClaims entity.TokenClaims
}

func (s *fakeTokenService) Generate(claims entity.TokenClaims) (string, error) {
	s.lastClaims = claims
	if claims.UserID == 0 {
		return "", errors.New("invalid claims")
	}
	return "token", nil
}

func (s *fakeTokenService) Parse(_ string) (*entity.TokenClaims, error) {
	claims := s.lastClaims
	return &claims, nil
}

func TestAuthUseCase_RegisterAndLogin(t *testing.T) {
	users := newFakeUserRepo()
	sessions := newFakeSessionRepo()
	cache := newFakeSessionCache()
	tokens := &fakeTokenService{}
	uc := NewAuthUseCase(users, sessions, cache, fakePasswordService{}, tokens)

	ctx := context.Background()
	register, err := uc.Register(ctx, RegisterInput{
		Role:         "student",
		FullName:     "Alice Demo",
		Email:        "alice@example.com",
		Password:     "Strong123",
		DeviceID:     "web",
		StudentGroup: "P22-3E",
		AutoApprove:  true,
	})
	if err != nil {
		t.Fatalf("register failed: %v", err)
	}
	if register.User.ID == 0 {
		t.Fatalf("expected assigned user id")
	}
	if register.AccessToken == "" {
		t.Fatalf("expected access token")
	}

	_, err = uc.Register(ctx, RegisterInput{
		Role:         "student",
		FullName:     "Alice Demo",
		Email:        "alice@example.com",
		Password:     "Strong123",
		StudentGroup: "P22-3E",
	})
	if !errors.Is(err, domainErrors.ErrConflict) {
		t.Fatalf("expected conflict, got: %v", err)
	}

	login, err := uc.Login(ctx, LoginInput{
		Email:    "alice@example.com",
		Password: "Strong123",
	})
	if err != nil {
		t.Fatalf("login failed: %v", err)
	}
	if login.User.Email != "alice@example.com" {
		t.Fatalf("unexpected user: %s", login.User.Email)
	}

	if _, err := uc.Login(ctx, LoginInput{
		Email:    "alice@example.com",
		Password: "wrong",
	}); !errors.Is(err, domainErrors.ErrUnauthorized) {
		t.Fatalf("expected unauthorized, got: %v", err)
	}
}

func TestAuthUseCase_GetCurrentUserAndLogout(t *testing.T) {
	users := newFakeUserRepo()
	sessions := newFakeSessionRepo()
	cache := newFakeSessionCache()
	tokens := &fakeTokenService{}
	uc := NewAuthUseCase(users, sessions, cache, fakePasswordService{}, tokens)

	ctx := context.Background()
	result, err := uc.Register(ctx, RegisterInput{
		Role:         "student",
		FullName:     "Bob Demo",
		Email:        "bob@example.com",
		Password:     "Strong123",
		StudentGroup: "P22-3E",
		AutoApprove:  true,
	})
	if err != nil {
		t.Fatalf("register failed: %v", err)
	}
	claims := tokens.lastClaims

	user, err := uc.GetCurrentUser(ctx, claims)
	if err != nil {
		t.Fatalf("get current user failed: %v", err)
	}
	if user.ID != result.User.ID {
		t.Fatalf("unexpected user id: %d", user.ID)
	}

	if err := uc.Logout(ctx, claims.SessionID); err != nil {
		t.Fatalf("logout failed: %v", err)
	}
	if _, err := uc.GetCurrentUser(ctx, claims); !errors.Is(err, domainErrors.ErrSessionExpired) {
		t.Fatalf("expected session expired after logout, got: %v", err)
	}
}
