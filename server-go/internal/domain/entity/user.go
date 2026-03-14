package entity

import "time"

type User struct {
	ID              uint
	Role            string
	FullName        string
	Email           string
	PasswordHash    string
	Phone           string
	AvatarURL       string
	About           string
	NotifySchedule  bool
	NotifyRequests  bool
	StudentGroup    string
	TeacherName     string
	ChildFullName   string
	ParentStudentID *uint
	IsApproved      bool
	ApprovedAt      *time.Time
	ApprovedBy      *uint
	BirthDate       *time.Time
	CreatedAt       time.Time
	UpdatedAt       time.Time
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
