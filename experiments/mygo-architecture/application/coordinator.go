package application

import (
	"errors"
	"sync"
)

// 状态与命令属于应用服务；不依赖 MyGo、AppKit 或 Win32。
type Event struct {
	ID           int64   `json:"id"`
	Kind         string  `json:"kind"`
	Detail       string  `json:"detail"`
	Milliseconds float64 `json:"milliseconds"`
}
type State struct {
	ID     int64  `json:"id"`
	Phase  string `json:"phase"`
	Detail string `json:"detail"`
	Active bool   `json:"active"`
	Closed bool   `json:"closed"`
}
type CaptureRequest struct {
	Mode   string
	Output string
}
type Capabilities struct {
	Region                   bool
	Scroll                   bool
	WindowPreselection       bool
	ScreenPermissionRequired bool
}
type CaptureBackend interface {
	Begin(int64, CaptureRequest) error
	Capabilities() Capabilities
	Commit(int64) error
	Cancel(int64)
	Shutdown()
}
type Coordinator struct {
	mu      sync.Mutex
	backend CaptureBackend
	state   State
}

func NewCoordinator(b CaptureBackend) *Coordinator {
	return &Coordinator{backend: b, state: State{Phase: "idle"}}
}
func (c *Coordinator) Snapshot() State { c.mu.Lock(); defer c.mu.Unlock(); return c.state }
func (c *Coordinator) Begin(request CaptureRequest) (int64, error) {
	caps := c.backend.Capabilities()
	if request.Mode != "region" || !caps.Region {
		return 0, errors.New("当前适配器尚未实现该捕获方式")
	}
	if request.Output != "clipboard" {
		return 0, errors.New("当前适配器尚未实现该输出方式")
	}
	c.mu.Lock()
	if c.state.Closed {
		c.mu.Unlock()
		return 0, errors.New("服务已关闭")
	}
	if c.state.Active {
		c.mu.Unlock()
		return 0, errors.New("已有截图会话")
	}
	c.state.ID++
	id := c.state.ID
	c.state.Phase = "freezing"
	c.state.Detail = ""
	c.state.Active = true
	c.mu.Unlock()
	if err := c.backend.Begin(id, request); err != nil {
		c.Handle(Event{ID: id, Kind: "failed", Detail: err.Error()})
		return id, err
	}
	return id, nil
}

// 原生选区只产生结果；由公共服务决定是否提交输出，避免取消后的迟到结果写剪贴板。
func (c *Coordinator) Handle(e Event) bool {
	c.mu.Lock()
	if c.state.Closed || !c.state.Active || e.ID != c.state.ID {
		c.mu.Unlock()
		return false
	}
	p := c.state.Phase
	valid := true
	commit := false
	switch e.Kind {
	case "freezing":
		valid = p == "freezing"
	case "frozen":
		valid = p == "freezing"
	case "selecting":
		valid = p == "frozen"
	case "selected":
		valid = p == "selecting"
		commit = valid
	case "completed":
		valid = p == "committing"
		if valid {
			c.state.Active = false
		}
	case "cancelled", "failed":
		c.state.Active = false
	default:
		valid = false
	}
	if !valid {
		c.mu.Unlock()
		return false
	}
	c.state.Phase = e.Kind
	if commit {
		c.state.Phase = "committing"
	}
	c.state.Detail = e.Detail
	c.mu.Unlock()
	// 不持锁调用平台，平台可同步回调。committing 是输出授权的线性化点。
	if commit {
		if err := c.backend.Commit(e.ID); err != nil {
			c.Handle(Event{ID: e.ID, Kind: "failed", Detail: err.Error()})
		}
	}
	return true
}
func (c *Coordinator) Cancel() {
	c.mu.Lock()
	if !c.state.Active || c.state.Closed || c.state.Phase == "committing" {
		c.mu.Unlock()
		return
	}
	id := c.state.ID
	c.state.Phase = "cancelling"
	c.mu.Unlock()
	c.backend.Cancel(id)
}
func (c *Coordinator) Close() {
	c.mu.Lock()
	if c.state.Closed {
		c.mu.Unlock()
		return
	}
	c.state.Closed = true
	c.state.Active = false
	c.state.Phase = "closed"
	c.mu.Unlock()
	c.backend.Shutdown()
}

func (c *Coordinator) Capabilities() Capabilities { return c.backend.Capabilities() }
