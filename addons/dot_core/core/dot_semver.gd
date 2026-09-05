class_name DotSemVer
extends RefCounted

## Semantic version parsing and comparison.
##
## Needed in three places that all have the same failure mode if they guess:
## dot-cloud refusing content built for a newer manifest format, dot-server
## refusing a client with an incompatible protocol, and dot-auth refusing an API
## version it does not understand. Comparing version strings lexically makes
## [code]"0.10.0" < "0.9.0"[/code], which is how a client that should have been
## refused gets let in.

var major: int = 0
var minor: int = 0
var patch: int = 0

## Pre-release identifier, e.g. [code]"rc.1"[/code]. Empty for a release.
var prerelease: String = ""

## Build metadata after [code]+[/code]. Ignored in comparisons, per semver.
var build: String = ""

var valid: bool = false


static func parse(s: String) -> DotSemVer:
	var v := DotSemVer.new()

	var t := s.strip_edges()
	if t.begins_with("v"):
		t = t.substr(1)

	if t.contains("+"):
		var bparts := t.split("+", true, 1)
		t = bparts[0]
		v.build = bparts[1]

	if t.contains("-"):
		var pparts := t.split("-", true, 1)
		t = pparts[0]
		v.prerelease = pparts[1]

	var nums := t.split(".")
	if nums.size() == 0 or not nums[0].is_valid_int():
		return v

	v.major = nums[0].to_int()
	if nums.size() > 1 and nums[1].is_valid_int():
		v.minor = nums[1].to_int()
	if nums.size() > 2 and nums[2].is_valid_int():
		v.patch = nums[2].to_int()

	v.valid = true
	return v


static func from_parts(
	p_major: int,
	p_minor: int = 0,
	p_patch: int = 0
) -> DotSemVer:
	var v := DotSemVer.new()
	v.major = p_major
	v.minor = p_minor
	v.patch = p_patch
	v.valid = true
	return v


## The engine's own version, for content that declares a minimum.
static func engine() -> DotSemVer:
	var info := Engine.get_version_info()
	return from_parts(
		int(info["major"]), int(info["minor"]), int(info["patch"])
	)


## -1, 0 or 1. Build metadata is ignored; a pre-release sorts below its release.
func compare(other: DotSemVer) -> int:
	if major != other.major:
		return -1 if major < other.major else 1
	if minor != other.minor:
		return -1 if minor < other.minor else 1
	if patch != other.patch:
		return -1 if patch < other.patch else 1

	# 1.0.0-rc.1 precedes 1.0.0. An absent pre-release is the higher version,
	# which is the opposite of what a naive string compare gives.
	if prerelease == "" and other.prerelease == "":
		return 0
	if prerelease == "":
		return 1
	if other.prerelease == "":
		return -1

	if prerelease == other.prerelease:
		return 0
	return -1 if prerelease < other.prerelease else 1


func is_older_than(other: DotSemVer) -> bool:
	return compare(other) < 0


func is_newer_than(other: DotSemVer) -> bool:
	return compare(other) > 0


func equals(other: DotSemVer) -> bool:
	return compare(other) == 0


## Whether [param other] can consume content produced by this version.
##
## Caret semantics: same major, and [param other] at least as new. Below 1.0.0
## the minor acts as the major, because pre-1.0 projects break compatibility on
## minor bumps and pretending otherwise loads content that does not work.
func is_compatible_with(other: DotSemVer) -> bool:
	if major != other.major:
		return false
	if major == 0 and minor != other.minor:
		return false
	return compare(other) <= 0


func _to_string() -> String:
	var s := "%d.%d.%d" % [major, minor, patch]
	if prerelease != "":
		s += "-" + prerelease
	if build != "":
		s += "+" + build
	return s
