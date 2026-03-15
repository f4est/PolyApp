package usecase

import (
	"errors"
	"math"
	"testing"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
)

func TestFormulaEngine_ParseAndEvaluate(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	node, err := engine.Parse("IF(score >= 50, AVG(score, bonus), 0)")
	if err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	result, err := engine.Evaluate(node, FormulaEvalContext{Values: map[string]any{
		"score": 60,
		"bonus": 20,
	}})
	if err != nil {
		t.Fatalf("evaluate failed: %v", err)
	}
	if math.Abs(toNumber(result)-40) > 0.0001 {
		t.Fatalf("unexpected result: %v", result)
	}
}

func TestFormulaEngine_ValidateDefinitionCycle(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	def := entity.PresetDefinition{
		Columns: []entity.PresetColumn{
			{Key: "A", Kind: entity.PresetColumnTypeComputed, Type: entity.ValueTypeNumber, Formula: "B + 1"},
			{Key: "B", Kind: entity.PresetColumnTypeComputed, Type: entity.ValueTypeNumber, Formula: "A + 1"},
		},
	}
	_, _, err := engine.ValidateDefinition(def)
	if err == nil {
		t.Fatalf("expected cycle error")
	}
	if !errors.Is(err, domainErrors.ErrInvalidInput) {
		t.Fatalf("expected invalid input error, got %v", err)
	}
}

func TestFormulaEngine_ValidateDefinitionUnknownFunction(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	def := entity.PresetDefinition{
		Columns: []entity.PresetColumn{
			{Key: "A", Kind: entity.PresetColumnTypeComputed, Type: entity.ValueTypeNumber, Formula: "RUN(1,2)"},
		},
	}
	_, _, err := engine.ValidateDefinition(def)
	if err == nil {
		t.Fatalf("expected validation error")
	}
	if !errors.Is(err, domainErrors.ErrInvalidInput) {
		t.Fatalf("expected invalid input, got %v", err)
	}
}

func TestFormulaEngine_ValidateDefinitionUnknownIdentifier(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	def := entity.PresetDefinition{
		Columns: []entity.PresetColumn{
			{
				Key:      "total",
				Kind:     entity.PresetColumnTypeComputed,
				Type:     entity.ValueTypeNumber,
				Formula:  "SUM(missing_col, DATE_AVG)",
				Editable: false,
			},
		},
	}
	_, _, err := engine.ValidateDefinition(def)
	if err == nil {
		t.Fatalf("expected validation error for unknown identifier")
	}
	if !errors.Is(err, domainErrors.ErrInvalidInput) {
		t.Fatalf("expected invalid input, got %v", err)
	}
}

func TestFormulaEngine_ValidateDefinitionStatusCodeCounters(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	def := entity.PresetDefinition{
		StatusCodes: []entity.StatusCodeRule{
			{Key: "NKI", Code: "Н"},
			{Code: "n"},
		},
		Columns: []entity.PresetColumn{
			{
				Key:      "final",
				Kind:     entity.PresetColumnTypeComputed,
				Type:     entity.ValueTypeNumber,
				Formula:  "CODE_COUNT_NKI + STATUS_COUNT_N + STUDENT_CODE_COUNT_NKI + DATE_MAX",
				Editable: false,
			},
		},
	}
	if _, _, err := engine.ValidateDefinition(def); err != nil {
		t.Fatalf("expected valid definition, got %v", err)
	}
}

func TestFormulaEngine_ValidateDefinitionUnknownStatusCounter(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	def := entity.PresetDefinition{
		StatusCodes: []entity.StatusCodeRule{
			{Key: "NKI", Code: "Н"},
		},
		Columns: []entity.PresetColumn{
			{
				Key:      "final",
				Kind:     entity.PresetColumnTypeComputed,
				Type:     entity.ValueTypeNumber,
				Formula:  "CODE_COUNT_UNKNOWN",
				Editable: false,
			},
		},
	}
	_, _, err := engine.ValidateDefinition(def)
	if err == nil {
		t.Fatalf("expected validation error for unknown status counter")
	}
	if !errors.Is(err, domainErrors.ErrInvalidInput) {
		t.Fatalf("expected invalid input, got %v", err)
	}
}

func TestFormulaEngine_ValidateDefinitionDuplicateStatusKey(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	def := entity.PresetDefinition{
		StatusCodes: []entity.StatusCodeRule{
			{Key: "NKI", Code: "Н"},
			{Key: "NKI", Code: "ABS"},
		},
		Columns: []entity.PresetColumn{
			{
				Key:      "final",
				Kind:     entity.PresetColumnTypeComputed,
				Type:     entity.ValueTypeNumber,
				Formula:  "DATE_AVG",
				Editable: false,
			},
		},
	}
	_, _, err := engine.ValidateDefinition(def)
	if err == nil {
		t.Fatalf("expected duplicate status key error")
	}
	if !errors.Is(err, domainErrors.ErrInvalidInput) {
		t.Fatalf("expected invalid input, got %v", err)
	}
}

func TestFormulaEngine_ValidateDefinitionInvalidStatusKey(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	def := entity.PresetDefinition{
		StatusCodes: []entity.StatusCodeRule{
			{Key: "N-KI", Code: "Н"},
		},
		Columns: []entity.PresetColumn{
			{
				Key:      "final",
				Kind:     entity.PresetColumnTypeComputed,
				Type:     entity.ValueTypeNumber,
				Formula:  "DATE_AVG",
				Editable: false,
			},
		},
	}
	_, _, err := engine.ValidateDefinition(def)
	if err == nil {
		t.Fatalf("expected invalid status key error")
	}
	if !errors.Is(err, domainErrors.ErrInvalidInput) {
		t.Fatalf("expected invalid input, got %v", err)
	}
}

func TestFormulaEngine_FunctionsAndBoolLogic(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	node, err := engine.Parse("COUNT_IF(a > 0, b > 0, c > 0) + SUM(a, b, c)")
	if err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	result, err := engine.Evaluate(node, FormulaEvalContext{Values: map[string]any{
		"a": 1,
		"b": "0",
		"c": 3,
	}})
	if err != nil {
		t.Fatalf("evaluate failed: %v", err)
	}
	// COUNT_IF => 2, SUM => 4
	if math.Abs(toNumber(result)-6) > 0.0001 {
		t.Fatalf("unexpected result: %v", result)
	}
}

func TestFormulaEngine_IfElseClauseSyntax(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	node, err := engine.Parse("IF(score >= 50, score) ELSE(0)")
	if err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	result, err := engine.Evaluate(node, FormulaEvalContext{Values: map[string]any{
		"score": 42,
	}})
	if err != nil {
		t.Fatalf("evaluate failed: %v", err)
	}
	if math.Abs(toNumber(result)-0) > 0.0001 {
		t.Fatalf("unexpected result: %v", result)
	}
}

func TestFormulaEngine_ElseFunction(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	node, err := engine.Parse("IF(score >= 50, score, ELSE(0))")
	if err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	result, err := engine.Evaluate(node, FormulaEvalContext{Values: map[string]any{
		"score": 60,
	}})
	if err != nil {
		t.Fatalf("evaluate failed: %v", err)
	}
	if math.Abs(toNumber(result)-60) > 0.0001 {
		t.Fatalf("unexpected result: %v", result)
	}
}

func TestFormulaEngine_ComputedOrderAndEvaluation(t *testing.T) {
	engine := NewFormulaEngineUseCase()
	def := entity.PresetDefinition{
		Columns: []entity.PresetColumn{
			{Key: "manualA", Kind: entity.PresetColumnTypeManual, Type: entity.ValueTypeNumber, Editable: true},
			{Key: "manualB", Kind: entity.PresetColumnTypeManual, Type: entity.ValueTypeNumber, Editable: true},
			{Key: "sum", Kind: entity.PresetColumnTypeComputed, Type: entity.ValueTypeNumber, Formula: "SUM(manualA, manualB)"},
			{Key: "flag", Kind: entity.PresetColumnTypeComputed, Type: entity.ValueTypeBool, Formula: "sum >= 80"},
		},
	}
	asts, order, err := engine.ValidateDefinition(def)
	if err != nil {
		t.Fatalf("validate failed: %v", err)
	}
	out, err := engine.EvaluateComputedColumns(def, asts, order, map[string]any{
		"manualA": 50,
		"manualB": 35,
	})
	if err != nil {
		t.Fatalf("evaluate computed failed: %v", err)
	}
	if math.Abs(toNumber(out["sum"])-85) > 0.0001 {
		t.Fatalf("unexpected sum: %v", out["sum"])
	}
	if out["flag"] != true {
		t.Fatalf("unexpected flag: %v", out["flag"])
	}
}
