extends RefCounted

## dot-core's API level. The rule for bumping it is on [DotAddonApi].
##
## LEVEL rises by one for anything a game could call that did not exist before. OLDEST is
## raised to LEVEL when something a game could have called is removed or changes meaning,
## because every pack built before that no longer compiles against this addon.

# 2: DotTransportDual, DotDualPeer, DotUdpDemux (WebSocket + ENet in one server).
# 3: DotMeteredPeer (any MultiplayerPeer, counted per channel; what net_stat draws).
# 4: DotAddonApi.FLOOR_FILE, apply_floors, floor_audit, guarded, and parse's file_name
#    (a game asking less of an addon whose newer API it guards).
# 5: camera/: DotCameraProbe, DotCameraBoom, DotCameraFade (cameras that stay out of the
#    level and fade the people between them and what they look at).
# 6: DotCollisionAudit (visible level geometry nothing collides with; `dot_no_collision` opt-out).
# 7: DotTcpScreen, DotTransportDual.tls_hello_screen / TlsHelloScreen / is_loopback_bind,
#    DotDualPeer.screen (a TLS ClientHello at a plain WebSocket listener closed at once).
# 8: DotRenderWarmup (draws a scene's materials once, out of sight, so shaders compile under a cover).
# 9: DotContentIndex, DotContentEntry (what mounted packs provide, tagged by session: solo or online).
# 10: loading/: DotLoadGate, DotLoadingCover (the game is not ready to be seen yet: holds,
#     requirements, frozen nodes, a cover a host can claim).
# 11: DotParallel (a fork/join on the worker pool that returns inside the tick: pure tasks,
#     results in index order, a verify mode that runs them twice).
# 12: DotYaml (the YAML subset reader), DotRotationSpec (maps.yml / games.yml: rotations,
#     wildcards, layering, `commands:`), DotCommandNames (renames, aliases, collision skip).
# 13: DotAddonConfig (cfg/addons/<name>/*.yml: every file read in name order over defaults,
#     then environment, then command line).
# 14: DotHttpServer, DotHttpRequest, DotHttpResponse (net/: a small HTTP/1.1 server, desktop and server only).
# 15: DotCfgLegacy (old cfg path read through a warn-once shim until 2026-12-31),
#     DotAddonConfig.folder_name / file_layers and the cfg/server/<addon>/ operator tier;
#     an addon name's `-` is now `_` in its cfg/addons folder.
# 16: DotAddonConfig.apply_file (one named yml through the addon, server and legacy layers, applied by the caller).
# 17: DotAddonConfig.merge (public), config_root, DotAddonConfig.game and the cfg/game/<game>/<addon>/ tier; the operator
#     tier is now cfg/server/addons/<addon>/ (the old cfg/server/<addon>/ is read through DotCfgLegacy: old paths are
#     read-only compat, which is why OLDEST stays 1). Also in 17: DotAddonConfig.replace_aware_layers; DotProfileSet reads
#     tier first (schema < addon < game < server legacy < server/addons < server/game, roots res then user);
#     DotProfileRuntime saves to <root>/server/game/<game>/ or server/addons/<addon>/ (server/<kind>/ with neither).
# 18: DotAddonConfig user tier (cfg/user/addons/<addon>/ in user://, solo and listen host only): set_user_tier,
#     user_tier_enabled, user_file, user_paths, save_user, reset_user; DotProfileSet.set_user_tier switches both.
# 19: DotAddonConfig.tier_dirs and apply_overrides (public; DotMapConfig no longer calls the private ones).
# 20: DotHttp max_bytes on get_bytes, request and download_to_file (a per-call body_size_limit).
# 21: cfg directory names are singular (cfg/addon/, cfg/game/, cfg/server/addon/, cfg/server/game/, user/addon/);
#     the plural names are read through DotCfgLegacy until 2026-12-31, the singular file winning whole.
# 22: the profile classes (DotProfileSet, DotProfile, DotProfileRuntime, tools/profile_check.gd) moved to the dot-profile
#     addon, class names unchanged: a project that used them now needs dot-profile (same class names, so OLDEST stays 1).
#     New here for it: DotYaml.emit, DotAddonConfig.set_nested, is_finite_value and check_field (the schema check
#     save_user uses). DotAddonConfig.set_user_tier no longer touches DotProfileSet; that set reads the same flag.
# 23: DotCollisionSweep (drawn floor and walls against the physics world, and collision nothing is drawn at).
# 24: DotAddonApi.USES_FILE and declared_uses: derive() counts addons a project names in requires.uses.json
#     (use through config only), so a floor on them is not refused as "does not use".
# 25: camera/: DotViewLens (the first-person model lens maths: vertical_from_horizontal_4_3, lens_scale, apply).
const LEVEL := 25
const OLDEST := 1
