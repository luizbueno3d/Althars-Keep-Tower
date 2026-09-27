extends SceneTree
## Minimal zero-dependency test harness — mirrors the canonical
## Althar's Keep style.
## Run: godot --headless --path . -s res://tests/run_tests.gd

var passed := 0
var failed := 0
var failures: Array[String] = []

func check(cond: bool, msg: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		failures.append(msg)
		print("FAIL  ", msg)

func eq(a, b, msg := "") -> void:
	check(a == b, "%s  (expected %s, got %s)" % [msg, str(b), str(a)])

func _initialize() -> void:
	var modules := [
		"res://tests/test_command_state.gd",
	]
	for m in modules:
		print("== ", m.get_file())
		(load(m) as GDScript).new().run(self)
	print("----------------------------------------")
	print("%d passed, %d failed" % [passed, failed])
	if failed > 0:
		for f in failures:
			print("  FAILED: ", f)
	quit(0 if failed == 0 else 1)
