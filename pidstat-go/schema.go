package main

import (
	"github.com/parquet-go/parquet-go"
	"github.com/parquet-go/parquet-go/format"
)

// fieldOrder freezes the production Python writer's order and physical widths.
// All columns are OPTIONAL, including fields normally present in every sample.
type fieldOrder struct {
	Time        int64   `parquet:"time,optional"`
	UID         int32   `parquet:"uid,optional"`
	PID         int32   `parquet:"pid,optional"`
	User        float32 `parquet:"usr_percent,optional"`
	System      float32 `parquet:"system_percent,optional"`
	Guest       float32 `parquet:"guest_percent,optional"`
	Wait        float32 `parquet:"wait_percent,optional"`
	CPU         float32 `parquet:"cpu_percent,optional"`
	Core        int32   `parquet:"cpu_core,optional"`
	MinFault    float32 `parquet:"minflt_per_sec,optional"`
	MajFault    float32 `parquet:"majflt_per_sec,optional"`
	VSZ         int64   `parquet:"vsz_kb,optional"`
	RSS         int64   `parquet:"rss_kb,optional"`
	Memory      float32 `parquet:"mem_percent,optional"`
	Read        float32 `parquet:"kb_read_per_sec,optional"`
	Write       float32 `parquet:"kb_write_per_sec,optional"`
	Cancelled   float32 `parquet:"kb_cancelled_write_per_sec,optional"`
	IODelay     int32   `parquet:"iodelay_ticks,optional"`
	Voluntary   float32 `parquet:"context_switch_per_sec,optional"`
	Involuntary float32 `parquet:"nonvoluntary_context_switch_per_sec,optional"`
	Command     string  `parquet:"command,optional"`
	Hostname    string  `parquet:"hostname,optional"`
	Cgroup      string  `parquet:"cgroup_path,optional"`
	Namespace   int64   `parquet:"pid_ns_inode,optional"`
	Runtime     string  `parquet:"container_runtime,optional"`
	Container   string  `parquet:"container_id,optional"`
}

// DuckDB's existing writer uses legacy converted annotations for signed integers
// and UTF8, but a modern, non-UTC MICROS logical annotation for time. Preserve
// this observable schema instead of accepting a merely reader-compatible one.
type legacyType struct{ parquet.Type }

func (legacyType) LogicalType() *format.LogicalType { return nil }

type typedField struct {
	parquet.Field
	typ parquet.Type
}

func (f typedField) Type() parquet.Type { return f.typ }

type orderedRoot struct {
	parquet.Node
	fields []parquet.Field
}

func (r orderedRoot) Fields() []parquet.Field { return r.fields }

func pythonSchema() *parquet.Schema {
	base := parquet.SchemaOf(fieldOrder{})
	fields := append([]parquet.Field(nil), base.Fields()...)
	for i, field := range fields {
		typ := parquet.Type(legacyType{field.Type()})
		if i == 0 {
			typ = parquet.TimestampAdjusted(parquet.Microsecond, false).Type()
		}
		fields[i] = typedField{Field: field, typ: typ}
	}
	return parquet.NewSchema("pidstat", orderedRoot{Node: base, fields: fields})
}
