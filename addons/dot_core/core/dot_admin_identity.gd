class_name DotAdminIdentity
extends RefCounted

## Admin-only identity gate for an api with `identity(token)` and `permit(actor, flag)` hooks (dot-workbench, dot-radio), duck-typed so dot-auth and dot-console stay optional.

const ACTOR_PREFIX := "id:"

## Log channel for refusals and admissions.
var channel := "admin"
## Callable(token) -> identity or null; the host backs it with dot-auth. An identity is an Object (DotAuthIdentity) or a Dictionary with `uid`.
var resolver: Callable = Callable()
## Uids allowed in. Deny by default: with no uid and no group listed, nobody is admitted.
var admin_uids := PackedStringArray()
## Groups (the identity's `groups`) allowed in.
var admin_groups := PackedStringArray()
## Flags an admitted identity holds when no [member fallback_permit] decides.
var flags := PackedStringArray()
## Optional Callable(uid, flag) -> bool (dot-server's admin manager or console permissions); when valid it decides every flag instead of [member flags].
var fallback_permit: Callable = Callable()

var _admitted: Dictionary = {}


## The identity hook: an actor string for an admitted identity, null otherwise (a token path still gets its turn).
func authenticate(token: String) -> Variant:
	if token.is_empty() or not resolver.is_valid():
		return null
	var who: Variant = resolver.call(token)
	if who == null:
		return null
	var uid := _uid_of(who)
	if uid.is_empty() or _is_guest(who) or _is_expired(who):
		DotLog.warn(channel, "identity refused", {"why": "anonymous, guest or expired"})
		return null
	if not (admin_uids.has(uid) or _in_admin_group(who)):
		DotLog.warn(channel, "identity refused", {"uid": uid, "why": "not an admin"})
		return null
	var actor := ACTOR_PREFIX + uid
	_admitted[actor] = true
	DotLog.info(channel, "identity admitted", {"uid": uid})
	return actor


## The permit hook; only actors this gate admitted get anything.
func permit(actor: Variant, flag: String) -> bool:
	if not (actor is String) or not _admitted.has(actor):
		return false
	if fallback_permit.is_valid():
		return bool(fallback_permit.call((actor as String).substr(ACTOR_PREFIX.length()), flag))
	return flags.has(flag)


static func _uid_of(who: Variant) -> String:
	if who is Dictionary:
		return str((who as Dictionary).get("uid", ""))
	if who is Object and "uid" in who:
		return str(who.get("uid"))
	return ""


static func _is_guest(who: Variant) -> bool:
	if who is Dictionary:
		return bool((who as Dictionary).get("is_guest", false))
	return who is Object and "is_guest" in who and bool(who.get("is_guest"))


static func _is_expired(who: Variant) -> bool:
	if who is Object and who.has_method("is_expired"):
		return bool(who.call("is_expired"))
	if who is Dictionary:
		var exp := int((who as Dictionary).get("expires_at", 0))
		return exp > 0 and int(Time.get_unix_time_from_system()) >= exp
	return false


func _in_admin_group(who: Variant) -> bool:
	var groups: Variant = null
	if who is Object and who.has_method("groups"):
		groups = who.call("groups")
	elif who is Dictionary:
		groups = (who as Dictionary).get("groups", [])
	if not (groups is Array or groups is PackedStringArray):
		return false
	for g in groups:
		if admin_groups.has(str(g)):
			return true
	return false
