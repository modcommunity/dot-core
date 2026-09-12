class_name DotContent
extends Object

## The one place the family asks for downloadable content.
##
## [b]Every addon that lets a developer deliver something declares a `content_id`, and
## until this existed only one of them ever fetched one.[/b] dot-map wrote its own
## twenty lines against a duck-typed cloud client; dot-user-avatar, dot-props, dot-npc,
## dot-vehicle and dot-loadout each declared the id, serialised it onto the wire, and
## resolved it against content that nothing had ever downloaded. A part, prop, NPC,
## vehicle or item naming content therefore fell back forever, and the fallback is
## working-as-designed — so nothing errored, nothing warned, and no suite could see it.
##
## That failure has already happened once in this family with the ends one step further
## apart: dot-map called [code]ensure()[/code] and [code]is_mounted()[/code] from the day
## it was written while dot-cloud offered [code]acquire()[/code] and [code]is_ready()[/code],
## so every delivered map failed with "does not speak the content interface" and the only
## test covering it ran with no cloud client at all — the branch that falls back to the
## disk and passes. One shared caller is how that stops being a per-addon accident.
##
## [b]dot-cloud is not imported and must not be.[/b] It is found through [DotRegistry]
## under [constant SERVICE] and duck-typed, so an addon that uses this gains no
## dependency on it: a deployment with no dot-cloud installed keeps working, because
## content that is not delivered ships in the build.
##
## [b]The interface, spelled out, because both ends of it are duck-typed:[/b]
## [codeblock]
## ensure(content_id, version, groups, manifest_url) -> DotResult
## resolve(content_id) -> String
## is_mounted(content_id, version) -> bool
## [/codeblock]
## [method ensure] is idempotent — content already mounted returns without touching the
## network — which is what lets a resolve-miss call it without any bookkeeping here.
##
## Static, and therefore no signals and no state: everything worth remembering is the
## cloud client's, and a second copy of it here is a second thing to keep in step. See
## [DotLogBus] for why a static class that needed a signal would have to be something
## else.

## Registry name dot-cloud publishes itself under.
const SERVICE := &"dot_cloud_client"

const CHANNEL := "dot.content"


## The cloud client, or null when this deployment has none.
##
## [b]Null is a normal answer.[/b] A build that ships all of its content installs no
## cloud client, and that is a supported deployment rather than a broken one.
static func client() -> Object:
	return DotRegistry.get_service(SERVICE)


## Whether anything here can actually fetch.
static func available() -> bool:
	var cloud := client()
	return cloud != null and cloud.has_method("ensure")


## Download, verify and mount [param content_id] unless it is already there.
##
## Returns a [DotResult] whose value is the mount prefix or the entry path the manifest
## named — whichever the client gave — and which is a SUCCESS carrying [code]false[/code]
## when there is no cloud client at all. Those are deliberately not the same: "there is
## nothing to fetch with, so assume it is in the build" is the ordinary case for a build
## that ships its content, and reporting it as a failure would make every such
## deployment log an error about a file it has.
##
## A client that is installed but does not speak the interface IS a failure, because
## that one is a configuration mistake nobody can see from the outside.
static func ensure(
	content_id: StringName,
	version: String = "",
	groups: PackedStringArray = PackedStringArray(),
	manifest_url: String = ""
) -> DotResult:
	if content_id == &"":
		return DotResult.fail(DotError.CODE_INVALID, "No content id to ensure.")

	var cloud := client()

	if cloud == null:
		DotLog.debug(CHANNEL, "no cloud client; assuming it ships in the build", {
			"content": String(content_id)
		})
		return DotResult.success(false)

	if not cloud.has_method("ensure"):
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"The registered cloud client does not speak the content interface.",
			"no ensure() on %s, registered as %s" % [cloud.get_class(), String(SERVICE)]
		)

	DotLog.info(CHANNEL, "fetching content", {
		"content": String(content_id),
		"version": version if version != "" else "(default)",
		"url": manifest_url if manifest_url != "" else "(derived)",
	})

	var got: Variant = await cloud.call(
		"ensure", content_id, version, groups, manifest_url
	)

	if got is DotResult:
		return got

	# A client that answered with something else is a configuration error rather than a
	# fetch failure, and saying which is what makes it findable.
	return DotResult.fail(
		DotError.CODE_INTERNAL,
		"The cloud client returned something that is not a DotResult.",
		str(got)
	)


## Fetch every id in [param content_ids], and report what did not arrive.
##
## [b]One failure does not stop the others, and none of them fails the call.[/b] A
## catalogue is a list an operator maintains, and one pack that will not download is a
## prop that cannot spawn or a cosmetic that draws its fallback — not a reason to refuse
## to start. The caller gets a count and the ids that failed, so a server can log them
## once at boot instead of discovering each one when a player asks for it.
##
## Returns a success carrying
## [code]{wanted, fetched, failed: PackedStringArray}[/code]. Duplicates are collapsed:
## a catalogue with forty props in one pack fetches one pack.
static func ensure_all(content_ids: PackedStringArray) -> DotResult:
	var wanted := PackedStringArray()

	for raw in content_ids:
		var id := String(raw).strip_edges()

		if id != "" and not wanted.has(id):
			wanted.append(id)

	var failed := PackedStringArray()
	var fetched := 0

	for id in wanted:
		var res := await ensure(StringName(id))

		if res.ok:
			fetched += 1
		else:
			failed.append(id)
			DotLog.warn(CHANNEL, "content did not arrive", {
				"content": id,
				"code": res.error.code if res.error != null else "",
				"message": res.error.message if res.error != null else "",
			})

	if not failed.is_empty():
		DotLog.warn(CHANNEL, "some content did not arrive", {
			"wanted": wanted.size(), "failed": failed.size(),
		})

	return DotResult.success({
		"wanted": wanted.size(), "fetched": fetched, "failed": failed,
	})


## Where mounted content lives, or "" when it is not mounted.
##
## Does not fetch. This is the cheap synchronous question a catalogue asks while it is
## drawing; [method ensure] is the expensive one it asks once.
static func resolve(content_id: StringName) -> String:
	if content_id == &"":
		return ""

	var cloud := client()

	if cloud == null or not cloud.has_method("resolve"):
		return ""

	var got: Variant = cloud.call("resolve", content_id)

	return str(got) if got != null else ""
