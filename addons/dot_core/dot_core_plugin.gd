@tool
extends EditorPlugin

## Editor entry point for dot-core. The addon is autoload-free (static utilities, [Resource]s and [Node]s you place yourself),
## so the plugin only registers inspector custom types: enabling or disabling it never changes runtime behaviour.

const _ICON := "res://addons/dot_core/icon_placeholder.svg"


func _enter_tree() -> void:
	# Custom types are a convenience for the "Add Node" dialog. The scripts are
	# globally available via class_name regardless, so we tolerate a missing
	# icon rather than hard-failing the plugin load.
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	add_custom_type(
		"DotScheduler",
		"Node",
		load("res://addons/dot_core/core/dot_scheduler.gd"),
		icon
	)
	add_custom_type(
		"DotLogSink",
		"Node",
		load("res://addons/dot_core/core/dot_log_sink.gd"),
		icon
	)

	# A manager is placed by the host, never autoloaded: a server's streams and a client's cosmetic
	# ones are two managers in one process with different seeds.
	add_custom_type(
		"DotRandomManager",
		"Node",
		load("res://addons/dot_core/random/dot_random_manager.gd"),
		icon
	)


func _exit_tree() -> void:
	remove_custom_type("DotRandomManager")
	remove_custom_type("DotLogSink")
	remove_custom_type("DotScheduler")
