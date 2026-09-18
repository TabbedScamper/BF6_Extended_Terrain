extends SceneTree
# The grid is only "fixed" if the tiling comes out at 12 m per cell on a real
# published mesh, with a material shaped like the SDK's. Asserting the code
# path ran is not the same as asserting the number is right.
const Plugin = preload("res://addons/bf6_terrain_pack/terrain_pack_plugin.gd")
var _fail := 0
func _init() -> void: call_deferred("_r")
func _c(n: String, ok: bool, d: String) -> void:
	if not ok: _fail += 1
	print("%-6s %-34s %s" % ["ok" if ok else "FAIL", n, d])
func _r() -> void:
	# a material shaped like M_LevelTerrain: white, textured, untiled
	var base := StandardMaterial3D.new()
	base.albedo_color = Color(1,1,1,1)
	base.uv1_scale = Vector3(1,1,1)
	for span in [2048.0, 4096.0, 8192.0]:
		var m: Material = Plugin._tiled_material(base, span)
		var got: float = (m as BaseMaterial3D).uv1_scale.x
		var want: float = span / 12.0
		_c("tile %.0f m map" % span, absf(got-want) < 0.001,
			"uv1_scale %.2f, one cell every %.3f m" % [got, span/maxf(got,0.001)])
	# the SDK material must NOT be edited in place
	_c("original material untouched", absf(base.uv1_scale.x - 1.0) < 0.0001,
		"uv1_scale still %.3f" % base.uv1_scale.x)
	# span must come from geometry
	var holder := Node3D.new()
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(4096, 4096)
	mi.mesh = pm; holder.add_child(mi)
	var sp: float = Plugin._span_of(holder)
	_c("span read from geometry", absf(sp-4096.0) < 1.0, "%.0f m" % sp)
	holder.free()
	_c("null material passes through", Plugin._tiled_material(null, 4096.0) == null, "no crash")
	print("\n%s" % ("ALL PASS" if _fail == 0 else "%d FAILURE(S)" % _fail))
	quit(1 if _fail else 0)
