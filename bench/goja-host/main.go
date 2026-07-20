// goja-host — feasibility probe: how far does a pure-Go JS engine get with the real
// Claude Code bundle, and at what compile-time / memory cost, on 32-bit-clean Go?
//
// This is NOT an attempt to run Claude Code. It answers four questions for the report:
//   (a) does goja even PARSE + COMPILE the ~26 MB es2020-lowered bundle?
//   (b) how long does that compile take, per launch (goja can't cache *Program to disk)?
//   (c) how much memory does compiling + holding the program cost?
//   (d) what is the first Node API wall — the ordered list of modules the `--version`
//       path require()s that a Go host would have to reimplement.
//
// Output: one JSON line to stdout (consumed by run.sh). Peak RSS is measured by the
// outer measure.py wrapper. Exit 0 means "probe ran and reported"; a wall is a result,
// not a failure.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/dop251/goja"
)

type report struct {
	Engine        string   `json:"engine"`
	BundlePath    string   `json:"bundle"`
	BundleBytes   int64    `json:"bundle_bytes"`
	CompileOK     bool     `json:"compile_ok"`
	CompileErr    string   `json:"compile_err,omitempty"`
	CompileMs     float64  `json:"compile_ms"`
	RunReached    string   `json:"run_reached"` // "n/a" | "factory-called" | "version-printed" | "aborted"
	RunErr        string   `json:"run_err,omitempty"`
	RunMs         float64  `json:"run_ms"`
	Requested     []string `json:"modules_requested"`  // every require() id, in first-seen order
	Unshimmed     []string `json:"modules_unshimmed"`  // subset we did not provide (the shim mountain)
	FirstWall     string   `json:"first_wall,omitempty"`
	VersionOutput string   `json:"version_output,omitempty"`
	GoHeapMB      float64  `json:"go_heap_mb"`
	GoArch        string   `json:"go_arch"`
}

// modules we can hand back a trivial-enough object for, to let execution proceed a
// little further and reveal MORE of the surface instead of dying at the first require.
// Everything else is recorded and throws UNSHIMMED (caught-or-not by the bundle's own
// try/catch — either way we log it).
func provided(vm *goja.Runtime) map[string]func() goja.Value {
	empty := func() goja.Value { return vm.NewObject() }
	return map[string]func() goja.Value{
		"node:events":        empty,
		"events":             empty,
		"node:util":          empty,
		"util":               empty,
		"node:path":          empty,
		"path":               empty,
		"node:os":            empty,
		"os":                 empty,
		"node:assert":        empty,
		"assert":             empty,
		"node:string_decoder": empty,
		"string_decoder":     empty,
	}
}

func main() {
	var bundlePath string
	var compileOnly bool
	var argsCSV string
	flag.StringVar(&bundlePath, "bundle", envOr("BENCH_BUNDLE", "../build/bundle.goja.cjs"), "path to es2020 cjs bundle")
	flag.BoolVar(&compileOnly, "compile-only", false, "measure compile only, then exit")
	flag.StringVar(&argsCSV, "args", "--version", "comma-separated argv passed to the bundle")
	flag.Parse()

	r := report{Engine: "goja", BundlePath: bundlePath, RunReached: "n/a", GoArch: runtime.GOARCH}

	src, err := os.ReadFile(bundlePath)
	if err != nil {
		r.CompileErr = "read bundle: " + err.Error()
		emit(r)
		return
	}
	r.BundleBytes = int64(len(src))

	// (a)+(b) compile
	t0 := time.Now()
	prog, err := goja.Compile(bundlePath, string(src), false)
	r.CompileMs = msSince(t0)
	if err != nil {
		r.CompileErr = trunc(err.Error(), 400)
		emit(r)
		return
	}
	r.CompileOK = true

	if compileOnly {
		r.GoHeapMB = heapMB()
		emit(r)
		return
	}

	// (c)+(d) set up a minimal host and run
	vm := goja.New()
	seen := map[string]bool{}
	requireFn := func(call goja.FunctionCall) goja.Value {
		id := call.Argument(0).String()
		if !seen[id] {
			seen[id] = true
			r.Requested = append(r.Requested, id)
		}
		if f, ok := provided(vm)[id]; ok {
			return f()
		}
		// record as a wall and throw (the bundle may or may not catch it)
		if !contains(r.Unshimmed, id) {
			r.Unshimmed = append(r.Unshimmed, id)
			if r.FirstWall == "" {
				r.FirstWall = id
			}
		}
		panic(vm.ToValue("UNSHIMMED:" + id))
	}
	installGlobals(vm, requireFn, splitCSV(argsCSV), &r)

	// run the outer cjs wrapper: assigns module.exports.default = factory
	outerModule := vm.NewObject()
	outerExports := vm.NewObject()
	_ = outerModule.Set("exports", outerExports)
	_ = vm.Set("module", outerModule)
	_ = vm.Set("exports", outerExports)
	_ = vm.Set("require", vm.ToValue(requireFn))
	_ = vm.Set("__filename", "/opt/claude-code/lib/claude-code/cli.js")
	_ = vm.Set("__dirname", "/opt/claude-code/lib/claude-code")

	t1 := time.Now()
	func() {
		defer func() {
			if rec := recover(); rec != nil {
				r.RunErr = trunc(fmt.Sprint(rec), 300)
			}
			r.RunMs = msSince(t1)
		}()
		if _, e := vm.RunProgram(prog); e != nil {
			r.RunErr = trunc(e.Error(), 300)
			return
		}
		// fetch factory = module.exports.default (or module.exports if not esModule-wrapped)
		factory := resolveFactory(vm, outerModule)
		if factory == nil {
			r.RunErr = "no factory export found on module.exports(.default)"
			return
		}
		r.RunReached = "factory-called"
		innerModule := vm.NewObject()
		innerExports := vm.NewObject()
		_ = innerModule.Set("exports", innerExports)
		_, e := factory(goja.Undefined(),
			innerExports,
			vm.ToValue(requireFn),
			innerModule,
			vm.ToValue("/opt/claude-code/lib/claude-code/cli.js"),
			vm.ToValue("/opt/claude-code/lib/claude-code"),
		)
		if e != nil {
			r.RunErr = trunc(e.Error(), 300)
		}
	}()

	r.GoHeapMB = heapMB()
	emit(r)
}

// resolveFactory returns module.exports.default if present, else module.exports if callable.
func resolveFactory(vm *goja.Runtime, mod *goja.Object) goja.Callable {
	exportsV := mod.Get("exports")
	exports, ok := exportsV.(*goja.Object)
	if !ok {
		return nil
	}
	if d := exports.Get("default"); d != nil {
		if fn, ok := goja.AssertFunction(d); ok {
			return fn
		}
	}
	if fn, ok := goja.AssertFunction(exportsV); ok {
		return fn
	}
	return nil
}

func installGlobals(vm *goja.Runtime, requireFn func(goja.FunctionCall) goja.Value, argv []string, r *report) {
	// console
	console := vm.NewObject()
	logf := func(call goja.FunctionCall) goja.Value {
		parts := make([]string, 0, len(call.Arguments))
		for _, a := range call.Arguments {
			parts = append(parts, a.String())
		}
		line := strings.Join(parts, " ")
		// capture anything that looks like the version print
		if strings.Contains(line, "Claude Code") || strings.Contains(line, "2.1.") {
			if r.VersionOutput == "" {
				r.VersionOutput = trunc(line, 120)
				r.RunReached = "version-printed"
			}
		}
		return goja.Undefined()
	}
	for _, m := range []string{"log", "error", "warn", "info", "debug", "trace"} {
		_ = console.Set(m, logf)
	}
	_ = vm.Set("console", console)

	// process
	proc := vm.NewObject()
	fullArgv := append([]string{"node", "cli.js"}, argv...)
	_ = proc.Set("argv", fullArgv)
	_ = proc.Set("platform", "linux")
	_ = proc.Set("arch", "arm")
	_ = proc.Set("version", "v20.19.0")
	versions := vm.NewObject()
	_ = versions.Set("node", "20.19.0")
	_ = proc.Set("versions", versions)
	env := vm.NewObject()
	_ = env.Set("DISABLE_AUTOUPDATER", "1")
	_ = env.Set("USE_BUILTIN_RIPGREP", "0")
	_ = proc.Set("env", env)
	_ = proc.Set("cwd", func(goja.FunctionCall) goja.Value { return vm.ToValue("/home/pi") })
	_ = proc.Set("on", func(goja.FunctionCall) goja.Value { return goja.Undefined() })
	_ = proc.Set("nextTick", func(call goja.FunctionCall) goja.Value {
		if fn, ok := goja.AssertFunction(call.Argument(0)); ok {
			_, _ = fn(goja.Undefined())
		}
		return goja.Undefined()
	})
	_ = proc.Set("exit", func(call goja.FunctionCall) goja.Value {
		panic(vm.ToValue("PROCESS_EXIT"))
	})
	stdout := vm.NewObject()
	_ = stdout.Set("write", func(call goja.FunctionCall) goja.Value {
		s := call.Argument(0).String()
		if strings.Contains(s, "Claude Code") || strings.Contains(s, "2.1.") {
			if r.VersionOutput == "" {
				r.VersionOutput = trunc(strings.TrimSpace(s), 120)
				r.RunReached = "version-printed"
			}
		}
		return vm.ToValue(true)
	})
	_ = stdout.Set("isTTY", false)
	_ = proc.Set("stdout", stdout)
	_ = proc.Set("stderr", stdout)
	_ = vm.Set("process", proc)

	// minimal Bun stub (surface mirrors shim/bun-shim.mjs, enough to not crash on lookup)
	bun := vm.NewObject()
	_ = bun.Set("isStandaloneExecutable", false)
	_ = bun.Set("stringWidth", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(len(call.Argument(0).String()))
	})
	_ = vm.Set("Bun", bun)

	// global aliases
	_ = vm.Set("global", vm.GlobalObject())
	_ = vm.Set("globalThis", vm.GlobalObject())
}

// ---- helpers ----
func emit(r report) {
	b, _ := json.Marshal(r)
	fmt.Println(string(b))
}
func msSince(t time.Time) float64 { return float64(time.Since(t).Microseconds()) / 1000.0 }
func heapMB() float64 {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return float64(m.HeapAlloc) / (1024 * 1024)
}
func trunc(s string, n int) string {
	if len(s) > n {
		return s[:n] + "…"
	}
	return s
}
func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}
func splitCSV(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, ",")
}
func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
