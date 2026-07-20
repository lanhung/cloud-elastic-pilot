package ack

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/hooke-repro/hooke-ack/internal/event"
)

type Rule struct {
	Name             string   `yaml:"name" json:"name"`
	EventType        string   `yaml:"event_type" json:"event_type"`
	MatchField       string   `yaml:"match_field" json:"match_field"`
	MatchRegex       string   `yaml:"match_regex" json:"match_regex"`
	EventTimeField   string   `yaml:"event_time_field" json:"event_time_field"`
	RunIDField       string   `yaml:"run_id_field" json:"run_id_field"`
	NodeNameField    string   `yaml:"node_name_field" json:"node_name_field"`
	NodeUIDField     string   `yaml:"node_uid_field" json:"node_uid_field"`
	PodUIDField      string   `yaml:"pod_uid_field" json:"pod_uid_field"`
	WorkloadUIDField string   `yaml:"workload_uid_field" json:"workload_uid_field"`
	InstanceIDField  string   `yaml:"instance_id_field" json:"instance_id_field"`
	TaskIDField      string   `yaml:"task_id_field" json:"task_id_field"`
	ReasonField      string   `yaml:"reason_field" json:"reason_field"`
	ResultField      string   `yaml:"result_field" json:"result_field"`
	AttributeFields  []string `yaml:"attribute_fields" json:"attribute_fields"`
}

type Config struct {
	ClusterID    string `yaml:"cluster_id" json:"cluster_id"`
	DefaultRunID string `yaml:"default_run_id" json:"default_run_id"`
	Rules        []Rule `yaml:"rules" json:"rules"`
}

type compiledRule struct {
	Rule
	re *regexp.Regexp
}

type Parser struct {
	config Config
	rules  []compiledRule
}

func NewParser(config Config) (*Parser, error) {
	if config.ClusterID == "" {
		return nil, fmt.Errorf("cluster_id is required")
	}
	p := &Parser{config: config}
	for _, rule := range config.Rules {
		if rule.EventType == "" || rule.MatchField == "" || rule.MatchRegex == "" {
			return nil, fmt.Errorf("rule %q is incomplete", rule.Name)
		}
		re, err := regexp.Compile(rule.MatchRegex)
		if err != nil {
			return nil, fmt.Errorf("compile rule %q: %w", rule.Name, err)
		}
		p.rules = append(p.rules, compiledRule{Rule: rule, re: re})
	}
	return p, nil
}

func (p *Parser) Parse(record map[string]any) ([]event.Event, error) {
	var result []event.Event
	for _, rule := range p.rules {
		value, _ := lookup(record, rule.MatchField)
		if !rule.re.MatchString(toString(value)) {
			continue
		}
		at := time.Now().UTC()
		if raw, ok := lookup(record, rule.EventTimeField); ok {
			parsed, err := parseTime(raw)
			if err != nil {
				return nil, fmt.Errorf("rule %q event time: %w", rule.Name, err)
			}
			at = parsed
		}
		runID := p.config.DefaultRunID
		if raw, ok := lookup(record, rule.RunIDField); ok && toString(raw) != "" {
			runID = toString(raw)
		}
		e := event.New(p.config.ClusterID, runID, rule.EventType, "ack-log-adapter", at)
		e.ClockType = event.ClockSource
		e.NodeName = fieldString(record, rule.NodeNameField)
		e.NodeUID = fieldString(record, rule.NodeUIDField)
		e.PodUID = fieldString(record, rule.PodUIDField)
		e.WorkloadUID = fieldString(record, rule.WorkloadUIDField)
		e.Reason = fieldString(record, rule.ReasonField)
		e.Result = fieldString(record, rule.ResultField)
		e.Attributes = map[string]any{"adapter_rule": rule.Name}
		if v := fieldString(record, rule.InstanceIDField); v != "" {
			e.Attributes["instance_id"] = v
		}
		if v := fieldString(record, rule.TaskIDField); v != "" {
			e.Attributes["task_id"] = v
		}
		for _, field := range rule.AttributeFields {
			if value, ok := lookup(record, field); ok {
				e.Attributes[field] = value
			}
		}
		result = append(result, e)
	}
	return result, nil
}

func fieldString(record map[string]any, path string) string {
	if path == "" {
		return ""
	}
	v, _ := lookup(record, path)
	return toString(v)
}

func lookup(record map[string]any, path string) (any, bool) {
	if path == "" {
		return nil, false
	}
	var current any = record
	for _, part := range strings.Split(path, ".") {
		m, ok := current.(map[string]any)
		if !ok {
			return nil, false
		}
		current, ok = m[part]
		if !ok {
			return nil, false
		}
	}
	return current, true
}

func toString(value any) string {
	switch v := value.(type) {
	case nil:
		return ""
	case string:
		return v
	case json.Number:
		return v.String()
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	case bool:
		return strconv.FormatBool(v)
	default:
		b, _ := json.Marshal(v)
		return string(b)
	}
}

func parseTime(value any) (time.Time, error) {
	s := toString(value)
	if parsed, err := time.Parse(time.RFC3339Nano, s); err == nil {
		return parsed.UTC(), nil
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return time.Time{}, fmt.Errorf("unsupported timestamp %q", s)
	}
	switch {
	case n > 1e17:
		return time.Unix(0, n).UTC(), nil
	case n > 1e14:
		return time.Unix(0, n*1e3).UTC(), nil
	case n > 1e11:
		return time.UnixMilli(n).UTC(), nil
	default:
		return time.Unix(n, 0).UTC(), nil
	}
}
