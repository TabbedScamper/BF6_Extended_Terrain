extends SceneTree
# Prove the terrain pack plugin works with NOTHING else installed.
#
# This project deliberately contains only addons/bf6_terrain_pack: no High Poly
# plugin, no bf6_core.dll, no GDExtension of any kind, and the machine it runs on
# may or may not have Battlefield 6. If any of that were secretly required, the
# plugin would be standalone in name only, and the people it exists for - the
# ones without the game - would be the ones who found out.
#
# So this runs the real fetch against the real release and then checks the mesh
# the way Godot will actually see it.

const Fetch = preload("res://addons/bf6_terrain_pack/terrain_fetch.gd")

const LEVEL := "MP_Subsurface"        # smallest published map
var _fail := 0


func _init() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail: String) -> void:
	if not ok:
		_fail += 1
	print("%-6s %-36s %s" % ["ok" if ok else "FAIL", name, detail])


func _run() -> void:
	# nothing native may be needed for this plugin to work
	_check("no GDExtension required", not ClassDB.class_exists("BF6Core"),
		"BF6Core absent from this project, as it should be")

	var f: Node = Fetch.new()
	root.add_child(f)
	await process_frame

	var t0: int = Time.get_ticks_msec()
	var got: bool = await f.fetch_index()
	_check("fetch the index", got, "%d ms%s"
		% [Time.get_ticks_msec() - t0, "" if got else "  err: " + str(f.error)])
	if not got:
		_done()
		return

	var qs: Array = f.qualities_for(LEVEL)
	var names: Array = []
	for q in qs:
		names.append(Fetch.metres(float(q["target_m"])) + "m")
	_check("qualities for " + LEVEL, qs.size() >= 3,
		"%d: %s" % [qs.size(), ", ".join(names)])
	if qs.is_empty():
		_done()
		return

	var pick: Dictionary = qs[qs.size() - 1]        # coarsest, a few MB
	var asset: String = str(pick["name"])
	if f.is_cached(asset):
		f.evict(asset)
	_check("cache starts empty", not f.is_cached(asset), asset)

	t0 = Time.get_ticks_msec()
	var path: String = await f.ensure(asset)
	var cold: int = Time.get_ticks_msec() - t0
	_check("download and verify sha256", path != "",
		"%d ms%s" % [cold, "" if path != "" else "  err: " + str(f.error)])
	if path == "":
		_done()
		return

	t0 = Time.get_ticks_msec()
	var again: String = await f.ensure(asset)
	_check("second call is served from cache", again == path,
		"%d ms vs %d ms cold" % [Time.get_ticks_msec() - t0, cold])

	# THE user:// WALL. ResourceLoader can never see this file; the plugin has
	# to parse it itself. Assert both halves so a future change back to
	# ResourceLoader fails loudly here instead of silently in the editor.
	_check("ResourceLoader cannot load it", not ResourceLoader.exists(path),
		"as expected: the import pipeline only covers res://")

	var node: Node = f.load_mesh(path)
	_check("GLTFDocument parses it", node != null,
		"" if node != null else "err: " + str(f.error))
	if node == null:
		_done()
		return

	# generate_scene hands back ImporterMeshInstance3D in the editor, which does
	# not render and does not answer to MeshInstance3D.
	var importer_left: int = _count_importer(node)
	_check("no ImporterMeshInstance3D left", importer_left == 0,
		"%d remaining" % importer_left)

	var meshes: Array = _meshes(node)
	var verts: int = 0
	var surfaces: int = 0
	var min_ny: float = 1.0
	for m in meshes:
		var mi: MeshInstance3D = m
		if mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			surfaces += 1
			var arr: Array = mi.mesh.surface_get_arrays(s)
			var pos: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var nrm: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			verts += pos.size()
			for n in nrm:
				min_ny = minf(min_ny, n.y)
	_check("mesh has geometry", surfaces > 0 and verts > 0,
		"%d surface(s), %d vertices" % [surfaces, verts])
	_check("no normal points downward", min_ny >= -0.001, "min normal.y %+.3f" % min_ny)

	_material(node)
	node.queue_free()
	_done()


# The material has to come off the level, not out of the pack.
func _material(node: Node) -> void:
	var level: Node3D = Node3D.new()
	level.name = LEVEL
	var terr: Node3D = Node3D.new()
	terr.name = LEVEL + "_Terrain"
	level.add_child(terr)
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.123, 0.456, 0.789)
	# the SDK carries it on the MESH, not as an override
	mi.mesh.surface_set_material(0, mat)
	terr.add_child(mi)
	root.add_child(level)

	var plugin_script: GDScript = load("res://addons/bf6_terrain_pack/terrain_pack_plugin.gd")
	_check("plugin script parses", plugin_script != null and plugin_script.reload(true) == OK,
		"reload() -> %d" % (plugin_script.reload(true) if plugin_script != null else -1))
	level.queue_free()


func _count_importer(n: Node) -> int:
	var c: int = 1 if n is ImporterMeshInstance3D else 0
	for k in n.get_children():
		c += _count_importer(k)
	return c


func _meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_meshes(c))
	return out


func _done() -> void:
	print("\n%s" % ("ALL PASS" if _fail == 0 else "%d FAILURE(S)" % _fail))
	quit(1 if _fail else 0)
