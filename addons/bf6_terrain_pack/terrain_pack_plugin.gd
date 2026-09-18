@tool
extends EditorPlugin
# BF6 Extended Terrain: the ground outside the playable area, for the open map.
#
# STANDALONE. This plugin needs the Godot Portal SDK and nothing else - not the
# High Poly plugin, not the BF6 native core, and not Battlefield 6 installed.
# That is the entire point: the terrain is fetched ready-made so someone who
# does not own the game can still see where their level sits in the world.
#
# The green grid material is NOT shipped and does not need to be. It is read off
# the level's own <Map>_Terrain node at placement time, so the extended ground
# matches the playable ground exactly, in whatever the SDK ships, and no game
# material is redistributed.
#
# The terrain goes under the level's "Static" node, beside its own
# MP_<Map>_Terrain and MP_<Map>_Assets, and it IS owned, so it appears in the
# Scene dock and can be selected, hidden or deleted like any other node.
#
# It used to be added with owner = null to keep it out of the saved file. That
# also kept it out of the Scene dock, so there was nothing to select and nothing
# to hide: the node was there and invisible to the person meant to manage it.
#
# Owning it is safe only because the download lands in res:// and goes through
# Godot's import pipeline, so the instance has a scene_file_path and saving the
# level writes a reference. A mesh parsed at runtime from user:// has no such
# path, and owning THAT would serialise every vertex into the .tscn.

const Fetch = preload("terrain_fetch.gd")

# The placed node is named MP_<Map>_Extended_Terrain_<N>m, e.g.
# MP_Capstone_Extended_Terrain_8m, so it is obvious what it is and which detail
# level is loaded without opening anything. NODE_SUFFIX is what removal matches
# on, because the name carries the quality and therefore changes between loads;
# matching the fixed part is what lets a different quality replace an existing
# one instead of stacking a second copy on top of it.
const NODE_SUFFIX := "_Extended_Terrain_"
# The backdrop is a separate download and a separate node, named the same way:
# MP_Capstone_Backdrop. It is the distant landscape beyond the heightfield's
# edge, so it is independent of which terrain density is loaded, and switching
# density must not silently drop it.
const BACKDROP_SUFFIX := "_Backdrop"
# Used only when a level has no <Map>_Terrain node to read a material from.
const SDK_GREEN := Color(0.4078, 0.5608, 0.3098)
# One grid cell of the SDK terrain material, in metres. Measured off the SDK's
# own MP_Capstone_Terrain: its UVs span 0..100 over 1200.4 m.
const GRID_M := 12.0

var _dock: VBoxContainer
var _map_lbl: Label
var _quality: OptionButton
var _status: Label
var _clear_btn: Button
var _backdrop: CheckBox
var _fetch: Node
var _listed := ""
var _busy := false


func _enter_tree() -> void:
	_fetch = Fetch.new()
	_fetch.name = "TerrainFetch"
	add_child(_fetch)

	_dock = VBoxContainer.new()
	_dock.name = "Extended Terrain"
	_dock.add_theme_constant_override("separation", 6)

	var title := Label.new()
	title.text = "BF6 Extended Terrain"
	_dock.add_child(title)

	_map_lbl = Label.new()
	_map_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dock.add_child(_map_lbl)

	var row := HBoxContainer.new()
	var q := Label.new()
	q.text = "Quality"
	row.add_child(q)
	_quality = OptionButton.new()
	_quality.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_quality.add_item("Off")
	_quality.tooltip_text = "Metres per vertex: smaller is finer detail and a much larger download. Files are cached, so a map you have already fetched costs nothing the second time."
	# Filled the first time the list is opened, not when the editor starts, so
	# opening Godot never makes a network call nobody asked for.
	_quality.get_popup().about_to_popup.connect(_fill_qualities)
	_quality.item_selected.connect(_on_quality_selected)
	row.add_child(_quality)
	_dock.add_child(row)

	_backdrop = CheckBox.new()
	_backdrop.text = "Distant landscape (backdrop)"
	_backdrop.tooltip_text = "The scenery beyond the terrain's edge - hills, cliffs and outlying buildings. Downloaded separately and independent of the terrain quality above. The flipbook smoke and haze cards are left out on purpose: they are camera-facing planes and would stand in the landscape as giant flat rectangles."
	_backdrop.toggled.connect(_on_backdrop_toggled)
	_dock.add_child(_backdrop)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(220, 0)
	_dock.add_child(_status)

	_clear_btn = Button.new()
	_clear_btn.text = "Clear downloaded files"
	_clear_btn.pressed.connect(_on_clear_cache)
	_dock.add_child(_clear_btn)

	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)
	scene_changed.connect(_on_scene_changed)
	_refresh_map()


func _exit_tree() -> void:
	_remove_terrain(_root())
	_remove_named(_root(), BACKDROP_SUFFIX)
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	if _fetch != null and is_instance_valid(_fetch):
		_fetch.queue_free()
		_fetch = null


func _root() -> Node:
	return get_editor_interface().get_edited_scene_root()


# The level's map name: the key into the index, and the prefix of the terrain
# node the material comes from.
#
# THE ROOT NAME IS NOT ENOUGH. A stock level scene is named MP_<something>, but a
# Creator workspace is a copy the author is free to rename, and renaming it is
# normal. The SDK records the real base map on the root as `bf6_base_level` when
# it imports one, so that meta is the authority and the node name is the
# fallback. Checking only the name makes the plugin look broken on exactly the
# scenes people actually build in.
func _map_name() -> String:
	var r: Node = _root()
	if r == null:
		return ""
	var explicit: String = str(r.get_meta("bf6_base_level", ""))
	if explicit.begins_with("MP_") and not explicit.contains("/") \
			and not explicit.contains("\\"):
		return explicit
	var n: String = String(r.name)
	return n if n.begins_with("MP_") else ""


# What the panel says when it cannot identify the map. "Open a Portal level"
# is unhelpful when a level IS open and simply was not recognised.
func _why_no_map() -> String:
	var r: Node = _root()
	if r == null:
		return "No scene is open. Open a Portal level to begin."
	return ("\"%s\" does not look like a Portal level.\nExpected a root named "
		+ "MP_... or a bf6_base_level property naming the base map.") % String(r.name)


func _on_scene_changed(_s: Node) -> void:
	# the pack is per map, so a scene change invalidates the list and anything
	# already placed - the backdrop included, or the previous map's 50 km of
	# scenery stays sitting around the new one
	var r: Node = _root()
	_remove_terrain(r)
	_remove_named(r, BACKDROP_SUFFIX)
	if _quality != null:
		_quality.select(0)
	if _backdrop != null:
		_backdrop.set_pressed_no_signal(false)
	_listed = ""
	_refresh_map()


func _refresh_map() -> void:
	if _map_lbl == null:
		return
	var map: String = _map_name()
	if map == "":
		_map_lbl.text = _why_no_map()
		_status.text = ""
	else:
		_map_lbl.text = "Map: %s" % map
		_status.text = "Open the Quality list above to see what is available, then pick one."
	_update_cache_button()


func _update_cache_button() -> void:
	if _clear_btn == null or _fetch == null:
		return
	var n: int = _fetch.cache_bytes()
	_clear_btn.disabled = n <= 0
	_clear_btn.text = "Clear downloaded files" if n <= 0 else \
		"Clear downloaded files (%s)" % String.humanize_size(n)


func _fill_qualities() -> void:
	var map: String = _map_name()
	if map == "":
		# Opening an empty list and saying nothing is how this reads as broken.
		_status.text = _why_no_map()
		return
	if map == _listed or _busy:
		return
	if not _fetch.has_index():
		_status.text = "Looking up what is available…"
		if not await _fetch.fetch_index():
			_status.text = "Could not reach the terrain list: " + str(_fetch.error)
			return
	var rows: Array = _fetch.qualities_for(map)
	_quality.clear()
	_quality.add_item("Off")
	for r in rows:
		var asset: String = str(r["name"])
		var size: String = "cached" if _fetch.is_cached(asset) \
			else String.humanize_size(int(r["bytes"]))
		_quality.add_item("%s m / vertex  (%s)" % [Fetch.metres(float(r["target_m"])), size])
		_quality.set_item_metadata(_quality.item_count - 1, asset)
	_listed = map
	if rows.is_empty():
		_status.text = "No terrain published for %s." % map
	else:
		_status.text = "%d quality level(s) for %s." % [rows.size(), map]


func _on_quality_selected(i: int) -> void:
	if _busy:
		return
	var root: Node = _root()
	if root == null or _map_name() == "":
		_status.text = _why_no_map()
		_quality.select(0)
		return
	if i <= 0:
		_remove_terrain(root)
		_status.text = "Extended terrain off."
		return
	var asset: String = str(_quality.get_item_metadata(i))
	if asset == "":
		return
	_busy = true
	_quality.disabled = true
	if not _fetch.is_cached(asset):
		_status.text = "Downloading %s…\nThis can take a while the first time." % asset
	var path: String = await _fetch.ensure(asset)
	_quality.disabled = false
	_busy = false
	if path == "":
		_status.text = "Download failed: " + str(_fetch.error)
		_quality.select(0)
		_update_cache_button()
		return

	var node: Node = _instance_of(path)
	if node == null:
		_status.text = "Could not read the terrain: " + str(_fetch.error)
		_quality.select(0)
		return
	_remove_terrain(root)
	# MP_Capstone_Extended_Terrain_8m, so the node says what it is and which
	# detail level it is without anyone having to check.
	var q_m: String = Fetch.metres(float(_quality_metres(i)))
	node.name = "%s%s%sm" % [_map_name(), NODE_SUFFIX, q_m]
	var mat: Material = _tiled_material(_sdk_terrain_material(root, _map_name()),
										_span_of(node))
	var bound: int = _apply_material(node, mat)
	if bound == 0:
		# Zero surfaces means nothing was recognised, not that the terrain is
		# empty. Saying so beats adding an invisible node and calling it done.
		node.queue_free()
		_status.text = "The terrain parsed but held no visible surfaces."
		_quality.select(0)
		return
	_attach(root, node)
	_status.text = "Showing %s\n%d surface(s), material: %s" % [
		asset, bound,
		"the level's own terrain material" if mat != null else "fallback green"]
	_update_cache_button()


func _on_clear_cache() -> void:
	var d: DirAccess = DirAccess.open(Fetch.CACHE_DIR)
	if d == null:
		return
	_remove_terrain(_root())
	if _quality != null:
		_quality.select(0)
	for f in d.get_files():
		DirAccess.remove_absolute("%s/%s" % [Fetch.CACHE_DIR, f])
	_listed = ""
	_status.text = "Downloaded files cleared."
	_update_cache_button()


# The metres-per-vertex behind the dropdown row, read back off the index so the
# node name states the real density rather than the menu's wording.
func _quality_metres(i: int) -> float:
	var asset: String = str(_quality.get_item_metadata(i))
	for r in _fetch.qualities_for(_map_name()):
		if str(r["name"]) == asset:
			return float(r["target_m"])
	return 0.0



# ---- the distant landscape ---------------------------------------------------
# Separate from the terrain on purpose: it is a separate download, it does not
# change with terrain density, and someone may want the ground without 50 km of
# scenery around it.
func _on_backdrop_toggled(on: bool) -> void:
	var root: Node = _root()
	if root == null or _map_name() == "":
		_status.text = _why_no_map()
		_backdrop.set_pressed_no_signal(false)
		return
	if not on:
		_remove_named(root, BACKDROP_SUFFIX)
		_status.text = "Backdrop off."
		return
	if _busy:
		_backdrop.set_pressed_no_signal(false)
		return
	if not _fetch.has_index():
		_status.text = "Looking up what is available..."
		if not await _fetch.fetch_index():
			_status.text = "Could not reach the terrain list: " + str(_fetch.error)
			_backdrop.set_pressed_no_signal(false)
			return
	var e: Dictionary = _fetch.backdrop_for(_map_name())
	if e.is_empty():
		_status.text = "No backdrop is published for %s." % _map_name()
		_backdrop.set_pressed_no_signal(false)
		return
	var asset: String = str(e["name"])
	_busy = true
	_backdrop.disabled = true
	if not _fetch.is_cached(asset):
		_status.text = "Downloading the backdrop (%s)..." % String.humanize_size(int(e.get("bytes", 0)))
	var path: String = await _fetch.ensure(asset)
	_backdrop.disabled = false
	_busy = false
	if path == "":
		_status.text = "Backdrop download failed: " + str(_fetch.error)
		_backdrop.set_pressed_no_signal(false)
		return
	var node: Node = _instance_of(path)
	if node == null:
		_status.text = "Could not read the backdrop: " + str(_fetch.error)
		_backdrop.set_pressed_no_signal(false)
		return
	_remove_named(root, BACKDROP_SUFFIX)
	node.name = "%s%s" % [_map_name(), BACKDROP_SUFFIX]
	# The backdrop is scenery spread over tens of kilometres, so tiling its
	# material to the terrain's own span would stretch the grid across all of it.
	# Give it the same 12 m cell by scaling to ITS span.
	var mat: Material = _tiled_material(_sdk_terrain_material(root, _map_name()),
										_span_of(node))
	var bound: int = _apply_material(node, mat)
	if bound == 0:
		node.queue_free()
		_status.text = "The backdrop parsed but held no visible surfaces."
		_backdrop.set_pressed_no_signal(false)
		return
	_attach(root, node)
	_status.text = "Backdrop: %d surface(s)%s" % [bound,
		"" if int(e.get("instances", 0)) == 0 else ", %d pieces" % int(e["instances"])]
	_update_cache_button()


# Remove by name suffix so terrain and backdrop can be cleared independently.
func _remove_named(root: Node, suffix: String) -> void:
	if root == null:
		return
	for c in root.get_children():
		if String(c.name).contains(suffix):
			root.remove_child(c)
			c.queue_free()


# ---- where the terrain goes in the scene -------------------------------------
# Under "Static", beside the level's own MP_<Map>_Terrain and MP_<Map>_Assets,
# which is where a Portal level keeps its static geometry and therefore the only
# place someone would think to look for more of it.
#
# AND IT IS OWNED, so it shows up in the Scene dock and can be selected, hidden
# or deleted like anything else. An earlier version used owner = null to keep it
# out of the saved file; that also kept it out of the dock entirely, so there was
# nothing to hide - the node existed but was invisible to the person who wanted
# to manage it.
#
# Owning it is only safe because the mesh is an IMPORTED resource in res://. The
# instance therefore has a scene_file_path and the level saves a one-line
# reference to it. Were the mesh built at runtime from user://, as it used to be,
# owning the node would serialise every vertex into the .tscn.
func _attach(root: Node, node: Node) -> void:
	var parent: Node = _static_parent(root)
	parent.add_child(node)
	node.owner = root


func _static_parent(root: Node) -> Node:
	for c in root.get_children():
		if String(c.name) == "Static":
			return c
	# A level that has no Static node is unusual but not broken; make one rather
	# than dropping the terrain at the root where it does not belong.
	var n := Node3D.new()
	n.name = "Static"
	root.add_child(n)
	n.owner = root
	return n


# The imported resource, not a runtime parse. ResourceLoader works here BECAUSE
# the download lands in res:// and has been through the import pipeline; that is
# what gives the instance a scene_file_path and keeps the saved level small.
func _instance_of(res_path: String) -> Node:
	if not ResourceLoader.exists(res_path):
		return null
	var r: Variant = ResourceLoader.load(res_path)
	if r is PackedScene:
		return (r as PackedScene).instantiate()
	if r is Mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = r
		return mi
	return null


func _remove_terrain(root: Node) -> void:
	if root == null:
		return
	for c in root.get_children():
		# match the fixed part: the name carries the detail level, so an exact
		# match would miss a node placed at a different quality and leave two
		# terrains stacked in the scene
		if String(c.name).contains(NODE_SUFFIX):
			root.remove_child(c)
			c.queue_free()


# THE GRID HAS TO BE TILED BY THE MATERIAL, because the mesh cannot do it.
#
# M_LevelTerrain keeps the green AND the grid in a 256x256 albedo texture
# sampled through UV1 - measured: albedo_color is white, uv1_triplanar false,
# uv1_scale (1,1,1), so it tiles nothing by itself. The pack's meshes carry
# 0..1 UVs across the whole map, so applied unchanged the material stretches a
# single grid cell over several kilometres and the pattern disappears.
#
# Scaling by span/12 puts one cell every 12 m, which is what the SDK's own
# terrain measures (UV 0..100 over 1200.4 m). Done on a DUPLICATE: the material
# belongs to the level and editing it in place would re-tile the shipped terrain
# too. This is the same fix, for the same reason, as highpoly_mapcontext.gd:4317.
static func _tiled_material(base: Material, span: float) -> Material:
	if base == null or span <= 0.0:
		return base
	if not (base is BaseMaterial3D):
		return base          # a ShaderMaterial tiles however its shader says
	var m: BaseMaterial3D = (base as BaseMaterial3D).duplicate()
	var cells: float = span / GRID_M
	m.uv1_scale = Vector3(cells, cells, 1.0)
	return m


# How many metres across the placed terrain is, taken from the geometry rather
# than assumed: the pack covers a different span on different maps, from 2048 m
# to 8192 m, and a fixed number would mis-tile most of them.
static func _span_of(node: Node) -> float:
	var box := AABB()
	var first := true
	for m in _all_meshes(node):
		var mi: MeshInstance3D = m
		if mi.mesh == null:
			continue
		var a: AABB = mi.mesh.get_aabb()
		box = a if first else box.merge(a)
		first = false
	return 0.0 if first else maxf(box.size.x, box.size.z)


static func _all_meshes(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_all_meshes(c))
	return out


# The SDK's own terrain material, read off the level's existing terrain node.
# Nothing game-derived ships with this plugin; it borrows what is already there.
func _sdk_terrain_material(root: Node, map: String) -> Material:
	if root == null or map == "":
		return null
	var node: Node = root.find_child("%s_Terrain" % map, true, false)
	if node == null:
		return null
	var mi: MeshInstance3D = _first_mesh(node)
	if mi == null or mi.mesh == null:
		return null
	# The SDK carries its terrain material on the MESH, not as an override, so
	# the override lookup has to fall through rather than give up.
	var m: Material = mi.get_surface_override_material(0)
	if m == null:
		m = mi.mesh.surface_get_material(0)
	return m


func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var f: MeshInstance3D = _first_mesh(c)
		if f != null:
			return f
	return null


func _apply_material(n: Node, mat: Material) -> int:
	var count: int = 0
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n
		if mi.mesh != null:
			var use: Material = mat
			if use == null:
				var sm: StandardMaterial3D = StandardMaterial3D.new()
				sm.albedo_color = SDK_GREEN
				use = sm
			for s in range(mi.mesh.get_surface_count()):
				mi.set_surface_override_material(s, use)
				count += 1
	for c in n.get_children():
		count += _apply_material(c, mat)
	return count
