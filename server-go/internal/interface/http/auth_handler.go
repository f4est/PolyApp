package http

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
	"polyapp/server-go/internal/infrastructure/persistence"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"
	"polyapp/server-go/internal/usecase"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type authRegisterPayload struct {
	Role            string `json:"role"`
	FullName        string `json:"full_name"`
	Email           string `json:"email"`
	Password        string `json:"password"`
	DeviceID        string `json:"device_id"`
	NotifySchedule  *bool  `json:"notify_schedule"`
	NotifyRequests  *bool  `json:"notify_requests"`
	StudentGroup    string `json:"student_group"`
	TeacherName     string `json:"teacher_name"`
	ChildFullName   string `json:"child_full_name"`
	ParentStudentID *uint  `json:"parent_student_id"`
	IsApproved      *bool  `json:"is_approved"`
}

type authLoginPayload struct {
	Email    string `json:"email"`
	Password string `json:"password"`
	DeviceID string `json:"device_id"`
}

type userUpdatePayload struct {
	Role            *string `json:"role"`
	FullName        *string `json:"full_name"`
	Email           *string `json:"email"`
	Phone           *string `json:"phone"`
	AvatarURL       *string `json:"avatar_url"`
	About           *string `json:"about"`
	NotifySchedule  *bool   `json:"notify_schedule"`
	NotifyRequests  *bool   `json:"notify_requests"`
	StudentGroup    *string `json:"student_group"`
	TeacherName     *string `json:"teacher_name"`
	ChildFullName   *string `json:"child_full_name"`
	ParentStudentID *uint   `json:"parent_student_id"`
	IsApproved      *bool   `json:"is_approved"`
	Password        *string `json:"password"`
	BirthDate       *string `json:"birth_date"`
}

type deviceTokenPayload struct {
	Token    string `json:"token"`
	Platform string `json:"platform"`
}

func (h *Handler) RegisterAuthRoutes(router *gin.Engine, auth *httpMiddleware.AuthMiddleware) {
	router.POST("/auth/register", h.register)
	router.POST("/auth/login", h.login)
	router.GET("/auth/check-email", h.checkEmailExists)

	secured := router.Group("/")
	secured.Use(auth.RequireAuth())
	{
		secured.GET("/auth/me", h.me)
		secured.POST("/auth/logout", h.logout)
		secured.POST("/devices/register", h.registerDeviceToken)
		secured.GET("/notifications", h.listNotifications)
		secured.POST("/notifications/:id/read", h.markNotificationRead)
		secured.DELETE("/notifications/:id", h.deleteNotification)
	}

	admin := router.Group("/")
	admin.Use(auth.RequireAuth(), httpMiddleware.RequireRoles("admin"))
	{
		admin.POST("/users", h.createUser)
		admin.GET("/users", h.listUsers)
		admin.GET("/users/students/approved", h.listApprovedStudents)
		admin.POST("/users/:id/approve", h.approveUser)
		admin.DELETE("/users/:id", h.deleteUser)
	}
	userRoutes := router.Group("/")
	userRoutes.Use(auth.RequireAuth())
	{
		userRoutes.GET("/users/:id/public", h.getUserPublic)
		userRoutes.GET("/users/:id", h.getUser)
		userRoutes.PATCH("/users/:id", h.updateUser)
	}
}

func (h *Handler) register(c *gin.Context) {
	var payload authRegisterPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	result, err := h.authUC.Register(c.Request.Context(), usecase.RegisterInput{
		Role:            payload.Role,
		FullName:        payload.FullName,
		Email:           payload.Email,
		Password:        payload.Password,
		DeviceID:        payload.DeviceID,
		NotifySchedule:  payload.NotifySchedule,
		NotifyRequests:  payload.NotifyRequests,
		StudentGroup:    payload.StudentGroup,
		TeacherName:     payload.TeacherName,
		ChildFullName:   payload.ChildFullName,
		ParentStudentID: payload.ParentStudentID,
	})
	if err != nil {
		switch {
		case errors.Is(err, domainErrors.ErrConflict):
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Email already registered"})
		case errors.Is(err, domainErrors.ErrInvalidInput):
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid input"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Internal error"})
		}
		return
	}
	if result.PendingApproval {
		c.JSON(http.StatusAccepted, gin.H{
			"pending_approval": true,
			"detail":           "Account created and pending admin approval",
			"user":             toUserPublic(result.User),
		})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"access_token": result.AccessToken,
		"token_type":   result.TokenType,
		"user":         toUserPublic(result.User),
	})
}

func (h *Handler) login(c *gin.Context) {
	var payload authLoginPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	result, err := h.authUC.Login(c.Request.Context(), usecase.LoginInput{
		Email:    payload.Email,
		Password: payload.Password,
		DeviceID: payload.DeviceID,
	})
	if err != nil {
		if errors.Is(err, domainErrors.ErrUnauthorized) {
			c.JSON(http.StatusUnauthorized, gin.H{"detail": "Invalid credentials"})
			return
		}
		if errors.Is(err, domainErrors.ErrPendingApproval) {
			c.JSON(http.StatusForbidden, gin.H{"detail": "Account pending admin approval"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Internal error"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"access_token": result.AccessToken,
		"token_type":   result.TokenType,
		"user":         toUserPublic(result.User),
	})
}

func (h *Handler) me(c *gin.Context) {
	user := httpMiddleware.CurrentUser(c)
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	c.JSON(http.StatusOK, toUserPublic(*user))
}

func (h *Handler) logout(c *gin.Context) {
	claims := httpMiddleware.CurrentClaims(c)
	if claims == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	if err := h.authUC.Logout(c.Request.Context(), claims.SessionID); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to logout"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) createUser(c *gin.Context) {
	var payload authRegisterPayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	role := strings.ToLower(strings.TrimSpace(payload.Role))
	autoApprove := payload.IsApproved == nil || *payload.IsApproved
	if role == "parent" {
		if payload.IsApproved == nil {
			autoApprove = false
		}
		if autoApprove {
			if payload.ParentStudentID == nil || *payload.ParentStudentID == 0 {
				c.JSON(http.StatusBadRequest, gin.H{
					"detail": "parent_student_id is required to approve parent account",
				})
				return
			}
			linkedStudent, linkErr := h.validateParentLinkedStudent(
				c.Request.Context(),
				payload.ParentStudentID,
				payload.ChildFullName,
				payload.StudentGroup,
			)
			if linkErr != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to validate parent link"})
				return
			}
			if linkedStudent == nil {
				c.JSON(http.StatusBadRequest, gin.H{
					"detail": "Parent can be approved only after linking to an approved student",
				})
				return
			}
			payload.ParentStudentID = &linkedStudent.ID
			payload.ChildFullName = linkedStudent.FullName
			payload.StudentGroup = linkedStudent.StudentGroup
		}
	}
	result, err := h.authUC.Register(c.Request.Context(), usecase.RegisterInput{
		Role:            payload.Role,
		FullName:        payload.FullName,
		Email:           payload.Email,
		Password:        payload.Password,
		DeviceID:        payload.DeviceID,
		NotifySchedule:  payload.NotifySchedule,
		NotifyRequests:  payload.NotifyRequests,
		StudentGroup:    payload.StudentGroup,
		TeacherName:     payload.TeacherName,
		ChildFullName:   payload.ChildFullName,
		ParentStudentID: payload.ParentStudentID,
		AutoApprove:     autoApprove,
	})
	if err != nil {
		switch {
		case errors.Is(err, domainErrors.ErrConflict):
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Email already registered"})
		case errors.Is(err, domainErrors.ErrInvalidInput):
			c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid input"})
		default:
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Internal error"})
		}
		return
	}
	c.JSON(http.StatusOK, toUserPublic(result.User))
}

func (h *Handler) checkEmailExists(c *gin.Context) {
	email := strings.ToLower(strings.TrimSpace(c.Query("email")))
	if email == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "email is required"})
		return
	}
	_, err := h.userRepo.GetByEmail(c.Request.Context(), email)
	if err == nil {
		c.JSON(http.StatusOK, gin.H{
			"email":   email,
			"exists":  true,
			"matched": true,
		})
		return
	}
	if errors.Is(err, domainErrors.ErrNotFound) {
		c.JSON(http.StatusOK, gin.H{
			"email":   email,
			"exists":  false,
			"matched": false,
		})
		return
	}
	c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to check email"})
}

func (h *Handler) listUsers(c *gin.Context) {
	role := strings.TrimSpace(c.Query("role"))
	approvedRaw := strings.TrimSpace(c.Query("approved"))
	sortBy := strings.TrimSpace(c.DefaultQuery("sort", "id_asc"))
	var approvedFilter *bool
	if approvedRaw != "" {
		switch strings.ToLower(approvedRaw) {
		case "true", "1", "yes":
			value := true
			approvedFilter = &value
		case "false", "0", "no":
			value := false
			approvedFilter = &value
		default:
			c.JSON(http.StatusBadRequest, gin.H{"detail": "approved should be true or false"})
			return
		}
	}
	users, err := h.userRepo.List(c.Request.Context(), role)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to list users"})
		return
	}
	filtered := make([]entity.User, 0, len(users))
	for _, user := range users {
		if approvedFilter != nil && user.IsApproved != *approvedFilter {
			continue
		}
		filtered = append(filtered, user)
	}
	switch sortBy {
	case "name_asc":
		sort.Slice(filtered, func(i, j int) bool {
			return strings.ToLower(filtered[i].FullName) < strings.ToLower(filtered[j].FullName)
		})
	case "name_desc":
		sort.Slice(filtered, func(i, j int) bool {
			return strings.ToLower(filtered[i].FullName) > strings.ToLower(filtered[j].FullName)
		})
	case "created_desc":
		sort.Slice(filtered, func(i, j int) bool {
			return filtered[i].CreatedAt.After(filtered[j].CreatedAt)
		})
	case "created_asc":
		sort.Slice(filtered, func(i, j int) bool {
			return filtered[i].CreatedAt.Before(filtered[j].CreatedAt)
		})
	default:
		sort.Slice(filtered, func(i, j int) bool {
			return filtered[i].ID < filtered[j].ID
		})
	}
	out := make([]gin.H, 0, len(users))
	for _, user := range filtered {
		out = append(out, toUserPublic(user))
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) listApprovedStudents(c *gin.Context) {
	var students []persistence.DBUser
	if err := h.db.WithContext(c.Request.Context()).
		Where("role = ? AND is_approved = ?", "student", true).
		Order("full_name asc").
		Find(&students).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to list students"})
		return
	}
	out := make([]gin.H, 0, len(students))
	for _, student := range students {
		out = append(out, gin.H{
			"id":            student.ID,
			"full_name":     student.FullName,
			"student_group": nullOrString(student.StudentGroup),
		})
	}
	c.JSON(http.StatusOK, out)
}

func (h *Handler) getUser(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid user id"})
		return
	}
	if currentUser.Role != "admin" && currentUser.ID != uint(id) {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	user, err := h.userRepo.GetByID(c.Request.Context(), uint(id))
	if err != nil {
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "User not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load user"})
		return
	}
	c.JSON(http.StatusOK, toUserPublic(*user))
}

func (h *Handler) approveUser(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid user id"})
		return
	}
	user, err := h.userRepo.GetByID(c.Request.Context(), uint(id))
	if err != nil {
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "User not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load user"})
		return
	}
	if user.Role == "parent" {
		if user.ParentStudentID == nil || *user.ParentStudentID == 0 {
			c.JSON(http.StatusBadRequest, gin.H{
				"detail": "parent_student_id is required to approve parent account",
			})
			return
		}
		linkedStudent, linkErr := h.validateParentLinkedStudent(
			c.Request.Context(),
			user.ParentStudentID,
			user.ChildFullName,
			user.StudentGroup,
		)
		if linkErr != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to validate parent link"})
			return
		}
		if linkedStudent == nil {
			c.JSON(http.StatusBadRequest, gin.H{
				"detail": "Parent must be linked to an approved student before approval",
			})
			return
		}
		user.ParentStudentID = &linkedStudent.ID
		user.ChildFullName = linkedStudent.FullName
		user.StudentGroup = linkedStudent.StudentGroup
	}
	now := time.Now().UTC()
	user.IsApproved = true
	user.ApprovedAt = &now
	user.ApprovedBy = &currentUser.ID
	if err := h.userRepo.Update(c.Request.Context(), user); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to approve user"})
		return
	}
	c.JSON(http.StatusOK, toUserPublic(*user))
}

func (h *Handler) getUserPublic(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid user id"})
		return
	}
	user, err := h.userRepo.GetByID(c.Request.Context(), uint(id))
	if err != nil {
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "User not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load user"})
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"id":              user.ID,
		"role":            user.Role,
		"full_name":       user.FullName,
		"avatar_url":      nullOrString(user.AvatarURL),
		"about":           nullOrString(user.About),
		"student_group":   nullOrString(user.StudentGroup),
		"teacher_name":    nullOrString(user.TeacherName),
		"child_full_name": nullOrString(user.ChildFullName),
	})
}

func (h *Handler) deleteUser(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid user id"})
		return
	}
	userID := uint(id)
	if currentUser.ID == userID {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Admin cannot delete self"})
		return
	}
	if err := h.userRepo.Delete(c.Request.Context(), userID); err != nil {
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "User not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete user"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) updateUser(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid user id"})
		return
	}
	userID := uint(id)
	if currentUser.Role != "admin" && currentUser.ID != userID {
		c.JSON(http.StatusForbidden, gin.H{"detail": "Insufficient role"})
		return
	}
	var payload userUpdatePayload
	if err := c.ShouldBindJSON(&payload); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	user, err := h.userRepo.GetByID(c.Request.Context(), userID)
	if err != nil {
		if errors.Is(err, domainErrors.ErrNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "User not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load user"})
		return
	}
	if payload.Role != nil && currentUser.Role == "admin" {
		user.Role = strings.TrimSpace(*payload.Role)
	}
	if payload.FullName != nil {
		user.FullName = strings.TrimSpace(*payload.FullName)
	}
	if payload.Email != nil {
		user.Email = strings.ToLower(strings.TrimSpace(*payload.Email))
	}
	if payload.Phone != nil {
		user.Phone = strings.TrimSpace(*payload.Phone)
	}
	if payload.AvatarURL != nil {
		user.AvatarURL = strings.TrimSpace(*payload.AvatarURL)
	}
	if payload.About != nil {
		user.About = strings.TrimSpace(*payload.About)
	}
	if payload.NotifySchedule != nil {
		user.NotifySchedule = *payload.NotifySchedule
	}
	if payload.NotifyRequests != nil {
		user.NotifyRequests = *payload.NotifyRequests
	}
	if payload.StudentGroup != nil && currentUser.Role == "admin" {
		user.StudentGroup = strings.TrimSpace(*payload.StudentGroup)
	}
	if payload.TeacherName != nil && (currentUser.Role == "admin" || (currentUser.ID == user.ID && user.Role == "teacher")) {
		user.TeacherName = strings.TrimSpace(*payload.TeacherName)
	}
	if payload.ChildFullName != nil && currentUser.Role == "admin" {
		user.ChildFullName = strings.TrimSpace(*payload.ChildFullName)
	}
	if payload.ParentStudentID != nil && currentUser.Role == "admin" {
		if *payload.ParentStudentID == 0 {
			user.ParentStudentID = nil
		} else {
			studentID := *payload.ParentStudentID
			var linkedStudent persistence.DBUser
			if err := h.db.WithContext(c.Request.Context()).
				Where("id = ? AND role = ? AND is_approved = ?", studentID, "student", true).
				First(&linkedStudent).Error; err != nil {
				if errors.Is(err, gorm.ErrRecordNotFound) {
					c.JSON(http.StatusBadRequest, gin.H{
						"detail": "parent_student_id must reference an approved student",
					})
					return
				}
				c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to validate parent_student_id"})
				return
			}
			user.ParentStudentID = &studentID
			if strings.TrimSpace(linkedStudent.FullName) != "" {
				user.ChildFullName = linkedStudent.FullName
			}
			user.StudentGroup = strings.TrimSpace(linkedStudent.StudentGroup)
		}
	}
	if currentUser.Role == "admin" && user.Role == "parent" && payload.ChildFullName != nil {
		user.ChildFullName = strings.TrimSpace(*payload.ChildFullName)
	}
	if payload.IsApproved != nil && currentUser.Role == "admin" {
		if *payload.IsApproved && user.Role == "parent" {
			if user.ParentStudentID == nil || *user.ParentStudentID == 0 {
				c.JSON(http.StatusBadRequest, gin.H{
					"detail": "parent_student_id is required to approve parent account",
				})
				return
			}
			linkedStudent, linkErr := h.validateParentLinkedStudent(
				c.Request.Context(),
				user.ParentStudentID,
				user.ChildFullName,
				user.StudentGroup,
			)
			if linkErr != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to validate parent link"})
				return
			}
			if linkedStudent == nil {
				c.JSON(http.StatusBadRequest, gin.H{
					"detail": "Parent must be linked to an approved student before approval",
				})
				return
			}
			user.ParentStudentID = &linkedStudent.ID
			user.ChildFullName = linkedStudent.FullName
			user.StudentGroup = linkedStudent.StudentGroup
		}
		user.IsApproved = *payload.IsApproved
		if *payload.IsApproved {
			now := time.Now().UTC()
			user.ApprovedAt = &now
			user.ApprovedBy = &currentUser.ID
		} else {
			user.ApprovedAt = nil
			user.ApprovedBy = nil
		}
	}
	if payload.Password != nil && currentUser.Role == "admin" {
		nextPassword := strings.TrimSpace(*payload.Password)
		if nextPassword != "" {
			hash, hashErr := h.authUC.HashPassword(nextPassword)
			if hashErr != nil {
				c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid password"})
				return
			}
			user.PasswordHash = hash
		}
	}
	if payload.BirthDate != nil {
		value := strings.TrimSpace(*payload.BirthDate)
		if value == "" {
			user.BirthDate = nil
		} else {
			parsed, parseErr := time.Parse("2006-01-02", value)
			if parseErr != nil {
				c.JSON(http.StatusBadRequest, gin.H{"detail": "Birth date must be in YYYY-MM-DD format."})
				return
			}
			user.BirthDate = &parsed
		}
	}
	if err := h.userRepo.Update(c.Request.Context(), user); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update user"})
		return
	}
	c.JSON(http.StatusOK, toUserPublic(*user))
}

func (h *Handler) validateParentLinkedStudent(
	ctx context.Context,
	parentStudentID *uint,
	childFullName string,
	studentGroup string,
) (*persistence.DBUser, error) {
	candidate := &entity.User{
		Role:            "parent",
		ParentStudentID: parentStudentID,
		ChildFullName:   strings.TrimSpace(childFullName),
		StudentGroup:    strings.TrimSpace(studentGroup),
	}
	return h.parentLinkedStudent(ctx, candidate)
}

func (h *Handler) registerDeviceToken(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	var payload deviceTokenPayload
	if err := c.ShouldBindJSON(&payload); err != nil || strings.TrimSpace(payload.Token) == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid payload"})
		return
	}
	now := time.Now().UTC()
	model := persistence.DBDeviceToken{
		UserID:     currentUser.ID,
		Token:      strings.TrimSpace(payload.Token),
		Platform:   strings.TrimSpace(payload.Platform),
		CreatedAt:  now,
		LastSeenAt: now,
		RevokedAt:  nil,
	}
	// Upsert by token.
	err := h.db.WithContext(c.Request.Context()).
		Where("token = ?", model.Token).
		Assign(map[string]any{
			"user_id":      model.UserID,
			"platform":     model.Platform,
			"last_seen_at": model.LastSeenAt,
			"revoked_at":   nil,
		}).
		FirstOrCreate(&model).Error
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to register device"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *Handler) listNotifications(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}

	cacheKey := "notifications:user:" + strconv.FormatUint(uint64(currentUser.ID), 10) + ":" + strconv.Itoa(offset) + ":" + strconv.Itoa(limit)
	if cached, err := h.redis.Get(c.Request.Context(), cacheKey).Result(); err == nil {
		var decoded []gin.H
		if json.Unmarshal([]byte(cached), &decoded) == nil {
			c.JSON(http.StatusOK, decoded)
			return
		}
	}

	var models []persistence.DBNotification
	if err := h.db.WithContext(c.Request.Context()).
		Where("user_id = ?", currentUser.ID).
		Order("created_at desc").
		Offset(offset).
		Limit(limit).
		Find(&models).Error; err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load notifications"})
		return
	}
	result := make([]gin.H, 0, len(models))
	for _, item := range models {
		result = append(result, mapNotification(item))
	}
	if blob, err := json.Marshal(result); err == nil {
		_ = h.redis.Set(c.Request.Context(), cacheKey, string(blob), 60*time.Second).Err()
	}
	c.JSON(http.StatusOK, result)
}

func (h *Handler) markNotificationRead(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid notification id"})
		return
	}
	var notification persistence.DBNotification
	if err := h.db.WithContext(c.Request.Context()).
		Where("id = ? AND user_id = ?", id, currentUser.ID).
		First(&notification).Error; err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			c.JSON(http.StatusNotFound, gin.H{"detail": "Notification not found"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to load notification"})
		return
	}
	now := time.Now().UTC()
	if err := h.db.WithContext(c.Request.Context()).Transaction(func(tx *gorm.DB) error {
		readAt := now
		if notification.ReadAt != nil {
			readAt = *notification.ReadAt
		}
		notification.ReadAt = &readAt
		return tx.Where("id = ? AND user_id = ?", id, currentUser.ID).
			Delete(&persistence.DBNotification{}).Error
	}); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to update notification"})
		return
	}
	_ = h.invalidateNotificationCache(c.Request.Context(), currentUser.ID)
	out := mapNotification(notification)
	out["deleted"] = true
	out["is_deleted"] = true
	out["is_unread"] = false
	out["is_read"] = true
	out["status"] = "deleted"
	out["can_mark_read"] = false
	out["can_delete"] = false
	c.JSON(http.StatusOK, out)
}

func (h *Handler) deleteNotification(c *gin.Context) {
	currentUser := httpMiddleware.CurrentUser(c)
	if currentUser == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Unauthorized"})
		return
	}
	id, err := strconv.ParseUint(c.Param("id"), 10, 64)
	if err != nil || id == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Invalid notification id"})
		return
	}
	result := h.db.WithContext(c.Request.Context()).
		Where("id = ? AND user_id = ?", id, currentUser.ID).
		Delete(&persistence.DBNotification{})
	if result.Error != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Failed to delete notification"})
		return
	}
	if result.RowsAffected == 0 {
		c.JSON(http.StatusNotFound, gin.H{"detail": "Notification not found"})
		return
	}
	_ = h.invalidateNotificationCache(c.Request.Context(), currentUser.ID)
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func mapNotification(item persistence.DBNotification) gin.H {
	isRead := item.ReadAt != nil
	status := "unread"
	if isRead {
		status = "read"
	}
	out := gin.H{
		"id":            item.ID,
		"title":         item.Title,
		"body":          item.Body,
		"created_at":    item.CreatedAt.Format(time.RFC3339),
		"read_at":       nil,
		"data":          nil,
		"is_read":       isRead,
		"is_unread":     !isRead,
		"is_deleted":    false,
		"status":        status,
		"can_mark_read": !isRead,
		"can_delete":    true,
		"deleted":       false,
	}
	if item.ReadAt != nil {
		out["read_at"] = item.ReadAt.Format(time.RFC3339)
	}
	if strings.TrimSpace(item.DataJSON) != "" {
		var parsed map[string]any
		if json.Unmarshal([]byte(item.DataJSON), &parsed) == nil {
			out["data"] = parsed
		}
	}
	return out
}

func (h *Handler) createNotifications(ctx context.Context, userIDs []uint, title, body string, data map[string]any) error {
	if len(userIDs) == 0 {
		return nil
	}
	filteredIDs, err := h.filterNotificationRecipients(ctx, userIDs, data)
	if err != nil {
		return err
	}
	if len(filteredIDs) == 0 {
		return nil
	}
	payload, _ := json.Marshal(data)
	now := time.Now().UTC()
	models := make([]persistence.DBNotification, 0, len(filteredIDs))
	for _, id := range filteredIDs {
		models = append(models, persistence.DBNotification{
			UserID:    id,
			Title:     title,
			Body:      body,
			DataJSON:  string(payload),
			CreatedAt: now,
		})
	}
	if err := h.db.WithContext(ctx).Create(&models).Error; err != nil {
		return err
	}
	seen := map[uint]struct{}{}
	for _, id := range filteredIDs {
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		_ = h.invalidateNotificationCache(ctx, id)
	}
	return nil
}

func (h *Handler) filterNotificationRecipients(
	ctx context.Context,
	userIDs []uint,
	data map[string]any,
) ([]uint, error) {
	if len(userIDs) == 0 {
		return nil, nil
	}
	unique := make([]uint, 0, len(userIDs))
	seen := make(map[uint]struct{}, len(userIDs))
	for _, id := range userIDs {
		if id == 0 {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		unique = append(unique, id)
	}
	if len(unique) == 0 {
		return nil, nil
	}

	notificationType := strings.ToLower(strings.TrimSpace(anyToString(data["type"])))
	query := h.db.WithContext(ctx).
		Model(&persistence.DBUser{}).
		Where("id IN ?", unique).
		Where("is_approved = ?", true)
	switch notificationType {
	case "schedule_update":
		query = query.Where("notify_schedule = ?", true)
	case "request_created", "request_updated", "request_update":
		query = query.Where("notify_requests = ?", true)
	}

	var filtered []uint
	if err := query.Pluck("id", &filtered).Error; err != nil {
		return nil, err
	}
	return filtered, nil
}

func anyToString(value any) string {
	switch item := value.(type) {
	case string:
		return item
	case []byte:
		return string(item)
	default:
		return ""
	}
}

func (h *Handler) invalidateNotificationCache(ctx context.Context, userID uint) error {
	pattern := "notifications:user:" + strconv.FormatUint(uint64(userID), 10) + ":*"
	iter := h.redis.Scan(ctx, 0, pattern, 100).Iterator()
	for iter.Next(ctx) {
		_ = h.redis.Del(ctx, iter.Val()).Err()
	}
	return iter.Err()
}
