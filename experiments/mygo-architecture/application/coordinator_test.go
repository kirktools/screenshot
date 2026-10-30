package application

import (
	"errors"
	"sync"
	"testing"
)

type fakeBackend struct {
	starts    int
	cancelled int64
	shutdown  int
	commits   int
	fail      bool
	mu        sync.Mutex
}

func (f *fakeBackend) Begin(id int64, request CaptureRequest) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.starts++
	if f.fail {
		return errors.New("capture denied")
	}
	return nil
}
func (f *fakeBackend) Commit(id int64) error      { f.commits++; return nil }
func (f *fakeBackend) Cancel(id int64)            { f.cancelled = id }
func (f *fakeBackend) Capabilities() Capabilities { return Capabilities{Region: true} }
func (f *fakeBackend) Shutdown()                  { f.shutdown++ }
func TestLifecycle(t *testing.T) {
	f := &fakeBackend{}
	c := NewCoordinator(f)
	id, e := c.Begin(CaptureRequest{Mode: "region", Output: "clipboard"})
	if e != nil {
		t.Fatal(e)
	}
	if _, e = c.Begin(CaptureRequest{Mode: "region", Output: "clipboard"}); e == nil {
		t.Fatal("duplicate start")
	}
	if c.Handle(Event{ID: id, Kind: "selecting"}) {
		t.Fatal("selection before freeze")
	}
	for _, k := range []string{"frozen", "selecting", "selected", "completed"} {
		if !c.Handle(Event{ID: id, Kind: k}) {
			t.Fatal(k)
		}
	}
	if c.Snapshot().Active {
		t.Fatal("leak active")
	}
	next, e := c.Begin(CaptureRequest{Mode: "region", Output: "clipboard"})
	if e != nil || next <= id {
		t.Fatal("generation")
	}
	if c.Handle(Event{ID: id, Kind: "failed"}) {
		t.Fatal("stale callback")
	}
	c.Cancel()
	if f.cancelled != next || c.Snapshot().Phase != "cancelling" {
		t.Fatal("cancel")
	}
	if c.Handle(Event{ID: next, Kind: "frozen"}) {
		t.Fatal("freeze after cancel")
	}
	if !c.Handle(Event{ID: next, Kind: "cancelled"}) {
		t.Fatal("cancel result")
	}
	c.Close()
	c.Close()
	if f.shutdown != 1 {
		t.Fatal("double close")
	}
	if _, e = c.Begin(CaptureRequest{Mode: "region", Output: "clipboard"}); e == nil {
		t.Fatal("start after close")
	}
	if c.Handle(Event{ID: next, Kind: "completed"}) {
		t.Fatal("callback after close")
	}
}
func TestBackendFailure(t *testing.T) {
	c := NewCoordinator(&fakeBackend{fail: true})
	if _, e := c.Begin(CaptureRequest{Mode: "region", Output: "clipboard"}); e == nil {
		t.Fatal("expected error")
	}
	if c.Snapshot().Active || c.Snapshot().Phase != "failed" {
		t.Fatal("stuck after failure")
	}
}
func TestConcurrentStart(t *testing.T) {
	f := &fakeBackend{}
	c := NewCoordinator(f)
	var wg sync.WaitGroup
	for range 32 {
		wg.Go(func() { _, _ = c.Begin(CaptureRequest{Mode: "region", Output: "clipboard"}) })
	}
	wg.Wait()
	if f.starts != 1 {
		t.Fatal(f.starts)
	}
}

func TestUnsupportedCapabilities(t *testing.T) {
	f := &fakeBackend{}
	c := NewCoordinator(f)
	for _, r := range []CaptureRequest{{Mode: "scroll", Output: "clipboard"}, {Mode: "region", Output: "save"}} {
		if _, e := c.Begin(r); e == nil {
			t.Fatal("unsupported feature accepted")
		}
	}
	if f.starts != 0 || c.Snapshot().Active {
		t.Fatal("unsupported command reached backend")
	}
}

func TestCancelDiscardsLateSelectionBeforeOutput(t *testing.T) {
	f := &fakeBackend{}
	c := NewCoordinator(f)
	id, _ := c.Begin(CaptureRequest{Mode: "region", Output: "clipboard"})
	c.Handle(Event{ID: id, Kind: "frozen"})
	c.Handle(Event{ID: id, Kind: "selecting"})
	c.Cancel()
	if c.Handle(Event{ID: id, Kind: "selected"}) || f.commits != 0 {
		t.Fatal("late selection committed after cancellation")
	}
	c.Handle(Event{ID: id, Kind: "cancelled"})
	if c.Snapshot().Active {
		t.Fatal("cancel stuck")
	}
}
func TestCommitLinearization(t *testing.T) {
	f := &fakeBackend{}
	c := NewCoordinator(f)
	id, _ := c.Begin(CaptureRequest{Mode: "region", Output: "clipboard"})
	for _, k := range []string{"frozen", "selecting", "selected"} {
		c.Handle(Event{ID: id, Kind: k})
	}
	c.Cancel()
	if f.cancelled != 0 || f.commits != 1 || c.Snapshot().Phase != "committing" {
		t.Fatal("output commit interrupted")
	}
	if !c.Handle(Event{ID: id, Kind: "completed"}) || c.Snapshot().Active {
		t.Fatal("completion lost")
	}
}
