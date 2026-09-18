extends SceneTree
# Assert that every placement path is actually WIRED to the shared attach.
#
# This exists because of a bug that shipped. The terrain and the backdrop each
# place a node, and a patch that rewired both silently rewired only one: the
# backdrop went under "Static" with an owner and appeared in the Scene dock, and
# the terrain kept calling root.add_child with owner = null and stayed invisible.
#
# Nothing caught it. The parse gate was green, because the file was valid. The
# runtime test was green, because it called _attach and _static_parent directly
# and proved the helper worked - which it did. What went untested was whether
# the code paths a person actually uses CALL that helper. A unit test on a
# helper cannot see a caller that does not call it.
#
# So this checks the source itself: two placement sites, both using _attach,
# none using the raw add_child, and no comment left behind claiming the old
# behaviour. It is a lint rather than a test, and it is the only thing here that
# would have failed on the broken version.
#
#   Godot --headless --path <proj> -s res://tests_wiring.gd

const PLUGIN := "res://addons/bf6_terrain_pack/terrain_pack_plugin.gd"

var _fail := 0


func _init() -> void:
	call_deferred("_run")


func _c(name: String, ok: bool, detail: String) -> void:
	if not ok:
		_fail += 1
	print("%-6s %-42s %s" % ["ok" if ok else "FAIL", name, detail])


func _run() -> void:
	var f: FileAccess = FileAccess.open(PLUGIN, FileAccess.READ)
	if f == null:
		print("cannot read " + PLUGIN)
		quit(1)
		return
	var src: String = f.get_as_text()
	f.close()

	var attach := _count(src, "_attach(root, node)")
	var raw := _count(src, "root.add_child(node)")
	var stale := _count(src, "owner stays null")

	# Two things place a node: the terrain and the backdrop. Both must go
	# through _attach, which is what puts them under Static and owns them.
	_c("both placements use _attach", attach == 2, "%d found, expected 2" % attach)
	_c("no placement bypasses it", raw == 0,
		"%d raw root.add_child(node) left" % raw)
	_c("no stale owner=null comment", stale == 0,
		"%d left" % stale)

	# The helper itself must still do the two things its callers rely on.
	_c("_attach parents under Static", src.contains("_static_parent(root)"),
		"calls _static_parent")
	_c("_attach sets an owner", src.contains("node.owner = root"),
		"sets node.owner")
	# And the mesh must come from the imported resource, or owning the node
	# would serialise geometry into the level.
	_c("instances from the imported asset",
		src.contains("_instance_of(path)") and not src.contains("_fetch.load_mesh(path)"),
		"uses _instance_of, not a runtime parse")

	print("\n%s" % ("ALL PASS" if _fail == 0 else "%d FAILURE(S)" % _fail))
	quit(1 if _fail else 0)


func _count(hay: String, needle: String) -> int:
	var n := 0
	var at := hay.find(needle)
	while at != -1:
		n += 1
		at = hay.find(needle, at + needle.length())
	return n
