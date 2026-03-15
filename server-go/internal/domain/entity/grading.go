package entity

import "time"

type PresetVisibility string

const (
	PresetVisibilityPrivate PresetVisibility = "private"
	PresetVisibilityPublic  PresetVisibility = "public"
)

type PresetColumnType string

const (
	PresetColumnTypeManual   PresetColumnType = "manual"
	PresetColumnTypeComputed PresetColumnType = "computed"
)

type ValueType string

const (
	ValueTypeNumber ValueType = "number"
	ValueTypeString ValueType = "string"
	ValueTypeBool   ValueType = "bool"
)

type GradingPreset struct {
	ID          uint
	OwnerID     uint
	Name        string
	Description string
	Tags        []string
	Visibility  PresetVisibility
	CreatedAt   time.Time
	UpdatedAt   time.Time
	ArchivedAt  *time.Time
}

type GradingPresetVersion struct {
	ID            uint
	PresetID      uint
	Version       int
	Definition    PresetDefinition
	CreatedBy     uint
	CreatedAt     time.Time
	DefinitionAST map[string]FormulaNode
}

type PresetDefinition struct {
	StatusCodes []StatusCodeRule `json:"status_codes"`
	Variables   []PresetVariable `json:"variables"`
	Columns     []PresetColumn   `json:"columns"`
}

type StatusCodeRule struct {
	Key           string   `json:"key,omitempty"`
	Code          string   `json:"code"`
	NumericValue  *float64 `json:"numeric_value,omitempty"`
	CountsAsMiss  bool     `json:"counts_as_miss"`
	CountsInStats bool     `json:"counts_in_stats"`
}

type PresetVariable struct {
	Key          string    `json:"key"`
	Title        string    `json:"title"`
	Type         ValueType `json:"type"`
	DefaultValue any       `json:"default_value"`
}

type PresetColumn struct {
	Key       string           `json:"key"`
	Title     string           `json:"title"`
	Kind      PresetColumnType `json:"kind"`
	Type      ValueType        `json:"type"`
	Editable  bool             `json:"editable"`
	Formula   string           `json:"formula,omitempty"`
	Format    string           `json:"format,omitempty"`
	DependsOn []string         `json:"depends_on,omitempty"`
}

type GroupPresetBinding struct {
	ID              uint
	GroupName       string
	PresetID        uint
	PresetVersionID uint
	AutoUpdate      bool
	AppliedBy       uint
	AppliedAt       time.Time
	UpdatedAt       time.Time
}

type JournalCell struct {
	ID           uint
	GroupName    string
	ClassDate    time.Time
	StudentName  string
	RawValue     string
	NumericValue *float64
	StatusCode   string
	UpdatedBy    uint
	UpdatedAt    time.Time
}

type ManualCell struct {
	ID           uint
	GroupName    string
	StudentName  string
	ColumnKey    string
	RawValue     string
	NumericValue *float64
	UpdatedBy    uint
	UpdatedAt    time.Time
}

type ComputedRow struct {
	ID              uint
	GroupName       string
	StudentName     string
	PresetVersionID uint
	Values          map[string]any
	CalculatedAt    time.Time
}

type JournalGrid struct {
	GroupName   string
	Students    []string
	Dates       []time.Time
	DateCells   []JournalCell
	ManualCells []ManualCell
	Computed    []ComputedRow
	Preset      *GradingPreset
	Version     *GradingPresetVersion
	Binding     *GroupPresetBinding
	SyncState   string
}

type PresetSearchFilter struct {
	Query      string
	AuthorID   *uint
	Tag        string
	Visibility *PresetVisibility
	ActorID    uint
	ActorRole  string
}

// Formula AST model

type FormulaNode interface {
	formulaNode()
}

type NumberNode struct {
	Value float64
}

func (NumberNode) formulaNode() {}

type StringNode struct {
	Value string
}

func (StringNode) formulaNode() {}

type BoolNode struct {
	Value bool
}

func (BoolNode) formulaNode() {}

type IdentifierNode struct {
	Name string
}

func (IdentifierNode) formulaNode() {}

type UnaryNode struct {
	Op    string
	Value FormulaNode
}

func (UnaryNode) formulaNode() {}

type BinaryNode struct {
	Op    string
	Left  FormulaNode
	Right FormulaNode
}

func (BinaryNode) formulaNode() {}

type CallNode struct {
	Name string
	Args []FormulaNode
}

func (CallNode) formulaNode() {}
