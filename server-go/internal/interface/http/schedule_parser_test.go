package http

import (
	"testing"
	"time"
)

func TestParseScheduleDateFromFilename(t *testing.T) {
	t.Run("dd.mm.yyyy", func(t *testing.T) {
		got, ok := parseScheduleDateFromFilename("14.01.2026 1-2 ауысым.docx")
		if !ok {
			t.Fatalf("expected date to be parsed")
		}
		if got.Format("2006-01-02") != "2026-01-14" {
			t.Fatalf("unexpected date: %s", got.Format("2006-01-02"))
		}
	})

	t.Run("yyyy-mm-dd", func(t *testing.T) {
		got, ok := parseScheduleDateFromFilename("schedule_2026-03-10.docx")
		if !ok {
			t.Fatalf("expected date to be parsed")
		}
		if got.Format("2006-01-02") != "2026-03-10" {
			t.Fatalf("unexpected date: %s", got.Format("2006-01-02"))
		}
	})

	t.Run("missing date", func(t *testing.T) {
		if _, ok := parseScheduleDateFromFilename("schedule-latest.docx"); ok {
			t.Fatalf("expected parsing to fail for filename without date")
		}
	})
}

func TestParseScheduleDateInputPriority(t *testing.T) {
	raw := "2026-03-11"
	detected := time.Date(2026, time.March, 9, 0, 0, 0, 0, time.UTC)

	got, err := parseScheduleDateInput(raw, "14.01.2026.docx", &detected)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil || got.Format("2006-01-02") != "2026-03-11" {
		t.Fatalf("expected explicit date to win, got %v", got)
	}

	got, err = parseScheduleDateInput("", "14.01.2026.docx", &detected)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil || got.Format("2006-01-02") != "2026-03-09" {
		t.Fatalf("expected detected date, got %v", got)
	}

	got, err = parseScheduleDateInput("", "14.01.2026.docx", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got == nil || got.Format("2006-01-02") != "2026-01-14" {
		t.Fatalf("expected filename date, got %v", got)
	}
}

func TestParseScheduleLessonsFromDOCXRejectsNonDocx(t *testing.T) {
	_, _, err := parseScheduleLessonsFromDOCX("schedule.xlsx", []byte("x"))
	if err == nil {
		t.Fatalf("expected error for non-docx filename")
	}
}

func TestExtractGroupTokens(t *testing.T) {
	got := extractGroupTokens("ИС23-3А ИС25-1Б")
	if len(got) != 2 {
		t.Fatalf("expected 2 group tokens, got %d (%v)", len(got), got)
	}
	if got[0] != "ИС23-3А" || got[1] != "ИС25-1Б" {
		t.Fatalf("unexpected tokenization: %v", got)
	}
}

func TestGroupIncludesToken(t *testing.T) {
	if !groupIncludesToken("ИС23-3А ИС25-1Б", "ИС25-1Б") {
		t.Fatalf("expected merged group text to include token")
	}
	if groupIncludesToken("ИС23-3А", "ИС99-9Я") {
		t.Fatalf("did not expect unknown group token")
	}
}
