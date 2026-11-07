extends Node

## Exercises [DotAdminIdentity]: deny by default, uid and group allowlists, guest and expiry refusals, flags and the fallback permit.

const SECTIONS := 4
const CHECKS := 20

var _passed := 0
var _failed := 0
var _section_count := 0


class FakeIdentity:
	extends RefCounted
	var uid := ""
	var is_guest := false
	var expires_at := 0
	var _groups: Array = []

	func groups() -> Array:
		return _groups

	func is_expired() -> bool:
		return expires_at > 0 and int(Time.get_unix_time_from_system()) >= expires_at


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_line("dot-core admin identity self-test")
	_test_deny_by_default()
	_test_admission()
	_test_refusals()
	_test_permit()
	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		_line("ERROR: %d sections, %d checks ran; expected %d and %d." % [_section_count, _passed + _failed, SECTIONS, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _fake(uid: String, guest := false, groups: Array = [], expires := 0) -> FakeIdentity:
	var f := FakeIdentity.new()
	f.uid = uid
	f.is_guest = guest
	f._groups = groups
	f.expires_at = expires
	return f


func _gate() -> DotAdminIdentity:
	var table := {"t-admin": _fake("backbone:a"), "t-user": _fake("backbone:u"), "t-guest": _fake("backbone:a", true),
		"t-group": _fake("backbone:m", false, ["radio"]), "t-old": _fake("backbone:a", false, [], 1),
		"t-dict": {"uid": "backbone:a"}, "t-dict-old": {"uid": "backbone:a", "expires_at": 1}, "t-nouid": _fake("")}
	var gate := DotAdminIdentity.new()
	gate.channel = "selftest"
	gate.flags = PackedStringArray(["radio"])
	gate.resolver = func(t: String) -> Variant: return table.get(t)
	return gate


func _test_deny_by_default() -> void:
	_section("deny by default")
	var gate := _gate()
	_check(gate.authenticate("t-admin") == null, "with no admins listed nobody is admitted")
	_check(not gate.permit("id:backbone:a", "radio"), "an actor never admitted holds nothing")
	var bare := DotAdminIdentity.new()
	bare.admin_uids = PackedStringArray(["backbone:a"])
	_check(bare.authenticate("t-admin") == null, "with no resolver nobody is admitted")
	_check(bare.flags.is_empty(), "no flags by default")


func _test_admission() -> void:
	_section("admission")
	var gate := _gate()
	gate.admin_uids = PackedStringArray(["backbone:a"])
	gate.admin_groups = PackedStringArray(["radio"])
	_check(gate.authenticate("t-admin") == "id:backbone:a", "a listed uid is admitted as an id: actor")
	_check(gate.authenticate("t-group") == "id:backbone:m", "a member of an admin group is admitted")
	_check(gate.authenticate("t-dict") == "id:backbone:a", "a Dictionary identity works")
	_check(gate.permit("id:backbone:a", "radio"), "an admitted actor holds a listed flag")
	_check(not gate.permit("id:backbone:a", "root"), "and not an unlisted one")


func _test_refusals() -> void:
	_section("refusals")
	var gate := _gate()
	gate.admin_uids = PackedStringArray(["backbone:a"])
	_check(gate.authenticate("t-user") == null, "a signed-in non-admin is refused")
	_check(gate.authenticate("t-guest") == null, "a guest is refused even when listed")
	_check(gate.authenticate("t-old") == null, "an expired identity is refused")
	_check(gate.authenticate("t-dict-old") == null, "an expired Dictionary identity is refused")
	_check(gate.authenticate("t-nouid") == null, "an identity with no uid is refused")
	_check(gate.authenticate("nobody") == null and gate.authenticate("") == null, "an unknown or empty token is refused")
	_check(not gate.permit("id:backbone:u", "radio") and not gate.permit(null, "radio") and not gate.permit(5, "radio"), "strangers and non-strings hold nothing")


func _test_permit() -> void:
	_section("fallback permit")
	var gate := _gate()
	gate.admin_uids = PackedStringArray(["backbone:a", "backbone:b"])
	var actor: Variant = gate.authenticate("t-admin")
	gate.fallback_permit = func(uid: String, flag: String) -> bool: return uid == "backbone:a" and flag == "cvar"
	_check(gate.permit(actor, "cvar"), "the fallback grants what it names")
	_check(not gate.permit(actor, "radio"), "and decides instead of flags: a listed flag is now refused")
	_check(not gate.permit("id:backbone:b", "cvar"), "a uid the gate did not admit is refused even if the fallback would allow")
	gate.fallback_permit = Callable()
	_check(gate.permit(actor, "radio"), "clearing the fallback returns to flags")


func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
