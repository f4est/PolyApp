package http

import (
	"testing"

	"polyapp/server-go/internal/domain/entity"
)

func TestScopedJournalGroupNameForUser(t *testing.T) {
	teacher := &entity.User{ID: 17, Role: "teacher"}
	if got := scopedJournalGroupNameForUser(teacher, "P22-3E"); got != "P22-3E@@t17" {
		t.Fatalf("unexpected scoped name: %s", got)
	}

	admin := &entity.User{ID: 1, Role: "admin"}
	if got := scopedJournalGroupNameForUser(admin, "P22-3E"); got != "P22-3E" {
		t.Fatalf("admin should not receive scoped name, got: %s", got)
	}

	if got := scopedJournalGroupNameForUser(nil, "P22-3E"); got != "P22-3E" {
		t.Fatalf("nil user should keep name unchanged, got: %s", got)
	}
}

func TestBaseJournalGroupName(t *testing.T) {
	if got := baseJournalGroupName("P22-3E@@t17"); got != "P22-3E" {
		t.Fatalf("unexpected base name: %s", got)
	}
	if got := baseJournalGroupName("P22-3E"); got != "P22-3E" {
		t.Fatalf("unexpected base name without suffix: %s", got)
	}
	if got := baseJournalGroupName("P22-3E@@tabc"); got != "P22-3E@@tabc" {
		t.Fatalf("non numeric suffix must stay unchanged: %s", got)
	}
}

func TestTeacherIDFromScopedJournalGroupName(t *testing.T) {
	id, ok := teacherIDFromScopedJournalGroupName("P22-3E@@t99")
	if !ok || id != 99 {
		t.Fatalf("expected teacher id 99, got (%d, %v)", id, ok)
	}

	if _, ok := teacherIDFromScopedJournalGroupName("P22-3E"); ok {
		t.Fatalf("non scoped name should not return teacher id")
	}
}

func TestTeacherGroupRequestHelpers(t *testing.T) {
	if !isTeacherGroupAccessRequest("Запрос на преподавание группы") {
		t.Fatalf("expected teacher group access request to be recognized")
	}
	if isTeacherGroupAccessRequest("Справка") {
		t.Fatalf("unexpected teacher group request detection")
	}

	if !isTeacherGroupDecisionStatus("approved") {
		t.Fatalf("approved should be a valid decision status")
	}
	if !isTeacherGroupDecisionStatus("Отклонена") {
		t.Fatalf("localized reject should be a valid decision status")
	}
	if isTeacherGroupDecisionStatus("На рассмотрении") {
		t.Fatalf("intermediate status must be invalid for teacher group decision")
	}

	if got := normalizeTeacherGroupDecisionStatus("Одобрена"); got != "approved" {
		t.Fatalf("unexpected normalized status: %s", got)
	}
	if got := normalizeTeacherGroupDecisionStatus("Отклонена"); got != "rejected" {
		t.Fatalf("unexpected normalized status: %s", got)
	}
}

func TestExtractGroupNameFromRequestDetails(t *testing.T) {
	if got := extractGroupNameFromRequestDetails("Группа: P22-3E\nКомментарий: test"); got != "P22-3E" {
		t.Fatalf("expected group name P22-3E, got: %s", got)
	}
	if got := extractGroupNameFromRequestDetails("Group: WEB25-1A"); got != "WEB25-1A" {
		t.Fatalf("expected english group line parsing, got: %s", got)
	}
	if got := extractGroupNameFromRequestDetails("Комментарий без группы"); got != "" {
		t.Fatalf("expected empty group for unrelated details, got: %s", got)
	}
}

func TestGroupsMatch(t *testing.T) {
	if !groupsMatch("ИС23-3А ИС25-1Б", "ИС25-1Б") {
		t.Fatalf("expected merged group name to match token")
	}
	if groupsMatch("P22-3E", "P22-4D") {
		t.Fatalf("different groups must not match")
	}
}

func TestIsAbsenceToken(t *testing.T) {
	if !isAbsenceToken("Н") || !isAbsenceToken("n") {
		t.Fatalf("absence tokens must be recognized")
	}
	if isAbsenceToken("90") {
		t.Fatalf("numeric grade must not be recognized as absence")
	}
}

func TestSanitizeGroupCatalog(t *testing.T) {
	in := []string{
		" P22-3E ",
		"P22-3E@@t1",
		"P22-3E@@t2",
		"  ",
		"П22-4Д",
		"П22-4Д@@t5",
	}
	got := sanitizeGroupCatalog(in)
	if len(got) != 2 {
		t.Fatalf("expected 2 groups, got %d: %#v", len(got), got)
	}
	if got[0] != "P22-3E" || got[1] != "П22-4Д" {
		t.Fatalf("unexpected sanitized groups: %#v", got)
	}
}
