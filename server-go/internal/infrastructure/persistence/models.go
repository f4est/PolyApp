package persistence

import "time"

type DBUser struct {
	ID                   uint       `gorm:"primaryKey"`
	Role                 string     `gorm:"size:32;not null;index"`
	FullName             string     `gorm:"size:255;not null"`
	Email                string     `gorm:"size:255;uniqueIndex;not null"`
	PasswordHash         string     `gorm:"size:255;not null"`
	Phone                string     `gorm:"size:64"`
	AvatarURL            string     `gorm:"size:512"`
	About                string     `gorm:"type:text"`
	NotifySchedule       bool       `gorm:"not null;default:true"`
	NotifyRequests       bool       `gorm:"not null;default:true"`
	StudentGroup         string     `gorm:"size:64;index"`
	TeacherName          string     `gorm:"size:255;index"`
	ChildFullName        string     `gorm:"size:255;index"`
	ParentStudentID      *uint      `gorm:"index"`
	AdminPermissionsJSON string     `gorm:"type:text;not null;default:'[]'"`
	IsApproved           bool       `gorm:"not null;default:false;index"`
	ApprovedAt           *time.Time `gorm:"index"`
	ApprovedBy           *uint      `gorm:"index"`
	BirthDate            *time.Time `gorm:"type:date"`
	CreatedAt            time.Time
	UpdatedAt            time.Time
}

type DBAuthSession struct {
	ID         uint   `gorm:"primaryKey"`
	SessionID  string `gorm:"size:64;uniqueIndex;not null"`
	UserID     uint   `gorm:"index;not null"`
	DeviceID   string `gorm:"size:128"`
	CreatedAt  time.Time
	LastSeenAt time.Time  `gorm:"index"`
	RevokedAt  *time.Time `gorm:"index"`
}

type DBDeviceToken struct {
	ID         uint   `gorm:"primaryKey"`
	UserID     uint   `gorm:"index;not null"`
	Token      string `gorm:"size:512;uniqueIndex;not null"`
	Platform   string `gorm:"size:64"`
	CreatedAt  time.Time
	LastSeenAt time.Time  `gorm:"index"`
	RevokedAt  *time.Time `gorm:"index"`
}

type DBNotification struct {
	ID        uint       `gorm:"primaryKey"`
	UserID    uint       `gorm:"index;not null"`
	Title     string     `gorm:"size:255;not null"`
	Body      string     `gorm:"type:text;not null"`
	DataJSON  string     `gorm:"type:text"`
	CreatedAt time.Time  `gorm:"index"`
	ReadAt    *time.Time `gorm:"index"`
}

type DBNewsPost struct {
	ID         uint      `gorm:"primaryKey"`
	Title      string    `gorm:"size:255;not null"`
	Body       string    `gorm:"type:text;not null"`
	AuthorID   uint      `gorm:"index;not null"`
	Category   string    `gorm:"size:64;default:news;index"`
	Pinned     bool      `gorm:"default:false;index"`
	ShareCount int       `gorm:"default:0"`
	CreatedAt  time.Time `gorm:"index"`
	UpdatedAt  time.Time
}

type DBNewsMedia struct {
	ID           uint   `gorm:"primaryKey"`
	PostID       uint   `gorm:"index;not null"`
	OriginalName string `gorm:"size:255;not null"`
	StoredName   string `gorm:"size:255;not null"`
	MediaType    string `gorm:"size:32;not null"`
	MimeType     string `gorm:"size:128"`
	Size         int64
	CreatedAt    time.Time
}

type DBNewsLike struct {
	ID        uint   `gorm:"primaryKey"`
	PostID    uint   `gorm:"uniqueIndex:idx_news_like;not null"`
	UserID    uint   `gorm:"uniqueIndex:idx_news_like;not null"`
	Reaction  string `gorm:"size:32;default:like;index"`
	CreatedAt time.Time
}

type DBNewsComment struct {
	ID        uint      `gorm:"primaryKey"`
	PostID    uint      `gorm:"index;not null"`
	UserID    uint      `gorm:"index;not null"`
	Text      string    `gorm:"type:text;not null"`
	CreatedAt time.Time `gorm:"index"`
	UpdatedAt time.Time `gorm:"index"`
}

type DBNewsShare struct {
	ID        uint      `gorm:"primaryKey"`
	PostID    uint      `gorm:"uniqueIndex:idx_news_share;index;not null"`
	UserID    uint      `gorm:"uniqueIndex:idx_news_share;index;not null"`
	CreatedAt time.Time `gorm:"index"`
}

type DBScheduleUpload struct {
	ID           uint       `gorm:"primaryKey"`
	Filename     string     `gorm:"size:255;not null"`
	DBFilename   string     `gorm:"size:255"`
	ScheduleDate *time.Time `gorm:"type:date;index"`
	UploadedAt   time.Time
}

type DBScheduleLesson struct {
	ID          uint   `gorm:"primaryKey"`
	UploadID    uint   `gorm:"index"`
	Shift       int    `gorm:"index"`
	Period      int    `gorm:"index"`
	TimeText    string `gorm:"size:64"`
	Audience    string `gorm:"size:128"`
	Lesson      string `gorm:"size:255"`
	GroupName   string `gorm:"size:64;index"`
	TeacherName string `gorm:"size:255;index"`
	CreatedAt   time.Time
}

type DBRequestTicket struct {
	ID          uint       `gorm:"primaryKey"`
	StudentID   uint       `gorm:"index;not null"`
	RequestType string     `gorm:"size:255;not null"`
	Status      string     `gorm:"size:64;index;not null"`
	Details     string     `gorm:"type:text"`
	Comment     string     `gorm:"type:text"`
	CreatedAt   time.Time  `gorm:"index"`
	UpdatedAt   *time.Time `gorm:"index"`
}

type DBAttendanceRecord struct {
	ID          uint      `gorm:"primaryKey"`
	GroupName   string    `gorm:"size:64;uniqueIndex:idx_attendance_record;not null"`
	ClassDate   time.Time `gorm:"type:date;uniqueIndex:idx_attendance_record;not null"`
	StudentName string    `gorm:"size:255;uniqueIndex:idx_attendance_record;not null"`
	Present     bool      `gorm:"not null"`
	TeacherID   uint      `gorm:"index"`
}

type DBGradeRecord struct {
	ID          uint      `gorm:"primaryKey"`
	GroupName   string    `gorm:"size:64;uniqueIndex:idx_grade_record;not null"`
	ClassDate   time.Time `gorm:"type:date;uniqueIndex:idx_grade_record;not null"`
	StudentName string    `gorm:"size:255;uniqueIndex:idx_grade_record;not null"`
	Grade       int       `gorm:"not null"`
	TeacherID   uint      `gorm:"index"`
}

type DBExamUpload struct {
	ID         uint      `gorm:"primaryKey"`
	GroupName  string    `gorm:"size:64;index;not null"`
	ExamName   string    `gorm:"size:255;index;not null"`
	Filename   string    `gorm:"size:255;not null"`
	RowsCount  int       `gorm:"not null"`
	UploadedAt time.Time `gorm:"index"`
	TeacherID  uint      `gorm:"index"`
}

type DBExamGrade struct {
	ID          uint      `gorm:"primaryKey"`
	GroupName   string    `gorm:"size:64;index;not null"`
	ExamName    string    `gorm:"size:255;index;not null"`
	StudentName string    `gorm:"size:255;index;not null"`
	Grade       int       `gorm:"not null"`
	CreatedAt   time.Time `gorm:"index"`
	TeacherID   uint      `gorm:"index"`
	UploadID    uint      `gorm:"index"`
}

type DBTeacherGroupAssignment struct {
	ID        uint   `gorm:"primaryKey"`
	TeacherID uint   `gorm:"index;not null"`
	GroupName string `gorm:"size:64;index;not null"`
	Subject   string `gorm:"size:128;not null"`
	CreatedAt time.Time
}

type DBDepartment struct {
	ID         uint      `gorm:"primaryKey"`
	Name       string    `gorm:"size:255;uniqueIndex;not null"`
	Key        string    `gorm:"size:32;uniqueIndex;not null"`
	HeadUserID *uint     `gorm:"index"`
	CreatedAt  time.Time `gorm:"index"`
	UpdatedAt  time.Time `gorm:"index"`
}

type DBDepartmentGroup struct {
	ID           uint      `gorm:"primaryKey"`
	DepartmentID uint      `gorm:"index;uniqueIndex:idx_department_group;not null"`
	GroupName    string    `gorm:"size:64;uniqueIndex:idx_department_group;uniqueIndex;not null"`
	CreatedAt    time.Time `gorm:"index"`
}

type DBCuratorGroupAssignment struct {
	ID        uint      `gorm:"primaryKey"`
	CuratorID uint      `gorm:"index;uniqueIndex:idx_curator_group;not null"`
	GroupName string    `gorm:"size:64;uniqueIndex:idx_curator_group;uniqueIndex;not null"`
	CreatedAt time.Time `gorm:"index"`
}

type DBJournalGroup struct {
	ID   uint   `gorm:"primaryKey"`
	Name string `gorm:"size:64;uniqueIndex;not null"`
}

type DBJournalStudent struct {
	ID          uint   `gorm:"primaryKey"`
	GroupName   string `gorm:"size:64;uniqueIndex:idx_journal_student;not null"`
	StudentName string `gorm:"size:255;uniqueIndex:idx_journal_student;not null"`
}

type DBJournalDate struct {
	ID        uint      `gorm:"primaryKey"`
	GroupName string    `gorm:"size:64;uniqueIndex:idx_journal_date;not null"`
	ClassDate time.Time `gorm:"type:date;uniqueIndex:idx_journal_date;not null"`
}

type DBGradingPreset struct {
	ID          uint      `gorm:"primaryKey"`
	OwnerID     uint      `gorm:"index;not null"`
	Name        string    `gorm:"size:255;not null;index"`
	Description string    `gorm:"type:text"`
	TagsJSON    string    `gorm:"type:text;not null;default:'[]'"`
	Visibility  string    `gorm:"size:16;index;not null;default:private"`
	CreatedAt   time.Time `gorm:"index"`
	UpdatedAt   time.Time
	ArchivedAt  *time.Time `gorm:"index"`
}

type DBGradingPresetVersion struct {
	ID             uint      `gorm:"primaryKey"`
	PresetID       uint      `gorm:"uniqueIndex:idx_preset_version;index;not null"`
	Version        int       `gorm:"uniqueIndex:idx_preset_version;not null"`
	DefinitionJSON string    `gorm:"type:text;not null"`
	CreatedBy      uint      `gorm:"index;not null"`
	CreatedAt      time.Time `gorm:"index"`
}

type DBGroupPresetBinding struct {
	ID              uint      `gorm:"primaryKey"`
	GroupName       string    `gorm:"size:64;uniqueIndex;not null"`
	PresetID        uint      `gorm:"index;not null"`
	PresetVersionID uint      `gorm:"index;not null"`
	AutoUpdate      bool      `gorm:"not null;default:true"`
	AppliedBy       uint      `gorm:"index;not null"`
	AppliedAt       time.Time `gorm:"index"`
	UpdatedAt       time.Time `gorm:"index"`
}

type DBJournalDateCellV2 struct {
	ID           uint      `gorm:"primaryKey"`
	GroupName    string    `gorm:"size:64;uniqueIndex:idx_journal_date_cell_v2;index;not null"`
	ClassDate    time.Time `gorm:"type:date;uniqueIndex:idx_journal_date_cell_v2;not null"`
	StudentName  string    `gorm:"size:255;uniqueIndex:idx_journal_date_cell_v2;not null"`
	RawValue     string    `gorm:"size:128;not null;default:''"`
	NumericValue *float64
	StatusCode   string    `gorm:"size:32;index"`
	UpdatedBy    uint      `gorm:"index;not null"`
	UpdatedAt    time.Time `gorm:"index"`
}

type DBJournalManualCellV2 struct {
	ID           uint   `gorm:"primaryKey"`
	GroupName    string `gorm:"size:64;uniqueIndex:idx_journal_manual_cell_v2;index;not null"`
	StudentName  string `gorm:"size:255;uniqueIndex:idx_journal_manual_cell_v2;not null"`
	ColumnKey    string `gorm:"size:64;uniqueIndex:idx_journal_manual_cell_v2;not null"`
	RawValue     string `gorm:"size:128;not null;default:''"`
	NumericValue *float64
	UpdatedBy    uint      `gorm:"index;not null"`
	UpdatedAt    time.Time `gorm:"index"`
}

type DBJournalComputedRowV2 struct {
	ID              uint      `gorm:"primaryKey"`
	GroupName       string    `gorm:"size:64;uniqueIndex:idx_journal_computed_row_v2;index;not null"`
	StudentName     string    `gorm:"size:255;uniqueIndex:idx_journal_computed_row_v2;not null"`
	PresetVersionID uint      `gorm:"index;not null"`
	ValuesJSON      string    `gorm:"type:text;not null;default:'{}'"`
	CalculatedAt    time.Time `gorm:"index"`
}

type DBMakeupCase struct {
	ID                   uint       `gorm:"primaryKey"`
	GroupName            string     `gorm:"size:64;index;not null"`
	TeacherID            uint       `gorm:"index;not null"`
	StudentID            uint       `gorm:"index;not null"`
	ClassDate            time.Time  `gorm:"type:date;index;not null"`
	Status               string     `gorm:"size:32;index;not null"`
	TeacherNote          string     `gorm:"type:text"`
	MedicalProofURL      string     `gorm:"size:512"`
	MedicalProofComment  string     `gorm:"type:text"`
	TeacherTask          string     `gorm:"type:text"`
	TeacherTaskAt        *time.Time `gorm:"index"`
	StudentSubmission    string     `gorm:"type:text"`
	StudentSubmissionURL string     `gorm:"size:512"`
	SubmissionSentAt     *time.Time `gorm:"index"`
	Grade                string     `gorm:"size:64"`
	GradeComment         string     `gorm:"type:text"`
	GradeSetAt           *time.Time `gorm:"index"`
	ProofSubmittedAt     *time.Time `gorm:"index"`
	TeacherNoteAt        *time.Time `gorm:"index"`
	CreatedAt            time.Time  `gorm:"index"`
	UpdatedAt            time.Time  `gorm:"index"`
	ClosedAt             *time.Time `gorm:"index"`
}

type DBMakeupMessage struct {
	ID            uint      `gorm:"primaryKey"`
	MakeupCaseID  uint      `gorm:"index;not null"`
	SenderID      uint      `gorm:"index;not null"`
	Body          string    `gorm:"type:text"`
	AttachmentURL string    `gorm:"size:512"`
	CreatedAt     time.Time `gorm:"index"`
}

func ModelSet() []any {
	return []any{
		&DBUser{},
		&DBAuthSession{},
		&DBDeviceToken{},
		&DBNotification{},
		&DBNewsPost{},
		&DBNewsMedia{},
		&DBNewsLike{},
		&DBNewsComment{},
		&DBNewsShare{},
		&DBScheduleUpload{},
		&DBScheduleLesson{},
		&DBRequestTicket{},
		&DBAttendanceRecord{},
		&DBGradeRecord{},
		&DBExamUpload{},
		&DBExamGrade{},
		&DBTeacherGroupAssignment{},
		&DBDepartment{},
		&DBDepartmentGroup{},
		&DBCuratorGroupAssignment{},
		&DBJournalGroup{},
		&DBJournalStudent{},
		&DBJournalDate{},
		&DBGradingPreset{},
		&DBGradingPresetVersion{},
		&DBGroupPresetBinding{},
		&DBJournalDateCellV2{},
		&DBJournalManualCellV2{},
		&DBJournalComputedRowV2{},
		&DBMakeupCase{},
		&DBMakeupMessage{},
	}
}
