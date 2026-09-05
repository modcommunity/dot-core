@tool
extends EditorPlugin

## Editor entry point for dot-core.
##
## dot-core is deliberately autoload-free: every class here is either a static
## utility, a [Resource], or a [Node] you place yourself. That is what lets a
## consumer drop the addon into an existing project without inheriting a fixed
## scene-tree shape or a reserved global name.
##
## The plugin therefore registers custom types for the inspector and nothing
## else — enabling or disabling it never changes runtime behaviour of code that
## already references the classes by [code]class_name[/code].

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


func _exit_tree() -> void:
	remove_custom_type("DotLogSink")
	remove_custom_type("DotScheduler")
