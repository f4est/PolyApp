package http

import (
	"strconv"
	"strings"
	"time"

	"polyapp/server-go/internal/infrastructure/persistence"
	httpMiddleware "polyapp/server-go/internal/interface/http/middleware"

	"github.com/gin-gonic/gin"
)

var requestTypes = []string{
	"Справка на онай",
	"Справка на военкомат",
	"Справка по месту требования",
	"Приложение №2",
	"Приложение №4",
	"Приложение №6",
	"Приложение №29",
	"Приложение №31",
	"Справка в школу",
	"Запрос на преподавание группы",
}

var requestStatuses = []string{
	"Отправлена",
	"На рассмотрении",
	"Отклонена",
	"В работе",
	"Готова",
}

type requestPayload struct {
	RequestType string `json:"request_type"`
	GroupName   string `json:"group_name"`
	Details     string `json:"details"`
}

type requestUpdatePayload struct {
	Status  *string `json:"status"`
	Details *string `json:"details"`
	Comment *string `json:"comment"`
}

type journalGroupPayload struct {
	Name string `json:"name"`
}

type journalStudentPayload struct {
	GroupName   string `json:"group_name"`
	StudentName string `json:"student_name"`
}

type journalDatePayload struct {
	GroupName  string `json:"group_name"`
	ClassDate  string `json:"class_date"`
	LessonSlot *int   `json:"lesson_slot"`
}

type attendancePayload struct {
	GroupName   string `json:"group_name"`
	ClassDate   string `json:"class_date"`
	LessonSlot  *int   `json:"lesson_slot"`
	StudentName string `json:"student_name"`
	Present     bool   `json:"present"`
}

type gradePayload struct {
	GroupName   string `json:"group_name"`
	ClassDate   string `json:"class_date"`
	StudentName string `json:"student_name"`
	Grade       int    `json:"grade"`
}

type teacherAssignmentPayload struct {
	TeacherID uint   `json:"teacher_id"`
	GroupName string `json:"group_name"`
	Subject   string `json:"subject"`
}

type teacherAssignmentUpdatePayload struct {
	GroupName *string `json:"group_name"`
	Subject   *string `json:"subject"`
}

type examUploadUpdatePayload struct {
	GroupName *string `json:"group_name"`
	ExamName  *string `json:"exam_name"`
}

func (h *Handler) RegisterAcademicRoutes(router *gin.Engine, auth *httpMiddleware.AuthMiddleware) {
	router.GET("/exams/template", h.downloadExamTemplate)

	secured := router.Group("/")
	secured.Use(auth.RequireAuth())
	{
		secured.GET("/schedule", h.listScheduleUploads)
		secured.GET("/schedule/latest", h.latestScheduleUpload)
		secured.GET("/schedule/groups", h.scheduleGroups)
		secured.GET("/schedule/teachers", h.scheduleTeachers)
		secured.GET("/schedule/me", h.scheduleForMe)
		secured.GET("/schedule/group/:group", h.scheduleForGroup)
		secured.GET("/schedule/teacher/:teacher", h.scheduleForTeacher)
		secured.POST("/schedule/upload", httpMiddleware.RequireRoles("admin", "teacher"), h.uploadSchedule)
		secured.PATCH("/schedule/:id", httpMiddleware.RequireRoles("admin"), h.updateScheduleUpload)
		secured.DELETE("/schedule/:id", httpMiddleware.RequireRoles("admin"), h.deleteScheduleUpload)

		secured.GET("/journal/groups", h.listJournalGroups)
		secured.GET("/journal/groups/catalog", httpMiddleware.RequireRoles("teacher", "admin"), h.listJournalGroupCatalog)
		secured.POST("/journal/groups", httpMiddleware.RequireRoles("admin"), h.upsertJournalGroup)
		secured.DELETE("/journal/groups", httpMiddleware.RequireRoles("admin"), h.deleteJournalGroup)
		secured.GET("/journal/students", h.listJournalStudents)
		secured.GET(
			"/journal/groups/:group_name/confirmed-students",
			httpMiddleware.RequireRoles("teacher", "admin"),
			h.listConfirmedStudentsForGroup,
		)
		secured.POST("/journal/students", httpMiddleware.RequireRoles("teacher", "admin"), h.upsertJournalStudent)
		secured.DELETE("/journal/students", httpMiddleware.RequireRoles("teacher", "admin"), h.deleteJournalStudent)
		secured.GET("/journal/dates", h.listJournalDates)
		secured.POST("/journal/dates", httpMiddleware.RequireRoles("teacher", "admin"), h.upsertJournalDate)
		secured.DELETE("/journal/dates", httpMiddleware.RequireRoles("teacher", "admin"), h.deleteJournalDate)

		secured.POST("/requests", h.createRequest)
		secured.GET("/requests", h.listRequests)
		secured.DELETE("/requests/:id", h.deleteRequest)
		secured.PATCH("/requests/:id", h.updateRequest)

		secured.POST("/attendance", httpMiddleware.RequireRoles("teacher", "admin"), h.upsertAttendance)
		secured.GET("/attendance", httpMiddleware.RequireRoles("teacher", "admin", "parent"), h.listAttendance)
		secured.DELETE("/attendance", httpMiddleware.RequireRoles("teacher", "admin"), h.deleteAttendance)
		secured.GET("/attendance/summary", httpMiddleware.RequireRoles("teacher", "admin", "parent"), h.attendanceSummary)

		secured.POST("/grades", httpMiddleware.RequireRoles("teacher", "admin"), h.upsertGrade)
		secured.GET("/grades", httpMiddleware.RequireRoles("teacher", "admin", "parent"), h.listGrades)
		secured.DELETE("/grades", httpMiddleware.RequireRoles("teacher", "admin"), h.deleteGrade)
		secured.GET("/grades/summary", httpMiddleware.RequireRoles("teacher", "admin", "parent"), h.gradeSummary)

		secured.GET("/grading-presets", h.listGradingPresetsV2)
		secured.POST("/grading-presets", httpMiddleware.RequireRoles("teacher", "admin"), h.createGradingPresetV2)
		secured.GET("/grading-presets/:id", h.getGradingPresetV2)
		secured.PATCH("/grading-presets/:id", httpMiddleware.RequireRoles("teacher", "admin"), h.updateGradingPresetV2)
		secured.POST("/grading-presets/:id/publish", httpMiddleware.RequireRoles("teacher", "admin"), h.publishGradingPresetV2)
		secured.POST("/grading-presets/:id/unpublish", httpMiddleware.RequireRoles("teacher", "admin"), h.unpublishGradingPresetV2)

		secured.GET("/journal/v2/groups/:group_name/preset", h.getGroupPresetBindingV2)
		secured.PUT("/journal/v2/groups/:group_name/preset", httpMiddleware.RequireRoles("teacher", "admin"), h.applyGroupPresetBindingV2)
		secured.DELETE("/journal/v2/groups/:group_name/preset", httpMiddleware.RequireRoles("teacher", "admin"), h.deleteGroupPresetBindingV2)

		secured.GET("/journal/v2/groups/:group_name/grid", h.getJournalGridV2)
		secured.POST("/journal/v2/groups/:group_name/date-cells/bulk-upsert", httpMiddleware.RequireRoles("teacher", "admin"), h.bulkUpsertDateCellsV2)
		secured.POST("/journal/v2/groups/:group_name/date-cells/bulk-delete", httpMiddleware.RequireRoles("teacher", "admin"), h.bulkDeleteDateCellsV2)
		secured.POST("/journal/v2/groups/:group_name/manual-cells/bulk-upsert", httpMiddleware.RequireRoles("teacher", "admin"), h.bulkUpsertManualCellsV2)
		secured.POST("/journal/v2/groups/:group_name/recalculate", httpMiddleware.RequireRoles("teacher", "admin"), h.recalculateJournalV2)

		secured.GET("/makeups", h.listMakeupCases)
		secured.POST("/makeups", httpMiddleware.RequireRoles("teacher", "admin"), h.createMakeupCase)
		secured.GET("/makeups/:id", h.getMakeupCase)
		secured.PATCH("/makeups/:id", h.patchMakeupCase)
		secured.DELETE("/makeups/:id", httpMiddleware.RequireRoles("teacher", "admin"), h.deleteMakeupCase)
		secured.GET("/makeups/:id/messages", h.listMakeupMessages)
		secured.POST("/makeups/:id/messages", h.createMakeupMessage)
		secured.POST("/makeups/:id/proof", httpMiddleware.RequireRoles("student", "admin"), h.uploadMakeupProof)
		secured.POST("/makeups/:id/submission", httpMiddleware.RequireRoles("student", "admin"), h.uploadMakeupSubmission)
		secured.GET("/makeups/groups", httpMiddleware.RequireRoles("teacher", "admin"), h.listMakeupGroupsForActor)
		secured.GET("/makeups/groups/:group_name/students", httpMiddleware.RequireRoles("teacher", "admin"), h.listMakeupStudentsForGroup)

		secured.GET("/teacher-assignments", httpMiddleware.RequireRoles("teacher", "admin"), h.listTeacherAssignments)
		secured.POST("/teacher-assignments", httpMiddleware.RequireRoles("admin"), h.createTeacherAssignment)
		secured.PATCH("/teacher-assignments/:id", httpMiddleware.RequireRoles("admin"), h.updateTeacherAssignment)
		secured.DELETE("/teacher-assignments/:id", httpMiddleware.RequireRoles("admin"), h.deleteTeacherAssignment)

		secured.GET("/departments", httpMiddleware.RequireRoles("admin"), h.listDepartments)
		secured.POST("/departments", httpMiddleware.RequireRoles("admin"), h.createDepartment)
		secured.PATCH("/departments/:id", httpMiddleware.RequireRoles("admin"), h.patchDepartment)
		secured.DELETE("/departments/:id", httpMiddleware.RequireRoles("admin"), h.deleteDepartment)
		secured.GET("/departments/:id/groups", httpMiddleware.RequireRoles("admin"), h.listDepartmentGroups)
		secured.POST("/departments/:id/groups", httpMiddleware.RequireRoles("admin"), h.addDepartmentGroup)
		secured.DELETE("/departments/:id/groups", httpMiddleware.RequireRoles("admin"), h.removeDepartmentGroup)
		secured.GET("/curator-groups", httpMiddleware.RequireRoles("admin"), h.listCuratorGroups)
		secured.POST("/curator-groups", httpMiddleware.RequireRoles("admin"), h.createCuratorGroup)
		secured.DELETE("/curator-groups/:id", httpMiddleware.RequireRoles("admin"), h.deleteCuratorGroup)

		secured.GET("/analytics/groups", httpMiddleware.RequireRoles("teacher", "admin"), h.analyticsGroups)
		secured.GET("/analytics/attendance", httpMiddleware.RequireRoles("teacher", "admin"), h.analyticsAttendance)
		secured.GET("/analytics/grades", httpMiddleware.RequireRoles("teacher", "admin"), h.analyticsGrades)

		secured.GET("/exams", httpMiddleware.RequireRoles("student", "parent", "teacher", "admin"), h.listExamGrades)
		secured.GET("/exams/uploads", httpMiddleware.RequireRoles("teacher", "admin"), h.listExamUploads)
		secured.DELETE("/exams/uploads/past", httpMiddleware.RequireRoles("admin"), h.deletePastExamUploads)
		secured.PATCH("/exams/uploads/:id", httpMiddleware.RequireRoles("teacher", "admin"), h.updateExamUpload)
		secured.DELETE("/exams/uploads/:id", httpMiddleware.RequireRoles("teacher", "admin"), h.deleteExamUpload)
		secured.POST("/exams/upload", httpMiddleware.RequireRoles("teacher", "admin"), h.uploadExamGrades)
	}
}

func parseDate(value string) (time.Time, error) {
	parsed, err := time.Parse("2006-01-02", strings.TrimSpace(value))
	if err != nil {
		return time.Time{}, err
	}
	return parsed.UTC(), nil
}

func normalizeLessonSlot(value int) int {
	if value < 1 {
		return 1
	}
	return value
}

func parseOptionalLessonSlot(raw string) (*int, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, nil
	}
	value, err := strconv.Atoi(trimmed)
	if err != nil {
		return nil, err
	}
	if value < 1 {
		return nil, strconv.ErrSyntax
	}
	normalized := normalizeLessonSlot(value)
	return &normalized, nil
}

func lessonSlotFromPointer(value *int) int {
	if value == nil {
		return 1
	}
	return normalizeLessonSlot(*value)
}

func contains(items []string, value string) bool {
	value = normalizeGroupName(value)
	for _, item := range items {
		if strings.EqualFold(normalizeGroupName(item), value) {
			return true
		}
	}
	return false
}

func mapIDSet(in map[uint]struct{}) []uint {
	out := make([]uint, 0, len(in))
	for key := range in {
		out = append(out, key)
	}
	return out
}

func mapScheduleUpload(item persistence.DBScheduleUpload) gin.H {
	out := gin.H{
		"id":            item.ID,
		"filename":      item.Filename,
		"db_filename":   nullOrString(item.DBFilename),
		"schedule_date": nil,
		"uploaded_at":   item.UploadedAt.Format(time.RFC3339),
	}
	if item.ScheduleDate != nil {
		out["schedule_date"] = dateOnly(*item.ScheduleDate)
	}
	return out
}

func mapScheduleLessons(lessons []persistence.DBScheduleLesson) []gin.H {
	out := make([]gin.H, 0, len(lessons))
	seen := make(map[string]struct{}, len(lessons))
	for _, row := range lessons {
		key := strings.ToLower(strings.TrimSpace(strings.Join([]string{
			strconv.Itoa(row.Shift),
			strconv.Itoa(row.Period),
			strings.TrimSpace(row.TimeText),
			strings.TrimSpace(row.GroupName),
			strings.TrimSpace(row.Lesson),
			strings.TrimSpace(row.TeacherName),
		}, "|")))
		if key != "" {
			if _, exists := seen[key]; exists {
				continue
			}
			seen[key] = struct{}{}
		}
		out = append(out, gin.H{
			"shift":      row.Shift,
			"period":     row.Period,
			"time":       row.TimeText,
			"audience":   row.Audience,
			"lesson":     row.Lesson,
			"group_name": row.GroupName,
		})
	}
	return out
}
