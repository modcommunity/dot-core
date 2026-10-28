class_name DotContent
extends Object

## The one place the family asks for downloadable content.
##
## dot-cloud is found through [DotRegistry] under [constant SERVICE] and duck-typed, never
## imported: a build that ships its content installs no cloud client. Static, so no state;
## the client's [code]ensure/resolve/is_mounted[/code] interface is the cloud's to keep.

## Registry name dot-cloud publishes itself under.
const SERVICE := &"dot_cloud_client"

const CHANNEL := "dot.content"


## The cloud client, or null when this deployment has none; null is a supported answer.
static func client() -> Object:
	return DotRegistry.get_service(SERVICE)


## Whether anything here can actually fetch.
static func available() -> bool:
	var cloud := client()
	return cloud != null and cloud.has_method("ensure")


## Download, verify and mount [param content_id] unless it is already there. With no cloud
## client this SUCCEEDS carrying false (assume it is in the build); a client that does not
## speak the interface is a failure, because that is a configuration mistake.
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


## Fetch every id in [param content_ids]; one failure neither stops the others nor fails the
## call. Returns [code]{wanted, fetched, failed: PackedStringArray}[/code] so a server logs
## failures once at boot. Duplicates are collapsed.
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


## Where mounted content lives, or "" when it is not mounted. Does not fetch.
static func resolve(content_id: StringName) -> String:
	if content_id == &"":
		return ""

	var cloud := client()

	if cloud == null or not cloud.has_method("resolve"):
		return ""

	var got: Variant = cloud.call("resolve", content_id)

	return str(got) if got != null else ""
