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
# The terrain is added with owner = null. Godot only saves nodes that have an
# owner, so it can never be written into the user's level, cannot be exported by
# accident, and the shipped terrain underneath is left untouched.

const Fetch = preload("terrain_fetch.gd")

# The placed node is named MP_<Map>_Extended_Terrain_<N>m, e.g.
# MP_Capstone_Extended_Terrain_8m, so it is obvious what it is and which detail
# level is loaded without opening anything. NODE_SUFFIX is what removal matches
# on, because the name carries the quality and therefore changes between loads;
# matching the fixed part is what lets a different quality replace an existing
# one instead of stacking a second copy on top of it.
const NODE_SUFFIX := "_Extended_Terrain_"
# Used only when a level has no <Map>_Terrain node to read a material from.
const SDK_GREEN := Color(0.4078, 0.5608, 0.3098)

var _dock: VBoxContainer
var _map_lbl: Label
var _quality: OptionButton
var _status: Label
var _clear_btn: Button
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
	# already placed
	_remove_terrain(_root())
	if _quality != null:
		_quality.select(0)
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

	var node: Node = _fetch.load_mesh(path)
	if node == null:
		_status.text = "Could not read the terrain: " + str(_fetch.error)
		_quality.select(0)
		return
	_remove_terrain(root)
	# MP_Capstone_Extended_Terrain_8m, so the node says what it is and which
	# detail level it is without anyone having to check.
	var q_m: String = Fetch.metres(float(_quality_metres(i)))
	node.name = "%s%s%sm" % [_map_name(), NODE_SUFFIX, q_m]
	var mat: Material = _sdk_terrain_material(root, _map_name())
	var bound: int = _apply_material(node, mat)
	if bound == 0:
		# Zero surfaces means nothing was recognised, not that the terrain is
		# empty. Saying so beats adding an invisible node and calling it done.
		node.queue_free()
		_status.text = "The terrain parsed but held no visible surfaces."
		_quality.select(0)
		return
	root.add_child(node)
	# owner stays null deliberately: see the note at the top of this file
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
