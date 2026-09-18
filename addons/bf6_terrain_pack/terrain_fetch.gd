@tool
extends Node
# Fetching, caching and loading the terrain pack. Standalone: this plugin does
# not require the High Poly plugin, the BF6 core, or Battlefield 6 installed.
#
# NO class_name anywhere in this addon. An unregistered class_name global is one
# of the few things that can disable a Godot addon outright, and it buries the
# real cause under a pile of downstream parse errors. preload is unambiguous.
#
# Why a download: the meshes are 20.7 GB across 108 assets and one map can be
# 900 MB, which is past git's 100 MB per-file limit and far past what belongs in
# a plugin. GitHub release assets take 2 GB each, do not count against repository
# size and serve free, so one map at one quality comes down on demand.

const REPO := "TabbedScamper/BF6_Extended_Terrain"
const INDEX_URL := "https://raw.githubusercontent.com/%s/main/terrain_index.json"
# THE MAP FILES LIVE IN A RELEASE OF THEIR OWN, fetched BY TAG rather than via
# /releases/latest. There are 133 of them and a release page listing all 133
# hides the one thing a person actually came for, which is the plugin. So the
# latest release carries the plugin zip alone and the data sits in DATA_TAG,
# marked as a pre-release so GitHub does not show it as the current one.
#
# Consequence worth knowing: adding maps means uploading to DATA_TAG, not to
# whatever is newest, and shipping a plugin that expects assets the data release
# does not have would break it. Bump DATA_TAG when the asset set changes shape.
const DATA_TAG := "v1.0.0"
const RELEASE_API := "https://api.github.com/repos/%s/releases/tags/%s"
const CACHE_DIR := "user://bf6_terrain_pack"
const USER_AGENT := "BF6-Extended-Terrain-Plugin"

var error := ""

var _index: Dictionary = {}          # asset name -> {level, target_m, bytes, sha256, ...}
var _assets: Dictionary = {}         # asset name -> download url
var _http: HTTPRequest


func _ready() -> void:
	_http = HTTPRequest.new()
	# use_threads defaults to FALSE, which services the socket from _process on
	# the main thread: a download then runs at the rate the editor renders
	# frames. timeout 0 because a 900 MB asset is not a 30 second request.
	_http.use_threads = true
	_http.timeout = 0.0
	add_child(_http)


func has_index() -> bool:
	return not _index.is_empty()


func fetch_index() -> bool:
	error = ""
	var body: PackedByteArray = await _http_get(INDEX_URL % REPO)
	if body.is_empty():
		error = "could not reach the terrain index"
		return false
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		error = "the index is not valid JSON"
		return false
	var d: Dictionary = parsed
	if not d.has("files"):
		error = "the index has no file list"
		return false
	_index = d["files"]
	return true


# Every TERRAIN quality published for a map, finest first.
#
# Filtered on kind. The index also carries backdrop entries, which have no
# density and would otherwise appear in the quality list as a nonsense row - and
# sort_custom would be comparing a missing target_m while it did so.
func qualities_for(level: String) -> Array:
	var want: String = level.to_lower()
	var out: Array = []
	for name in _index:
		var e: Dictionary = _index[name]
		if str(e.get("level", "")).to_lower() != want:
			continue
		if str(e.get("kind", "terrain")) != "terrain":
			continue
		var row: Dictionary = e.duplicate()
		row["name"] = name
		out.append(row)
	out.sort_custom(func(a, b): return float(a["target_m"]) < float(b["target_m"]))
	return out


# The map's backdrop, or an empty dictionary when none is published. Not every
# map has one: the distant landscape is authored per level and some are enclosed
# enough not to need it.
func backdrop_for(level: String) -> Dictionary:
	var want: String = level.to_lower()
	for name in _index:
		var e: Dictionary = _index[name]
		if str(e.get("level", "")).to_lower() != want:
			continue
		if str(e.get("kind", "")) != "backdrop":
			continue
		var row: Dictionary = e.duplicate()
		row["name"] = name
		return row
	return {}


func cached_path(asset: String) -> String:
	return "%s/%s" % [CACHE_DIR, asset]


# A cached file counts only if it is the RIGHT file. Size alone is not enough:
# a transfer cut at a block boundary and an asset replaced by a later release
# both leave a plausible-looking file behind, and a wrong file trusted once is
# trusted forever.
func is_cached(asset: String) -> bool:
	var p: String = cached_path(asset)
	if not FileAccess.file_exists(p):
		return false
	var e: Dictionary = _index.get(asset, {})
	if e.is_empty():
		return true
	var f: FileAccess = FileAccess.open(p, FileAccess.READ)
	if f == null:
		return false
	var size: int = f.get_length()
	f.close()
	if size != int(e.get("bytes", -1)):
		return false
	var want: String = str(e.get("sha256", ""))
	return want == "" or sha256_of(p) == want


# Returns the local path, or "" with `error` set.
func ensure(asset: String) -> String:
	error = ""
	if is_cached(asset):
		return cached_path(asset)
	if _assets.is_empty() and not await _fetch_asset_urls():
		return ""
	if not _assets.has(asset):
		error = "%s is not published in the current release" % asset
		return ""

	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var dest: String = cached_path(asset)
	# Download to .part and only name it properly once it verifies. A transfer
	# that dies half way must not leave a truncated file where a valid one
	# belongs, because the next run would find it and trust it.
	var part: String = dest + ".part"
	if not await _get_to_file(str(_assets[asset]), part):
		DirAccess.remove_absolute(part)
		error = "the download did not complete"
		return ""

	var e: Dictionary = _index.get(asset, {})
	if not e.is_empty():
		var f: FileAccess = FileAccess.open(part, FileAccess.READ)
		var got: int = f.get_length() if f != null else -1
		if f != null:
			f.close()
		if got != int(e.get("bytes", -1)):
			DirAccess.remove_absolute(part)
			error = "size mismatch: got %d, expected %d" % [got, int(e.get("bytes", -1))]
			return ""
		var want: String = str(e.get("sha256", ""))
		if want != "" and sha256_of(part) != want:
			DirAccess.remove_absolute(part)
			error = "checksum mismatch, the download is corrupt"
			return ""
	DirAccess.remove_absolute(dest)
	if DirAccess.rename_absolute(part, dest) != OK:
		DirAccess.remove_absolute(part)
		error = "could not move the finished download into place"
		return ""
	return dest


func evict(asset: String) -> void:
	var p: String = cached_path(asset)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func cache_bytes() -> int:
	var total: int = 0
	var d: DirAccess = DirAccess.open(CACHE_DIR)
	if d == null:
		return 0
	for f in d.get_files():
		var fa: FileAccess = FileAccess.open("%s/%s" % [CACHE_DIR, f], FileAccess.READ)
		if fa != null:
			total += fa.get_length()
			fa.close()
	return total


# ---------------------------------------------------------------- the mesh
# NOT ResourceLoader. Godot's import pipeline only covers res://, so a .glb
# cached under user:// is bytes on disk and ResourceLoader.exists() is false for
# it permanently. GLTFDocument parses it directly instead.
func load_mesh(path: String) -> Node:
	error = ""
	var doc: GLTFDocument = GLTFDocument.new()
	var st: GLTFState = GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(path), st) != OK:
		error = "could not parse %s" % path.get_file()
		return null
	var scene: Node = doc.generate_scene(st)
	if scene == null:
		error = "empty scene from %s" % path.get_file()
		return null
	# generate_scene yields ImporterMeshInstance3D in the EDITOR and
	# MeshInstance3D outside it. An ImporterMeshInstance3D does not render and
	# does not answer to MeshInstance3D, so a walker that knows only one of them
	# quietly sees an empty scene.
	_fix_importer_meshes(scene)
	return scene


static func _fix_importer_meshes(node: Node) -> void:
	for c in node.get_children():
		_fix_importer_meshes(c)
	if node is ImporterMeshInstance3D:
		var im: ImporterMeshInstance3D = node
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.name = im.name
		mi.transform = im.transform
		if im.mesh != null:
			mi.mesh = im.mesh.get_mesh()
		node.replace_by(mi)
		node.queue_free()


# ------------------------------------------------------------------- http
func _http_get(url: String) -> PackedByteArray:
	_http.download_file = ""
	for attempt in range(4):
		if attempt > 0:
			# api.github.com rate-limits anonymous callers and
			# objects.githubusercontent.com can refuse a burst, so a single
			# 403/429/5xx is usually transient. Back off rather than give up.
			await get_tree().create_timer(0.4 * pow(2.0, attempt - 1)).timeout
			if not is_instance_valid(_http):
				break
		if _http.request(url, _headers(), HTTPClient.METHOD_GET) != OK:
			continue
		var res: Array = await _http.request_completed
		if int(res[0]) == HTTPRequest.RESULT_SUCCESS and int(res[1]) == 200:
			return res[3]
	return PackedByteArray()


func _get_to_file(url: String, dest: String) -> bool:
	for attempt in range(4):
		if attempt > 0:
			await get_tree().create_timer(0.4 * pow(2.0, attempt - 1)).timeout
			if not is_instance_valid(_http):
				return false
		_http.download_file = dest
		var started: int = _http.request(url, _headers(), HTTPClient.METHOD_GET)
		if started != OK:
			continue
		var res: Array = await _http.request_completed
		_http.download_file = ""
		if int(res[0]) == HTTPRequest.RESULT_SUCCESS and int(res[1]) == 200:
			return true
	_http.download_file = ""
	return false


func _fetch_asset_urls() -> bool:
	var body: PackedByteArray = await _http_get(RELEASE_API % [REPO, DATA_TAG])
	if body.is_empty():
		error = "could not read the %s data release" % DATA_TAG
		return false
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		error = "the release listing is not valid JSON"
		return false
	var d: Dictionary = parsed
	for a in d.get("assets", []):
		if a is Dictionary:
			var ad: Dictionary = a
			_assets[str(ad.get("name", ""))] = str(ad.get("browser_download_url", ""))
	if _assets.is_empty():
		error = "that release has no assets"
		return false
	return true


func _headers() -> PackedStringArray:
	return PackedStringArray(["User-Agent: " + USER_AGENT, "Accept: */*"])


static func sha256_of(path: String) -> String:
	var ctx: HashingContext = HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var chunk: PackedByteArray = f.get_buffer(1 << 22)
		if chunk.is_empty():
			break
		ctx.update(chunk)
	f.close()
	return ctx.finish().hex_encode()


# GDScript has no %g, and ("%.1f" % v).trim_suffix(".0") rounds 0.25 to 0.3.
static func metres(v: float) -> String:
	return ("%.3f" % v).rstrip("0").rstrip(".")
