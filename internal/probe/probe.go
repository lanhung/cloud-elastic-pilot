package probe

import "context"

type Event struct {
	Type        string
	TimestampNS int64
	PID         uint32
	TID         uint32
	Payload     map[string]any
}

type Probe interface {
	Run(context.Context, chan<- Event) error
	Close() error
}

type Disabled struct{}

func (Disabled) Run(ctx context.Context, _ chan<- Event) error { <-ctx.Done(); return ctx.Err() }
func (Disabled) Close() error                                  { return nil }
