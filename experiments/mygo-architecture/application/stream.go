package application

import "fmt"

type Frame struct {
	Pixels                     []byte
	Width, Height, SourceWidth int32
	Time                       float64
}
type Tracking struct{ Kind, Match, Rows int32 }
type FrameBackend interface {
	Read(int64) (Frame, error)
	Append(int64, int32) error
	Release(int64)
}
type Tracker interface {
	Consume(Frame) Tracking
	Unmatched() bool
	Close()
}
type StreamStats struct{ Rows, Appends, Duplicates, Recoveries int }

// 每个会话单一 worker 串行消费。帧租约在所有分支释放，像素不进入 UI。
type StreamProcessor struct {
	backend        FrameBackend
	core           Tracker
	Stats          StreamStats
	closed, failed bool
}

func NewStreamProcessor(b FrameBackend, t Tracker) *StreamProcessor {
	return &StreamProcessor{backend: b, core: t}
}
func (p *StreamProcessor) Process(id int64) error {
	defer p.backend.Release(id)
	if p.closed || p.failed {
		return fmt.Errorf("stream is closed or failed")
	}
	frame, e := p.backend.Read(id)
	if e != nil {
		p.failed = true
		return e
	}
	result := p.core.Consume(frame)
	rows := int32(0)
	switch result.Kind {
	case 0:
		rows = frame.Height
	case 1:
		rows = result.Rows
	case 2:
		p.Stats.Duplicates++
	case 3:
		p.Stats.Recoveries++
	default:
		p.failed = true
		return fmt.Errorf("tracker stopped: kind=%d reason=%d", result.Kind, result.Match)
	}
	if rows > 0 {
		if e = p.backend.Append(id, rows); e != nil {
			p.failed = true
			return e
		}
		p.Stats.Rows += int(rows)
		p.Stats.Appends++
	}
	return nil
}
func (p *StreamProcessor) CanFinish() bool {
	return !p.closed && !p.failed && p.Stats.Rows > 0 && !p.core.Unmatched()
}
func (p *StreamProcessor) Close() {
	if p.closed {
		return
	}
	p.closed = true
	p.core.Close()
}
