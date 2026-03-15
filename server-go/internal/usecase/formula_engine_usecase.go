package usecase

import (
	"fmt"
	"math"
	"strconv"
	"strings"
	"unicode"

	"polyapp/server-go/internal/domain/entity"
	domainErrors "polyapp/server-go/internal/domain/errors"
)

type FormulaEngineUseCase struct{}

func NewFormulaEngineUseCase() *FormulaEngineUseCase {
	return &FormulaEngineUseCase{}
}

type FormulaEvalContext struct {
	Values map[string]any
}

func (u *FormulaEngineUseCase) Parse(input string) (entity.FormulaNode, error) {
	parser, err := newFormulaParser(input)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", domainErrors.ErrInvalidInput, err)
	}
	node, err := parser.parse()
	if err != nil {
		return nil, fmt.Errorf("%w: %v", domainErrors.ErrInvalidInput, err)
	}
	if err := validateCallWhitelist(node); err != nil {
		return nil, fmt.Errorf("%w: %v", domainErrors.ErrInvalidInput, err)
	}
	return node, nil
}

func (u *FormulaEngineUseCase) ValidateDefinition(def entity.PresetDefinition) (map[string]entity.FormulaNode, []string, error) {
	columnKeys := map[string]struct{}{}
	for _, col := range def.Columns {
		key := strings.TrimSpace(col.Key)
		if key == "" {
			return nil, nil, fmt.Errorf("%w: empty column key", domainErrors.ErrInvalidInput)
		}
		if _, exists := columnKeys[key]; exists {
			return nil, nil, fmt.Errorf("%w: duplicate column key %s", domainErrors.ErrInvalidInput, key)
		}
		columnKeys[key] = struct{}{}
	}
	variableKeys := map[string]struct{}{}
	for _, variable := range def.Variables {
		key := strings.TrimSpace(variable.Key)
		if key == "" {
			return nil, nil, fmt.Errorf("%w: empty variable key", domainErrors.ErrInvalidInput)
		}
		if _, exists := variableKeys[key]; exists {
			return nil, nil, fmt.Errorf("%w: duplicate variable key %s", domainErrors.ErrInvalidInput, key)
		}
		variableKeys[key] = struct{}{}
	}
	allowedStatusRefs, err := allowedStatusCounterRefs(def.StatusCodes)
	if err != nil {
		return nil, nil, err
	}

	asts := map[string]entity.FormulaNode{}
	computedDeps := map[string][]string{}
	for _, col := range def.Columns {
		if col.Kind != entity.PresetColumnTypeComputed {
			continue
		}
		formula := strings.TrimSpace(col.Formula)
		if formula == "" {
			return nil, nil, fmt.Errorf("%w: computed column %s requires formula", domainErrors.ErrInvalidInput, col.Key)
		}
		node, err := u.Parse(formula)
		if err != nil {
			return nil, nil, err
		}
		asts[col.Key] = node
		refs := map[string]struct{}{}
		collectIdentifiers(node, refs)
		for ref := range refs {
			if isStatusCounterIdentifier(ref) {
				normalized := strings.ToUpper(strings.TrimSpace(ref))
				if _, ok := allowedStatusRefs[normalized]; !ok {
					return nil, nil, fmt.Errorf(
						"%w: unknown status counter %s in column %s",
						domainErrors.ErrInvalidInput,
						ref,
						col.Key,
					)
				}
				continue
			}
			if isBuiltinIdentifier(ref) {
				continue
			}
			if _, exists := columnKeys[ref]; exists {
				continue
			}
			if _, exists := variableKeys[ref]; exists {
				continue
			}
			return nil, nil, fmt.Errorf(
				"%w: unknown identifier %s in column %s",
				domainErrors.ErrInvalidInput,
				ref,
				col.Key,
			)
		}
		computedDeps[col.Key] = mapKeysToSortedSlice(refs)
	}

	order, err := detectComputedOrder(def.Columns, computedDeps)
	if err != nil {
		return nil, nil, err
	}

	return asts, order, nil
}

func isBuiltinIdentifier(value string) bool {
	normalized := strings.ToUpper(strings.TrimSpace(value))
	switch normalized {
	case "DATE_SUM", "DATE_COUNT", "DATE_AVG", "DATE_MIN", "DATE_MAX", "MISS_COUNT", "STUDENT_MISS_COUNT":
		return true
	}
	return strings.HasPrefix(normalized, "DATE_")
}

func isStatusCounterIdentifier(value string) bool {
	normalized := strings.ToUpper(strings.TrimSpace(value))
	return strings.HasPrefix(normalized, "CODE_COUNT_") ||
		strings.HasPrefix(normalized, "STATUS_COUNT_") ||
		strings.HasPrefix(normalized, "STUDENT_CODE_COUNT_")
}

func allowedStatusCounterRefs(statusCodes []entity.StatusCodeRule) (map[string]struct{}, error) {
	allowed := map[string]struct{}{}
	seenCode := map[string]struct{}{}
	seenKey := map[string]struct{}{}
	for _, rule := range statusCodes {
		code := strings.TrimSpace(rule.Code)
		if code == "" {
			return nil, fmt.Errorf("%w: empty status code", domainErrors.ErrInvalidInput)
		}
		normalizedCode := strings.ToUpper(code)
		if _, ok := seenCode[normalizedCode]; ok {
			return nil, fmt.Errorf("%w: duplicate status code %s", domainErrors.ErrInvalidInput, code)
		}
		seenCode[normalizedCode] = struct{}{}

		rawKey := strings.TrimSpace(rule.Key)
		if rawKey != "" && !isValidIdentifierKey(rawKey) {
			return nil, fmt.Errorf("%w: invalid status key %s", domainErrors.ErrInvalidInput, rawKey)
		}
		suffix := strings.ToUpper(statusCounterSuffix(rule))
		if suffix == "" {
			return nil, fmt.Errorf("%w: empty status key for code %s", domainErrors.ErrInvalidInput, code)
		}
		if _, ok := seenKey[suffix]; ok {
			return nil, fmt.Errorf("%w: duplicate status key %s", domainErrors.ErrInvalidInput, suffix)
		}
		seenKey[suffix] = struct{}{}

		allowed["CODE_COUNT_"+suffix] = struct{}{}
		allowed["STATUS_COUNT_"+suffix] = struct{}{}
		allowed["STUDENT_CODE_COUNT_"+suffix] = struct{}{}
	}
	return allowed, nil
}

func statusCounterSuffix(rule entity.StatusCodeRule) string {
	key := strings.TrimSpace(rule.Key)
	if key != "" {
		return key
	}
	return statusCodeRefSuffix(strings.TrimSpace(rule.Code))
}

func isValidIdentifierKey(value string) bool {
	if value == "" {
		return false
	}
	for i, r := range value {
		if i == 0 {
			if !unicode.IsLetter(r) && r != '_' {
				return false
			}
			continue
		}
		if !unicode.IsLetter(r) && !unicode.IsDigit(r) && r != '_' {
			return false
		}
	}
	return true
}

func (u *FormulaEngineUseCase) Evaluate(node entity.FormulaNode, ctx FormulaEvalContext) (any, error) {
	if ctx.Values == nil {
		ctx.Values = map[string]any{}
	}
	return evalFormulaNode(node, ctx.Values)
}

func (u *FormulaEngineUseCase) EvaluateComputedColumns(
	def entity.PresetDefinition,
	asts map[string]entity.FormulaNode,
	order []string,
	baseValues map[string]any,
) (map[string]any, error) {
	values := map[string]any{}
	for key, value := range baseValues {
		values[key] = value
	}

	columnMap := map[string]entity.PresetColumn{}
	for _, col := range def.Columns {
		columnMap[col.Key] = col
	}

	for _, key := range order {
		node, ok := asts[key]
		if !ok {
			continue
		}
		result, err := u.Evaluate(node, FormulaEvalContext{Values: values})
		if err != nil {
			return nil, fmt.Errorf("computed %s: %w", key, err)
		}
		values[key] = castValueType(result, columnMap[key].Type)
	}

	out := map[string]any{}
	for _, col := range def.Columns {
		if col.Kind == entity.PresetColumnTypeComputed {
			out[col.Key] = values[col.Key]
		}
	}
	return out, nil
}

func castValueType(value any, typ entity.ValueType) any {
	switch typ {
	case entity.ValueTypeString:
		return toString(value)
	case entity.ValueTypeBool:
		return truthy(value)
	default:
		return toNumber(value)
	}
}

func validateCallWhitelist(node entity.FormulaNode) error {
	switch n := node.(type) {
	case entity.CallNode:
		allowed := map[string]struct{}{
			"IF":       {},
			"ELSE":     {},
			"SUM":      {},
			"AVG":      {},
			"MIN":      {},
			"MAX":      {},
			"COUNT_IF": {},
		}
		name := strings.ToUpper(strings.TrimSpace(n.Name))
		if _, ok := allowed[name]; !ok {
			return fmt.Errorf("unsupported function %s", n.Name)
		}
		for _, arg := range n.Args {
			if err := validateCallWhitelist(arg); err != nil {
				return err
			}
		}
	case entity.UnaryNode:
		return validateCallWhitelist(n.Value)
	case entity.BinaryNode:
		if err := validateCallWhitelist(n.Left); err != nil {
			return err
		}
		return validateCallWhitelist(n.Right)
	}
	return nil
}

func detectComputedOrder(columns []entity.PresetColumn, deps map[string][]string) ([]string, error) {
	computed := map[string]struct{}{}
	for _, col := range columns {
		if col.Kind == entity.PresetColumnTypeComputed {
			computed[col.Key] = struct{}{}
		}
	}

	filtered := map[string][]string{}
	for key, refs := range deps {
		for _, ref := range refs {
			if _, ok := computed[ref]; ok {
				filtered[key] = append(filtered[key], ref)
			}
		}
	}

	const (
		stateNew = iota
		stateVisiting
		stateDone
	)
	states := map[string]int{}
	order := make([]string, 0, len(computed))

	var visit func(string) error
	visit = func(key string) error {
		switch states[key] {
		case stateVisiting:
			return fmt.Errorf("%w: computed columns dependency cycle", domainErrors.ErrInvalidInput)
		case stateDone:
			return nil
		}
		states[key] = stateVisiting
		for _, dep := range filtered[key] {
			if err := visit(dep); err != nil {
				return err
			}
		}
		states[key] = stateDone
		order = append(order, key)
		return nil
	}

	for key := range computed {
		if err := visit(key); err != nil {
			return nil, err
		}
	}
	return order, nil
}

func collectIdentifiers(node entity.FormulaNode, out map[string]struct{}) {
	switch n := node.(type) {
	case entity.IdentifierNode:
		out[n.Name] = struct{}{}
	case entity.UnaryNode:
		collectIdentifiers(n.Value, out)
	case entity.BinaryNode:
		collectIdentifiers(n.Left, out)
		collectIdentifiers(n.Right, out)
	case entity.CallNode:
		for _, arg := range n.Args {
			collectIdentifiers(arg, out)
		}
	}
}

func mapKeysToSortedSlice(in map[string]struct{}) []string {
	out := make([]string, 0, len(in))
	for key := range in {
		out = append(out, key)
	}
	if len(out) < 2 {
		return out
	}
	for i := 0; i < len(out)-1; i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j] < out[i] {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	return out
}

func evalFormulaNode(node entity.FormulaNode, ctx map[string]any) (any, error) {
	switch n := node.(type) {
	case entity.NumberNode:
		return n.Value, nil
	case entity.StringNode:
		return n.Value, nil
	case entity.BoolNode:
		return n.Value, nil
	case entity.IdentifierNode:
		if value, ok := ctx[n.Name]; ok {
			return value, nil
		}
		return 0.0, nil
	case entity.UnaryNode:
		value, err := evalFormulaNode(n.Value, ctx)
		if err != nil {
			return nil, err
		}
		switch n.Op {
		case "-":
			return -toNumber(value), nil
		case "!":
			return !truthy(value), nil
		default:
			return nil, fmt.Errorf("unsupported unary operator %s", n.Op)
		}
	case entity.BinaryNode:
		left, err := evalFormulaNode(n.Left, ctx)
		if err != nil {
			return nil, err
		}
		right, err := evalFormulaNode(n.Right, ctx)
		if err != nil {
			return nil, err
		}
		return evalBinary(n.Op, left, right), nil
	case entity.CallNode:
		args := make([]any, 0, len(n.Args))
		for _, arg := range n.Args {
			value, err := evalFormulaNode(arg, ctx)
			if err != nil {
				return nil, err
			}
			args = append(args, value)
		}
		return evalCall(n.Name, args)
	default:
		return nil, fmt.Errorf("unsupported formula node")
	}
}

func evalBinary(op string, left any, right any) any {
	switch op {
	case "+":
		return toNumber(left) + toNumber(right)
	case "-":
		return toNumber(left) - toNumber(right)
	case "*":
		return toNumber(left) * toNumber(right)
	case "/":
		divisor := toNumber(right)
		if divisor == 0 {
			return 0.0
		}
		return toNumber(left) / divisor
	case "==":
		return compareEqual(left, right)
	case "!=":
		return !compareEqual(left, right)
	case ">":
		return toNumber(left) > toNumber(right)
	case ">=":
		return toNumber(left) >= toNumber(right)
	case "<":
		return toNumber(left) < toNumber(right)
	case "<=":
		return toNumber(left) <= toNumber(right)
	case "&&":
		return truthy(left) && truthy(right)
	case "||":
		return truthy(left) || truthy(right)
	default:
		return 0.0
	}
}

func evalCall(name string, args []any) (any, error) {
	switch strings.ToUpper(strings.TrimSpace(name)) {
	case "IF":
		if len(args) < 3 {
			return nil, fmt.Errorf("IF requires 3 arguments")
		}
		if truthy(args[0]) {
			return args[1], nil
		}
		return args[2], nil
	case "ELSE":
		if len(args) != 1 {
			return nil, fmt.Errorf("ELSE requires 1 argument")
		}
		return args[0], nil
	case "SUM":
		total := 0.0
		for _, arg := range args {
			total += toNumber(arg)
		}
		return total, nil
	case "AVG":
		if len(args) == 0 {
			return 0.0, nil
		}
		total := 0.0
		for _, arg := range args {
			total += toNumber(arg)
		}
		return total / float64(len(args)), nil
	case "MIN":
		if len(args) == 0 {
			return 0.0, nil
		}
		min := toNumber(args[0])
		for i := 1; i < len(args); i++ {
			v := toNumber(args[i])
			if v < min {
				min = v
			}
		}
		return min, nil
	case "MAX":
		if len(args) == 0 {
			return 0.0, nil
		}
		max := toNumber(args[0])
		for i := 1; i < len(args); i++ {
			v := toNumber(args[i])
			if v > max {
				max = v
			}
		}
		return max, nil
	case "COUNT_IF":
		count := 0
		for _, arg := range args {
			if truthy(arg) {
				count++
			}
		}
		return float64(count), nil
	default:
		return nil, fmt.Errorf("unsupported function %s", name)
	}
}

func compareEqual(left any, right any) bool {
	if isNumeric(left) || isNumeric(right) {
		return math.Abs(toNumber(left)-toNumber(right)) < 1e-9
	}
	return strings.EqualFold(toString(left), toString(right))
}

func isNumeric(value any) bool {
	switch value.(type) {
	case int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64,
		float32, float64:
		return true
	}
	return false
}

func toNumber(value any) float64 {
	switch v := value.(type) {
	case float64:
		return v
	case float32:
		return float64(v)
	case int:
		return float64(v)
	case int8:
		return float64(v)
	case int16:
		return float64(v)
	case int32:
		return float64(v)
	case int64:
		return float64(v)
	case uint:
		return float64(v)
	case uint8:
		return float64(v)
	case uint16:
		return float64(v)
	case uint32:
		return float64(v)
	case uint64:
		return float64(v)
	case bool:
		if v {
			return 1
		}
		return 0
	case string:
		n, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
		if err != nil {
			return 0
		}
		return n
	default:
		return 0
	}
}

func toString(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case bool:
		if v {
			return "true"
		}
		return "false"
	default:
		return strconv.FormatFloat(toNumber(v), 'f', -1, 64)
	}
}

func truthy(value any) bool {
	switch v := value.(type) {
	case bool:
		return v
	case string:
		normalized := strings.TrimSpace(strings.ToLower(v))
		return normalized != "" && normalized != "0" && normalized != "false" && normalized != "null"
	default:
		return toNumber(v) != 0
	}
}

// ----------------- parser -----------------

type formulaTokenType int

const (
	tokenEOF formulaTokenType = iota
	tokenNumber
	tokenIdentifier
	tokenString
	tokenOp
	tokenLParen
	tokenRParen
	tokenComma
)

type formulaToken struct {
	typ formulaTokenType
	lit string
}

type formulaParser struct {
	tokens []formulaToken
	pos    int
}

func newFormulaParser(input string) (*formulaParser, error) {
	tokens, err := tokenizeFormula(input)
	if err != nil {
		return nil, err
	}
	return &formulaParser{tokens: tokens}, nil
}

func (p *formulaParser) parse() (entity.FormulaNode, error) {
	node, err := p.parseOr()
	if err != nil {
		return nil, err
	}
	node, err = p.parseIfElseClause(node)
	if err != nil {
		return nil, err
	}
	if p.peek().typ != tokenEOF {
		return nil, fmt.Errorf("unexpected token %s", p.peek().lit)
	}
	return node, nil
}

func (p *formulaParser) parseIfElseClause(node entity.FormulaNode) (entity.FormulaNode, error) {
	tok := p.peek()
	if tok.typ != tokenIdentifier || !strings.EqualFold(tok.lit, "ELSE") {
		return node, nil
	}
	call, ok := node.(entity.CallNode)
	if !ok || !strings.EqualFold(strings.TrimSpace(call.Name), "IF") {
		return nil, fmt.Errorf("ELSE can only be used after IF")
	}
	if len(call.Args) >= 3 {
		return nil, fmt.Errorf("IF already contains else argument")
	}
	if len(call.Args) < 2 {
		return nil, fmt.Errorf("IF requires at least 2 arguments before ELSE")
	}

	p.next() // ELSE
	if p.peek().typ != tokenLParen {
		return nil, fmt.Errorf("expected ( after ELSE")
	}
	p.next() // (

	elseExpr, err := p.parseOr()
	if err != nil {
		return nil, err
	}
	if p.peek().typ != tokenRParen {
		return nil, fmt.Errorf("expected ) after ELSE")
	}
	p.next() // )

	call.Args = append(call.Args, elseExpr)
	return call, nil
}

func (p *formulaParser) parseOr() (entity.FormulaNode, error) {
	node, err := p.parseAnd()
	if err != nil {
		return nil, err
	}
	for {
		tok := p.peek()
		if tok.typ == tokenOp && tok.lit == "||" {
			p.next()
			right, err := p.parseAnd()
			if err != nil {
				return nil, err
			}
			node = entity.BinaryNode{Op: tok.lit, Left: node, Right: right}
			continue
		}
		return node, nil
	}
}

func (p *formulaParser) parseAnd() (entity.FormulaNode, error) {
	node, err := p.parseCompare()
	if err != nil {
		return nil, err
	}
	for {
		tok := p.peek()
		if tok.typ == tokenOp && tok.lit == "&&" {
			p.next()
			right, err := p.parseCompare()
			if err != nil {
				return nil, err
			}
			node = entity.BinaryNode{Op: tok.lit, Left: node, Right: right}
			continue
		}
		return node, nil
	}
}

func (p *formulaParser) parseCompare() (entity.FormulaNode, error) {
	node, err := p.parseAdd()
	if err != nil {
		return nil, err
	}
	for {
		tok := p.peek()
		if tok.typ == tokenOp && (tok.lit == "==" || tok.lit == "!=" || tok.lit == ">" || tok.lit == ">=" || tok.lit == "<" || tok.lit == "<=") {
			p.next()
			right, err := p.parseAdd()
			if err != nil {
				return nil, err
			}
			node = entity.BinaryNode{Op: tok.lit, Left: node, Right: right}
			continue
		}
		return node, nil
	}
}

func (p *formulaParser) parseAdd() (entity.FormulaNode, error) {
	node, err := p.parseMul()
	if err != nil {
		return nil, err
	}
	for {
		tok := p.peek()
		if tok.typ == tokenOp && (tok.lit == "+" || tok.lit == "-") {
			p.next()
			right, err := p.parseMul()
			if err != nil {
				return nil, err
			}
			node = entity.BinaryNode{Op: tok.lit, Left: node, Right: right}
			continue
		}
		return node, nil
	}
}

func (p *formulaParser) parseMul() (entity.FormulaNode, error) {
	node, err := p.parseUnary()
	if err != nil {
		return nil, err
	}
	for {
		tok := p.peek()
		if tok.typ == tokenOp && (tok.lit == "*" || tok.lit == "/") {
			p.next()
			right, err := p.parseUnary()
			if err != nil {
				return nil, err
			}
			node = entity.BinaryNode{Op: tok.lit, Left: node, Right: right}
			continue
		}
		return node, nil
	}
}

func (p *formulaParser) parseUnary() (entity.FormulaNode, error) {
	tok := p.peek()
	if tok.typ == tokenOp && (tok.lit == "-" || tok.lit == "!") {
		p.next()
		value, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		return entity.UnaryNode{Op: tok.lit, Value: value}, nil
	}
	return p.parsePrimary()
}

func (p *formulaParser) parsePrimary() (entity.FormulaNode, error) {
	tok := p.next()
	switch tok.typ {
	case tokenNumber:
		value, err := strconv.ParseFloat(tok.lit, 64)
		if err != nil {
			return nil, fmt.Errorf("invalid number %s", tok.lit)
		}
		return entity.NumberNode{Value: value}, nil
	case tokenString:
		return entity.StringNode{Value: tok.lit}, nil
	case tokenIdentifier:
		normalized := strings.ToUpper(tok.lit)
		if normalized == "TRUE" {
			return entity.BoolNode{Value: true}, nil
		}
		if normalized == "FALSE" {
			return entity.BoolNode{Value: false}, nil
		}
		if p.peek().typ == tokenLParen {
			p.next() // (
			args := []entity.FormulaNode{}
			if p.peek().typ != tokenRParen {
				for {
					expr, err := p.parseOr()
					if err != nil {
						return nil, err
					}
					args = append(args, expr)
					if p.peek().typ == tokenComma {
						p.next()
						continue
					}
					break
				}
			}
			if p.peek().typ != tokenRParen {
				return nil, fmt.Errorf("expected )")
			}
			p.next()
			return entity.CallNode{Name: tok.lit, Args: args}, nil
		}
		return entity.IdentifierNode{Name: tok.lit}, nil
	case tokenLParen:
		node, err := p.parseOr()
		if err != nil {
			return nil, err
		}
		if p.peek().typ != tokenRParen {
			return nil, fmt.Errorf("expected )")
		}
		p.next()
		return node, nil
	default:
		return nil, fmt.Errorf("unexpected token %s", tok.lit)
	}
}

func (p *formulaParser) peek() formulaToken {
	if p.pos >= len(p.tokens) {
		return formulaToken{typ: tokenEOF}
	}
	return p.tokens[p.pos]
}

func (p *formulaParser) next() formulaToken {
	tok := p.peek()
	if p.pos < len(p.tokens) {
		p.pos++
	}
	return tok
}

func tokenizeFormula(input string) ([]formulaToken, error) {
	result := make([]formulaToken, 0, len(input)/2)
	runes := []rune(strings.TrimSpace(input))
	for i := 0; i < len(runes); {
		r := runes[i]
		if unicode.IsSpace(r) {
			i++
			continue
		}

		if unicode.IsDigit(r) || (r == '.' && i+1 < len(runes) && unicode.IsDigit(runes[i+1])) {
			start := i
			dotUsed := r == '.'
			i++
			for i < len(runes) {
				ch := runes[i]
				if ch == '.' {
					if dotUsed {
						break
					}
					dotUsed = true
					i++
					continue
				}
				if !unicode.IsDigit(ch) {
					break
				}
				i++
			}
			result = append(result, formulaToken{typ: tokenNumber, lit: string(runes[start:i])})
			continue
		}

		if unicode.IsLetter(r) || r == '_' {
			start := i
			i++
			for i < len(runes) && (unicode.IsLetter(runes[i]) || unicode.IsDigit(runes[i]) || runes[i] == '_' || runes[i] == '.') {
				i++
			}
			ident := string(runes[start:i])
			normalized := strings.ToUpper(ident)
			switch normalized {
			case "AND":
				result = append(result, formulaToken{typ: tokenOp, lit: "&&"})
			case "OR":
				result = append(result, formulaToken{typ: tokenOp, lit: "||"})
			case "NOT":
				result = append(result, formulaToken{typ: tokenOp, lit: "!"})
			default:
				result = append(result, formulaToken{typ: tokenIdentifier, lit: ident})
			}
			continue
		}

		if r == '\'' || r == '"' {
			quote := r
			start := i + 1
			i++
			for i < len(runes) && runes[i] != quote {
				i++
			}
			if i >= len(runes) {
				return nil, fmt.Errorf("unterminated string literal")
			}
			result = append(result, formulaToken{typ: tokenString, lit: string(runes[start:i])})
			i++
			continue
		}

		if i+1 < len(runes) {
			two := string(runes[i : i+2])
			switch two {
			case "==", "!=", ">=", "<=", "&&", "||":
				result = append(result, formulaToken{typ: tokenOp, lit: two})
				i += 2
				continue
			}
		}

		switch r {
		case '+', '-', '*', '/', '>', '<', '!':
			result = append(result, formulaToken{typ: tokenOp, lit: string(r)})
		case '(':
			result = append(result, formulaToken{typ: tokenLParen, lit: string(r)})
		case ')':
			result = append(result, formulaToken{typ: tokenRParen, lit: string(r)})
		case ',':
			result = append(result, formulaToken{typ: tokenComma, lit: string(r)})
		default:
			return nil, fmt.Errorf("unexpected symbol %q", string(r))
		}
		i++
	}
	result = append(result, formulaToken{typ: tokenEOF, lit: ""})
	return result, nil
}
