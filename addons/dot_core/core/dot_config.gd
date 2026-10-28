@tool
class_name DotConfig
extends Resource

## Base class for every dot-* configuration object, with layered overrides.
## Layers, later wins: exported defaults < file < environment < command line.
## Subclasses declare [code]@export[/code] vars; discovery is reflective, no registration.

const CHANNEL := "config"

## Keys seen that match no exported property; kept so boot reports every typo at once.
var unknown_keys: PackedStringArray = PackedStringArray()



## Prefix for [method apply_env], e.g. [code]"DOT_SERVER_"[/code].
## Return [code]""[/code] to disable environment overrides (content configs, not deployment).
func env_prefix() -> String:
	return ""


## Prefix for [method apply_cli], e.g. [code]"--sv-"[/code].
func cli_prefix() -> String:
	return ""


## Properties that must never be settable from the environment or command line.
## Override for secrets: environment and argv are readable by other processes.
func sensitive_keys() -> PackedStringArray:
	return PackedStringArray()


## Checks internal consistency after every layer has been applied.
## Override for what reflection cannot catch (port range, zero tickrate, URL scheme).
func validate() -> DotResult:
	return DotResult.success(null)



## The names of every configurable property on this resource.
## Filtered to script variables so the engine's own properties stay out of config files.
func config_keys() -> PackedStringArray:
	var out := PackedStringArray()
	for prop in get_property_list():
		if not _is_config_property(prop):
			continue
		out.append(str(prop["name"]))
	return out


func _is_config_property(prop: Dictionary) -> bool:
	var usage: int = prop.get("usage", 0)
	if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
		return false
	# Groups and categories appear in the list with no storage; skip them.
	if not (usage & PROPERTY_USAGE_STORAGE):
		return false
	var name := str(prop.get("name", ""))
	if name.begins_with("_"):
		return false
	if name == "unknown_keys":
		return false
	return true


func _property_type(key: String) -> int:
	for prop in get_property_list():
		if str(prop.get("name", "")) == key:
			return int(prop.get("type", TYPE_NIL))
	return TYPE_NIL


func has_key(key: String) -> bool:
	return config_keys().has(key)



## Applies a dictionary of overrides; keys match after normalisation (max_players, maxPlayers, max-players).
## Returns the keys applied. Unknown keys go to [member unknown_keys], not fatal: a newer file must still boot.
func apply_dictionary(
	d: Dictionary,
	layer_name: String = "dict",
	allow_sensitive: bool = true
) -> PackedStringArray:
	var applied := PackedStringArray()
	var keys := config_keys()
	var blocked := sensitive_keys()

	for raw_key in d:
		var key := _match_key(str(raw_key), keys)

		if key == "":
			unknown_keys.append(str(raw_key))
			DotLog.warn(
				CHANNEL,
				"unknown config key",
				{"key": str(raw_key), "layer": layer_name}
			)
			continue

		if not allow_sensitive and blocked.has(key):
			DotLog.warn(
				CHANNEL,
				"refusing to set a sensitive key from this layer",
				{"key": key, "layer": layer_name}
			)
			continue

		var coerced := _coerce(d[raw_key], _property_type(key))
		if not coerced.ok:
			DotLog.warn(
				CHANNEL,
				"bad value for config key",
				{
					"key": key,
					"layer": layer_name,
					"error": coerced.error.message,
				}
			)
			continue

		set(key, coerced.value)
		applied.append(key)

	return applied


## Resolves an incoming key name to a real property name.
##
## Tries exact, then snake_case-normalised, then case-insensitive.
func _match_key(raw: String, keys: PackedStringArray) -> String:
	if keys.has(raw):
		return raw

	var norm := _normalise_key(raw)
	for k in keys:
		if _normalise_key(k) == norm:
			return k

	return ""


static func _normalise_key(s: String) -> String:
	# camelCase -> camel_case, then unify separators and drop case.
	var out := ""
	for i in range(s.length()):
		var c := s[i]
		if c == "-" or c == "." or c == " ":
			out += "_"
		elif c == c.to_upper() and c != c.to_lower() and i > 0:
			out += "_" + c.to_lower()
		else:
			out += c.to_lower()

	while out.contains("__"):
		out = out.replace("__", "_")

	return out


## Converts a config-file or environment value to a property's declared type.
## Environment and argv values are strings; strictness here reports a bad value with its key at boot.
func _coerce(value: Variant, want: int) -> DotResult:
	if want == TYPE_NIL:
		return DotResult.success(value)

	var have := typeof(value)
	if have == want:
		return DotResult.success(value)

	match want:
		TYPE_BOOL:
			return _coerce_bool(value, have)

		TYPE_INT:
			return _coerce_int(value, have)

		TYPE_FLOAT:
			if have == TYPE_INT:
				return DotResult.success(float(value))
			if have == TYPE_STRING or have == TYPE_STRING_NAME:
				var s := str(value).strip_edges()
				if s.is_valid_float():
					return DotResult.success(s.to_float())
				return DotResult.fail(
					DotError.CODE_INVALID, "'%s' is not a number." % s
				)

		TYPE_STRING:
			if have != TYPE_OBJECT and have != TYPE_DICTIONARY:
				return DotResult.success(str(value))

		TYPE_STRING_NAME:
			return DotResult.success(StringName(str(value)))

		TYPE_PACKED_STRING_ARRAY:
			var arr := _to_string_list(value)
			if arr == null:
				return DotResult.fail(
					DotError.CODE_INVALID, "Cannot read '%s' as a list." % value
				)
			return DotResult.success(arr)

		TYPE_ARRAY:
			if have == TYPE_PACKED_STRING_ARRAY:
				return DotResult.success(Array(value))
			var arr2 := _to_string_list(value)
			if arr2 != null:
				return DotResult.success(Array(arr2))

	return _expected(want, have)


func _expected(want: int, have: int) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INVALID,
		"Expected %s, got %s." % [type_string(want), type_string(have)]
	)


func _coerce_bool(value: Variant, have: int) -> DotResult:
	if have == TYPE_STRING or have == TYPE_STRING_NAME:
		var s := str(value).strip_edges().to_lower()
		if ["1", "true", "yes", "on", "enabled"].has(s):
			return DotResult.success(true)
		if ["0", "false", "no", "off", "disabled", ""].has(s):
			return DotResult.success(false)
		return DotResult.fail(DotError.CODE_INVALID, "'%s' is not a boolean." % s)
	if have == TYPE_INT or have == TYPE_FLOAT:
		return DotResult.success(float(value) != 0.0)
	return _expected(TYPE_BOOL, have)


func _coerce_int(value: Variant, have: int) -> DotResult:
	if have == TYPE_FLOAT:
		return DotResult.success(int(value))
	if have == TYPE_BOOL:
		return DotResult.success(1 if value else 0)
	if have == TYPE_STRING or have == TYPE_STRING_NAME:
		var s := str(value).strip_edges()
		if s.is_valid_int():
			return DotResult.success(s.to_int())
		# JSON has no integers, so whole floats arrive as "27015.0".
		if s.is_valid_float():
			var f := s.to_float()
			if is_equal_approx(f, roundf(f)):
				return DotResult.success(int(f))
		return DotResult.fail(DotError.CODE_INVALID, "'%s' is not an integer." % s)
	return _expected(TYPE_INT, have)


## Reads a list from an Array, a JSON array string, or a comma-separated string.
## The last form makes environment lists work: [code]DOT_SERVER_ADMINS=alice,bob[/code].
static func _to_string_list(value: Variant) -> Variant:
	var have := typeof(value)

	if have == TYPE_PACKED_STRING_ARRAY:
		return value

	if have == TYPE_ARRAY:
		var out := PackedStringArray()
		for v in (value as Array):
			out.append(str(v))
		return out

	if have == TYPE_STRING or have == TYPE_STRING_NAME:
		var s := str(value).strip_edges()
		if s == "":
			return PackedStringArray()
		if s.begins_with("["):
			var parsed: Variant = JSON.parse_string(s)
			if parsed is Array:
				var out2 := PackedStringArray()
				for v in (parsed as Array):
					out2.append(str(v))
				return out2
			return null
		var out3 := PackedStringArray()
		for part in s.split(",", false):
			out3.append(part.strip_edges())
		return out3

	return null



## Applies a JSON config file. A missing file is not an error (first launch runs on defaults).
## A file that exists but is malformed IS an error: the admin wrote it and means it.
func apply_json_file(path: String) -> DotResult:
	if not FileAccess.file_exists(path):
		DotLog.debug(CHANNEL, "no config file", {"path": path})
		return DotResult.success(PackedStringArray())

	var res := DotPaths.read_json(path)
	if not res.ok:
		return res.wrap("Could not read config '%s'." % path)

	var data: Variant = res.value
	if not (data is Dictionary):
		return DotResult.fail(
			DotError.CODE_PARSE,
			"Config '%s' must contain a JSON object." % path
		)

	var applied := apply_dictionary(data as Dictionary, path)
	DotLog.info(
		CHANNEL,
		"applied config file",
		{"path": path, "keys": applied.size()}
	)
	return DotResult.success(applied)


func save_json_file(path: String) -> DotResult:
	return DotPaths.write_json(path, to_dictionary())



## Applies environment variables matching [method env_prefix].
## Sensitive keys are refused ([method sensitive_keys]). No-op on web, which has no environment.
func apply_env(prefix_override: String = "") -> PackedStringArray:
	var prefix := prefix_override if prefix_override != "" else env_prefix()
	if prefix == "":
		return PackedStringArray()

	var d := {}
	for key in config_keys():
		var env_name := prefix + key.to_upper()
		if OS.has_environment(env_name):
			d[key] = OS.get_environment(env_name)

	if d.is_empty():
		return PackedStringArray()

	var applied := apply_dictionary(d, "env", false)
	DotLog.info(
		CHANNEL, "applied environment", {"keys": applied.size()}
	)
	return applied



## Applies command-line arguments matching [method cli_prefix]: [code]--k=v[/code], [code]--k v[/code], bare [code]--flag[/code].
## Also reads [method OS.get_cmdline_user_args] (after [code]--[/code]): the engine eats unknown args in some launches.
func apply_cli(prefix_override: String = "") -> PackedStringArray:
	var prefix := prefix_override if prefix_override != "" else cli_prefix()
	if prefix == "":
		return PackedStringArray()

	# A prefix without the leading "--" matches nothing and drops every flag silently.
	if not prefix.begins_with("--"):
		var script: Script = get_script()
		var who := String(script.get_global_name())
		if who == "":
			who = script.resource_path.get_file()
		push_error(
			"%s.cli_prefix() is '%s', which matches no argument: it must begin with '--'."
				% [who, prefix]
		)

	var args := PackedStringArray()
	args.append_array(OS.get_cmdline_args())
	args.append_array(OS.get_cmdline_user_args())

	var d := {}
	var keys := config_keys()
	var i := 0

	while i < args.size():
		var arg := args[i]
		i += 1

		if not arg.begins_with(prefix):
			continue

		var body := arg.substr(prefix.length())
		var raw_key := body
		var raw_value: Variant = null

		if body.contains("="):
			var split := body.split("=", true, 1)
			raw_key = split[0]
			raw_value = split[1]

		var key := _match_key(raw_key, keys)
		if key == "":
			unknown_keys.append(arg)
			DotLog.warn(CHANNEL, "unknown command-line key", {"arg": arg})
			continue

		if raw_value == null:
			# A bare flag means `true` for booleans; for anything else the next
			# argument is the value, unless it looks like another flag.
			if _property_type(key) == TYPE_BOOL:
				raw_value = true
			elif i < args.size() and not args[i].begins_with("--"):
				raw_value = args[i]
				i += 1
			else:
				DotLog.warn(
					CHANNEL, "command-line key has no value", {"arg": arg}
				)
				continue

		d[key] = raw_value

	if d.is_empty():
		return PackedStringArray()

	var applied := apply_dictionary(d, "cli", false)
	DotLog.info(CHANNEL, "applied command line", {"keys": applied.size()})
	return applied



## Runs every layer in order and validates the result; the one call a host needs at boot.
## [param file_path] may be empty to skip the file layer.
func load_layered(file_path: String = "") -> DotResult:
	unknown_keys = PackedStringArray()

	if file_path != "":
		var file_res := apply_json_file(file_path)
		if not file_res.ok:
			return file_res

	apply_env()
	apply_cli()

	var valid := validate()
	if not valid.ok:
		return valid.wrap("Configuration is invalid.")

	return DotResult.success(self)



## Every configurable property as a plain dictionary.
## [param redact_sensitive] replaces secrets with [code]"***"[/code], for the status command and logs.
func to_dictionary(redact_sensitive: bool = false) -> Dictionary:
	var out := {}
	var blocked := sensitive_keys()

	for key in config_keys():
		var v: Variant = get(key)
		if redact_sensitive and blocked.has(key) and str(v) != "":
			out[key] = "***"
		elif v is PackedStringArray:
			out[key] = Array(v)
		else:
			out[key] = v

	return out


## Lines for a `config_dump`-style console command.
func describe_lines(redact_sensitive: bool = true) -> PackedStringArray:
	var out := PackedStringArray()
	var d := to_dictionary(redact_sensitive)
	var keys := d.keys()
	keys.sort()
	for k in keys:
		out.append("%-28s %s" % [str(k), str(d[k])])
	return out


## A deep copy, for "revert to the config we booted with".
func clone() -> DotConfig:
	var c := duplicate(true)
	return c as DotConfig
