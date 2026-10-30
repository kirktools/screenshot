package application

import (
	"errors"
	"testing"
)

type frameFake struct {
	releases, appends    int
	failRead, failAppend bool
}

func (f *frameFake) Read(id int64) (Frame, error) {
	if f.failRead {
		return Frame{}, errors.New("invalid lease")
	}
	return Frame{Height: 100}, nil
}
func (f *frameFake) Append(id int64, rows int32) error {
	if f.failAppend {
		return errors.New("memory limit")
	}
	f.appends++
	return nil
}
func (f *frameFake) Release(id int64) { f.releases++ }

type trackerFake struct {
	result  Tracking
	pending bool
	closes  int
}

func (f *trackerFake) Consume(frame Frame) Tracking { return f.result }
func (f *trackerFake) Unmatched() bool              { return f.pending }
func (f *trackerFake) Close()                       { f.closes++ }
func TestFrameLeasesAndUnreliableOutput(t *testing.T) {
	b := &frameFake{}
	core := &trackerFake{}
	p := NewStreamProcessor(b, core)
	if e := p.Process(1); e != nil {
		t.Fatal(e)
	}
	core.result = Tracking{Kind: 3}
	core.pending = true
	p.Process(2)
	if p.CanFinish() || b.appends != 1 || b.releases != 2 {
		t.Fatal("unreliable content exported or lease leaked")
	}
	core.result = Tracking{Kind: 2}
	core.pending = false
	p.Process(3)
	if !p.CanFinish() || p.Stats.Rows != 100 {
		t.Fatal("duplicate changed output")
	}
	p.Close()
	p.Close()
	if p.Process(4) == nil || b.releases != 4 || core.closes != 1 {
		t.Fatal("closed worker leaked lease or double free")
	}
}
func TestFrameFailureAlwaysReleases(t *testing.T) {
	for _, b := range []*frameFake{{failRead: true}, {failAppend: true}} {
		p := NewStreamProcessor(b, &trackerFake{})
		if p.Process(1) == nil || b.releases != 1 || p.CanFinish() {
			t.Fatal("frame failure exposed output or leaked lease")
		}
		p.Close()
	}
}
