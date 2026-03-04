package entity

import "time"

type User struct {
	ID           uint
	Role         string
	FullName     string
	Email        string
	PasswordHash string
	Phone        string
	AvatarURL    string
	About        string
	StudentGroup string
	TeacherName  string
	BirthDate    *time.Time
	CreatedAt    time.Time
	UpdatedAt    time.Time
}

type AuthSession struct {
	SessionID  string
	UserID     uint
	DeviceID   string
	CreatedAt  time.Time
	LastSeenAt time.Time
	RevokedAt  *time.Time
}

type TokenClaims struct {
	UserID    uint
	Role      string
	SessionID string
	ExpiresAt time.Time
}
