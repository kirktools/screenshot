package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	pngcodec "image/png"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/ebitengine/purego"
	"github.com/egoist/mygo"
	"github.com/egoist/mygo/ui"
)

type Frame struct {
	Width       int32
	Height      int32
	SourceWidth int32
	Pixels      string
}
type Vector struct {
	Name     string
	Previous Frame
	Next     Frame
	Expected string
}
type Settings struct {
	Normal string
	Scroll string
}
type Service struct {
	mu    sync.Mutex
	value Settings
}

func (s *Service) Save(normal, scroll string) Settings {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.value = Settings{normal, scroll}
	return s.value
}
func (s *Service) Read() Settings { s.mu.Lock(); defer s.mu.Unlock(); return s.value }
func (s *Service) Core() int32    { return abi() }

var abi func() int32
var match func(unsafe.Pointer, int32, int32, int32, int32, unsafe.Pointer, int32, int32, int32, int32, unsafe.Pointer) int32

func coreCheck() {
	h, e := loadLibrary(filepath.Join(mustWD(), libraryName))
	if e != nil {
		panic(e)
	}
	purego.RegisterLibFunc(&abi, h, "screenshot_stitch_abi_version")
	purego.RegisterLibFunc(&match, h, "screenshot_stitch_match")
	if abi() != 1 {
		panic("ABI mismatch")
	}
	data, e := os.ReadFile(filepath.Join(mustWD(), "vectors.json"))
	if e != nil {
		panic(e)
	}
	var vs []Vector
	if e = json.Unmarshal(data, &vs); e != nil {
		panic(e)
	}
	labels := []string{"duplicate", "append", "reverse", "incompatibleSize", "insufficientOverlap", "ambiguous", "changedContent"}
	start := time.Now()
	for _, v := range vs {
		a, e := base64.StdEncoding.DecodeString(v.Previous.Pixels)
		if e != nil {
			panic(e)
		}
		b, e := base64.StdEncoding.DecodeString(v.Next.Pixels)
		if e != nil {
			panic(e)
		}
		var rows int32
		r := match(unsafe.Pointer(&a[0]), int32(len(a)), v.Previous.Width, v.Previous.Height, v.Previous.SourceWidth, unsafe.Pointer(&b[0]), int32(len(b)), v.Next.Width, v.Next.Height, v.Next.SourceWidth, unsafe.Pointer(&rows))
		runtime.KeepAlive(a)
		runtime.KeepAlive(b)
		if r < 0 || int(r) >= len(labels) {
			panic(fmt.Sprint("invalid result ", r))
		}
		actual := labels[r]
		if r == 1 {
			actual += fmt.Sprintf(":%d", rows)
		}
		if actual != v.Expected {
			panic(fmt.Sprintf("%s got %s expected %s", v.Name, actual, v.Expected))
		}
		fmt.Println("PASS Swift vector", v.Name)
	}
	fmt.Printf("PASS Go→Swift %d vectors elapsed=%s\n", len(vs), time.Since(start))
	var create func() uintptr
	var destroy func(uintptr)
	var consume func(uintptr, unsafe.Pointer, int32, int32, int32, int32, float64, unsafe.Pointer, unsafe.Pointer) int32
	purego.RegisterLibFunc(&create, h, "screenshot_stitch_tracker_create")
	purego.RegisterLibFunc(&destroy, h, "screenshot_stitch_tracker_destroy")
	purego.RegisterLibFunc(&consume, h, "screenshot_stitch_tracker_consume")
	tracker := create()
	if tracker == 0 {
		panic("tracker create")
	}
	a, _ := base64.StdEncoding.DecodeString(vs[0].Previous.Pixels)
	b, _ := base64.StdEncoding.DecodeString(vs[0].Next.Pixels)
	var kind, rows int32
	if consume(tracker, unsafe.Pointer(&a[0]), int32(len(a)), 32, 160, 320, 0, unsafe.Pointer(&kind), unsafe.Pointer(&rows)) != 0 {
		panic("tracker seed")
	}
	if consume(tracker, unsafe.Pointer(&b[0]), int32(len(b)), 32, 160, 320, .1, unsafe.Pointer(&kind), unsafe.Pointer(&rows)) != 1 || rows != 40 {
		panic("tracker append")
	}
	if consume(tracker, unsafe.Pointer(&b[0]), 1, 32, 160, 320, .2, unsafe.Pointer(&kind), unsafe.Pointer(&rows)) != -1 {
		panic("tracker invalid frame")
	}
	runtime.KeepAlive(a)
	runtime.KeepAlive(b)
	destroy(tracker)
	fmt.Println("PASS real tracker create/seed/append/invalid frame/destroy")
	n := 100000
	start = time.Now()
	for range n {
		if abi() != 1 {
			panic("ABI")
		}
	}
	fmt.Printf("FFI abi version call mean=%s (not frame throughput)\n", time.Since(start)/time.Duration(n))
}
func mustWD() string {
	p, e := os.Executable()
	if e != nil {
		panic(e)
	}
	return filepath.Dir(p)
}

const html = `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><style>body{font:15px system-ui;margin:32px;background:#f6f7f9;color:#222}label{display:block;margin:18px 0}input,button{font:inherit;padding:8px}p{color:#555}</style><h2>Screenshot 设置 · MyGo 实验</h2><p>独立设置小样，不修改正式版偏好和权限</p><label>普通截图 <input id="normal" value="Command+Shift+2"></label><label>滚动长截图 <input id="scroll" value="Command+Shift+7"></label><button id="save">保存测试设置</button><p id="status">加载中</p><script>save.onclick=async()=>{let v=await mygo.call('Service.Save',normal.value,scroll.value);document.getElementById('status').textContent=JSON.stringify(v)};mygo.call('Service.Core').then(v=>document.getElementById('status').textContent='Swift 核心 ABI '+v)</script></html>`

func main() {
	coreCheck()
	if len(os.Args) > 1 && os.Args[1] == "core" {
		return
	}
	native := len(os.Args) > 1 && os.Args[1] == "native"
	svc := &Service{}
	watchdog := time.AfterFunc(25*time.Second, func() { panic("UI probe timed out") })
	defer watchdog.Stop()
	mygo.Bind(svc)
	mygo.App.SetName("Screenshot MyGo Probe")
	mygo.App.WhenReady(func() {
		started := time.Now()
		opts := mygo.WindowOptions{Title: "Screenshot MyGo 实验", Width: 520, Height: 380}
		if native {
			opts.Content = ui.View(func(c *ui.Context) {
				ui.Column(c).Fill().Gap(16).Children(func() {
					ui.Text(c, "Screenshot 设置 · 原生绘制实验")
					ui.Text(c, "Swift 共享核心 ABI 1")
					if ui.Button(c.Key("close"), "结束实验").Clicked() {
						mygo.App.Quit()
					}
				})
			})
		}
		w := mygo.NewWindow(opts)
		if !native {
			w.Page().LoadHTML(html, "")
		}
		mygo.App.SetMenu(mygo.NewMenu([]*mygo.MenuItem{{Role: mygo.RoleAppMenu}, {Role: mygo.RoleEditMenu}}))
		go func() {
			defer func() {
				if os.Getenv("KEEP_OPEN") != "1" {
					mygo.App.Quit()
				}
			}()
			if !native {
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				defer cancel()
				for {
					v, e := w.Page().EvalContext(ctx, "typeof mygo !== 'undefined'")
					if e == nil && v == true {
						break
					}
					if ctx.Err() != nil {
						panic("web bridge startup timeout")
					}
					time.Sleep(30 * time.Millisecond)
				}
				fmt.Printf("WEB bridge ready since window create=%s\n", time.Since(started))
				r, e := w.Page().EvalContext(ctx, "return await mygo.call('Service.Save','Command+Shift+2','Command+Shift+7')")
				if e != nil {
					panic(e)
				}
				fmt.Println("PASS Web→Go settings IPC", r)
				v, e := w.Page().EvalContext(ctx, "return await mygo.call('Service.Core')")
				if e != nil || fmt.Sprint(v) != "1" {
					panic(fmt.Sprint("Web→Go→Swift failed", v, e))
				}
				fmt.Println("PASS Web→Go→Swift ABI")
				start := time.Now()
				_, e = w.Page().EvalContext(ctx, "for(let i=0;i<100;i++) await mygo.call('Service.Core'); return true")
				if e != nil {
					panic(e)
				}
				fmt.Printf("100 sequential JS→Go→Swift IPC=%s\n", time.Since(start))
				png, e := w.CapturePage()
				if e != nil {
					panic(e)
				}
				if e = os.WriteFile(filepath.Join(mustWD(), "settings.png"), png, 0600); e != nil {
					panic(e)
				}
				verifyPNG(png)
				fmt.Println("PASS own page snapshot has rendered content")
			}
			err := mygo.GlobalShortcut.Register("CmdOrCtrl+Alt+Shift+F12", func() {})
			if err != nil {
				fmt.Println("NOT VERIFIED shortcut registration", err)
			} else {
				fmt.Println("PASS global shortcut registration and release")
				mygo.GlobalShortcut.UnregisterAll()
			}
			if native {
				time.Sleep(250 * time.Millisecond)
				data, e := w.CapturePage()
				if e != nil {
					panic(e)
				}
				verifyPNG(data)
				if e = os.WriteFile(filepath.Join(mustWD(), "native-settings.png"), data, 0600); e != nil {
					panic(e)
				}
				fmt.Println("PASS native MyGo UI rendered content")
			}
			fmt.Println("NOT VERIFIED: capture overlays, screen permissions and live scrolling are outside this probe")
			if !native {
				fmt.Println("PASS settings remain", strings.Contains(fmt.Sprint(svc.Read()), "Command"))
			}
		}()
	})
	if e := mygo.App.Run(); e != nil {
		log.Fatal(e)
	}
}

func verifyPNG(data []byte) {
	img, e := pngcodec.Decode(bytes.NewReader(data))
	if e != nil {
		panic(e)
	}
	colors := map[uint64]bool{}
	for y := 0; y < img.Bounds().Dy(); y += 4 {
		for x := 0; x < img.Bounds().Dx(); x += 4 {
			r, g, b, a := img.At(x, y).RGBA()
			colors[uint64(r)<<48|uint64(g)<<32|uint64(b)<<16|uint64(a)] = true
		}
	}
	if len(colors) < 8 {
		panic("page rendered blank")
	}
}
