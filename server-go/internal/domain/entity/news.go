package entity

import "time"

type NewsPost struct {
	ID             uint
	Title          string
	Body           string
	AuthorID       uint
	AuthorName     string
	Category       string
	Pinned         bool
	CreatedAt      time.Time
	UpdatedAt      *time.Time
	ShareCount     int
	LikesCount     int
	CommentsCount  int
	LikedByMe      bool
	ReactionCounts map[string]int
	MyReaction     *string
	Media          []NewsMedia
	Comments       []NewsComment
}

type NewsMedia struct {
	ID           uint
	URL          string
	MediaType    string
	OriginalName string
	MimeType     string
	Size         int64
}

type NewsComment struct {
	ID            uint
	UserID        uint
	UserName      string
	UserRole      string
	UserAvatarURL string
	Text          string
	CreatedAt     time.Time
	UpdatedAt     *time.Time
}

type NewsLikeResult struct {
	LikesCount     int
	Liked          bool
	ReactionCounts map[string]int
	MyReaction     *string
}
