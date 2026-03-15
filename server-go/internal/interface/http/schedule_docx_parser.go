package http

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	reDocxDateAny    = regexp.MustCompile(`\b(\d{2}\.\d{2}\.\d{4})\b`)
	reDocxPeriod     = regexp.MustCompile(`(?i)\b([1-9])\s*пара\b`)
	reDocxTimeAny    = regexp.MustCompile(`(\d{1,2})(?:[:\.]|)?([0-9⁰¹²³⁴⁵⁶⁷⁸⁹]{2})\s*[-–—]\s*(\d{1,2})(?:[:\.]|)?([0-9⁰¹²³⁴⁵⁶⁷⁸⁹]{2})`)
	reDocxPeriodTime = regexp.MustCompile(`(?i)([1-9])\s*пара.*?(\d{1,2})(?:[:\.]|)?([0-9⁰¹²³⁴⁵⁶⁷⁸⁹]{2})\s*[-–—]\s*(\d{1,2})(?:[:\.]|)?([0-9⁰¹²³⁴⁵⁶⁷⁸⁹]{2})`)
	reDocxGroup      = regexp.MustCompile(`^[\p{L}]+[0-9]{2}-[0-9]+[\p{L}]*$`)
	reDocxGroupToken = regexp.MustCompile(`[\p{L}]+[0-9]{2}-[0-9]+[\p{L}]*`)
	reDocxHasLetter  = regexp.MustCompile(`\p{L}`)
	reDocxSpaces     = regexp.MustCompile(`[ \t]+`)
)

var docxSupersReplacer = strings.NewReplacer(
	"⁰", "0",
	"¹", "1",
	"²", "2",
	"³", "3",
	"⁴", "4",
	"⁵", "5",
	"⁶", "6",
	"⁷", "7",
	"⁸", "8",
	"⁹", "9",
)

var docxColorLabels = map[string]string{
	"D9D9D9": "Практика",
	"FFFF00": "Онлайн",
}

type scheduleLessonDraft struct {
	Shift       int
	Period      int
	TimeText    string
	Audience    string
	Lesson      string
	GroupName   string
	TeacherName string
}

type docxCell struct {
	Text string
	Fill string
}

type docxTable [][]docxCell

func parseScheduleLessonsFromDOCX(filename string, data []byte) ([]scheduleLessonDraft, *time.Time, error) {
	if strings.ToLower(filepath.Ext(filename)) != ".docx" {
		return nil, nil, fmt.Errorf("unsupported schedule file format. Use .docx")
	}
	tables, fullText, err := parseDOCXTables(data)
	if err != nil {
		return nil, nil, err
	}
	if len(tables) == 0 {
		return nil, nil, fmt.Errorf("DOCX does not contain schedule tables")
	}

	// Keep parser behavior aligned with the Python algorithm: first table is
	// first shift, second table is second shift.
	usable := make([]docxTable, 0, 2)
	if len(tables) >= 1 {
		usable = append(usable, tables[0])
	}
	if len(tables) >= 2 {
		usable = append(usable, tables[1])
	}
	if len(usable) == 0 {
		return nil, nil, fmt.Errorf("DOCX does not contain data rows")
	}

	lessons := make([]scheduleLessonDraft, 0, 256)
	for i, table := range usable {
		shift := i + 1
		lessons = append(lessons, buildScheduleDraftsForShift(table, shift)...)
	}
	lessons = normalizeScheduleDraftGroups(lessons)
	if len(lessons) == 0 {
		return nil, nil, fmt.Errorf("DOCX parsed but no lessons matched expected structure")
	}

	date := detectScheduleDate(fullText, usable)
	return lessons, date, nil
}

func parseDOCXTables(data []byte) ([]docxTable, string, error) {
	xmlBlob, err := extractDOCXDocumentXML(data)
	if err != nil {
		return nil, "", err
	}

	decoder := xml.NewDecoder(bytes.NewReader(xmlBlob))
	var (
		tables []docxTable

		currentTable docxTable
		currentRow   []docxCell

		cellBuilder strings.Builder
		cellFill    string

		inTable  bool
		inRow    bool
		inCell   bool
		inCellPr bool
		inText   bool
		inPara   bool

		fullTextBuilder strings.Builder
	)

	for {
		token, err := decoder.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, "", fmt.Errorf("invalid DOCX XML: %w", err)
		}

		switch typed := token.(type) {
		case xml.StartElement:
			switch typed.Name.Local {
			case "tbl":
				inTable = true
				currentTable = docxTable{}
			case "tr":
				if inTable {
					inRow = true
					currentRow = []docxCell{}
				}
			case "tc":
				if inRow {
					inCell = true
					cellBuilder.Reset()
					cellFill = ""
				}
			case "tcPr":
				if inCell {
					inCellPr = true
				}
			case "shd":
				if inCell && inCellPr {
					for _, attr := range typed.Attr {
						if attr.Name.Local != "fill" {
							continue
						}
						fill := strings.ToUpper(strings.TrimSpace(attr.Value))
						if fill != "" && !strings.EqualFold(fill, "auto") {
							cellFill = fill
						}
					}
				}
			case "p":
				if inCell && cellBuilder.Len() > 0 {
					cellBuilder.WriteByte('\n')
				}
				inPara = true
			case "t":
				inText = true
			}

		case xml.EndElement:
			switch typed.Name.Local {
			case "t":
				inText = false
			case "p":
				inPara = false
			case "tcPr":
				inCellPr = false
			case "tc":
				if inCell {
					currentRow = append(currentRow, docxCell{
						Text: cleanCellText(cellBuilder.String()),
						Fill: cellFill,
					})
					inCell = false
				}
			case "tr":
				if inRow {
					currentTable = append(currentTable, currentRow)
					inRow = false
				}
			case "tbl":
				if inTable {
					tables = append(tables, currentTable)
					inTable = false
				}
			}

		case xml.CharData:
			if !inText {
				continue
			}
			text := string(typed)
			if inCell {
				cellBuilder.WriteString(text)
			}
			if inPara {
				fullTextBuilder.WriteString(text)
				fullTextBuilder.WriteByte(' ')
			}
		}
	}

	return tables, fullTextBuilder.String(), nil
}

func extractDOCXDocumentXML(data []byte) ([]byte, error) {
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return nil, fmt.Errorf("invalid DOCX archive")
	}
	for _, file := range reader.File {
		if file.Name != "word/document.xml" {
			continue
		}
		src, err := file.Open()
		if err != nil {
			return nil, fmt.Errorf("failed to open document.xml")
		}
		defer src.Close()
		blob, err := io.ReadAll(src)
		if err != nil {
			return nil, fmt.Errorf("failed to read document.xml")
		}
		return blob, nil
	}
	return nil, fmt.Errorf("DOCX document.xml not found")
}

func detectScheduleDate(fullText string, tables []docxTable) *time.Time {
	if m := reDocxDateAny.FindStringSubmatch(fullText); len(m) == 2 {
		if parsed, err := parseDOCXDate(m[1]); err == nil {
			return &parsed
		}
	}
	for _, table := range tables {
		if len(table) == 0 {
			continue
		}
		headerText := make([]string, 0, len(table[0]))
		for _, cell := range table[0] {
			if strings.TrimSpace(cell.Text) != "" {
				headerText = append(headerText, cell.Text)
			}
		}
		if m := reDocxDateAny.FindStringSubmatch(strings.Join(headerText, " ")); len(m) == 2 {
			if parsed, err := parseDOCXDate(m[1]); err == nil {
				return &parsed
			}
		}
	}
	return nil
}

func parseDOCXDate(ddmmyyyy string) (time.Time, error) {
	parsed, err := time.Parse("02.01.2006", strings.TrimSpace(ddmmyyyy))
	if err != nil {
		return time.Time{}, err
	}
	return time.Date(parsed.Year(), parsed.Month(), parsed.Day(), 0, 0, 0, 0, time.UTC), nil
}

func buildScheduleDraftsForShift(table docxTable, shift int) []scheduleLessonDraft {
	if len(table) <= 1 {
		return nil
	}
	timeMap := extractTimeMapFromHeader(table)
	out := make([]scheduleLessonDraft, 0, 128)

	for _, row := range table[1:] {
		if len(row) == 0 {
			continue
		}
		audience := cleanCellText(row[0].Text)
		if audience == "" {
			continue
		}
		rest := row[1:]
		if len(rest) == 0 {
			continue
		}
		pairsMode := len(rest)%2 == 0 && len(rest) >= 2
		isSportHall := strings.HasPrefix(strings.ToLower(audience), "спорт зал")

		if isSportHall {
			if pairsMode {
				period := 1
				for i := 0; i+1 < len(rest); i += 2 {
					label := labelByFill(firstNonEmpty(rest[i].Fill, rest[i+1].Fill))
					pairs := normalizeSportHall(rest[i].Text, rest[i+1].Text)
					for _, pair := range pairs {
						lessonText := appendLabel(pair.lesson, label)
						groupName := strings.TrimSpace(pair.group)
						if lessonText == "" && groupName == "" {
							continue
						}
						out = append(out, scheduleLessonDraft{
							Shift:     shift,
							Period:    period,
							TimeText:  timeMap[period],
							Audience:  audience,
							Lesson:    lessonText,
							GroupName: groupName,
							TeacherName: deriveTeacherNameFromLesson(
								lessonText,
							),
						})
					}
					period++
				}
			} else {
				for i, cell := range rest {
					period := i + 1
					label := labelByFill(cell.Fill)
					pairs := normalizeSportHall(cell.Text, "")
					for _, pair := range pairs {
						lessonText := appendLabel(pair.lesson, label)
						groupName := strings.TrimSpace(pair.group)
						if lessonText == "" && groupName == "" {
							continue
						}
						out = append(out, scheduleLessonDraft{
							Shift:     shift,
							Period:    period,
							TimeText:  timeMap[period],
							Audience:  audience,
							Lesson:    lessonText,
							GroupName: groupName,
							TeacherName: deriveTeacherNameFromLesson(
								lessonText,
							),
						})
					}
				}
			}
			continue
		}

		if pairsMode {
			period := 1
			for i := 0; i+1 < len(rest); i += 2 {
				label := labelByFill(firstNonEmpty(rest[i].Fill, rest[i+1].Fill))
				lessonText := appendLabel(rest[i].Text, label)
				groupName := cleanCellText(rest[i+1].Text)
				if lessonText == "" && groupName == "" {
					period++
					continue
				}
				out = append(out, scheduleLessonDraft{
					Shift:     shift,
					Period:    period,
					TimeText:  timeMap[period],
					Audience:  audience,
					Lesson:    lessonText,
					GroupName: groupName,
					TeacherName: deriveTeacherNameFromLesson(
						lessonText,
					),
				})
				period++
			}
			continue
		}

		for i, cell := range rest {
			period := i + 1
			label := labelByFill(cell.Fill)
			lines := splitCleanLines(cell.Text)
			if len(lines) >= 2 && reDocxGroup.MatchString(lines[len(lines)-1]) {
				lessonText := appendLabel(strings.Join(lines[:len(lines)-1], "\n"), label)
				groupName := lines[len(lines)-1]
				out = append(out, scheduleLessonDraft{
					Shift:     shift,
					Period:    period,
					TimeText:  timeMap[period],
					Audience:  audience,
					Lesson:    lessonText,
					GroupName: groupName,
					TeacherName: deriveTeacherNameFromLesson(
						lessonText,
					),
				})
				continue
			}
			if len(lines) > 0 {
				lessonText := appendLabel(lines[0], label)
				out = append(out, scheduleLessonDraft{
					Shift:     shift,
					Period:    period,
					TimeText:  timeMap[period],
					Audience:  audience,
					Lesson:    lessonText,
					GroupName: "",
					TeacherName: deriveTeacherNameFromLesson(
						lessonText,
					),
				})
			}
		}
	}

	return out
}

func extractTimeMapFromHeader(table docxTable) map[int]string {
	out := map[int]string{}
	if len(table) == 0 {
		return out
	}
	header := table[0]
	for _, cell := range header {
		text := supersToNormal(cleanCellText(cell.Text))
		if text == "" {
			continue
		}
		periodMatch := reDocxPeriod.FindStringSubmatch(text)
		timeMatch := reDocxTimeAny.FindStringSubmatch(text)
		if len(periodMatch) == 2 && len(timeMatch) == 5 {
			period, err := strconv.Atoi(periodMatch[1])
			if err != nil {
				continue
			}
			out[period] = buildTimeRange(timeMatch[1], timeMatch[2], timeMatch[3], timeMatch[4])
		}
	}
	if len(out) >= 4 {
		return out
	}
	fullHeader := make([]string, 0, len(header))
	for _, cell := range header {
		if text := supersToNormal(cleanCellText(cell.Text)); text != "" {
			fullHeader = append(fullHeader, text)
		}
	}
	big := strings.Join(fullHeader, " ")
	for _, match := range reDocxPeriodTime.FindAllStringSubmatch(big, -1) {
		if len(match) != 6 {
			continue
		}
		period, err := strconv.Atoi(match[1])
		if err != nil {
			continue
		}
		out[period] = buildTimeRange(match[2], match[3], match[4], match[5])
	}
	return out
}

type lessonGroupPair struct {
	lesson string
	group  string
}

func normalizeSportHall(lessonCell string, groupCell string) []lessonGroupPair {
	lessons := splitCleanLines(lessonCell)
	groups := splitCleanLines(groupCell)
	if len(lessons) > 0 && len(lessons) == len(groups) {
		out := make([]lessonGroupPair, 0, len(lessons))
		for i := 0; i < len(lessons); i++ {
			out = append(out, lessonGroupPair{
				lesson: lessons[i],
				group:  groups[i],
			})
		}
		return out
	}

	flat := splitCleanLines(lessonCell)
	pairs := make([]lessonGroupPair, 0)
	for i := 0; i+1 < len(flat); {
		a := flat[i]
		b := flat[i+1]
		if reDocxGroup.MatchString(b) {
			pairs = append(pairs, lessonGroupPair{lesson: a, group: b})
			i += 2
			continue
		}
		i++
	}
	if len(pairs) > 0 {
		return pairs
	}

	if len(lessons) > 0 {
		group := ""
		if len(groups) > 0 {
			group = groups[0]
		}
		return []lessonGroupPair{{lesson: lessons[0], group: group}}
	}
	return nil
}

func cleanCellText(value string) string {
	text := strings.ReplaceAll(value, "\u00a0", " ")
	text = strings.ReplaceAll(text, "\r", "")
	lines := splitCleanLines(text)
	return strings.Join(lines, "\n")
}

func splitCleanLines(value string) []string {
	rows := strings.Split(value, "\n")
	out := make([]string, 0, len(rows))
	for _, row := range rows {
		trimmed := strings.TrimSpace(row)
		trimmed = reDocxSpaces.ReplaceAllString(trimmed, " ")
		if trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func supersToNormal(value string) string {
	return docxSupersReplacer.Replace(value)
}

func buildTimeRange(h1, m1, h2, m2 string) string {
	h1i, _ := strconv.Atoi(strings.TrimSpace(supersToNormal(h1)))
	h2i, _ := strconv.Atoi(strings.TrimSpace(supersToNormal(h2)))
	min1 := supersToNormal(strings.TrimSpace(m1))
	min2 := supersToNormal(strings.TrimSpace(m2))
	return fmt.Sprintf("%02d:%s-%02d:%s", h1i, min1, h2i, min2)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func labelByFill(fill string) string {
	if fill == "" {
		return ""
	}
	if label, ok := docxColorLabels[strings.ToUpper(fill)]; ok {
		return " (" + label + ")"
	}
	return ""
}

func appendLabel(value string, label string) string {
	text := cleanCellText(value)
	if strings.TrimSpace(label) == "" {
		return text
	}
	if text == "" {
		return strings.TrimSpace(label)
	}
	return strings.TrimSpace(text + label)
}

func extractGroupTokens(groupText string) []string {
	normalized := cleanCellText(groupText)
	if normalized == "" {
		return nil
	}

	raw := reDocxGroupToken.FindAllString(normalized, -1)
	if len(raw) == 0 {
		return []string{normalized}
	}

	out := make([]string, 0, len(raw))
	seen := map[string]struct{}{}
	for _, token := range raw {
		trimmed := strings.TrimSpace(token)
		if trimmed == "" {
			continue
		}
		key := strings.ToLower(trimmed)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, trimmed)
	}
	if len(out) == 0 {
		return []string{normalized}
	}
	return out
}

func groupIncludesToken(groupText string, target string) bool {
	target = strings.TrimSpace(target)
	if target == "" {
		return false
	}
	targetLower := strings.ToLower(target)
	tokens := extractGroupTokens(groupText)
	for _, token := range tokens {
		if strings.ToLower(strings.TrimSpace(token)) == targetLower {
			return true
		}
	}
	return false
}

func normalizeScheduleDraftGroups(drafts []scheduleLessonDraft) []scheduleLessonDraft {
	if len(drafts) == 0 {
		return drafts
	}
	out := make([]scheduleLessonDraft, 0, len(drafts))
	for _, draft := range drafts {
		tokens := extractGroupTokens(draft.GroupName)
		if len(tokens) == 0 {
			out = append(out, draft)
			continue
		}
		for _, token := range tokens {
			clone := draft
			clone.GroupName = token
			out = append(out, clone)
		}
	}
	return out
}

func deriveTeacherNameFromLesson(lesson string) string {
	lines := splitCleanLines(lesson)
	if len(lines) == 0 {
		return ""
	}
	for _, line := range lines {
		candidate := strings.TrimSpace(line)
		candidate = strings.TrimSuffix(candidate, "(Практика)")
		candidate = strings.TrimSuffix(candidate, "(Онлайн)")
		candidate = strings.TrimSpace(candidate)
		if candidate == "" {
			continue
		}
		if reDocxHasLetter.MatchString(candidate) {
			return candidate
		}
	}
	return strings.TrimSpace(lines[0])
}
